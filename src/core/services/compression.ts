import { invoke } from '@tauri-apps/api/core';

/**
 * Sends a data chunk to the Rust backend for processing via QQX5/libkyu.
 * Falls back to a simple passthrough if the Rust backend is unavailable 
 * (e.g. on Mobile/Capacitor or standard web).
 */
export const processChunk = async (data: string): Promise<string> => {
  try {
    // Attempt to invoke the 'process_stream_chunk' command defined in main.rs
    // generic <string> specifies the return type we expect from Rust
    return await invoke<string>('process_stream_chunk', { chunk: data });
  } catch (error) {
    // If we are in the Browser or on Mobile, this will fail gracefully.
    // In a real mobile implementation, you might call a Capacitor plugin here.
    console.debug('Rust backend unavailable (running in pure Web/Mobile?), passing through data.');
    return data;
  }
};;
