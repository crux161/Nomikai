use crate::frb_generated::StreamSink;
use anyhow::{anyhow, bail, Context};
use flutter_rust_bridge::frb;
use sankaku_core::{KyuEvent as SankakuEvent, SankakuReceiver, SankakuSender, VideoFrame};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::task::spawn_blocking;

type HevcFrameTx = UnboundedSender<(Vec<u8>, bool, u64)>;
type AudioFrameTx = UnboundedSender<(Vec<u8>, u64)>;

/// Sankaku protocol defaults. Dart currently passes bind/dial addresses explicitly,
/// but keeping the canonical port here prevents drift across layers.
pub const DEFAULT_SANKAKU_UDP_PORT: u16 = 9292;
pub const DEFAULT_SANKAKU_RECEIVER_BIND_HOST: &str = "0.0.0.0";

static HEVC_FRAME_TX: OnceLock<Mutex<Option<HevcFrameTx>>> = OnceLock::new();
static AUDIO_FRAME_TX: OnceLock<Mutex<Option<AudioFrameTx>>> = OnceLock::new();
static SENDER_SHOULD_RUN: AtomicBool = AtomicBool::new(false);
static RECEIVER_SHOULD_RUN: AtomicBool = AtomicBool::new(false);

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    sankaku_core::init();
}

/// A Dart-friendly mapping of Sankaku transport events/state.
#[derive(Clone)]
pub enum UiEvent {
    Log {
        msg: String,
    },
    ConnectionState {
        state: String,
        detail: String,
    },
    HandshakeInitiated,
    HandshakeComplete {
        session_id: u64,
        bootstrap_mode: String,
    },
    Progress {
        stream_id: u32,
        frame_index: u64,
        bytes: u64,
        frames: u64,
    },
    Telemetry {
        name: String,
        value: u64,
    },
    FrameDrop {
        stream_id: u32,
        reason: String,
    },
    Fault {
        code: String,
        message: String,
    },
    BitrateChanged {
        bitrate_bps: u32,
    },
    VideoFrameReceived {
        data: Vec<u8>,
        pts: u64,
    },
    AudioFrameReceived {
        data: Vec<u8>,
        pts: u64,
    },
    Error {
        msg: String,
    },
}

impl From<SankakuEvent> for UiEvent {
    fn from(event: SankakuEvent) -> Self {
        match event {
            SankakuEvent::Log(msg) => UiEvent::Log { msg },
            SankakuEvent::HandshakeInitiated => UiEvent::HandshakeInitiated,
            SankakuEvent::HandshakeComplete => UiEvent::HandshakeComplete {
                session_id: 0,
                bootstrap_mode: "Unknown".to_string(),
            },
            SankakuEvent::Progress {
                stream_id,
                frame_index,
                bytes,
                frames,
            } => UiEvent::Progress {
                stream_id,
                frame_index,
                bytes,
                frames,
            },
            SankakuEvent::Fault { code, message, .. } => UiEvent::Fault {
                code: code.as_str().to_string(),
                message,
            },
        }
    }
}

fn sink_event(sink: &StreamSink<UiEvent>, event: UiEvent) {
    let _ = sink.add(event);
}

fn hevc_frame_tx_slot() -> &'static Mutex<Option<HevcFrameTx>> {
    HEVC_FRAME_TX.get_or_init(|| Mutex::new(None))
}

fn audio_frame_tx_slot() -> &'static Mutex<Option<AudioFrameTx>> {
    AUDIO_FRAME_TX.get_or_init(|| Mutex::new(None))
}

fn install_hevc_frame_tx(tx: HevcFrameTx) -> anyhow::Result<()> {
    let mut guard = hevc_frame_tx_slot()
        .lock()
        .map_err(|_| anyhow!("failed to lock HEVC frame sender slot"))?;
    if guard.is_some() {
        bail!("sender loop already running");
    }
    *guard = Some(tx);
    Ok(())
}

fn clear_hevc_frame_tx() {
    if let Ok(mut guard) = hevc_frame_tx_slot().lock() {
        *guard = None;
    }
}

fn install_audio_frame_tx(tx: AudioFrameTx) -> anyhow::Result<()> {
    let mut guard = audio_frame_tx_slot()
        .lock()
        .map_err(|_| anyhow!("failed to lock audio frame sender slot"))?;
    if guard.is_some() {
        bail!("sender loop already running");
    }
    *guard = Some(tx);
    Ok(())
}

