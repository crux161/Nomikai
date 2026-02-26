import AVFoundation
import Foundation

private enum AudioPlayerError: LocalizedError {
  case unsupportedOpusFormat
  case opusRequiresMacOS12
  case unsupportedPcmFormat
  case converterUnavailable
  case pcmBufferAllocationFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedOpusFormat:
      return "Unable to construct Opus playback format for native audio output."
    case .opusRequiresMacOS12:
      return "Native Opus audio playback requires macOS 12 or later."
    case .unsupportedPcmFormat:
      return "Unable to construct PCM playback format for native audio output."
    case .converterUnavailable:
      return "Unable to initialize Opus to PCM converter."
    case .pcmBufferAllocationFailed:
      return "Unable to allocate PCM playback buffer."
    }
  }
}

final class AudioPlayer {
  private static let opusSampleRateHz: Double = 48_000
  private static let opusChannelCount: AVAudioChannelCount = 1
  private static let opusBitrateBps = 32_000
  private static let opusFramesPerPacket: UInt32 = 960
  private static let audioLeadTrimUs: UInt64 = 60_000
  private static let staleAudioDropThresholdUs: UInt64 = 120_000
  private static let maxQueuedAudioSpanUs: UInt64 = 220_000
  private static let gateBypassStallUs: UInt64 = 750_000
  private static let gateBlockLogIntervalUs: UInt64 = 250_000
  private static let gateBypassQueueDepth = 10
  private static let maxDebugLogLines = 2_000

  private struct QueuedAudioFrame {
    let ptsUs: UInt64
    let data: Data
    let framesPerPacketHint: UInt32
  }

  private let playerQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.queue")
  private let debugLogQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.debug_log")
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let syncClock: PlaybackSyncClock

  private let opusFormat: AVAudioFormat
  private let pcmFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private var isStarted = false
  private var drainTimer: DispatchSourceTimer?
  private var queuedFrames: [QueuedAudioFrame] = []
  private var gateBlockedSinceUs: UInt64?
  private var lastGateBlockLogUs: UInt64 = 0
  private var lastDrainSummaryLogUs: UInt64 = 0
  private var debugLogLines: [String] = []

