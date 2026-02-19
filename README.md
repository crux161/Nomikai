# Nomikai 

Welcome to the official frontend and mobile client for **Nomikai**, a next-generation video transmission and communication platform. 

This repository houses the "Sankaku Era" architecture: a hybrid stack designed to extract maximum thermal efficiency from mobile hardware while routing media through a radically resilient, bespoke Rust transport engine.

## 🏗️ The Architecture

Nomikai bridges high-level, cross-platform UI with bare-metal hardware media engines and low-level UDP network programming.

1. **The UI (Flutter):** Provides a fluid, responsive, and cross-platform user experience for managing application state, signaling, and rendering the final decoded video textures to the screen.
   
2. **The Hardware Boundary (Swift / Native iOS):** Instead of relying on software encoders that drain battery and generate heat, Nomikai hooks directly into Apple Silicon via `AVCaptureSession` and `VTCompressionSession`. This delegates the heavy lifting of HEVC (H.265) video encoding entirely to the hardware, yielding a fully compressed bitstream inside a `CMSampleBuffer` with near-zero CPU cost.

3. **The Transport Engine (Sankaku / Rust):** The core networking layer. FFI bindings pass the raw HEVC bitstream from Swift directly into **Sankaku** (a specialized media fork of the Kyu2 protocol). Sankaku handles:
   * **In-Memory Bitstream Parsing:** Identifying Network Abstraction Layer (NAL) units on the fly.
   * **OpenZL Compression:** Extracting Sample Adaptive Offset (SAO) parameters and squeezing them using heavily trained, dynamically hot-swapped OpenZL graphs.
   * **Security:** 0-RTT session resumption with X25519 Diffie-Hellman handshakes and ChaCha20-Poly1305 authenticated encryption.
   * **Resilience:** Wirehair Forward Error Correction (FEC) fountain codes to eliminate head-of-line blocking and self-heal dropped packets without stalling the video frame.

## 📜 Repository History

**Note:** This `main` branch represents the new Flutter/Sankaku mobile client. If you are looking for the original web-based conceptual prototype, it has been safely archived. Simply run `git checkout concept-vite` to view the legacy codebase.

## 🚀 Getting Started

### Prerequisites
To build and run Nomikai, you will need the following development toolchains installed:
* **Flutter SDK:** For the primary frontend UI.
* **Rust (Cargo):** For compiling the `sankaku-core` engine and FFI bindings.
* **Xcode & iOS SDK:** For building the Swift hardware boundary plugins and deploying to physical Apple Silicon devices. (Note: A physical iPhone/iPad is highly recommended over a simulator to utilize hardware HEVC encoding).

### Setup
1. Clone the repository:
   ```bash
   git clone https://github.com/crux161/Nomikai
   cd nomikai
