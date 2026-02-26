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
  private static let gateBlockLogIntervalUs: UInt64 = 250_000
  private static let renderSummaryLogIntervalUs: UInt64 = 250_000
  private static let maxDebugLogLines = 2_000

  private struct QueuedPcmChunk {
    let ptsUs: UInt64
    let samples: [Float]  // Mono PCM float32 samples.
    var readIndex: Int
    let sourceByteCount: Int
    let senderFramesPerPacketHint: UInt32

    var remainingFrames: Int {
      max(0, samples.count - readIndex)
    }
  }

  private let playerQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.queue")
  private let debugLogQueue = DispatchQueue(label: "com.nomikai.sankaku.audio_player.debug_log")
  private let pcmQueueLock = NSLock()
  private let engine = AVAudioEngine()
  private let syncClock: PlaybackSyncClock

  private let opusFormat: AVAudioFormat
  private let pcmFormat: AVAudioFormat
  private let converter: AVAudioConverter

  private lazy var sourceNode: AVAudioSourceNode = makeSourceNode()

  private var isStarted = false
  private var sourceNodeAttached = false
  private var voiceProcessingConfigured = false
  private var queuedPcmChunks: [QueuedPcmChunk] = []
  private var gateBlockedSinceUs: UInt64?
  private var lastGateBlockLogUs: UInt64 = 0
  private var lastRenderSummaryLogUs: UInt64 = 0
  private var lastDecoderStatusTraceUs: UInt64 = 0
  private var lastDecoderStatusTraceName: String?
  private var renderedFramesSinceSummary: UInt64 = 0
  private var silentFramesSinceSummary: UInt64 = 0
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
    // No explicit timer teardown: rendering is pull-driven by AVAudioSourceNode.
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
    if !sourceNodeAttached {
      engine.attach(sourceNode)
      engine.connect(sourceNode, to: engine.mainMixerNode, format: pcmFormat)
      sourceNodeAttached = true
      logf("AudioPlayer: AVAudioSourceNode attached to main mixer")
    }

    if !voiceProcessingConfigured {
      // One-time best-effort voice processing enablement. If this device/configuration
      // rejects it (e.g. -10849), we log and continue without retrying every frame.
      voiceProcessingConfigured = true
      do {
        if #available(macOS 10.15, *) {
          try engine.outputNode.setVoiceProcessingEnabled(true)
          logf("AudioPlayer: voice processing enabled on output node")
        } else {
          logf("AudioPlayer: voice processing unavailable on this macOS version")
        }
      } catch {
        logf(
          "AudioPlayer: failed to enable voice processing on output node: %@",
          error.localizedDescription
        )
      }
    }

    if !isStarted {
      engine.mainMixerNode.outputVolume = 1.0
      engine.prepare()
      isStarted = true
      logf("AudioPlayer: engine graph attached and prepared")
    }

    if !engine.isRunning {
      try engine.start()
      logf("AudioPlayer: AVAudioEngine started")
    }
  }

  func decodeAndPlay(opusData: Data, ptsUs: UInt64 = 0, framesPerPacketHint: UInt32 = 0) {
    guard !opusData.isEmpty else { return }

    playerQueue.async { [weak self] in
      guard let self else { return }
      self.enqueueDecodedAudioOnQueue(opusData, ptsUs: ptsUs, framesPerPacketHint: framesPerPacketHint)
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
        self.logf("AudioPlayer: resumed playback")
      } catch {
        self.logf("AudioPlayer: failed to resume playback: %@", error.localizedDescription)
      }
    }
  }

  private func enqueueDecodedAudioOnQueue(
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
      syncClock.anchorIfNeeded(remotePtsUs: ptsUs, source: "first audio frame")
    }

    do {
      try start()
    } catch {
      logf("AudioPlayer: failed to start audio engine: %@", error.localizedDescription)
      return
    }

    let effectiveFramesHint = framesPerPacketHint > 0 ? framesPerPacketHint : Self.opusFramesPerPacket
    guard let (pcmBuffer, status, usedFramesHint) = decodeOpusPacketToPcm(
      opusData,
      framesPerPacketHint: effectiveFramesHint
    ) else {
      return
    }

    guard let channelData = pcmBuffer.floatChannelData else {
      logf("AudioPlayer: decoded PCM buffer missing float channel data")
      return
    }

    let frameCount = Int(pcmBuffer.frameLength)
    guard frameCount > 0 else {
      logf(
        "AudioPlayer: decoded PCM buffer was empty after successful decode (bytes=%d pts_us=%llu)",
        opusData.count,
        ptsUs
      )
      return
    }

    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    enqueuePcmChunkOnQueue(
      QueuedPcmChunk(
        ptsUs: ptsUs,
        samples: samples,
        readIndex: 0,
        sourceByteCount: opusData.count,
        senderFramesPerPacketHint: framesPerPacketHint
      )
    )

    log(
      "DEBUG: Audio buffer decoded to PCM and queued frames=\(pcmBuffer.frameLength) bytes=\(opusData.count) pts_us=\(ptsUs) status=\(Self.converterStatusName(status)) frames_hint=\(usedFramesHint) sender_frames_hint=\(framesPerPacketHint)"
    )
  }

  private func enqueuePcmChunkOnQueue(_ chunk: QueuedPcmChunk) {
    pcmQueueLock.lock()
    defer { pcmQueueLock.unlock() }

    insertPcmChunkLocked(chunk)
    trimPcmQueueSpanIfNeededLocked()
  }

  private func suspendPlaybackOnQueue() {
    pcmQueueLock.lock()
    queuedPcmChunks.removeAll(keepingCapacity: true)
    gateBlockedSinceUs = nil
    renderedFramesSinceSummary = 0
    silentFramesSinceSummary = 0
    pcmQueueLock.unlock()

    converter.reset()

    if engine.isRunning {
      engine.pause()
    }

    logf("AudioPlayer: playback suspended and queue cleared")
  }

  private func insertPcmChunkLocked(_ item: QueuedPcmChunk) {
    guard item.ptsUs > 0 else {
      queuedPcmChunks.append(item)
      return
    }

    let insertionIndex: Int =
      queuedPcmChunks.firstIndex(where: { existing in
        existing.ptsUs > 0 && existing.ptsUs > item.ptsUs
      }) ?? queuedPcmChunks.endIndex
    queuedPcmChunks.insert(item, at: insertionIndex)
  }

  private func trimPcmQueueSpanIfNeededLocked() {
    guard queuedPcmChunks.count > 2 else { return }
    guard
      let firstPtsUs = queuedPcmChunks.first(where: { $0.ptsUs > 0 })?.ptsUs,
      let lastChunk = queuedPcmChunks.last(where: { $0.ptsUs > 0 })
    else {
      return
    }

    let lastPtsUs = lastChunk.ptsUs + Self.framesToMicros(lastChunk.remainingFrames)
    var spanUs = lastPtsUs > firstPtsUs ? (lastPtsUs - firstPtsUs) : 0
    guard spanUs > Self.maxQueuedAudioSpanUs else { return }

    var dropped = 0
    while queuedPcmChunks.count > 1 {
      guard let head = queuedPcmChunks.first else { break }
      if head.ptsUs == 0 {
        queuedPcmChunks.removeFirst()
        dropped += 1
        continue
      }
      guard let newest = queuedPcmChunks.last(where: { $0.ptsUs > 0 }) else { break }
      let newestEndPtsUs = newest.ptsUs + Self.framesToMicros(newest.remainingFrames)
      spanUs = newestEndPtsUs > head.ptsUs ? (newestEndPtsUs - head.ptsUs) : 0
      if spanUs <= Self.maxQueuedAudioSpanUs {
        break
      }
      queuedPcmChunks.removeFirst()
      dropped += 1
    }

    if dropped > 0 {
      gateBlockedSinceUs = nil
      logf(
        "AudioPlayer: trimmed queued audio span by dropping %d PCM chunk(s); queue_depth=%d target_span_us=%llu",
        dropped,
        queuedPcmChunks.count,
        Self.maxQueuedAudioSpanUs
      )
    }
  }

  private func makeSourceNode() -> AVAudioSourceNode {
    AVAudioSourceNode(format: pcmFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
      guard let self else {
        Self.zeroAudioBufferList(audioBufferList, frameCount: frameCount)
        return noErr
      }
      return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
    }
  }

  private func renderAudio(
    frameCount: AVAudioFrameCount,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    Self.zeroAudioBufferList(audioBufferList, frameCount: frameCount)

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let nowUs = Self.monotonicNowUs()

    var framesWritten = 0
    var framesSilenced = Int(frameCount)
    var renderBlockReason: (String, UInt64, UInt64?)?

    let playablePtsUsRaw = syncClock.playablePtsUpperBoundUs()
    let playablePtsUs = playablePtsUsRaw.map { raw in
      raw > Self.audioLeadTrimUs ? (raw - Self.audioLeadTrimUs) : 0
    }

    pcmQueueLock.lock()
    defer {
      renderedFramesSinceSummary += UInt64(framesWritten)
      silentFramesSinceSummary += UInt64(max(0, framesSilenced))
      if lastRenderSummaryLogUs == 0 || nowUs - lastRenderSummaryLogUs >= Self.renderSummaryLogIntervalUs {
        lastRenderSummaryLogUs = nowUs
        logf(
          "AudioPlayer: render summary rendered_frames=%llu silent_frames=%llu queue_depth=%d engine_running=%d clock_anchored=%d",
          renderedFramesSinceSummary,
          silentFramesSinceSummary,
          queuedPcmChunks.count,
          engine.isRunning ? 1 : 0,
          syncClock.isAnchored() ? 1 : 0
        )
        renderedFramesSinceSummary = 0
        silentFramesSinceSummary = 0
      }
      if let (reason, nextPtsUs, playablePtsUs) = renderBlockReason,
        shouldLogGateBlockLocked(nowUs: nowUs)
      {
        if let playablePtsUs {
          let deltaUs = nextPtsUs > playablePtsUs ? (nextPtsUs - playablePtsUs) : 0
          logf(
            "AudioPlayer: render blocked reason=%@ queue_depth=%d next_pts_us=%llu playable_pts_us=%llu delta_us=%llu clock_anchored=%d",
            reason,
            queuedPcmChunks.count,
            nextPtsUs,
            playablePtsUs,
            deltaUs,
            syncClock.isAnchored() ? 1 : 0
          )
        } else {
          logf(
            "AudioPlayer: render blocked reason=%@ queue_depth=%d next_pts_us=%llu clock_anchored=%d",
            reason,
            queuedPcmChunks.count,
            nextPtsUs,
            syncClock.isAnchored() ? 1 : 0
          )
        }
      }
      pcmQueueLock.unlock()
    }

    while framesWritten < Int(frameCount) {
      if queuedPcmChunks.isEmpty {
        renderBlockReason = ("queue_empty", 0, playablePtsUs)
        break
      }

      if let playablePtsUs {
        let dropped = dropStalePcmLocked(playablePtsUs: playablePtsUs)
        if dropped > 0 {
          continue
        }
      }

      guard !queuedPcmChunks.isEmpty else {
        renderBlockReason = ("queue_empty", 0, playablePtsUs)
        break
      }

      var head = queuedPcmChunks[0]
      guard head.remainingFrames > 0 else {
        queuedPcmChunks.removeFirst()
        continue
      }

      if head.ptsUs > 0 {
        let currentHeadPtsUs = Self.chunkCurrentPtsUs(head)
        syncClock.anchorIfNeeded(remotePtsUs: currentHeadPtsUs, source: "first audio frame")

        guard let playablePtsUs else {
          gateBlockedSinceUs = gateBlockedSinceUs ?? nowUs
          renderBlockReason = ("waiting_for_sync_anchor", currentHeadPtsUs, nil)
          break
        }

        if currentHeadPtsUs > playablePtsUs {
          gateBlockedSinceUs = gateBlockedSinceUs ?? nowUs
          renderBlockReason = ("waiting_for_pts_window", currentHeadPtsUs, playablePtsUs)
          break
        }
      }

      gateBlockedSinceUs = nil

      let framesRemaining = Int(frameCount) - framesWritten
      let copyCount = min(framesRemaining, head.remainingFrames)
      if copyCount <= 0 {
        break
      }

      Self.copyMonoSamples(
        head.samples,
        from: head.readIndex,
        count: copyCount,
        into: buffers,
        destinationFrameOffset: framesWritten
      )

      head.readIndex += copyCount
      framesWritten += copyCount
      framesSilenced -= copyCount

      if head.remainingFrames <= 0 {
        queuedPcmChunks.removeFirst()
      } else {
        queuedPcmChunks[0] = head
      }
    }

    return noErr
  }

  private func dropStalePcmLocked(playablePtsUs: UInt64) -> Int {
    var dropped = 0
    while !queuedPcmChunks.isEmpty {
      var head = queuedPcmChunks[0]
      guard head.ptsUs > 0 else { break }
      guard head.remainingFrames > 0 else {
        queuedPcmChunks.removeFirst()
        dropped += 1
        continue
      }

      let currentPtsUs = Self.chunkCurrentPtsUs(head)
      let lateByUs = playablePtsUs > currentPtsUs ? (playablePtsUs - currentPtsUs) : 0
      if lateByUs <= Self.staleAudioDropThresholdUs {
        break
      }

      let dropFrames = min(
        head.remainingFrames,
        max(1, Self.microsToFrames(lateByUs - Self.staleAudioDropThresholdUs))
      )
      head.readIndex += dropFrames
      if head.remainingFrames <= 0 {
        queuedPcmChunks.removeFirst()
      } else {
        queuedPcmChunks[0] = head
      }
      dropped += 1
    }

    if dropped > 0 {
      gateBlockedSinceUs = nil
      logf(
        "AudioPlayer: dropped stale decoded audio chunk/frame window(s)=%d queue_depth=%d playable_pts_us=%llu threshold_us=%llu",
        dropped,
        queuedPcmChunks.count,
        playablePtsUs,
        Self.staleAudioDropThresholdUs
      )
    }

    return dropped
  }

  private func shouldLogGateBlockLocked(nowUs: UInt64) -> Bool {
    if lastGateBlockLogUs != 0 && nowUs - lastGateBlockLogUs < Self.gateBlockLogIntervalUs {
      return false
    }
    lastGateBlockLogUs = nowUs
    return true
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
        mVariableFramesInPacket: framesPerPacketHint,
        mDataByteSize: UInt32(opusData.count)
      )
    } else {
      logf("AudioPlayer: missing packetDescriptions for Opus buffer bytes=%d", opusData.count)
    }

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else {
      logf("AudioPlayer: %@", AudioPlayerError.pcmBufferAllocationFailed.localizedDescription)
      return nil
    }

    var providedInput = false
    var inputBlockReturnedNoDataNow = false
    var convertError: NSError?
    let status = converter.convert(to: pcmBuffer, error: &convertError) { _, outStatus in
      if providedInput {
        inputBlockReturnedNoDataNow = true
        outStatus.pointee = .noDataNow
        return nil
      }
      providedInput = true
      outStatus.pointee = .haveData
      return compressedBuffer
    }

    let statusName = Self.converterStatusName(status)
    let nowUs = Self.monotonicNowUs()
    let shouldTraceStatus =
      inputBlockReturnedNoDataNow
      || status == .haveData
      || lastDecoderStatusTraceName != statusName
    if shouldTraceStatus
      && (inputBlockReturnedNoDataNow
        || lastDecoderStatusTraceName != statusName
        || lastDecoderStatusTraceUs == 0
        || nowUs - lastDecoderStatusTraceUs >= 500_000)
    {
      logf(
        "AudioPlayer: Opus converter trace input_no_data_now=%d output_status=%@ pcm_frames=%u bytes=%d frames_hint=%u",
        inputBlockReturnedNoDataNow ? 1 : 0,
        statusName,
        pcmBuffer.frameLength,
        opusData.count,
        framesPerPacketHint
      )
      lastDecoderStatusTraceUs = nowUs
      lastDecoderStatusTraceName = statusName
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
      return nil
    }

    guard pcmBuffer.frameLength > 0 else {
      logf(
        "AudioPlayer: Opus decode produced no PCM (status=%@ bytes=%d frames_hint=%u)",
        statusName,
        opusData.count,
        framesPerPacketHint
      )
      return nil
    }

    return (pcmBuffer, status, framesPerPacketHint)
  }

  private static func zeroAudioBufferList(
    _ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
    frameCount: AVAudioFrameCount
  ) {
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for index in 0..<buffers.count {
      guard let data = buffers[index].mData else { continue }
      let bytesPerFrame = max(1, Int(buffers[index].mDataByteSize) / max(1, Int(frameCount)))
      let bytesToClear = min(Int(buffers[index].mDataByteSize), Int(frameCount) * bytesPerFrame)
      memset(data, 0, bytesToClear)
    }
  }

  private static func copyMonoSamples(
    _ source: [Float],
    from sourceOffset: Int,
    count: Int,
    into buffers: UnsafeMutableAudioBufferListPointer,
    destinationFrameOffset: Int
  ) {
    guard count > 0, sourceOffset >= 0, sourceOffset + count <= source.count else { return }

    if buffers.count == 1, let data = buffers[0].mData {
      let channels = max(1, Int(buffers[0].mNumberChannels))
      let dest = data.bindMemory(to: Float.self, capacity: (destinationFrameOffset + count) * channels)
      if channels == 1 {
        _ = source.withUnsafeBufferPointer { src in
          memcpy(
            dest.advanced(by: destinationFrameOffset),
            src.baseAddress!.advanced(by: sourceOffset),
            count * MemoryLayout<Float>.size
          )
        }
      } else {
        for frame in 0..<count {
          let sample = source[sourceOffset + frame]
          let base = (destinationFrameOffset + frame) * channels
          for channel in 0..<channels {
            dest[base + channel] = sample
          }
        }
      }
      return
    }

    for bufferIndex in 0..<buffers.count {
      guard let data = buffers[bufferIndex].mData else { continue }
      let dest = data.bindMemory(to: Float.self, capacity: destinationFrameOffset + count)
      for frame in 0..<count {
        dest[destinationFrameOffset + frame] = source[sourceOffset + frame]
      }
    }
  }

  private static func chunkCurrentPtsUs(_ chunk: QueuedPcmChunk) -> UInt64 {
    if chunk.ptsUs == 0 || chunk.readIndex <= 0 {
      return chunk.ptsUs
    }
    return chunk.ptsUs &+ framesToMicros(chunk.readIndex)
  }

  private static func framesToMicros(_ frames: Int) -> UInt64 {
    guard frames > 0 else { return 0 }
    return (UInt64(frames) * 1_000_000) / UInt64(opusSampleRateHz)
  }

  private static func microsToFrames(_ micros: UInt64) -> Int {
    if micros == 0 { return 0 }
    return Int((micros * UInt64(opusSampleRateHz)) / 1_000_000)
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
