import AVFoundation
import Flutter
import Foundation
import VideoToolbox

private enum HevcDumperError: LocalizedError {
  case cameraPermissionDenied
  case microphonePermissionDenied
  case cameraUnavailable
  case microphoneUnavailable
  case cannotAddInput
  case cannotAddAudioInput
  case cannotAddOutput
  case cannotAddAudioOutput
  case cannotCreateEncoder(status: OSStatus)
  case cannotSetBitrate(status: OSStatus)
  case cannotCreateAudioConverter
  case opusRequiresIos15
  case invalidBitrate
  case notRecording

  var errorDescription: String? {
    switch self {
    case .cameraPermissionDenied:
      return "Camera permission is required to record HEVC."
    case .microphonePermissionDenied:
      return "Microphone permission is required to capture Opus audio."
    case .cameraUnavailable:
      return "No usable camera was found on this device."
    case .microphoneUnavailable:
      return "No usable microphone was found on this device."
    case .cannotAddInput:
      return "Failed to add camera input to AVCaptureSession."
    case .cannotAddAudioInput:
      return "Failed to add microphone input to AVCaptureSession."
    case .cannotAddOutput:
      return "Failed to add AVCaptureVideoDataOutput to AVCaptureSession."
    case .cannotAddAudioOutput:
      return "Failed to add AVCaptureAudioDataOutput to AVCaptureSession."
    case .cannotCreateEncoder(let status):
      return "Failed to create HEVC encoder session (status \(status))."
    case .cannotSetBitrate(let status):
      return "Failed to update HEVC encoder bitrate (status \(status))."
    case .cannotCreateAudioConverter:
      return "Failed to create Opus audio converter."
    case .opusRequiresIos15:
      return "Native Opus audio capture requires iOS 15 or later."
    case .invalidBitrate:
      return "Bitrate must be a positive integer."
    case .notRecording:
      return "No active HEVC recording session."
    }
  }
}

final class HevcAudioStreamHandler: NSObject, FlutterStreamHandler {
  weak var owner: HevcDumper?

  init(owner: HevcDumper? = nil) {
    self.owner = owner
    super.init()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    owner?.setAudioEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.setAudioEventSink(nil)
    return nil
  }
}

