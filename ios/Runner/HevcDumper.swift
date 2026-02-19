import AVFoundation
import Foundation
import VideoToolbox

private enum HevcDumperError: LocalizedError {
  case cameraPermissionDenied
  case cameraUnavailable
  case cannotAddInput
  case cannotAddOutput
  case cannotCreateEncoder(status: OSStatus)
  case cannotCreateOutputFile
  case noOutputFileURL
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
    case .cannotCreateOutputFile:
      return "Failed to create output .h265 file."
    case .noOutputFileURL:
      return "Output file URL is not set."
    case .notRecording:
      return "No active HEVC recording session."
    }
  }
}

final class HevcDumper: NSObject {
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
  private let fileQueue = DispatchQueue(label: "com.nomikai.sankaku.hevc_dumper.file")

  private var compressionSession: VTCompressionSession?
  private var outputURL: URL?
  private var fileHandle: FileHandle?

  private(set) var isRecording = false

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

  func stopRecording(completion: @escaping (String?, Error?) -> Void) {
    sessionQueue.async {
      guard self.isRecording else {
        DispatchQueue.main.async {
          completion(nil, HevcDumperError.notRecording)
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

      self.fileQueue.sync {
        self.fileHandle?.synchronizeFile()
        self.fileHandle?.closeFile()
        self.fileHandle = nil
      }

      let path = self.outputURL?.path
      self.outputURL = nil
      self.isRecording = false

      DispatchQueue.main.async {
        completion(path, nil)
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
      outputURL = try createOutputURL()

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

  private func createOutputURL() throws -> URL {
    guard
      let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      throw HevcDumperError.cannotCreateOutputFile
    }

    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    let outputURL = documentsURL.appendingPathComponent("capture_\(timestamp).h265")

    if !FileManager.default.createFile(atPath: outputURL.path, contents: nil) {
      throw HevcDumperError.cannotCreateOutputFile
    }

    return outputURL
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

    fileQueue.sync {
      fileHandle?.closeFile()
      fileHandle = nil
    }

    outputURL = nil
    isRecording = false
  }

  private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    fileQueue.sync {
      do {
        try ensureOutputFileHandle()
        guard let fileHandle else { return }

        if isKeyFrame(sampleBuffer) {
          writeParameterSets(sampleBuffer, to: fileHandle)
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        writeAnnexBNALUnits(from: blockBuffer, to: fileHandle)
      } catch {
        NSLog("HevcDumper: failed writing sample buffer (\(error.localizedDescription))")
      }
    }
  }

  private func ensureOutputFileHandle() throws {
    guard fileHandle == nil else { return }
    guard let outputURL else { throw HevcDumperError.noOutputFileURL }

    fileHandle = try FileHandle(forWritingTo: outputURL)
  }

  private func writeParameterSets(_ sampleBuffer: CMSampleBuffer, to fileHandle: FileHandle) {
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
      fileHandle.write(Self.annexBStartCode)
      fileHandle.write(Data(bytes: parameterSetPointer, count: parameterSetSize))
    }
  }

  private func writeAnnexBNALUnits(from blockBuffer: CMBlockBuffer, to fileHandle: FileHandle) {
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

      fileHandle.write(Self.annexBStartCode)
      fileHandle.write(Data(bytes: dataPointer.advanced(by: nalStart), count: nalLength))

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