fn clear_audio_frame_tx() {
    if let Ok(mut guard) = audio_frame_tx_slot().lock() {
        *guard = None;
    }
}

struct FrameIngressGuard;

impl Drop for FrameIngressGuard {
    fn drop(&mut self) {
        clear_hevc_frame_tx();
        clear_audio_frame_tx();
    }
}

struct SenderRunGuard;

impl Drop for SenderRunGuard {
    fn drop(&mut self) {
        SENDER_SHOULD_RUN.store(false, Ordering::Relaxed);
    }
}

struct ReceiverRunGuard;

impl Drop for ReceiverRunGuard {
    fn drop(&mut self) {
        RECEIVER_SHOULD_RUN.store(false, Ordering::Relaxed);
    }
}

async fn send_sender_frame(
    sink: &StreamSink<UiEvent>,
    sender: &mut SankakuSender,
    stream_id: u32,
    payload: Vec<u8>,
    is_keyframe: bool,
    pts: u64,
    dest: &str,
    handshake_announced: &mut bool,
) -> anyhow::Result<()> {
    let payload_len = payload.len() as u64;
    let frame = VideoFrame::nal(payload, pts, is_keyframe);
    match sender.send_frame(stream_id, frame).await {
        Ok(frame_index) => {
            println!(
                "DEBUG: Sankaku sender sent VIDEO packet: stream_id={} frame_index={} bytes={} keyframe={} dest={}",
                stream_id, frame_index, payload_len, is_keyframe, dest
            );
            if !*handshake_announced {
                *handshake_announced = true;
                let session_id = sender.session_id().unwrap_or_default();
                sink_event(
                    sink,
                    UiEvent::HandshakeComplete {
                        session_id,
                        bootstrap_mode: format!("{:?}", sender.bootstrap_mode()),
                    },
                );
                sink_event(
                    sink,
                    UiEvent::ConnectionState {
                        state: "connected".to_string(),
                        detail: format!("session={session_id} dest={dest}"),
                    },
                );
            }

            sink_event(
                sink,
                UiEvent::Progress {
                    stream_id,
                    frame_index,
                    bytes: payload_len,
                    frames: frame_index.saturating_add(1),
                },
            );

            if let Some(redundancy) = sender.stream_redundancy(stream_id) {
                sink_event(
                    sink,
                    UiEvent::Telemetry {
                        name: "redundancy_ppm".to_string(),
                        value: (redundancy * 1_000_000.0) as u64,
                    },
                );
            }
            if let Some(bitrate_bps) = sender.take_bitrate_update_bps() {
                sink_event(sink, UiEvent::BitrateChanged { bitrate_bps });
            }
            Ok(())
        }
        Err(error) => {
            let message = error.to_string();
            sink_event(
                sink,
                UiEvent::FrameDrop {
                    stream_id,
                    reason: message.clone(),
                },
            );
            sink_event(
                sink,
                UiEvent::ConnectionState {
                    state: "stopped".to_string(),
                    detail: message.clone(),
                },
            );
            sink_event(sink, UiEvent::Error { msg: message });
            Err(error)
        }
    }
}

pub fn push_hevc_frame(frame_bytes: Vec<u8>, is_keyframe: bool, pts: u64) -> anyhow::Result<()> {
    let frame_len = frame_bytes.len();
    println!(
        "DEBUG: Rust received HEVC frame from Dart: {} bytes (keyframe={}, pts_us={})",
        frame_len, is_keyframe, pts
    );
    let tx = {
        let guard = hevc_frame_tx_slot()
            .lock()
            .map_err(|_| anyhow!("failed to lock HEVC frame sender slot"))?;
        guard
            .clone()
            .context("sender is not active; call start_sankaku_sender first")?
    };
    tx.send((frame_bytes, is_keyframe, pts))
        .map_err(|_| anyhow!("sender frame ingress channel is closed"))?;
    Ok(())
}

pub fn push_audio_frame(frame_bytes: Vec<u8>, pts: u64) -> anyhow::Result<()> {
    let frame_len = frame_bytes.len();
    println!(
        "DEBUG: Rust received AUDIO frame from Dart: {} bytes (pts_us={})",
        frame_len, pts
    );
    let tx = {
        let guard = audio_frame_tx_slot()
            .lock()
            .map_err(|_| anyhow!("failed to lock audio frame sender slot"))?;
        guard
            .clone()
            .context("sender is not active; call start_sankaku_sender first")?
    };
    tx.send((frame_bytes, pts))
        .map_err(|_| anyhow!("sender audio ingress channel is closed"))?;
    Ok(())
}

