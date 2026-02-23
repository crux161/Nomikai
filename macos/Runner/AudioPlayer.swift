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
  private struct QueuedAudioFrame {
    let ptsUs: UInt64
    let data: Data
  }

  private let playerQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.queue")
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let syncClock: PlaybackSyncClock

  private let aacFormat: AVAudioFormat
  private let pcmFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private var isStarted = false
  private var drainTimer: DispatchSourceTimer?
  private var queuedFrames: [QueuedAudioFrame] = []

  init(syncClock: PlaybackSyncClock) throws {
    self.syncClock = syncClock
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

  deinit {
    drainTimer?.setEventHandler {}
    drainTimer?.cancel()
    drainTimer = nil
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

  func decodeAndPlay(aacData: Data, ptsUs: UInt64 = 0) {
    guard !aacData.isEmpty else { return }

    playerQueue.async { [weak self] in
      guard let self else { return }
      self.enqueueAudioFrameOnQueue(aacData, ptsUs: ptsUs)
    }
  }

  private func enqueueAudioFrameOnQueue(_ aacData: Data, ptsUs: UInt64) {
    if ptsUs > 0 {
      NSLog("AudioPlayer: enqueue frame bytes=%d pts_us=%llu", aacData.count, ptsUs)
    }

    let item = QueuedAudioFrame(ptsUs: ptsUs, data: aacData)
    insertQueuedAudioFrame(item)
    ensureDrainTimerOnQueue()
    drainQueuedAudioOnQueue()
  }

  private func insertQueuedAudioFrame(_ item: QueuedAudioFrame) {
    guard item.ptsUs > 0 else {
      queuedFrames.append(item)
      return
    }

    let insertionIndex: Int =
      queuedFrames.firstIndex(where: { existing in
        existing.ptsUs > 0 && existing.ptsUs > item.ptsUs
      }) ?? queuedFrames.endIndex
    queuedFrames.insert(item, at: insertionIndex)
  }

  private func ensureDrainTimerOnQueue() {
    guard drainTimer == nil else { return }

    let timer = DispatchSource.makeTimerSource(queue: playerQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
      self?.drainQueuedAudioOnQueue()
    }
    drainTimer = timer
    timer.resume()
  }

  private func drainQueuedAudioOnQueue() {
    guard !queuedFrames.isEmpty else { return }

    do {
      try start()
    } catch {
      NSLog("AudioPlayer: failed to start audio engine: \(error.localizedDescription)")
      return
    }

    var drainedCount = 0
    while !queuedFrames.isEmpty {
      let next = queuedFrames[0]

      if next.ptsUs == 0 {
        queuedFrames.removeFirst()
        decodeAndSchedule(aacData: next.data)
        drainedCount += 1
      } else {
        guard let playablePtsUs = syncClock.playablePtsUpperBoundUs() else {
          break
        }
        if next.ptsUs > playablePtsUs {
          break
        }

        queuedFrames.removeFirst()
        decodeAndSchedule(aacData: next.data)
        drainedCount += 1
      }

      if drainedCount >= 16 {
        break
      }
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
