import AVFoundation
import Flutter
import Foundation
import VideoToolbox

private enum HevcDumperError: LocalizedError {
  case cameraPermissionDenied
  case cameraUnavailable
  case cannotAddInput
  case cannotAddOutput
  case cannotCreateEncoder(status: OSStatus)
  case notRecording

  var errorDescription: String? {
    switch self {
    case .cameraPermissionDenied:
      return "Camera permission is required to record HEVC."
    case .cameraUnavailable:
      return "No usable camera was found on this device."
    case .cannotAddInput:
      return "Failed to add camera input to AVCaptureSession."
    case .cannotAddOutput:
      return "Failed to add AVCaptureVideoDataOutput to AVCaptureSession."
    case .cannotCreateEncoder(let status):
      return "Failed to create HEVC encoder session (status \(status))."
    case .notRecording:
      return "No active HEVC recording session."
    }
  }
}

final class HevcDumper: NSObject, FlutterStreamHandler {
  private static let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])
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
  private let sessionQueue = DispatchQueue(label: "com.nomikai.sankaku.hevc_dumper.session")

  private var compressionSession: VTCompressionSession?
  private var eventSink: FlutterEventSink?

  private(set) var isRecording = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func startRecording(completion: @escaping (Error?) -> Void) {
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)

    switch authorization {
    case .authorized:
      sessionQueue.async {
        self.startRecordingOnSessionQueue(completion: completion)
      }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else {
          DispatchQueue.main.async {
            completion(HevcDumperError.cameraPermissionDenied)
          }
          return
        }

        self.sessionQueue.async {
          self.startRecordingOnSessionQueue(completion: completion)
        }
      }
    case .denied, .restricted:
      DispatchQueue.main.async {
        completion(HevcDumperError.cameraPermissionDenied)
      }
    @unknown default:
      DispatchQueue.main.async {
        completion(HevcDumperError.cameraPermissionDenied)
      }
    }
  }

  func stopRecording(completion: @escaping (Error?) -> Void) {
    sessionQueue.async {
      guard self.isRecording else {
        DispatchQueue.main.async {
          completion(HevcDumperError.notRecording)
        }
        return
      }

      self.captureSession.stopRunning()

      if let compressionSession = self.compressionSession {
        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
      }

      self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
      self.isRecording = false

      DispatchQueue.main.async {
        completion(nil)
      }
    }
  }

  private func startRecordingOnSessionQueue(completion: @escaping (Error?) -> Void) {
    guard !isRecording else {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }

    do {
      let dimensions = try configureCaptureSession()
      try configureCompressionSession(width: dimensions.width, height: dimensions.height)

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

  private func configureCaptureSession() throws -> CMVideoDimensions {
    captureSession.beginConfiguration()
    defer { captureSession.commitConfiguration() }

    captureSession.sessionPreset = .hd1280x720
    captureSession.inputs.forEach { captureSession.removeInput($0) }
    captureSession.outputs.forEach { captureSession.removeOutput($0) }

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
    isRecording = false
  }

  private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    let keyframe = isKeyFrame(sampleBuffer)
    var annexBFrame = Data()
    if keyframe {
      appendParameterSets(sampleBuffer, to: &annexBFrame)
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    appendAnnexBNALUnits(from: blockBuffer, to: &annexBFrame)

    guard !annexBFrame.isEmpty else { return }
    emitFrame(annexBFrame, isKeyframe: keyframe)
  }

  private func emitFrame(_ data: Data, isKeyframe: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let eventSink = self?.eventSink else { return }
      eventSink([
        "bytes": FlutterStandardTypedData(bytes: data),
        "is_keyframe": isKeyframe,
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

extension HevcDumper: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard
      isRecording,
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