pub fn stop_sankaku_sender() -> anyhow::Result<()> {
    SENDER_SHOULD_RUN.store(false, Ordering::Relaxed);
    clear_hevc_frame_tx();
    clear_audio_frame_tx();
    Ok(())
}

pub fn stop_sankaku_receiver() -> anyhow::Result<()> {
    RECEIVER_SHOULD_RUN.store(false, Ordering::Relaxed);
    Ok(())
}

async fn run_sender_loop(
    sink: StreamSink<UiEvent>,
    dest: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "starting".to_string(),
            detail: format!("dialing {dest}"),
        },
    );

    let mut sender = SankakuSender::new(&dest).await?;
    sender.update_compression_graph(&graph_bytes)?;
    let local_addr = sender.local_addr()?;

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "socket_ready".to_string(),
            detail: format!("local={local_addr}"),
        },
    );
    sink_event(&sink, UiEvent::HandshakeInitiated);

    let video_stream_id = sender.open_stream()?;
    let audio_stream_id = sender.open_stream()?;
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "stream_id".to_string(),
            value: video_stream_id as u64,
        },
    );
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "audio_stream_id".to_string(),
            value: audio_stream_id as u64,
        },
    );
    sink_event(
        &sink,
        UiEvent::BitrateChanged {
            bitrate_bps: sender.target_bitrate_bps(),
        },
    );
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "graph_bytes".to_string(),
            value: graph_bytes.len() as u64,
        },
    );

    let (frame_tx, mut frame_rx) = mpsc::unbounded_channel::<(Vec<u8>, bool, u64)>();
    let (audio_tx, mut audio_rx) = mpsc::unbounded_channel::<(Vec<u8>, u64)>();
    install_hevc_frame_tx(frame_tx)?;
    install_audio_frame_tx(audio_tx)?;
    let _frame_ingress_guard = FrameIngressGuard;

    let mut handshake_announced = false;
    let mut sent_packets: u64 = 0;
    SENDER_SHOULD_RUN.store(true, Ordering::Relaxed);
    let _sender_run_guard = SenderRunGuard;

    loop {
        tokio::select! {
            Some((frame_bytes, is_keyframe, pts)) = frame_rx.recv() => {
                if frame_bytes.is_empty() {
                    continue;
                }
                send_sender_frame(
                    &sink,
                    &mut sender,
                    video_stream_id,
                    frame_bytes,
                    is_keyframe,
                    pts,
                    &dest,
                    &mut handshake_announced,
                ).await?;
                sent_packets = sent_packets.saturating_add(1);
            }
            Some((audio_bytes, pts)) = audio_rx.recv() => {
                if audio_bytes.is_empty() {
                    continue;
                }

                let audio_len = audio_bytes.len();
                match sender.send_audio_frame(audio_stream_id, pts, audio_bytes).await {
                    Ok(_) => {
                        println!(
                            "DEBUG: Sankaku sender sent AUDIO packet: stream_id={} bytes={} pts_us={} dest={}",
                            audio_stream_id, audio_len, pts, dest
                        );
                        sent_packets = sent_packets.saturating_add(1);
                    }
                    Err(error) => {
                        sink_event(
                            &sink,
                            UiEvent::Error {
                                msg: format!("audio send failed: {error}"),
                            },
                        );
                    }
                }
            }
            else => {
                let detail = if SENDER_SHOULD_RUN.load(Ordering::Relaxed) {
                    "sender ingress channels closed".to_string()
                } else {
                    "sender stop requested".to_string()
                };
                sink_event(
                    &sink,
                    UiEvent::ConnectionState {
                        state: "stopped".to_string(),
                        detail,
                    },
                );
                break;
            }
        }

        if sent_packets > 0 && sent_packets.is_multiple_of(100) {
            println!("Sender heartbeat: sent {} packets...", sent_packets);
        }
    }

    Ok(())
}

