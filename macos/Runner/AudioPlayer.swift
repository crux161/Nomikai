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
  private static let aacSampleRateHz: Double = 48_000
  private static let aacChannelCount: AVAudioChannelCount = 1
  private static let aacBitrateBps = 64_000
  private static let gateBypassStallUs: UInt64 = 750_000
  private static let gateBlockLogIntervalUs: UInt64 = 250_000
  private static let gateBypassQueueDepth = 10

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
  private var gateBlockedSinceUs: UInt64?
  private var lastGateBlockLogUs: UInt64 = 0
  private var lastDrainSummaryLogUs: UInt64 = 0

  init(syncClock: PlaybackSyncClock) throws {
    self.syncClock = syncClock
    guard
      let aacFormat = AVAudioFormat(
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: Self.aacSampleRateHz,
          AVNumberOfChannelsKey: Self.aacChannelCount,
          AVEncoderBitRateKey: Self.aacBitrateBps,
        ]
      )
    else {
      throw AudioPlayerError.unsupportedAacFormat
    }
    guard
      let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.aacSampleRateHz,
        channels: Self.aacChannelCount,
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

    NSLog(
      "AudioPlayer: configured AAC->PCM path (aac=%0.0fHz ch=%u bitrate=%d, pcm=%0.0fHz ch=%u)",
      Self.aacSampleRateHz,
      Self.aacChannelCount,
      Self.aacBitrateBps,
      pcmFormat.sampleRate,
      pcmFormat.channelCount
    )
  }

  deinit {
    drainTimer?.setEventHandler {}
    drainTimer?.cancel()
    drainTimer = nil
  }

  func start() throws {
    if !isStarted {
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
      playerNode.volume = 1.0
      engine.mainMixerNode.outputVolume = 1.0
      engine.prepare()
      isStarted = true
      NSLog("AudioPlayer: engine graph attached and prepared")
    }

    if !engine.isRunning {
      try engine.start()
      NSLog("AudioPlayer: AVAudioEngine started")
    }
    if !playerNode.isPlaying {
      playerNode.play()
      NSLog("AudioPlayer: AVAudioPlayerNode started")
    }
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
        resetGateBlockTrackingOnQueue()
        queuedFrames.removeFirst()
        decodeAndSchedule(aacData: next.data, ptsUs: 0, bypassedPtsGate: false)
        drainedCount += 1
      } else {
        guard let playablePtsUs = syncClock.playablePtsUpperBoundUs() else {
          logGateBlockOnQueue(
            reason: "waiting_for_sync_anchor",
            nextPtsUs: next.ptsUs,
            playablePtsUs: nil
          )
          if shouldBypassPtsGateOnQueue(queueDepth: queuedFrames.count) {
            NSLog(
              "AudioPlayer: bypassing PTS gate after stall (no sync anchor yet). queue_depth=%d next_pts_us=%llu",
              queuedFrames.count,
              next.ptsUs
            )
            queuedFrames.removeFirst()
            decodeAndSchedule(aacData: next.data, ptsUs: next.ptsUs, bypassedPtsGate: true)
            drainedCount += 1
            continue
          }
          break
        }
        if next.ptsUs > playablePtsUs {
          logGateBlockOnQueue(
            reason: "waiting_for_pts_window",
            nextPtsUs: next.ptsUs,
            playablePtsUs: playablePtsUs
          )
          if shouldBypassPtsGateOnQueue(queueDepth: queuedFrames.count) {
            let deltaUs = next.ptsUs - playablePtsUs
            NSLog(
              "AudioPlayer: bypassing PTS gate after stall (delta_us=%llu queue_depth=%d next_pts_us=%llu playable_pts_us=%llu)",
              deltaUs,
              queuedFrames.count,
              next.ptsUs,
              playablePtsUs
            )
            queuedFrames.removeFirst()
            decodeAndSchedule(aacData: next.data, ptsUs: next.ptsUs, bypassedPtsGate: true)
            drainedCount += 1
            continue
          }
          break
        }

        resetGateBlockTrackingOnQueue()
        queuedFrames.removeFirst()
        decodeAndSchedule(aacData: next.data, ptsUs: next.ptsUs, bypassedPtsGate: false)
        drainedCount += 1
      }

      if drainedCount >= 16 {
        break
      }
    }

    if drainedCount > 0 {
      let nowUs = Self.monotonicNowUs()
      if lastDrainSummaryLogUs == 0 || nowUs - lastDrainSummaryLogUs >= 250_000 {
        lastDrainSummaryLogUs = nowUs
        NSLog(
          "AudioPlayer: drained=%d queued_remaining=%d engine_running=%d player_playing=%d clock_anchored=%d",
          drainedCount,
          queuedFrames.count,
          engine.isRunning ? 1 : 0,
          playerNode.isPlaying ? 1 : 0,
          syncClock.isAnchored() ? 1 : 0
        )
      }
    }
  }

  private func decodeAndSchedule(aacData: Data, ptsUs: UInt64, bypassedPtsGate: Bool) {
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
    } else {
      NSLog("AudioPlayer: missing packetDescriptions for AAC buffer bytes=%d", aacData.count)
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
      } else {
        NSLog("AudioPlayer: AAC decode failed with unknown converter error")
      }
      converter.reset()
      return
    }

    guard pcmBuffer.frameLength > 0 else {
      NSLog(
        "AudioPlayer: AAC decode produced no PCM (status=%@ bytes=%d pts_us=%llu bypassed=%d)",
        Self.converterStatusName(status),
        aacData.count,
        ptsUs,
        bypassedPtsGate ? 1 : 0
      )
      return
    }

    if !engine.isRunning || !playerNode.isPlaying {
      do {
        try start()
      } catch {
        NSLog(
          "AudioPlayer: failed to re-start engine before scheduling audio: \(error.localizedDescription)"
        )
        return
      }
    }

    playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    if !playerNode.isPlaying {
      playerNode.play()
    }
    if bypassedPtsGate {
      NSLog(
        "AudioPlayer: scheduled audio after PTS gate bypass frames=%u bytes=%d pts_us=%llu",
        pcmBuffer.frameLength,
        aacData.count,
        ptsUs
      )
    }
  }

  private func logGateBlockOnQueue(reason: String, nextPtsUs: UInt64, playablePtsUs: UInt64?) {
    let nowUs = Self.monotonicNowUs()
    if gateBlockedSinceUs == nil {
      gateBlockedSinceUs = nowUs
    }
    if lastGateBlockLogUs != 0 && nowUs - lastGateBlockLogUs < Self.gateBlockLogIntervalUs {
      return
    }
    lastGateBlockLogUs = nowUs

    if let playablePtsUs {
      let deltaUs = nextPtsUs > playablePtsUs ? nextPtsUs - playablePtsUs : 0
      NSLog(
        "AudioPlayer: drain blocked reason=%@ queue_depth=%d next_pts_us=%llu playable_pts_us=%llu delta_us=%llu clock_anchored=%d",
        reason,
        queuedFrames.count,
        nextPtsUs,
        playablePtsUs,
        deltaUs,
        syncClock.isAnchored() ? 1 : 0
      )
    } else {
      NSLog(
        "AudioPlayer: drain blocked reason=%@ queue_depth=%d next_pts_us=%llu clock_anchored=%d",
        reason,
        queuedFrames.count,
        nextPtsUs,
        syncClock.isAnchored() ? 1 : 0
      )
    }
  }

  private func shouldBypassPtsGateOnQueue(queueDepth: Int) -> Bool {
    guard queueDepth >= Self.gateBypassQueueDepth else {
      return false
    }
    guard let gateBlockedSinceUs else {
      return false
    }
    let nowUs = Self.monotonicNowUs()
    return nowUs >= gateBlockedSinceUs && (nowUs - gateBlockedSinceUs) >= Self.gateBypassStallUs
  }

  private func resetGateBlockTrackingOnQueue() {
    gateBlockedSinceUs = nil
  }

  private static func converterStatusName(_ status: AVAudioConverterOutputStatus) -> String {
    switch status {
    case .haveData:
      return "haveData"
    case .inputRanDry:
      return "inputRanDry"
    case .endOfStream:
      return "endOfStream"
    case .error:
      return "error"
    @unknown default:
      return "unknown"
    }
  }

  private static func monotonicNowUs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000
  }
}
