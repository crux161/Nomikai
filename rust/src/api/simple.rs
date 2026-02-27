use crate::frb_generated::StreamSink;
use anyhow::{anyhow, bail, Context};
use flutter_rust_bridge::frb;
use sankaku_core::{
    KyuEvent as SankakuEvent, SankakuReceiver, SankakuSender, StreamType, VideoFrame,
    AUDIO_CODEC_DEBUG_TEXT, AUDIO_CODEC_OPUS, VIDEO_CODEC_HEVC,
};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::task::spawn_blocking;

type HevcFrameTx = UnboundedSender<(Vec<u8>, bool, u64, u8)>;
type AudioFrameTx = UnboundedSender<(Vec<u8>, u64, u8, u32)>;

/// Sankaku protocol defaults. Dart currently passes bind/dial addresses explicitly,
/// but keeping the canonical port here prevents drift across layers.
pub const DEFAULT_SANKAKU_UDP_PORT: u16 = 9292;
pub const DEFAULT_SANKAKU_RECEIVER_BIND_HOST: &str = "[::]";

static HEVC_FRAME_TX: OnceLock<Mutex<Option<HevcFrameTx>>> = OnceLock::new();
static AUDIO_FRAME_TX: OnceLock<Mutex<Option<AudioFrameTx>>> = OnceLock::new();
static SENDER_SHOULD_RUN: AtomicBool = AtomicBool::new(false);
static RECEIVER_SHOULD_RUN: AtomicBool = AtomicBool::new(false);

#[derive(Debug)]
struct SkipServerVerification;

impl SkipServerVerification {
    fn new() -> Arc<Self> {
        Arc::new(Self)
    }
}

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
            rustls::SignatureScheme::ML_DSA_44,
            rustls::SignatureScheme::ML_DSA_65,
            rustls::SignatureScheme::ML_DSA_87,
        ]
    }
}

fn make_server_endpoint(bind_addr: &str) -> anyhow::Result<quinn::Endpoint> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let bind_addr: SocketAddr = bind_addr
        .parse()
        .with_context(|| format!("invalid bind address: {bind_addr}"))?;

    let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_string()])
        .context("failed to generate self-signed QUIC certificate")?;
    let cert_der = rustls::pki_types::CertificateDer::from(
        cert.serialize_der()
            .context("failed to serialize QUIC certificate")?,
    );
    let key_der = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.serialize_private_key_der());

    let mut server_crypto = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key_der.into())
        .context("failed to build QUIC rustls server config")?;
    server_crypto.alpn_protocols = vec![b"sankaku-rt".to_vec()];
    let server_config = quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto)
            .context("failed to build QUIC server crypto config")?,
    ));

    quinn::Endpoint::server(server_config, bind_addr)
        .context("failed to bind QUIC server endpoint")
}

fn make_client_endpoint() -> anyhow::Result<quinn::Endpoint> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let bind_addr: SocketAddr = "[::]:0"
        .parse()
        .context("failed to parse QUIC client bind address")?;
    let mut client_crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(SkipServerVerification::new())
        .with_no_client_auth();
    client_crypto.alpn_protocols = vec![b"sankaku-rt".to_vec()];
    let client_config = quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(client_crypto)
            .context("failed to build QUIC client crypto config")?,
    ));

    let mut endpoint =
        quinn::Endpoint::client(bind_addr).context("failed to bind QUIC client endpoint")?;
    endpoint.set_default_client_config(client_config);
    Ok(endpoint)
}

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
        frames_per_packet: u32,
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

fn emit_quic_network_telemetry(
    sink: &StreamSink<UiEvent>,
    stats: quinn::ConnectionStats,
) {
    let rtt_ms = stats.path.rtt.as_millis().min(u128::from(u64::MAX)) as u64;
    sink_event(
        sink,
        UiEvent::Telemetry {
            name: "path.rtt".to_string(),
            value: rtt_ms,
        },
    );
    sink_event(
        sink,
        UiEvent::Telemetry {
            name: "udp_tx.dropped".to_string(),
            value: stats.path.lost_packets as u64,
        },
    );
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

const DEBUG_REPORT_MAGIC: &[u8; 4] = b"NRPT";
const DEBUG_REPORT_PROTOCOL_VERSION: u8 = 1;
const DEBUG_REPORT_PACKET_BEGIN: u8 = 0x01;
const DEBUG_REPORT_PACKET_CHUNK: u8 = 0x02;
const DEBUG_REPORT_PACKET_END: u8 = 0x03;

struct RemoteDebugReportAssembly {
    report_id: u32,
    filename: String,
    total_chunks: u32,
    expected_bytes: u32,
    chunks: BTreeMap<u32, Vec<u8>>,
}

fn parse_u16_le(bytes: &[u8]) -> Option<u16> {
    let array: [u8; 2] = bytes.get(..2)?.try_into().ok()?;
    Some(u16::from_le_bytes(array))
}

fn parse_u32_le(bytes: &[u8]) -> Option<u32> {
    let array: [u8; 4] = bytes.get(..4)?.try_into().ok()?;
    Some(u32::from_le_bytes(array))
}

fn emit_remote_report_text_lines(sink: &StreamSink<UiEvent>, payload: &[u8]) {
    let text = String::from_utf8_lossy(payload);
    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        sink_event(
            sink,
            UiEvent::Log {
                msg: format!("[RemoteReport] {line}"),
            },
        );
    }
    if text.ends_with('\n') {
        sink_event(
            sink,
            UiEvent::Log {
                msg: "[RemoteReport] <blank line>".to_string(),
            },
        );
    }
}

