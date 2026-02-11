// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::command;

// This is the bridge command your UI will call.
// Eventually, this is where we will hook into libkyu/QQX5.
#[command]
fn process_stream_chunk(chunk: String) -> String {
    // TODO: Implement QQX5 streaming compression here.
    // For now, we'll return a formatted string to prove the Rust bridge is working.
    println!("Received chunk of size: {}", chunk.len());
    
    // Mocking a transformation
    format!("(Rust Kernel) QQX5 Processed: {}", chunk)
}

fn main() {
    tauri::Builder::default()
        // Register the command so the frontend can invoke it
        .invoke_handler(tauri::generate_handler![process_stream_chunk])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
