use kyu2_core::{KyuEvent, KyuSender, KyuReceiver, parse_psk_hex};
use std::path::{Path, PathBuf};
use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    kyu2_core::init();
}

/// A Dart-friendly mapping of the KyuEvent
#[derive(Clone)]
pub enum UiEvent {
    Log { msg: String },
    HandshakeInitiated,
    HandshakeComplete,
    FileDetected { stream_id: u32, trace_id: u64, name: String, size: u64 },
    Progress { stream_id: u32, trace_id: u64, current: u64, total: u64 },
    TransferComplete { stream_id: u32, trace_id: u64, path: String },
    EarlyTermination { stream_id: u32, trace_id: u64 },
    Fault { code: String, message: String },
    Metric { name: String, value: u64 },
    Error { msg: String },
}

impl From<KyuEvent> for UiEvent {
    fn from(event: KyuEvent) -> Self {
        match event {
            KyuEvent::Log(msg) => UiEvent::Log { msg },
            KyuEvent::HandshakeInitiated => UiEvent::HandshakeInitiated,
            KyuEvent::HandshakeComplete => UiEvent::HandshakeComplete,
            KyuEvent::FileDetected { stream_id, trace_id, name, size } => {
                UiEvent::FileDetected { stream_id, trace_id, name, size }
            }
            KyuEvent::Progress { stream_id, trace_id, current, total } => {
                UiEvent::Progress { stream_id, trace_id, current, total }
            }
            KyuEvent::TransferComplete { stream_id, trace_id, path } => {
                UiEvent::TransferComplete { stream_id, trace_id, path: path.to_string_lossy().to_string() }
            }
            KyuEvent::EarlyTermination { stream_id, trace_id } => {
                UiEvent::EarlyTermination { stream_id, trace_id }
            }
            KyuEvent::Fault { code, message, .. } => {
                UiEvent::Fault { code: code.as_str().to_string(), message }
            }
            KyuEvent::Metric { name, value, .. } => {
                UiEvent::Metric { name: name.to_string(), value }
            }
            KyuEvent::Error(msg) => UiEvent::Error { msg },
        }
    }
}

/// Asynchronous function that runs the Kyu2 sender engine and streams events back to Dart
pub fn send_files(
    sink: StreamSink<UiEvent>,
    dest: String,
    relay_routes: Vec<String>,
    psk_hex: String,
    file_paths: Vec<String>,
    redundancy: f32,
    max_bytes_per_sec: u64,
) -> anyhow::Result<()> {
    
    // 1. Parse the Handshake PSK
    let psk = parse_psk_hex(&psk_hex)?;

    // 2. Initialize the hardened Sender
    let mut sender = KyuSender::new_with_psk(&dest, psk)?;
    
    // 3. Apply the new Trusted Mesh Relay Fallbacks
    sender.set_relay_routes(relay_routes);

    // 4. Map Dart String paths to Rust PathBufs
    let paths: Vec<PathBuf> = file_paths.into_iter().map(PathBuf::from).collect();

    // 5. Execute the transfer, mapping engine events to the Dart UI stream
    sender.send_files(&paths, redundancy, max_bytes_per_sec, |event| {
        let _ = sink.add(event.into());
    })?;

    Ok(())
}

/// Asynchronous function that runs the Kyu2 receiver engine and streams events back to Dart
pub fn recv_files(
    sink: StreamSink<UiEvent>,
    bind_addr: String,
    out_dir: String,
    psk_hex: String,
) -> anyhow::Result<()> {
    
    // 1. Parse the Handshake PSK
    let psk = parse_psk_hex(&psk_hex)?;
    let out_path = Path::new(&out_dir);

    // 2. Initialize the hardened Receiver
    let receiver = KyuReceiver::new_with_psk(&bind_addr, out_path, psk)?;

    // 3. Execute the listen loop, mapping engine events to the Dart UI stream
    // Note: run_loop blocks indefinitely until an unrecoverable socket error occurs,
    // pumping events into the sink the entire time.
    receiver.run_loop(|_session_id, event| {
        let _ = sink.add(event.into());
    })?;

    Ok(())
}