fn sanitize_debug_report_filename(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_');
    if trimmed.is_empty() {
        "nomikai_sender_report.log".to_string()
    } else {
        trimmed.to_string()
    }
}

fn save_remote_debug_report_file(assembly: &RemoteDebugReportAssembly) -> anyhow::Result<String> {
    let mut data = Vec::new();
    if assembly.total_chunks > 0 {
        for seq in 0..assembly.total_chunks {
            let chunk = assembly
                .chunks
                .get(&seq)
                .with_context(|| format!("missing debug report chunk {seq}"))?;
            data.extend_from_slice(chunk);
        }
    }

    if assembly.expected_bytes != 0 && data.len() != assembly.expected_bytes as usize {
        bail!(
            "debug report byte length mismatch (expected={}, actual={})",
            assembly.expected_bytes,
            data.len()
        );
    }

    let cwd = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
    let mut reports_dir = cwd.join("remote_reports");
    if std::fs::create_dir_all(&reports_dir).is_err() {
        reports_dir = std::env::temp_dir().join("nomikai_remote_reports");
        std::fs::create_dir_all(&reports_dir)
            .context("failed to create remote debug report output dir")?;
    }

    let ts_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let mut filename = sanitize_debug_report_filename(&assembly.filename);
    if let Some((stem, ext)) = filename.rsplit_once('.') {
        filename = format!("{stem}_{ts_ms}.{ext}");
    } else {
        filename = format!("{filename}_{ts_ms}.log");
    }

    let path = reports_dir.join(filename);
    std::fs::write(&path, data).context("failed to write remote debug report file")?;
    Ok(path.display().to_string())
}