  init(syncClock: PlaybackSyncClock) throws {
    self.syncClock = syncClock
    guard #available(macOS 12.0, *) else {
      throw AudioPlayerError.opusRequiresMacOS12
    }
    guard
      let opusFormat = AVAudioFormat(
        settings: [
          AVFormatIDKey: kAudioFormatOpus,
          AVSampleRateKey: Self.opusSampleRateHz,
          AVNumberOfChannelsKey: Self.opusChannelCount,
          AVEncoderBitRateKey: Self.opusBitrateBps,
        ]
      )
    else {
      throw AudioPlayerError.unsupportedOpusFormat
    }
    guard
      let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.opusSampleRateHz,
        channels: Self.opusChannelCount,
        interleaved: false
      )
    else {
      throw AudioPlayerError.unsupportedPcmFormat
    }
    guard let converter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
      throw AudioPlayerError.converterUnavailable
    }

    self.opusFormat = opusFormat
    self.pcmFormat = pcmFormat
    self.converter = converter

    logf(
      "AudioPlayer: configured Opus->PCM path (opus=%0.0fHz ch=%u bitrate=%d, pcm=%0.0fHz ch=%u)",
      Self.opusSampleRateHz,
      Self.opusChannelCount,
      Self.opusBitrateBps,
      pcmFormat.sampleRate,
      pcmFormat.channelCount
    )
  }

  deinit {
    drainTimer?.setEventHandler {}
    drainTimer?.cancel()
    drainTimer = nil
  }

  func debugLogSnapshot() -> [String] {
    debugLogQueue.sync { debugLogLines }
  }

  func clearDebugLogs() {
    debugLogQueue.sync {
      debugLogLines.removeAll(keepingCapacity: true)
    }
  }

  func start() throws {
    if !isStarted {
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
      playerNode.volume = 1.0
      engine.mainMixerNode.outputVolume = 1.0
      engine.prepare()
      isStarted = true
      logf("AudioPlayer: engine graph attached and prepared")
    }

    if !engine.isRunning {
      try engine.start()
      logf("AudioPlayer: AVAudioEngine started")
    }
    if !playerNode.isPlaying {
      playerNode.play()
      logf("AudioPlayer: AVAudioPlayerNode started")
    }
  }

  func decodeAndPlay(opusData: Data, ptsUs: UInt64 = 0, framesPerPacketHint: UInt32 = 0) {
    guard !opusData.isEmpty else { return }

    playerQueue.async { [weak self] in
      guard let self else { return }
      self.enqueueAudioFrameOnQueue(opusData, ptsUs: ptsUs, framesPerPacketHint: framesPerPacketHint)
    }
  }

  func suspendPlayback() {
    playerQueue.async { [weak self] in
      self?.suspendPlaybackOnQueue()
    }
  }

  func resumePlayback() {
    playerQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.start()
        logf("AudioPlayer: resumed playback")
      } catch {
        logf("AudioPlayer: failed to resume playback: \(error.localizedDescription)")
      }
    }
  }

  private func enqueueAudioFrameOnQueue(
    _ opusData: Data,
    ptsUs: UInt64,
    framesPerPacketHint: UInt32
  ) {
    if ptsUs > 0 {
      logf(
        "AudioPlayer: enqueue frame bytes=%d pts_us=%llu frames_hint=%u",
        opusData.count,
        ptsUs,
        framesPerPacketHint
      )
    }

    let item = QueuedAudioFrame(
      ptsUs: ptsUs,
      data: opusData,
      framesPerPacketHint: framesPerPacketHint
    )
    insertQueuedAudioFrame(item)
    trimQueueSpanIfNeededOnQueue()
    ensureDrainTimerOnQueue()
    drainQueuedAudioOnQueue()
  }

  private func suspendPlaybackOnQueue() {
    queuedFrames.removeAll(keepingCapacity: true)
    resetGateBlockTrackingOnQueue()
    converter.reset()
    if playerNode.isPlaying {
      playerNode.stop()
    }
    if engine.isRunning {
      engine.pause()
    }
    logf("AudioPlayer: playback suspended and queue cleared")
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
      logf("AudioPlayer: failed to start audio engine: \(error.localizedDescription)")
      return
    }

    var drainedCount = 0
    while !queuedFrames.isEmpty {
      let next = queuedFrames[0]

      if next.ptsUs == 0 {
        resetGateBlockTrackingOnQueue()
        queuedFrames.removeFirst()
        decodeAndSchedule(
          opusData: next.data,
          ptsUs: 0,
          framesPerPacketHint: next.framesPerPacketHint,
          bypassedPtsGate: false
        )
        drainedCount += 1
      } else {
        // Audio-only sessions never receive a video keyframe, so allow audio
        // to establish the shared playback clock when it is the first media.
        syncClock.anchorIfNeeded(remotePtsUs: next.ptsUs, source: "first audio frame")

        guard let playablePtsUsRaw = syncClock.playablePtsUpperBoundUs() else {
          logGateBlockOnQueue(
            reason: "waiting_for_sync_anchor",
            nextPtsUs: next.ptsUs,
            playablePtsUs: nil
          )
          if shouldBypassPtsGateOnQueue(queueDepth: queuedFrames.count) {
            logf(
              "AudioPlayer: bypassing PTS gate after stall (no sync anchor yet). queue_depth=%d next_pts_us=%llu",
              queuedFrames.count,
              next.ptsUs
            )
            queuedFrames.removeFirst()
            decodeAndSchedule(
              opusData: next.data,
              ptsUs: next.ptsUs,
              framesPerPacketHint: next.framesPerPacketHint,
              bypassedPtsGate: true
            )
            drainedCount += 1
            continue
          }
          break
        }
        let playablePtsUs = playablePtsUsRaw > Self.audioLeadTrimUs
          ? (playablePtsUsRaw - Self.audioLeadTrimUs)
          : 0

        let droppedForLag = dropStaleQueuedAudioIfNeededOnQueue(playablePtsUs: playablePtsUs)
        if droppedForLag > 0 {
          continue
        }

        if next.ptsUs > playablePtsUs {
          logGateBlockOnQueue(
            reason: "waiting_for_pts_window",
            nextPtsUs: next.ptsUs,
            playablePtsUs: playablePtsUs
          )
          if shouldBypassPtsGateOnQueue(queueDepth: queuedFrames.count) {
            let deltaUs = next.ptsUs - playablePtsUs
            logf(
              "AudioPlayer: bypassing PTS gate after stall (delta_us=%llu queue_depth=%d next_pts_us=%llu playable_pts_us=%llu)",
              deltaUs,
              queuedFrames.count,
              next.ptsUs,
              playablePtsUs
            )
            queuedFrames.removeFirst()
            decodeAndSchedule(
              opusData: next.data,
              ptsUs: next.ptsUs,
              framesPerPacketHint: next.framesPerPacketHint,
              bypassedPtsGate: true
            )
            drainedCount += 1
            continue
          }
          break
        }

        resetGateBlockTrackingOnQueue()
        queuedFrames.removeFirst()
        decodeAndSchedule(
          opusData: next.data,
          ptsUs: next.ptsUs,
          framesPerPacketHint: next.framesPerPacketHint,
          bypassedPtsGate: false
        )
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
        logf(
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

  private func decodeAndSchedule(
    opusData: Data,
    ptsUs: UInt64,
    framesPerPacketHint: UInt32,
    bypassedPtsGate: Bool
  ) {
    var decodeAttempt: (AVAudioPCMBuffer, AVAudioConverterOutputStatus, UInt32)?
    var triedExactSenderHint = false
    if framesPerPacketHint > 0 {
      triedExactSenderHint = true
      decodeAttempt = decodeOpusPacketToPcm(opusData, framesPerPacketHint: framesPerPacketHint)
    }
    if decodeAttempt == nil {
      decodeAttempt = decodeOpusPacketToPcm(opusData, framesPerPacketHint: 0)
    }
    if decodeAttempt == nil
      && (!triedExactSenderHint || framesPerPacketHint != Self.opusFramesPerPacket)
    {
      decodeAttempt = decodeOpusPacketToPcm(opusData, framesPerPacketHint: Self.opusFramesPerPacket)
    }

    guard let (pcmBuffer, status, usedFramesHint) = decodeAttempt else {
      logf(
        "AudioPlayer: Opus decode exhausted retries (bytes=%d pts_us=%llu sender_frames_hint=%u bypassed=%d)",
        opusData.count,
        ptsUs,
        framesPerPacketHint,
        bypassedPtsGate ? 1 : 0
      )
      return
    }

    if !engine.isRunning || !playerNode.isPlaying {
      do {
        try start()
      } catch {
        logf(
          "AudioPlayer: failed to re-start engine before scheduling audio: \(error.localizedDescription)"
        )
        return
      }
    }

    playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    if !playerNode.isPlaying {
      playerNode.play()
    }
    log(
      "DEBUG: Audio buffer decoded to PCM and scheduled frames=\(pcmBuffer.frameLength) bytes=\(opusData.count) pts_us=\(ptsUs) bypassed_pts_gate=\(bypassedPtsGate) status=\(Self.converterStatusName(status)) frames_hint=\(usedFramesHint) sender_frames_hint=\(framesPerPacketHint)"
    )
    if bypassedPtsGate {
      logf(
        "AudioPlayer: scheduled audio after PTS gate bypass frames=%u bytes=%d pts_us=%llu",
        pcmBuffer.frameLength,
        opusData.count,
        ptsUs
      )
    }
  }

  private func decodeOpusPacketToPcm(
    _ opusData: Data,
    framesPerPacketHint: UInt32
  ) -> (AVAudioPCMBuffer, AVAudioConverterOutputStatus, UInt32)? {
    let maximumPacketSize = max(converter.maximumOutputPacketSize, opusData.count)
    let compressedBuffer = AVAudioCompressedBuffer(
      format: opusFormat,
      packetCapacity: 1,
      maximumPacketSize: maximumPacketSize
    )
    compressedBuffer.packetCount = 1
    compressedBuffer.byteLength = UInt32(opusData.count)

    opusData.withUnsafeBytes { rawBuffer in
      guard let source = rawBuffer.baseAddress else { return }
      memcpy(compressedBuffer.data, source, opusData.count)
    }

    if let packetDescriptions = compressedBuffer.packetDescriptions {
      packetDescriptions.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        // Opus packet durations vary (the sender now shows mixed 3ms/20ms packet cadence).
        // Prefer letting CoreAudio derive it from the bitstream; fall back to 960 if needed.
        mVariableFramesInPacket: framesPerPacketHint,
        mDataByteSize: UInt32(opusData.count)
      )
    } else {
      logf("AudioPlayer: missing packetDescriptions for Opus buffer bytes=%d", opusData.count)
    }

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else {
      logf("AudioPlayer: \(AudioPlayerError.pcmBufferAllocationFailed.localizedDescription)")
      return nil
    }

    converter.reset()
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
        logf(
          "AudioPlayer: Opus decode failed (frames_hint=%u bytes=%d): %@",
          framesPerPacketHint,
          opusData.count,
          convertError.localizedDescription
        )
      } else {
        logf(
          "AudioPlayer: Opus decode failed with unknown converter error (frames_hint=%u bytes=%d)",
          framesPerPacketHint,
          opusData.count
        )
      }
      converter.reset()
      return nil
    }

    guard pcmBuffer.frameLength > 0 else {
      logf(
        "AudioPlayer: Opus decode produced no PCM (status=%@ bytes=%d frames_hint=%u)",
        Self.converterStatusName(status),
        opusData.count,
        framesPerPacketHint
      )
      converter.reset()
      return nil
    }

    converter.reset()
    return (pcmBuffer, status, framesPerPacketHint)
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
      logf(
        "AudioPlayer: drain blocked reason=%@ queue_depth=%d next_pts_us=%llu playable_pts_us=%llu delta_us=%llu clock_anchored=%d",
        reason,
        queuedFrames.count,
        nextPtsUs,
        playablePtsUs,
        deltaUs,
        syncClock.isAnchored() ? 1 : 0
      )
    } else {
      logf(
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

  private func trimQueueSpanIfNeededOnQueue() {
    guard queuedFrames.count > 2 else { return }
    guard
      let firstPtsUs = queuedFrames.first(where: { $0.ptsUs > 0 })?.ptsUs,
      let lastPtsUs = queuedFrames.last(where: { $0.ptsUs > 0 })?.ptsUs,
      lastPtsUs > firstPtsUs
    else {
      return
    }

    var spanUs = lastPtsUs - firstPtsUs
    guard spanUs > Self.maxQueuedAudioSpanUs else { return }

    var dropped = 0
    while queuedFrames.count > 1 {
      guard let head = queuedFrames.first else { break }
      guard head.ptsUs > 0 else {
        queuedFrames.removeFirst()
        dropped += 1
        continue
      }
      guard let newLastPtsUs = queuedFrames.last(where: { $0.ptsUs > 0 })?.ptsUs else { break }
      spanUs = newLastPtsUs > head.ptsUs ? (newLastPtsUs - head.ptsUs) : 0
      if spanUs <= Self.maxQueuedAudioSpanUs {
        break
      }
      queuedFrames.removeFirst()
      dropped += 1
    }

    if dropped > 0 {
      resetGateBlockTrackingOnQueue()
      logf(
        "AudioPlayer: trimmed queued audio span by dropping %d packet(s); queue_depth=%d target_span_us=%llu",
        dropped,
        queuedFrames.count,
        Self.maxQueuedAudioSpanUs
      )
    }
  }

  private func dropStaleQueuedAudioIfNeededOnQueue(playablePtsUs: UInt64) -> Int {
    var dropped = 0
    while let head = queuedFrames.first {
      guard head.ptsUs > 0 else { break }
      let headLateByUs = playablePtsUs > head.ptsUs ? (playablePtsUs - head.ptsUs) : 0
      if headLateByUs <= Self.staleAudioDropThresholdUs {
        break
      }
      queuedFrames.removeFirst()
      dropped += 1
    }

    if dropped > 0 {
      resetGateBlockTrackingOnQueue()
      logf(
        "AudioPlayer: dropped %d stale audio packet(s) to catch up (queue_depth=%d playable_pts_us=%llu threshold_us=%llu)",
        dropped,
        queuedFrames.count,
        playablePtsUs,
        Self.staleAudioDropThresholdUs
      )
    }
    return dropped
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

  private func log(_ message: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(message)"
    debugLogQueue.sync {
      debugLogLines.append(line)
      if debugLogLines.count > Self.maxDebugLogLines {
        debugLogLines.removeFirst(debugLogLines.count - Self.maxDebugLogLines)
      }
    }
    NSLog("%@", message)
  }

  private func logf(_ format: String, _ args: CVarArg...) {
    let message = withVaList(args) { pointer in
      NSString(format: format, arguments: pointer) as String
    }
    log(message)
  }
}
