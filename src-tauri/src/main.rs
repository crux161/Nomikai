#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use futures::stream::StreamExt;
use libp2p::{
    gossipsub, mdns, noise, swarm::NetworkBehaviour, swarm::SwarmEvent, tcp, yamux, PeerId,
};
use std::{collections::hash_map::DefaultHasher, error::Error, hash::{Hash, Hasher}, time::Duration};
use tauri::{Emitter, Manager};
use tokio::{io, sync::mpsc};

// --- Types ---

#[derive(NetworkBehaviour)]
struct NomikaiBehavior {
    gossipsub: gossipsub::Behaviour,
    mdns: mdns::tokio::Behaviour,
}

struct AppState {
    // We keep a sender channel here to talk to the P2P loop
    command_sender: mpsc::Sender<SwarmCommand>,
    local_peer_id: PeerId,
}

enum SwarmCommand {
    Publish(String),
}

// --- Commands ---

#[tauri::command]
fn get_peer_id(state: tauri::State<AppState>) -> String {
    state.local_peer_id.to_string()
}

#[tauri::command]
async fn send_chat_message(message: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    // Send the message into the channel. The background thread will pick it up and publish it.
    state.command_sender
        .send(SwarmCommand::Publish(message))
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

            // 2. Create a Channel for communication (UI -> P2P Loop)
            let (cmd_tx, mut cmd_rx) = mpsc::channel(32);

            // 3. Manage State (so commands can access the channel)
            app.manage(AppState { 
                command_sender: cmd_tx,
                local_peer_id: peer_id 
            });

            // 4. Spawn the P2P Swarm
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
                        // Gossipsub Config
                        let message_id_fn = |message: &gossipsub::Message| {
                            let mut s = DefaultHasher::new();
                            message.data.hash(&mut s);
                            gossipsub::MessageId::from(s.finish().to_string())
                        };
                        let gossipsub_config = gossipsub::ConfigBuilder::default()
                            .heartbeat_interval(Duration::from_secs(1)) // Fast heartbeat for chat
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

                swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse().unwrap()).unwrap();

                // Subscribe to the global chat topic
                let topic = gossipsub::IdentTopic::new("nomikai-global");
                swarm.behaviour_mut().gossipsub.subscribe(&topic).unwrap();

                // THE EVENT LOOP
                loop {
                    tokio::select! {
                        // A: Handle Network Events (Discovery, Incoming Messages)
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                let _ = app_handle.emit("p2p-status", format!("Listening on {address}"));
                            }
                            // Handle Discovery
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    let _ = app_handle.emit("peer-discovery", format!("Found Peer: {}", peer_id));
                                    swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                                }
                            }
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _) in list {
                                    swarm.behaviour_mut().gossipsub.remove_explicit_peer(&peer_id);
                                }
                            }
                            // Handle Incoming Messages
                            SwarmEvent::Behaviour(NomikaiBehaviorEvent::Gossipsub(gossipsub::Event::Message { propagation_source: _, message_id: _, message })) => {
                                // 1. Convert bytes back to string
                                if let Ok(msg_content) = String::from_utf8(message.data) {
                                    println!("Received Gossip Message: {}", msg_content);
                                    // 2. Emit to Frontend (using the same event name as before)
                                    let _ = app_handle.emit("stream-event", msg_content);
                                }
                            }
                            _ => {}
                        },

                        // B: Handle UI Commands (Outgoing Messages)
                        command = cmd_rx.recv() => match command {
                            Some(SwarmCommand::Publish(msg)) => {
                                println!("Publishing to swarm: {}", msg);
                                let topic = gossipsub::IdentTopic::new("nomikai-global");
                                if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic, msg.as_bytes()) {
                                    eprintln!("Publish error: {:?}", e);
                                }
                            }
                            None => break, // Channel closed
                        }
                    }
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![get_peer_id, send_chat_message]) // Register new command
        .run(tauri::generate_context!())
        .expect("error while running tauri application");

    Ok(())
}