fn handle_remote_debug_report_payload(
    sink: &StreamSink<UiEvent>,
    payload: &[u8],
    assembly: &mut Option<RemoteDebugReportAssembly>,
) {
    if payload.len() < 6 || payload.get(..4) != Some(DEBUG_REPORT_MAGIC) {
        emit_remote_report_text_lines(sink, payload);
        sink_event(
            sink,
            UiEvent::Telemetry {
                name: "debug_report_bytes".to_string(),
                value: payload.len() as u64,
            },
        );
        return;
    }

    if payload.len() < 10 {
        sink_event(
            sink,
            UiEvent::Log {
                msg: "[RemoteReport] malformed packet: header too short".to_string(),
            },
        );
        return;
    }

    let version = payload[4];
    let packet_type = payload[5];
    let Some(report_id) = parse_u32_le(&payload[6..10]) else {
        sink_event(
            sink,
            UiEvent::Log {
                msg: "[RemoteReport] malformed packet: invalid report id".to_string(),
            },
        );
        return;
    };

    if version != DEBUG_REPORT_PROTOCOL_VERSION {
        sink_event(
            sink,
            UiEvent::Log {
                msg: format!(
                    "[RemoteReport] unsupported protocol version {} (expected {})",
                    version, DEBUG_REPORT_PROTOCOL_VERSION
                ),
            },
        );
        return;
    }

    match packet_type {
        DEBUG_REPORT_PACKET_BEGIN => {
            if payload.len() < 20 {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: "[RemoteReport] malformed BEGIN packet".to_string(),
                    },
                );
                return;
            }
            let Some(total_chunks) = parse_u32_le(&payload[10..14]) else {
                return;
            };
            let Some(expected_bytes) = parse_u32_le(&payload[14..18]) else {
                return;
            };
            let Some(filename_len) = parse_u16_le(&payload[18..20]) else {
                return;
            };
            let filename_end = 20usize.saturating_add(filename_len as usize);
            let Some(filename_bytes) = payload.get(20..filename_end) else {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: "[RemoteReport] malformed BEGIN packet filename".to_string(),
                    },
                );
                return;
            };
            let filename = String::from_utf8_lossy(filename_bytes).to_string();

            if let Some(existing) = assembly.take() {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] dropping incomplete report id={} while starting new report id={}",
                            existing.report_id, report_id
                        ),
                    },
                );
            }

            *assembly = Some(RemoteDebugReportAssembly {
                report_id,
                filename: if filename.is_empty() {
                    "nomikai_sender_report.log".to_string()
                } else {
                    filename
                },
                total_chunks,
                expected_bytes,
                chunks: BTreeMap::new(),
            });

            sink_event(
                sink,
                UiEvent::Log {
                    msg: format!(
                        "[RemoteReport] begin id={} file={} chunks={} bytes={}",
                        report_id,
                        assembly
                            .as_ref()
                            .map(|a| a.filename.as_str())
                            .unwrap_or("unknown"),
                        total_chunks,
                        expected_bytes
                    ),
                },
            );
        }
        DEBUG_REPORT_PACKET_CHUNK => {
            if payload.len() < 16 {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: "[RemoteReport] malformed CHUNK packet".to_string(),
                    },
                );
                return;
            }
            let Some(seq) = parse_u32_le(&payload[10..14]) else {
                return;
            };
            let Some(chunk_len) = parse_u16_le(&payload[14..16]) else {
                return;
            };
            let chunk_end = 16usize.saturating_add(chunk_len as usize);
            let Some(chunk_bytes) = payload.get(16..chunk_end) else {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!("[RemoteReport] malformed CHUNK packet seq={seq}"),
                    },
                );
                return;
            };

            let Some(active) = assembly.as_mut() else {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] dropped chunk seq={} for report id={} (no active report)",
                            seq, report_id
                        ),
                    },
                );
                return;
            };

            if active.report_id != report_id {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] dropped chunk seq={} for report id={} (active id={})",
                            seq, report_id, active.report_id
                        ),
                    },
                );
                return;
            }

            active.chunks.entry(seq).or_insert_with(|| chunk_bytes.to_vec());
            sink_event(
                sink,
                UiEvent::Telemetry {
                    name: "debug_report_bytes".to_string(),
                    value: chunk_bytes.len() as u64,
                },
            );
        }
        DEBUG_REPORT_PACKET_END => {
            if payload.len() < 18 {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: "[RemoteReport] malformed END packet".to_string(),
                    },
                );
                return;
            }
            let Some(total_chunks_sent) = parse_u32_le(&payload[10..14]) else {
                return;
            };
            let Some(total_bytes_sent) = parse_u32_le(&payload[14..18]) else {
                return;
            };

            let Some(active) = assembly.take() else {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] END received for report id={} with no active report",
                            report_id
                        ),
                    },
                );
                return;
            };

            if active.report_id != report_id {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] END report id mismatch active={} received={}",
                            active.report_id, report_id
                        ),
                    },
                );
                return;
            }

            let received_chunk_count = active.chunks.len() as u32;
            if active.total_chunks != total_chunks_sent || active.expected_bytes != total_bytes_sent {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] END metadata mismatch id={} begin(chunks={},bytes={}) end(chunks={},bytes={})",
                            report_id, active.total_chunks, active.expected_bytes, total_chunks_sent, total_bytes_sent
                        ),
                    },
                );
            }

            if active.total_chunks != received_chunk_count {
                sink_event(
                    sink,
                    UiEvent::Log {
                        msg: format!(
                            "[RemoteReport] incomplete report id={} chunks_received={}/{}",
                            report_id, received_chunk_count, active.total_chunks
                        ),
                    },
                );
                return;
            }

            match save_remote_debug_report_file(&active) {
                Ok(path) => {
                    sink_event(
                        sink,
                        UiEvent::Log {
                            msg: format!(
                                "[RemoteReport] saved file path={} bytes={} chunks={}",
                                path, active.expected_bytes, active.total_chunks
                            ),
                        },
                    );
                    sink_event(
                        sink,
                        UiEvent::Telemetry {
                            name: "debug_report_saved_bytes".to_string(),
                            value: active.expected_bytes as u64,
                        },
                    );
                }
                Err(error) => {
                    sink_event(
                        sink,
                        UiEvent::Error {
                            msg: format!("remote debug report save failed: {error}"),
                        },
                    );
                }
            }
        }
        _ => {
            sink_event(
                sink,
                UiEvent::Log {
                    msg: format!("[RemoteReport] unsupported packet type 0x{packet_type:02X}"),
                },
            );
        }
    }
}

