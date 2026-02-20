use crate::frb_generated::StreamSink;
use anyhow::{anyhow, bail, Context};
use flutter_rust_bridge::frb;
use sankaku_core::{
    parse_psk_hex, KyuEvent as SankakuEvent, SankakuReceiver, SankakuSender, VideoFrame,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::task::spawn_blocking;
use tokio::time::MissedTickBehavior;

type HevcFrameTx = UnboundedSender<(Vec<u8>, bool)>;

static HEVC_FRAME_TX: OnceLock<Mutex<Option<HevcFrameTx>>> = OnceLock::new();
static SENDER_SHOULD_RUN: AtomicBool = AtomicBool::new(false);

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
    VideoFrameReceived {
        data: Vec<u8>,
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

struct FrameIngressGuard;

impl Drop for FrameIngressGuard {
    fn drop(&mut self) {
        clear_hevc_frame_tx();
    }
}

struct SenderRunGuard;

impl Drop for SenderRunGuard {
    fn drop(&mut self) {
        SENDER_SHOULD_RUN.store(false, Ordering::Relaxed);
    }
}

fn unix_us_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

async fn send_sender_frame(
    sink: &StreamSink<UiEvent>,
    sender: &mut SankakuSender,
    stream_id: u32,
    payload: Vec<u8>,
    is_keyframe: bool,
    dest: &str,
    handshake_announced: &mut bool,
) -> anyhow::Result<()> {
    let payload_len = payload.len() as u64;
    let frame = VideoFrame::nal(payload, unix_us_now(), is_keyframe);
    match sender.send_frame(stream_id, frame).await {
        Ok(frame_index) => {
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

pub fn push_hevc_frame(frame_bytes: Vec<u8>, is_keyframe: bool) -> anyhow::Result<()> {
    let tx = {
        let guard = hevc_frame_tx_slot()
            .lock()
            .map_err(|_| anyhow!("failed to lock HEVC frame sender slot"))?;
        guard
            .clone()
            .context("sender is not active; call start_sankaku_sender first")?
    };
    tx.send((frame_bytes, is_keyframe))
        .map_err(|_| anyhow!("sender frame ingress channel is closed"))?;
    Ok(())
}

pub fn stop_sankaku_sender() -> anyhow::Result<()> {
    SENDER_SHOULD_RUN.store(false, Ordering::Relaxed);
    Ok(())
}

async fn run_sender_loop(
    sink: StreamSink<UiEvent>,
    dest: String,
    psk_hex: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "starting".to_string(),
            detail: format!("dialing {dest}"),
        },
    );

    let psk = parse_psk_hex(&psk_hex)?;
    let mut sender = SankakuSender::new_with_psk(&dest, psk).await?;
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

    let stream_id = sender.open_stream()?;
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "stream_id".to_string(),
            value: stream_id as u64,
        },
    );
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "graph_bytes".to_string(),
            value: graph_bytes.len() as u64,
        },
    );

    let (frame_tx, mut frame_rx) = mpsc::unbounded_channel::<(Vec<u8>, bool)>();
    install_hevc_frame_tx(frame_tx)?;
    let _frame_ingress_guard = FrameIngressGuard;

    let heartbeat_payload = vec![0x00, 0x00, 0x01, 0x65];
    let mut handshake_announced = false;
    let mut heartbeat = tokio::time::interval(Duration::from_millis(400));
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Skip);
    SENDER_SHOULD_RUN.store(true, Ordering::Relaxed);
    let _sender_run_guard = SenderRunGuard;

    loop {
        if !SENDER_SHOULD_RUN.load(Ordering::Relaxed) {
            sink_event(
                &sink,
                UiEvent::ConnectionState {
                    state: "stopped".to_string(),
                    detail: "sender stop requested".to_string(),
                },
            );
            return Ok(());
        }

        tokio::select! {
            maybe_frame = frame_rx.recv() => {
                let Some((frame_bytes, is_keyframe)) = maybe_frame else {
                    sink_event(
                        &sink,
                        UiEvent::ConnectionState {
                            state: "stopped".to_string(),
                            detail: "sender frame channel closed".to_string(),
                        },
                    );
                    return Ok(());
                };
                if frame_bytes.is_empty() {
                    continue;
                }
                send_sender_frame(
                    &sink,
                    &mut sender,
                    stream_id,
                    frame_bytes,
                    is_keyframe,
                    &dest,
                    &mut handshake_announced,
                ).await?;
            }
            _ = heartbeat.tick() => {
                send_sender_frame(
                    &sink,
                    &mut sender,
                    stream_id,
                    heartbeat_payload.clone(),
                    false,
                    &dest,
                    &mut handshake_announced,
                ).await?;
            }
        }
    }
}

async fn run_receiver_loop(
    sink: StreamSink<UiEvent>,
    bind_addr: String,
    psk_hex: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "starting".to_string(),
            detail: format!("binding {bind_addr}"),
        },
    );

    let psk = parse_psk_hex(&psk_hex)?;
    let mut receiver = SankakuReceiver::new_with_psk(&bind_addr, psk).await?;
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

    let mut inbound = receiver.spawn_frame_channel();
    let mut handshake_announced = false;

    while let Some(frame) = inbound.recv().await {
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

        sink_event(&sink, UiEvent::VideoFrameReceived { data: payload });
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
    }

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "stopped".to_string(),
            detail: "receiver channel closed".to_string(),
        },
    );

    Ok(())
}

/// Starts an async Sankaku sender loop and streams transport state/events to Dart.
pub async fn start_sankaku_sender(
    sink: StreamSink<UiEvent>,
    dest: String,
    psk_hex: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    spawn_blocking(move || -> anyhow::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to build sender runtime")?;
        runtime.block_on(run_sender_loop(sink, dest, psk_hex, graph_bytes))
    })
    .await
    .context("sender task join failed")?
}

/// Starts an async Sankaku receiver loop and streams transport state/events to Dart.
pub async fn start_sankaku_receiver(
    sink: StreamSink<UiEvent>,
    bind_addr: String,
    psk_hex: String,
    graph_bytes: Vec<u8>,
) -> anyhow::Result<()> {
    spawn_blocking(move || -> anyhow::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to build receiver runtime")?;
        runtime.block_on(run_receiver_loop(sink, bind_addr, psk_hex, graph_bytes))
    })
    .await
    .context("receiver task join failed")?
}
