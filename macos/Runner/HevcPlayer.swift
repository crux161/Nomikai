import CoreMedia
import CoreVideo
import FlutterMacOS
import Foundation
import VideoToolbox

private enum HevcPlayerError: LocalizedError {
  case decoderBootstrapMissing
  case formatDescriptionCreateFailed(status: OSStatus)
  case sessionCreateFailed(status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .decoderBootstrapMissing:
      return "Missing VPS/SPS/PPS parameter sets for decoder initialization."
    case .formatDescriptionCreateFailed(let status):
      return "Failed to create HEVC format description (status \(status))."
    case .sessionCreateFailed(let status):
      return "Failed to create HEVC decompression session (status \(status))."
    }
  }
}

final class HevcPlayer: NSObject, FlutterTexture {
  private static let decodeCallback: VTDecompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    imageBuffer,
    _,
    _
  in
    guard
      status == noErr,
      let outputCallbackRefCon,
      let imageBuffer
    else {
      return
    }

    let player = Unmanaged<HevcPlayer>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    player.handleDecodedImageBuffer(imageBuffer)
  }

  private let decodeQueue = DispatchQueue(label: "com.nomikai.sankaku.hevc_player.decode")
  private let pixelBufferLock = NSLock()

  private weak var textureRegistry: FlutterTextureRegistry?
  private var textureId: Int64 = 0

  private var decompressionSession: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?
  private var latestPixelBuffer: CVPixelBuffer?

  private var vps: Data?
  private var sps: Data?
  private var pps: Data?
  private var needsSessionRebuild = true
  private var presentationCounter: Int64 = 0

  init(textureRegistry: FlutterTextureRegistry) {
    self.textureRegistry = textureRegistry
    super.init()
  }

  deinit {
    teardownDecoderSession()
  }

  func setTextureId(_ textureId: Int64) {
    self.textureId = textureId
  }

  func decodeAnnexBFrame(_ frameData: Data) {
    guard !frameData.isEmpty else { return }

    decodeQueue.async { [weak self] in
      self?.decodeAnnexBFrameOnQueue(frameData)
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    let pixelBuffer = latestPixelBuffer
    pixelBufferLock.unlock()

    guard let pixelBuffer else {
      return nil
    }

    return Unmanaged.passRetained(pixelBuffer)
  }

  private func decodeAnnexBFrameOnQueue(_ frameData: Data) {
    let nalUnits = splitAnnexB(frameData)
    guard !nalUnits.isEmpty else {
      return
    }

    var vclUnits: [Data] = []

    for nalUnit in nalUnits {
      guard let nalType = Self.nalUnitType(for: nalUnit) else {
        continue
      }

      switch nalType {
      case 32:
        updateParameterSet(&vps, with: nalUnit)
      case 33:
        updateParameterSet(&sps, with: nalUnit)
      case 34:
        updateParameterSet(&pps, with: nalUnit)
      case 0...31:
        vclUnits.append(nalUnit)
      default:
        continue
      }
    }

    guard !vclUnits.isEmpty else {
      return
    }

    do {
      try ensureDecoderSession()
    } catch {
      NSLog("HevcPlayer: decoder setup failed: \(error.localizedDescription)")
      return
    }

    for vclNal in vclUnits {
      decodeVclNalUnit(vclNal)
    }
  }

  private func updateParameterSet(_ current: inout Data?, with newValue: Data) {
    if current != newValue {
      current = newValue
      needsSessionRebuild = true
    }
  }

  private func ensureDecoderSession() throws {
    if !needsSessionRebuild, decompressionSession != nil, formatDescription != nil {
      return
    }

    guard
      let vps,
      let sps,
      let pps
    else {
      throw HevcPlayerError.decoderBootstrapMissing
    }

    teardownDecoderSession()

    let vpsBytes = vps as NSData
    let spsBytes = sps as NSData
    let ppsBytes = pps as NSData

    let parameterSetPointers: [UnsafePointer<UInt8>] = [
      vpsBytes.bytes.assumingMemoryBound(to: UInt8.self),
      spsBytes.bytes.assumingMemoryBound(to: UInt8.self),
      ppsBytes.bytes.assumingMemoryBound(to: UInt8.self),
    ]
    let parameterSetSizes = [vps.count, sps.count, pps.count]

    var videoFormatDescription: CMFormatDescription?
    let formatStatus = parameterSetPointers.withUnsafeBufferPointer { pointers in
      parameterSetSizes.withUnsafeBufferPointer { sizes in
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: parameterSetPointers.count,
          parameterSetPointers: pointers.baseAddress!,
          parameterSetSizes: sizes.baseAddress!,
          nalUnitHeaderLength: 4,
          extensions: nil,
          formatDescriptionOut: &videoFormatDescription
        )
      }
    }

    guard
      formatStatus == noErr,
      let formatDescription = videoFormatDescription
    else {
      throw HevcPlayerError.formatDescriptionCreateFailed(status: formatStatus)
    }

    let imageBufferAttributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]

    let decoderSpecification: [CFString: Any] = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
    ]

    var callbackRecord = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: Self.decodeCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
    )

    var session: VTDecompressionSession?
    let sessionStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: decoderSpecification as CFDictionary,
      imageBufferAttributes: imageBufferAttributes as CFDictionary,
      outputCallback: &callbackRecord,
      decompressionSessionOut: &session
    )

    guard sessionStatus == noErr, let session else {
      throw HevcPlayerError.sessionCreateFailed(status: sessionStatus)
    }

    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

    self.formatDescription = formatDescription
    self.decompressionSession = session
    needsSessionRebuild = false
  }

  private func teardownDecoderSession() {
    if let decompressionSession {
      VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
      VTDecompressionSessionInvalidate(decompressionSession)
      self.decompressionSession = nil
    }

    formatDescription = nil
    presentationCounter = 0
  }

  private func decodeVclNalUnit(_ nalUnit: Data) {
    guard
      let decompressionSession,
      let formatDescription
    else {
      return
    }

    var nalLength = UInt32(nalUnit.count).bigEndian
    var avccSample = Data(bytes: &nalLength, count: MemoryLayout<UInt32>.size)
    avccSample.append(nalUnit)

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: avccSample.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: avccSample.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    guard
      blockStatus == kCMBlockBufferNoErr,
      let blockBuffer
    else {
      return
    }

    let replaceStatus = avccSample.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kCMBlockBufferBadCustomBlockSourceErr
      }

      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: avccSample.count
      )
    }

    guard replaceStatus == kCMBlockBufferNoErr else {
      return
    }

    let pts = CMTime(value: presentationCounter, timescale: 30)
    presentationCounter += 1
    var timingInfo = CMSampleTimingInfo(
      duration: CMTime.invalid,
      presentationTimeStamp: pts,
      decodeTimeStamp: CMTime.invalid
    )
    var sampleSize = avccSample.count
    var sampleBuffer: CMSampleBuffer?

    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timingInfo,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )

    guard sampleStatus == noErr, let sampleBuffer else {
      return
    }

    var infoFlags = VTDecodeInfoFlags()
    let decodeStatus = VTDecompressionSessionDecodeFrame(
      decompressionSession,
      sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression],
      frameRefcon: nil,
      infoFlagsOut: &infoFlags
    )

    if decodeStatus != noErr {
      NSLog("HevcPlayer: decode failed (status \(decodeStatus), flags \(infoFlags.rawValue))")
    }
  }

  private func handleDecodedImageBuffer(_ imageBuffer: CVImageBuffer) {
    pixelBufferLock.lock()
    latestPixelBuffer = imageBuffer
    pixelBufferLock.unlock()

    guard textureId != 0 else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.textureRegistry?.textureFrameAvailable(self.textureId)
    }
  }

  private static func nalUnitType(for nalUnit: Data) -> UInt8? {
    guard let firstByte = nalUnit.first else {
      return nil
    }

    return (firstByte >> 1) & 0x3F
  }

  private func splitAnnexB(_ stream: Data) -> [Data] {
    guard !stream.isEmpty else {
      return []
    }

    let bytes = [UInt8](stream)
    var units: [Data] = []
    var searchIndex = 0

    while let start = Self.findStartCode(in: bytes, from: searchIndex) {
      let payloadStart = start.index + start.length
      guard payloadStart < bytes.count else {
        break
      }

      let nextStart = Self.findStartCode(in: bytes, from: payloadStart)
      let payloadEnd = nextStart?.index ?? bytes.count

      if payloadEnd > payloadStart {
        units.append(Data(bytes[payloadStart..<payloadEnd]))
      }

      searchIndex = nextStart?.index ?? bytes.count
    }

    return units
  }

  private static func findStartCode(in bytes: [UInt8], from index: Int) -> (index: Int, length: Int)? {
    guard bytes.count >= 3, index < bytes.count - 2 else {
      return nil
    }

    var cursor = max(index, 0)
    let lastValidIndex = bytes.count - 3

    while cursor <= lastValidIndex {
      if bytes[cursor] == 0x00, bytes[cursor + 1] == 0x00 {
        if bytes[cursor + 2] == 0x01 {
          return (cursor, 3)
        }

        if cursor + 3 < bytes.count, bytes[cursor + 2] == 0x00, bytes[cursor + 3] == 0x01 {
          return (cursor, 4)
        }
      }

      cursor += 1
    }

    return nil
  }
}