final class HevcDumper: NSObject, FlutterStreamHandler {
  private static let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])
  private static let videoCodecHevc: UInt8 = 0x01
  private static let audioCodecOpus: UInt8 = 0x03
  private static let opusSampleRateHz: UInt64 = 48_000
  private static let defaultOpusFramesPerPacket: UInt32 = 960
  private static let hevcOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer
  in
    guard
      status == noErr,
      let outputCallbackRefCon,
      let sampleBuffer
    else {
      return
    }

    let dumper = Unmanaged<HevcDumper>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    dumper.handleEncodedSampleBuffer(sampleBuffer)
  }

  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let sessionQueue = DispatchQueue(label: "com.nomikai.sankaku.hevc_dumper.session")

  private var compressionSession: VTCompressionSession?
  private var videoEventSink: FlutterEventSink?
  private var audioEventSink: FlutterEventSink?
  private var audioConverter: AVAudioConverter?
  private var audioInputFormat: AVAudioFormat?
  private var audioOutputFormat: AVAudioFormat?
  private var audioConverterError: HevcDumperError?
  private var audioOnlyMode = false

  let audioStreamHandler: HevcAudioStreamHandler

  private(set) var isRecording = false

  override init() {
    self.audioStreamHandler = HevcAudioStreamHandler()
    super.init()
    self.audioStreamHandler.owner = self
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    videoEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    videoEventSink = nil
    return nil
  }

  func setAudioEventSink(_ sink: FlutterEventSink?) {
    audioEventSink = sink
  }

  private func ensureMediaAuthorization(
    for mediaType: AVMediaType,
    deniedError: HevcDumperError,
    completion: @escaping (Bool) -> Void
  ) {
    let status = AVCaptureDevice.authorizationStatus(for: mediaType)
    switch status {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: mediaType) { granted in
        completion(granted)
      }
    case .denied, .restricted:
      NSLog("HevcDumper: authorization denied for \(mediaType.rawValue): \(deniedError.localizedDescription)")
      completion(false)
    @unknown default:
      completion(false)
    }
  }

  func startRecording(videoEnabled: Bool, completion: @escaping (Error?) -> Void) {
    if !videoEnabled {
      ensureMediaAuthorization(
        for: .audio,
        deniedError: HevcDumperError.microphonePermissionDenied
      ) { [weak self] audioGranted in
        guard let self else { return }
        guard audioGranted else {
          DispatchQueue.main.async {
            completion(HevcDumperError.microphonePermissionDenied)
          }
          return
        }

        self.sessionQueue.async {
          self.startRecordingOnSessionQueue(videoEnabled: false, completion: completion)
        }
      }
      return
    }

    ensureMediaAuthorization(for: .video, deniedError: HevcDumperError.cameraPermissionDenied) {
      [weak self] videoGranted in
      guard let self else { return }
      guard videoGranted else {
        DispatchQueue.main.async {
          completion(HevcDumperError.cameraPermissionDenied)
        }
        return
      }

        self.ensureMediaAuthorization(
          for: .audio,
          deniedError: HevcDumperError.microphonePermissionDenied
        ) { audioGranted in
        guard audioGranted else {
          DispatchQueue.main.async {
            completion(HevcDumperError.microphonePermissionDenied)
          }
          return
        }

        self.sessionQueue.async {
          self.startRecordingOnSessionQueue(videoEnabled: true, completion: completion)
        }
      }
    }
  }

  // Backward-compatible wrapper for older call sites that still pass audioOnly.
  func startRecording(audioOnly: Bool = false, completion: @escaping (Error?) -> Void) {
    startRecording(videoEnabled: !audioOnly, completion: completion)
  }

  func stopRecording(completion: @escaping (Error?) -> Void) {
    sessionQueue.async {
      guard self.isRecording else {
        DispatchQueue.main.async {
          completion(HevcDumperError.notRecording)
        }
        return
      }

      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }

      if let compressionSession = self.compressionSession {
        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
      }

      self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
      self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
      self.audioConverter = nil
      self.audioInputFormat = nil
      self.audioOutputFormat = nil
      self.audioConverterError = nil
      self.audioOnlyMode = false
      self.isRecording = false
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )

      DispatchQueue.main.async {
        completion(nil)
      }
    }
  }

  func setBitrate(bitrate: Int, completion: @escaping (Error?) -> Void) {
    sessionQueue.async {
      guard bitrate > 0 else {
        DispatchQueue.main.async {
          completion(HevcDumperError.invalidBitrate)
        }
        return
      }
      if self.audioOnlyMode {
        DispatchQueue.main.async {
          completion(nil)
        }
        return
      }
      guard self.isRecording, let compressionSession = self.compressionSession else {
        DispatchQueue.main.async {
          completion(HevcDumperError.notRecording)
        }
        return
      }

      let normalizedBitrate = NSNumber(value: bitrate)
      let status = VTSessionSetProperty(
        compressionSession,
        key: kVTCompressionPropertyKey_AverageBitRate,
        value: normalizedBitrate
      )
      if status != noErr {
        DispatchQueue.main.async {
          completion(HevcDumperError.cannotSetBitrate(status: status))
        }
        return
      }

      DispatchQueue.main.async {
        completion(nil)
      }
    }
  }

  private func startRecordingOnSessionQueue(
    videoEnabled: Bool,
    completion: @escaping (Error?) -> Void
  ) {
    guard !isRecording else {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }

    do {
      self.audioOnlyMode = !videoEnabled
      let dimensions = try configureCaptureSession(videoEnabled: videoEnabled)
      if videoEnabled {
        guard let dimensions else {
          throw HevcDumperError.cameraUnavailable
        }
        try configureCompressionSession(width: dimensions.width, height: dimensions.height)
      } else {
        compressionSession = nil
      }

      isRecording = true
      captureSession.startRunning()

      DispatchQueue.main.async {
        completion(nil)
      }
    } catch {
      teardownSessionState()
      DispatchQueue.main.async {
        completion(error)
      }
    }
  }

  private func configureCaptureSession(videoEnabled: Bool) throws -> CMVideoDimensions? {
    captureSession.beginConfiguration()
    defer { captureSession.commitConfiguration() }

    captureSession.sessionPreset = videoEnabled ? .hd1280x720 : .high
    captureSession.inputs.forEach { captureSession.removeInput($0) }
    captureSession.outputs.forEach { captureSession.removeOutput($0) }

    guard let microphone = AVCaptureDevice.default(for: .audio) else {
      throw HevcDumperError.microphoneUnavailable
    }

    let audioInput = try AVCaptureDeviceInput(device: microphone)
    guard captureSession.canAddInput(audioInput) else {
      throw HevcDumperError.cannotAddAudioInput
    }
    captureSession.addInput(audioInput)

    audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    guard captureSession.canAddOutput(audioOutput) else {
      throw HevcDumperError.cannotAddAudioOutput
    }
    captureSession.addOutput(audioOutput)

    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    guard videoEnabled else {
      return nil
    }

    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else {
      throw HevcDumperError.cameraUnavailable
    }

    let input = try AVCaptureDeviceInput(device: camera)
    guard captureSession.canAddInput(input) else {
      throw HevcDumperError.cannotAddInput
    }
    captureSession.addInput(input)

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

    guard captureSession.canAddOutput(videoOutput) else {
      throw HevcDumperError.cannotAddOutput
    }
    captureSession.addOutput(videoOutput)

    return CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
  }

  private func configureCompressionSession(width: Int32, height: Int32) throws {
    var compressionSession: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: width,
      height: height,
      codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: Self.hevcOutputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &compressionSession
    )

    guard status == noErr, let compressionSession else {
      throw HevcDumperError.cannotCreateEncoder(status: status)
    }

    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_RealTime,
      value: kCFBooleanTrue
    )
    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_HEVC_Main_AutoLevel
    )
    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_AllowFrameReordering,
      value: kCFBooleanFalse
    )
    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: NSNumber(value: 30)
    )

    VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    self.compressionSession = compressionSession
  }

  private func teardownSessionState() {
    if captureSession.isRunning {
      captureSession.stopRunning()
    }

    if let compressionSession = compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
      self.compressionSession = nil
    }

    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    audioOutput.setSampleBufferDelegate(nil, queue: nil)
    audioConverter = nil
    audioInputFormat = nil
    audioOutputFormat = nil
    audioConverterError = nil
    audioOnlyMode = false
    isRecording = false
  }

  private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

    let keyframe = isKeyFrame(sampleBuffer)
    var annexBFrame = Data()
    if keyframe {
      appendParameterSets(sampleBuffer, to: &annexBFrame)
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    appendAnnexBNALUnits(from: blockBuffer, to: &annexBFrame)

    guard !annexBFrame.isEmpty else { return }
    emitFrame(annexBFrame, isKeyframe: keyframe, ptsUs: ptsUs)
  }

  private func emitFrame(_ data: Data, isKeyframe: Bool, ptsUs: UInt64) {
    DispatchQueue.main.async { [weak self] in
      guard let eventSink = self?.videoEventSink else { return }
      eventSink([
        "bytes": FlutterStandardTypedData(bytes: data),
        "is_keyframe": isKeyframe,
        "pts": NSNumber(value: ptsUs),
        "codec": NSNumber(value: Self.videoCodecHevc),
      ])
    }
  }

  private func appendParameterSets(_ sampleBuffer: CMSampleBuffer, to buffer: inout Data) {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

    var nalUnitHeaderLength: Int32 = 0
    for index in 0..<3 {
      var parameterSetPointer: UnsafePointer<UInt8>?
      var parameterSetSize = 0
      var parameterSetCount = 0

      let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: index,
        parameterSetPointerOut: &parameterSetPointer,
        parameterSetSizeOut: &parameterSetSize,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
      )

      guard status == noErr, let parameterSetPointer else { continue }
      buffer.append(Self.annexBStartCode)
      buffer.append(parameterSetPointer, count: parameterSetSize)
    }
  }

  private func appendAnnexBNALUnits(from blockBuffer: CMBlockBuffer, to buffer: inout Data) {
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    )

    guard status == kCMBlockBufferNoErr, let dataPointer else { return }

    var bufferOffset = 0
    let lengthFieldSize = 4

    while bufferOffset + lengthFieldSize <= totalLength {
      var nalUnitLength: UInt32 = 0
      memcpy(&nalUnitLength, dataPointer.advanced(by: bufferOffset), lengthFieldSize)
      nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)

      let nalLength = Int(nalUnitLength)
      let nalStart = bufferOffset + lengthFieldSize
      guard nalLength > 0, nalStart + nalLength <= totalLength else { break }

      buffer.append(Self.annexBStartCode)
      buffer.append(Data(bytes: dataPointer.advanced(by: nalStart), count: nalLength))

      bufferOffset = nalStart + nalLength
    }
  }

  private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

    do {
      let converter = try ensureAudioConverter(for: sampleBuffer)
      guard
        let pcmBuffer = makePcmBuffer(from: sampleBuffer, format: converter.inputFormat),
        let opusPackets = encodeOpus(from: pcmBuffer, using: converter),
        !opusPackets.isEmpty
      else {
        return
      }

      var packetPtsUs = ptsUs
      for packet in opusPackets {
        emitAudioFrame(
          packet.data,
          ptsUs: packetPtsUs,
          framesPerPacket: packet.framesPerPacket
        )
        let frameCount = max(UInt64(1), UInt64(packet.framesPerPacket))
        packetPtsUs =
          packetPtsUs
          &+ ((frameCount * 1_000_000) / Self.opusSampleRateHz)
      }
    } catch {
      if let dumpError = error as? HevcDumperError {
        audioConverterError = dumpError
      }
      NSLog("HevcDumper: audio encode error: \(error.localizedDescription)")
    }
  }

  private func emitAudioFrame(_ data: Data, ptsUs: UInt64, framesPerPacket: UInt32) {
    DispatchQueue.main.async { [weak self] in
      guard let eventSink = self?.audioEventSink else { return }
      eventSink([
        "bytes": FlutterStandardTypedData(bytes: data),
        "pts": NSNumber(value: ptsUs),
        "codec": NSNumber(value: Self.audioCodecOpus),
        "frames_per_packet": NSNumber(value: framesPerPacket),
      ])
    }
  }

  private static func microseconds(from time: CMTime) -> UInt64 {
    guard time.isValid, time.isNumeric, time.timescale != 0 else {
      return 0
    }

    let scaled = CMTimeConvertScale(
      time,
      timescale: 1_000_000,
      method: .default
    )
    guard scaled.isValid, scaled.isNumeric else {
      return 0
    }

    if scaled.value <= 0 {
      return 0
    }
    return UInt64(scaled.value)
  }

  private func ensureAudioConverter(for sampleBuffer: CMSampleBuffer) throws -> AVAudioConverter {
    let inputFormat = try makeInputAudioFormat(from: sampleBuffer)

    let needsNewConverter: Bool
    if let existingInputFormat = audioInputFormat,
      let existingOutputFormat = audioOutputFormat,
      let _ = audioConverter
    {
      needsNewConverter =
        existingInputFormat.sampleRate != inputFormat.sampleRate
        || existingInputFormat.channelCount != inputFormat.channelCount
        || existingOutputFormat.channelCount != 1
        || existingOutputFormat.sampleRate != 48_000
    } else {
      needsNewConverter = true
    }

    if !needsNewConverter, let audioConverter {
      return audioConverter
    }

    guard #available(iOS 15.0, *) else {
      throw HevcDumperError.opusRequiresIos15
    }

    guard
      let outputFormat = AVAudioFormat(
        settings: [
          AVFormatIDKey: kAudioFormatOpus,
          AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 32_000,
        ]
      ),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw HevcDumperError.cannotCreateAudioConverter
    }

    audioInputFormat = inputFormat
    audioOutputFormat = outputFormat
    audioConverter = converter
    audioConverterError = nil

    return converter
  }

  private func makeInputAudioFormat(from sampleBuffer: CMSampleBuffer) throws -> AVAudioFormat {
    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
      let format = AVAudioFormat(streamDescription: streamDescription)
    else {
      throw HevcDumperError.cannotCreateAudioConverter
    }

    return format
  }

  private func makePcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat)
    -> AVAudioPCMBuffer?
  {
    let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard sampleCount > 0 else { return nil }

    let frameCount = AVAudioFrameCount(sampleCount)
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      return nil
    }
    pcmBuffer.frameLength = frameCount

    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(sampleCount),
      into: pcmBuffer.mutableAudioBufferList
    )
    guard status == noErr else {
      NSLog("HevcDumper: failed to copy PCM audio (\(status))")
      return nil
    }

    return pcmBuffer
  }

  private struct EncodedOpusPacket {
    let data: Data
    let framesPerPacket: UInt32
  }

  private func encodeOpus(from pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter)
    -> [EncodedOpusPacket]?
  {
    let packetCapacity = max(
      AVAudioPacketCount(1),
      AVAudioPacketCount((pcmBuffer.frameLength / 1024) + 1)
    )
    let maximumPacketSize = max(
      512,
      converter.maximumOutputPacketSize
    )
    let outputBuffer = AVAudioCompressedBuffer(
      format: converter.outputFormat,
      packetCapacity: packetCapacity,
      maximumPacketSize: maximumPacketSize
    )

    var fedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      if fedInput {
        // Keep the converter in streaming mode between callbacks. Using
        // end-of-stream here causes per-callback flush/padding behavior.
        outStatus.pointee = .noDataNow
        return nil
      }

      fedInput = true
      outStatus.pointee = .haveData
      return pcmBuffer
    }

    if status == .error {
      if let conversionError {
        NSLog("HevcDumper: Opus conversion failed: \(conversionError)")
      } else {
        NSLog("HevcDumper: Opus conversion failed with unknown error")
      }
      converter.reset()
      return nil
    }

    guard outputBuffer.byteLength > 0, outputBuffer.packetCount > 0 else {
      NSLog(
        "HevcDumper: Opus conversion produced no output (status=%@ input_frames=%u packet_capacity=%u)",
        Self.converterStatusName(status),
        pcmBuffer.frameLength,
        packetCapacity
      )
      return nil
    }

    let totalByteLength = Int(outputBuffer.byteLength)
    let packetCount = Int(outputBuffer.packetCount)
    let packetDescriptions = outputBuffer.packetDescriptions

    if packetCount == 1 {
      let packetData = Data(bytes: outputBuffer.data, count: totalByteLength)
      let framesPerPacket =
        Self.opusFramesPerPacketHint(from: packetData)
        ?? packetDescriptions?.pointee.mVariableFramesInPacket
        ?? Self.defaultOpusFramesPerPacket
      let packet = EncodedOpusPacket(
        data: packetData,
        framesPerPacket: framesPerPacket > 0 ? framesPerPacket : Self.defaultOpusFramesPerPacket
      )
      return [packet]
    }

    guard let packetDescriptions else {
      NSLog(
        "HevcDumper: Opus encoder returned multiple packets (%d) without packetDescriptions; dropping buffer",
        packetCount
      )
      return nil
    }

    var packets: [EncodedOpusPacket] = []
    packets.reserveCapacity(packetCount)
    let descriptions = UnsafeBufferPointer(start: packetDescriptions, count: packetCount)
    for (index, desc) in descriptions.enumerated() {
      let startOffset = Int(desc.mStartOffset)
      let byteCount = Int(desc.mDataByteSize)
      guard startOffset >= 0, byteCount > 0, startOffset + byteCount <= totalByteLength else {
        NSLog(
          "HevcDumper: invalid Opus packet description idx=%d start=%d size=%d total=%d",
          index,
          startOffset,
          byteCount,
          totalByteLength
        )
        continue
      }
      let packetData = Data(bytes: outputBuffer.data.advanced(by: startOffset), count: byteCount)
      let describedFramesPerPacket: UInt32? =
        desc.mVariableFramesInPacket > 0 ? desc.mVariableFramesInPacket : nil
      let framesPerPacket =
        Self.opusFramesPerPacketHint(from: packetData)
        ?? describedFramesPerPacket
        ?? Self.defaultOpusFramesPerPacket
      packets.append(
        EncodedOpusPacket(data: packetData, framesPerPacket: framesPerPacket)
      )
    }

    if packets.count > 1 {
      NSLog(
        "HevcDumper: split Opus encode output into %d packets (input_frames=%u output_bytes=%u)",
        packets.count,
        pcmBuffer.frameLength,
        outputBuffer.byteLength
      )
    }

    return packets.isEmpty ? nil : packets
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

  private static func opusFramesPerPacketHint(from packetData: Data) -> UInt32? {
    guard let toc = packetData.first else {
      return nil
    }

    let config = toc >> 3
    guard let samplesPerFrame = opusSamplesPerFrame(tocConfig: config) else {
      return nil
    }

    let frameCountCode = toc & 0x03
    let frameCount: UInt8
    switch frameCountCode {
    case 0:
      frameCount = 1
    case 1, 2:
      frameCount = 2
    case 3:
      guard packetData.count >= 2 else {
        return nil
      }
      let countByte = packetData[packetData.index(after: packetData.startIndex)]
      let signaledFrameCount = countByte & 0x3F
      guard signaledFrameCount > 0 else {
        return nil
      }
      frameCount = signaledFrameCount
    default:
      return nil
    }

    let totalSamples = UInt32(samplesPerFrame) * UInt32(frameCount)
    guard totalSamples > 0, totalSamples <= 5_760 else {
      return nil
    }
    return totalSamples
  }

  private static func opusSamplesPerFrame(tocConfig: UInt8) -> UInt32? {
    switch tocConfig {
    case 0...11:
      switch tocConfig & 0x03 {
      case 0:
        return 480
      case 1:
        return 960
      case 2:
        return 1_920
      case 3:
        return 2_880
      default:
        return nil
      }
    case 12...15:
      return (tocConfig & 0x01) == 0 ? 480 : 960
    case 16...31:
      switch tocConfig & 0x03 {
      case 0:
        return 120
      case 1:
        return 240
      case 2:
        return 480
      case 3:
        return 960
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[CFString: Any]],
      let firstAttachment = attachments.first
    else {
      return false
    }

    let isNotSync = (firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    return !isNotSync
  }
}

extension HevcDumper: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard isRecording else { return }

    if output === audioOutput {
      handleAudioSampleBuffer(sampleBuffer)
      return
    }

    guard
      output === videoOutput,
      let compressionSession,
      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      return
    }

    let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: imageBuffer,
      presentationTimeStamp: presentationTimeStamp,
      duration: CMTime.invalid,
      frameProperties: nil,
      sourceFrameRefcon: nil,
      infoFlagsOut: nil
    )

    if status != noErr {
      NSLog("HevcDumper: encode error (\(status))")
    }
  }
}