fn announce_sender_handshake_if_needed(
    sink: &StreamSink<UiEvent>,
    sender: &SankakuSender,
    dest: &str,
    handshake_announced: &mut bool,
) {
    if *handshake_announced {
        return;
    }
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

async fn send_sender_frame(
    sink: &StreamSink<UiEvent>,
    sender: &mut SankakuSender,
    stream_id: u32,
    payload: Vec<u8>,
    is_keyframe: bool,
    pts: u64,
    codec: u8,
    dest: &str,
    handshake_announced: &mut bool,
) -> anyhow::Result<()> {
    let payload_len = payload.len() as u64;
    let frame = VideoFrame::nal_with_codec(payload, pts, is_keyframe, codec);
    match sender.send_frame(stream_id, frame).await {
        Ok(frame_index) => {
            println!(
                "DEBUG: Sankaku sender sent VIDEO packet: stream_id={} frame_index={} bytes={} keyframe={} dest={}",
                stream_id, frame_index, payload_len, is_keyframe, dest
            );
            announce_sender_handshake_if_needed(sink, sender, dest, handshake_announced);

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

pub fn push_video_frame(
    frame_bytes: Vec<u8>,
    is_keyframe: bool,
    pts: u64,
    codec: u8,
) -> anyhow::Result<()> {
    let codec = if codec == 0 { VIDEO_CODEC_HEVC } else { codec };
    let frame_len = frame_bytes.len();
    println!(
        "DEBUG: Rust received VIDEO frame from Dart: {} bytes (keyframe={}, pts_us={}, codec=0x{:02X})",
        frame_len, is_keyframe, pts, codec
    );
    let tx = {
        let guard = hevc_frame_tx_slot()
            .lock()
            .map_err(|_| anyhow!("failed to lock HEVC frame sender slot"))?;
        guard
            .clone()
            .context("sender is not active; call start_sankaku_sender first")?
    };
    tx.send((frame_bytes, is_keyframe, pts, codec))
        .map_err(|_| anyhow!("sender frame ingress channel is closed"))?;
    Ok(())
}

pub fn push_audio_frame(
    frame_bytes: Vec<u8>,
    pts: u64,
    codec: u8,
    frames_per_packet: u32,
) -> anyhow::Result<()> {
    let codec = if codec == 0 { AUDIO_CODEC_OPUS } else { codec };
    let frame_len = frame_bytes.len();
    println!(
        "DEBUG: Rust received AUDIO frame from Dart: {} bytes (pts_us={}, codec=0x{:02X}, frames_per_packet={})",
        frame_len, pts, codec, frames_per_packet
    );
    let tx = {
        let guard = audio_frame_tx_slot()
            .lock()
            .map_err(|_| anyhow!("failed to lock audio frame sender slot"))?;
        guard
            .clone()
            .context("sender is not active; call start_sankaku_sender first")?
    };
    tx.send((frame_bytes, pts, codec, frames_per_packet))
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
            detail: format!("establishing QUIC connection to {dest}"),
        },
    );

    let endpoint = make_client_endpoint()?;
    let dest_addr: SocketAddr = dest
        .parse()
        .with_context(|| format!("invalid destination address: {dest}"))?;
    let connecting = endpoint.connect(dest_addr, "localhost").map_err(|error| {
        println!("ERROR: failed to start QUIC connect to {dest_addr}: {error}");
        anyhow::Error::new(error).context("failed to start QUIC connect")
    })?;
    let connection = connecting.await.map_err(|error| {
        println!("ERROR: failed to establish QUIC connection to {dest_addr}: {error}");
        anyhow::Error::new(error).context("failed to establish QUIC connection")
    })?;
    let local_addr = endpoint
        .local_addr()
        .context("failed to read QUIC client local address")?;
    let remote_addr = connection.remote_address();

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "quic_connected".to_string(),
            detail: format!("local={local_addr} remote={remote_addr} server_name=localhost"),
        },
    );

    let mut sender = SankakuSender::new(connection).await?;
    sender.update_compression_graph(&graph_bytes)?;

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "socket_ready".to_string(),
            detail: format!("QUIC sender transport ready local={local_addr} remote={remote_addr}"),
        },
    );
    sink_event(&sink, UiEvent::HandshakeInitiated);

    let video_stream_id = sender.open_stream_with_type(StreamType::Video)?;
    let audio_stream_id = sender.open_stream_with_type(StreamType::Audio)?;
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

    let (frame_tx, mut frame_rx) = mpsc::unbounded_channel::<(Vec<u8>, bool, u64, u8)>();
    let (audio_tx, mut audio_rx) = mpsc::unbounded_channel::<(Vec<u8>, u64, u8, u32)>();
    install_hevc_frame_tx(frame_tx)?;
    install_audio_frame_tx(audio_tx)?;
    let _frame_ingress_guard = FrameIngressGuard;

    let mut handshake_announced = false;
    let mut sent_packets: u64 = 0;
    let mut telemetry_tick = tokio::time::interval(Duration::from_secs(1));
    telemetry_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    SENDER_SHOULD_RUN.store(true, Ordering::Relaxed);
    let _sender_run_guard = SenderRunGuard;

    loop {
        tokio::select! {
            _ = telemetry_tick.tick() => {
                if let Some(stats) = sender.network_stats() {
                    emit_quic_network_telemetry(&sink, stats);
                }
            }
            Some((frame_bytes, is_keyframe, pts, codec)) = frame_rx.recv() => {
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
                    codec,
                    &dest,
                    &mut handshake_announced,
                ).await?;
                sent_packets = sent_packets.saturating_add(1);
            }
            Some((audio_bytes, pts, codec, frames_per_packet)) = audio_rx.recv() => {
                if audio_bytes.is_empty() {
                    continue;
                }

                let audio_len = audio_bytes.len();
                match sender
                    .send_audio_frame(audio_stream_id, pts, codec, frames_per_packet, audio_bytes)
                    .await
                {
                    Ok(_) => {
                        println!(
                            "DEBUG: Sankaku sender sent AUDIO packet: stream_id={} bytes={} pts_us={} codec=0x{:02X} frames_per_packet={} dest={}",
                            audio_stream_id, audio_len, pts, codec, frames_per_packet, dest
                        );
                        announce_sender_handshake_if_needed(
                            &sink,
                            &sender,
                            &dest,
                            &mut handshake_announced,
                        );
                        if let Some(bitrate_bps) = sender.take_bitrate_update_bps() {
                            sink_event(&sink, UiEvent::BitrateChanged { bitrate_bps });
                        }
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

    let endpoint = make_server_endpoint(&bind_addr)?;
    let local_addr = endpoint
        .local_addr()
        .context("failed to read QUIC server local address")?;

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
            detail: "waiting for inbound QUIC connection".to_string(),
        },
    );

    let incoming = match endpoint.accept().await {
        Some(incoming) => incoming,
        None => {
            println!(
                "ERROR: QUIC endpoint stopped before accepting an incoming connection on {local_addr}"
            );
            bail!("failed to accept incoming connection");
        }
    };
    let connection = incoming.await.map_err(|error| {
        println!(
            "ERROR: failed to establish incoming QUIC connection on {local_addr}: {error}"
        );
        anyhow::Error::new(error).context("failed to establish incoming QUIC connection")
    })?;
    let remote_addr = connection.remote_address();

    sink_event(
        &sink,
        UiEvent::ConnectionState {
            state: "quic_connected".to_string(),
            detail: format!("accepted QUIC peer remote={remote_addr} local={local_addr}"),
        },
    );

    let mut receiver = SankakuReceiver::new(connection).await?;
    receiver.update_compression_graph(&graph_bytes)?;
    let stats_reader = receiver.network_stats_reader();
    sink_event(
        &sink,
        UiEvent::Telemetry {
            name: "graph_bytes".to_string(),
            value: graph_bytes.len() as u64,
        },
    );

    let (mut inbound_video, mut inbound_audio) = receiver.spawn_media_channels();
    let mut handshake_announced = false;
    let mut remote_debug_report_assembly: Option<RemoteDebugReportAssembly> = None;
    let mut shutdown_tick = tokio::time::interval(Duration::from_millis(200));
    let mut telemetry_tick = tokio::time::interval(Duration::from_secs(1));
    shutdown_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    telemetry_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

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
            _ = telemetry_tick.tick() => {
                if let Some(stats) = stats_reader.network_stats() {
                    emit_quic_network_telemetry(&sink, stats);
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
                let session_id = frame.session_id;
                let stream_id = frame.stream_id;
                let pts = frame.timestamp_us;
                let codec = frame.codec;
                let frames_per_packet = frame.frames_per_packet;
                let payload = frame.payload;

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

                if codec == AUDIO_CODEC_DEBUG_TEXT {
                    handle_remote_debug_report_payload(
                        &sink,
                        &payload,
                        &mut remote_debug_report_assembly,
                    );
                    continue;
                }

                sink_event(
                    &sink,
                    UiEvent::AudioFrameReceived {
                        data: payload,
                        pts,
                        frames_per_packet,
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