async fn run_receiver_loop(
    sink: StreamSink<UiEvent>,
    bind_addr: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    RECEIVER_SHOULD_RUN.store(true, Ordering::Relaxed);
    let _receiver_run_guard = ReceiverRunGuard;

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "starting".to_string(),
            detail: format!("binding {bind_addr}"),
        },
    );

    let mut receiver = SankakuReceiver::new(&bind_addr).await?;
    receiver.update_compression_graph(&graph_bytes)?;
    let local_addr = receiver.local_addr()?;

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "listening".to_string(),
            detail: format!("local={local_addr}"),
        },
    );
    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "awaiting_peer".to_string(),
            detail: "waiting for inbound Sankaku frames".to_string(),
        },
    );
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "graph_bytes".to_string(),
            value: graph_bytes.len() as u64,
        },
    );

    let (mut inbound_video, mut inbound_audio) = receiver.spawn_media_channels();
    let mut handshake_announced = false;
    let mut shutdown_tick = tokio::time::interval(Duration::from_millis(200));
    shutdown_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let stop_detail = loop {
        if !RECEIVER_SHOULD_RUN.load(Ordering::Relaxed) {
            break "receiver stop requested".to_string();
        }

        tokio::select! {
            biased;
            _ = shutdown_tick.tick() => {
                if !RECEIVER_SHOULD_RUN.load(Ordering::Relaxed) {
                    break "receiver stop requested".to_string();
                }
            }
            maybe_video = inbound_video.recv() => {
                let Some(frame) = maybe_video else {
                    break "receiver video channel closed".to_string();
                };
                let session_id = frame.session_id;
                let stream_id = frame.stream_id;
                let frame_index = frame.frame_index;
                let keyframe = frame.keyframe;
                let payload = frame.payload;
                let payload_len = payload.len() as u64;

                if !handshake_announced {
                    handshake_announced = true;
                    sink_event(&sink, UiEvent::HandshakeInitiated);
                    sink_event(
                        &sink,
                        UiEvent::HandshakeComplete {
                            session_id,
                            bootstrap_mode: "Receiver".to_string(),
                        },
                    );
                    sink_event(
                        &sink,
                        UiEvent::ConnectionState {
                            state: "connected".to_string(),
                            detail: format!("session={session_id} stream={stream_id}"),
                        },
                    );
                }

                sink_event(
                    &sink,
                    UiEvent::VideoFrameReceived {
                        data: payload,
                        pts: frame.timestamp_us,
                    },
                );
                sink_event(
                    &sink,
                    UiEvent::Progress {
                        stream_id,
                        frame_index,
                        bytes: payload_len,
                        frames: frame_index.saturating_add(1),
                    },
                );
                sink_event(
                    &sink,
                    UiEvent::Telemetry {
                        name: "keyframe".to_string(),
                        value: if keyframe { 1 } else { 0 },
                    },
                );
                sink_event(
                    &sink,
                    UiEvent::Telemetry {
                        name: "packet_loss_ppm".to_string(),
                        value: (frame.packet_loss_ratio.clamp(0.0, 1.0) * 1_000_000.0) as u64,
                    },
                );
            }
            maybe_audio = inbound_audio.recv() => {
                let Some(frame) = maybe_audio else {
                    break "receiver audio channel closed".to_string();
                };

                if !handshake_announced {
                    handshake_announced = true;
                    sink_event(&sink, UiEvent::HandshakeInitiated);
                    sink_event(
                        &sink,
                        UiEvent::HandshakeComplete {
                            session_id: frame.session_id,
                            bootstrap_mode: "Receiver".to_string(),
                        },
                    );
                    sink_event(
                        &sink,
                        UiEvent::ConnectionState {
                            state: "connected".to_string(),
                            detail: format!("session={} stream={}", frame.session_id, frame.stream_id),
                        },
                    );
                }

                sink_event(
                    &sink,
                    UiEvent::AudioFrameReceived {
                        data: frame.payload,
                        pts: frame.timestamp_us,
                    },
                );
            }
        }
    };

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "stopped".to_string(),
            detail: stop_detail,
        },
    );

    Ok(())
}

/// Starts an async Sankaku sender loop and streams transport state/events to Dart.
pub async fn start_sankaku_sender(
    sink: StreamSink<UiEvent>,
    dest: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    spawn_blocking(move || -> anyhow::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to build sender runtime")?;
        runtime.block_on(run_sender_loop(sink, dest, graph_bytes))
    })
    .await
    .context("sender task join failed")?
}

/// Starts an async Sankaku receiver loop and streams transport state/events to Dart.
pub async fn start_sankaku_receiver(
    sink: StreamSink<UiEvent>,
    bind_addr: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    spawn_blocking(move || -> anyhow::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to build receiver runtime")?;
        runtime.block_on(run_receiver_loop(sink, bind_addr, graph_bytes))
    })
    .await
    .context("receiver task join failed")?
}
