import AVFoundation
import Foundation

private enum AudioPlayerError: LocalizedError {
  case unsupportedAacFormat
  case unsupportedPcmFormat
  case converterUnavailable
  case pcmBufferAllocationFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedAacFormat:
      return "Unable to construct AAC playback format for native audio output."
    case .unsupportedPcmFormat:
      return "Unable to construct PCM playback format for native audio output."
    case .converterUnavailable:
      return "Unable to initialize AAC to PCM converter."
    case .pcmBufferAllocationFailed:
      return "Unable to allocate PCM playback buffer."
    }
  }
}

final class AudioPlayer {
  private let playerQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.queue")
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()

  private let aacFormat: AVAudioFormat
  private let pcmFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private var isStarted = false

  init() throws {
    guard
      let aacFormat = AVAudioFormat(
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 1,
        ]
      )
    else {
      throw AudioPlayerError.unsupportedAacFormat
    }
    guard
      let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    else {
      throw AudioPlayerError.unsupportedPcmFormat
    }
    guard let converter = AVAudioConverter(from: aacFormat, to: pcmFormat) else {
      throw AudioPlayerError.converterUnavailable
    }

    self.aacFormat = aacFormat
    self.pcmFormat = pcmFormat
    self.converter = converter
  }

  func start() throws {
    guard !isStarted else { return }

    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
    engine.prepare()
    try engine.start()
    playerNode.play()
    isStarted = true
  }

  func decodeAndPlay(aacData: Data) {
    guard !aacData.isEmpty else { return }

    playerQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.start()
      } catch {
        NSLog("AudioPlayer: failed to start audio engine: \(error.localizedDescription)")
        return
      }

      self.decodeAndSchedule(aacData: aacData)
    }
  }

  private func decodeAndSchedule(aacData: Data) {
    let maximumPacketSize = max(converter.maximumOutputPacketSize, aacData.count)
    let compressedBuffer = AVAudioCompressedBuffer(
      format: aacFormat,
      packetCapacity: 1,
      maximumPacketSize: maximumPacketSize
    )
    compressedBuffer.packetCount = 1
    compressedBuffer.byteLength = UInt32(aacData.count)

    aacData.withUnsafeBytes { rawBuffer in
      guard let source = rawBuffer.baseAddress else { return }
      memcpy(compressedBuffer.data, source, aacData.count)
    }

    if let packetDescriptions = compressedBuffer.packetDescriptions {
      packetDescriptions.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 1024,
        mDataByteSize: UInt32(aacData.count)
      )
    }

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else {
      NSLog("AudioPlayer: \(AudioPlayerError.pcmBufferAllocationFailed.localizedDescription)")
      return
    }

    var providedInput = false
    var convertError: NSError?
    let status = converter.convert(to: pcmBuffer, error: &convertError) { _, outStatus in
      if providedInput {
        outStatus.pointee = .endOfStream
        return nil
      }
      providedInput = true
      outStatus.pointee = .haveData
      return compressedBuffer
    }

    if status == .error {
      if let convertError {
        NSLog("AudioPlayer: AAC decode failed: \(convertError)")
      }
      return
    }

    guard pcmBuffer.frameLength > 0 else {
      return
    }
    playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }
}
