#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use futures::stream::StreamExt;
use libp2p::{
    gossipsub, mdns, noise, swarm::NetworkBehaviour, swarm::SwarmEvent, tcp, yamux, Multiaddr,
    PeerId,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::hash_map::DefaultHasher,
    error::Error,
    hash::{Hash, Hasher},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};
use tokio::{io, sync::mpsc};

// --- Types ---

#[derive(Serialize, Deserialize, Debug, Clone)]
struct ChatPacket {
    sender_id: String,
    sender_name: String,
    content: String,
    timestamp: u64,
}

#[derive(NetworkBehaviour)]
struct NomikaiBehavior {
    gossipsub: gossipsub::Behaviour,
    mdns: mdns::tokio::Behaviour,
}

struct AppState {
    command_sender: mpsc::Sender<SwarmCommand>,
    local_peer_id: PeerId,
}

enum SwarmCommand {
    Publish(ChatPacket),
    Dial(Multiaddr),
}

// --- Commands ---

#[tauri::command]
fn get_peer_id(state: tauri::State<AppState>) -> String {
    state.local_peer_id.to_string()
}

#[tauri::command]
async fn send_chat_message(
    name: String,
    message: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let packet = ChatPacket {
        sender_id: state.local_peer_id.to_string(),
        sender_name: name,
        content: message,
        timestamp: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs(),
    };

    state
        .command_sender
        .send(SwarmCommand::Publish(packet))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn connect_to_peer(
    address: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let addr: Multiaddr = address.parse().map_err(|_| "Invalid Address")?;

    state
        .command_sender
        .send(SwarmCommand::Dial(addr))
        .await
        .map_err(|e| e.to_string())
}

// --- Main ---

fn main() -> Result<(), Box<dyn Error>> {
    tauri::Builder::default()
        .setup(|app| {
            let app_handle = app.handle().clone();

            // 1. Generate Identity
            let id_keys = libp2p::identity::Keypair::generate_ed25519();
            let peer_id = PeerId::from(id_keys.public());
            println!("Local Peer ID: {peer_id}");

            // 2. Create Channel
            let (cmd_tx, mut cmd_rx) = mpsc::channel(32);

            // 3. Manage State
            app.manage(AppState {
                command_sender: cmd_tx,
                local_peer_id: peer_id,
            });

            // 4. Spawn P2P Swarm
            tauri::async_runtime::spawn(async move {
                let mut swarm = libp2p::SwarmBuilder::with_existing_identity(id_keys)
                    .with_tokio()
                    .with_tcp(
                        tcp::Config::default(),
                        noise::Config::new,
                        yamux::Config::default,
                    )
                    .expect("Failed to build transport")
                    .with_behaviour(|key| {
                        let message_id_fn = |message: &gossipsub::Message| {
                            let mut s = DefaultHasher::new();
                            message.data.hash(&mut s);
                            gossipsub::MessageId::from(s.finish().to_string())
                        };
                        let gossipsub_config = gossipsub::ConfigBuilder::default()
                            .heartbeat_interval(Duration::from_secs(1))
                            .validation_mode(gossipsub::ValidationMode::Strict)
                            .message_id_fn(message_id_fn)
                            .build()
                            .map_err(|msg| io::Error::new(io::ErrorKind::Other, msg))?;

                        let gossipsub = gossipsub::Behaviour::new(
                            gossipsub::MessageAuthenticity::Signed(key.clone()),
                            gossipsub_config,
                        )?;

                        let mdns = mdns::tokio::Behaviour::new(
                            mdns::Config::default(),
                            key.public().to_peer_id(),
                        )?;

                        Ok(NomikaiBehavior { gossipsub, mdns })
                    })
                    .expect("Failed to build behaviour")
                    .build();

                swarm
                    .listen_on("/ip4/0.0.0.0/tcp/0".parse().unwrap())
                    .unwrap();

                let topic = gossipsub::IdentTopic::new("nomikai-global");
                swarm.behaviour_mut().gossipsub.subscribe(&topic).unwrap();

                loop {
                    tokio::select! {
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                let _ = app_handle.emit("p2p-status", format!("Listening on {address}"));
                            }
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _) in list {
                                    let _ = app_handle.emit("peer-discovery", format!("Found Peer: {}", peer_id));
                                    swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                                }
                            }
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _) in list {
                                    swarm.behaviour_mut().gossipsub.remove_explicit_peer(&peer_id);
                                }
                            }
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Gossipsub(gossipsub::Event::Message { message, .. })) => {
                                // Polyglot Parsing: Try JSON first, then Raw String
                                if let Ok(packet) = serde_json::from_slice::<ChatPacket>(&message.data) {
                                    println!("Received Packet from {}: {}", packet.sender_name, packet.content);
                                    let _ = app_handle.emit("stream-event", packet);
                                }
                                else if let Ok(legacy_text) = String::from_utf8(message.data) {
                                    println!("Received Legacy Message: {}", legacy_text);
                                    let fallback_packet = ChatPacket {
                                        sender_id: "legacy-user".to_string(),
                                        sender_name: "Legacy User".to_string(),
                                        content: legacy_text,
                                        timestamp: SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs(),
                                    };
                                    let _ = app_handle.emit("stream-event", fallback_packet);
                                }
                            }
                            _ => {}
                        },

                        command = cmd_rx.recv() => match command {
                            Some(SwarmCommand::Publish(packet)) => {
                                if let Ok(json_bytes) = serde_json::to_vec(&packet) {
                                    let topic = gossipsub::IdentTopic::new("nomikai-global");
                                    if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic, json_bytes) {
                                        eprintln!("Publish error: {:?}", e);
                                    }
                                }
                            }
                            Some(SwarmCommand::Dial(addr)) => {
                                println!("Dialing {}", addr);
                                if let Err(e) = swarm.dial(addr) {
                                    eprintln!("Dial error: {:?}", e);
                                }
                            }
                            None => break,
                        }
                    }
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_peer_id,
            send_chat_message,
            connect_to_peer
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");

    Ok(())
}
