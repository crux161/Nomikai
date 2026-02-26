import Cocoa
import FlutterMacOS

private enum HevcPlayerChannelError: LocalizedError {
  case invalidArguments
  case invalidAudioArguments
  case textureRegistryUnavailable
  case playerNotInitialized
  case audioPlayerInitializationFailed
  case audioPlayerNotInitialized

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid decode_frame arguments. Expected bytes payload (and optional pts)."
    case .invalidAudioArguments:
      return "Invalid push_audio_frame arguments. Expected bytes payload (and optional pts)."
    case .textureRegistryUnavailable:
      return "Flutter texture registry is unavailable."
    case .playerNotInitialized:
      return "HEVC player is not initialized. Call initialize first."
    case .audioPlayerInitializationFailed:
      return "Failed to initialize native audio player."
    case .audioPlayerNotInitialized:
      return "Audio player is not initialized. Call initialize_audio first."
    }
  }
}

private extension FlutterEngine {
  var textureRegistry: FlutterTextureRegistry { self }
}

class MainFlutterWindow: NSWindow {
  private let playbackSyncClock = PlaybackSyncClock()
  private var hevcPlayer: HevcPlayer?
  private var hevcTextureId: Int64?
  private var audioPlayer: AudioPlayer?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    registerHevcPlayerChannel(flutterViewController: flutterViewController)
    registerAudioPlayerChannel(flutterViewController: flutterViewController)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func registerHevcPlayerChannel(flutterViewController: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: "com.nomikai.sankaku/hevc_player",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "DEALLOCATED",
            message: "MainFlutterWindow is unavailable.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "initialize":
        do {
          let textureId = try self.initializePlayer(flutterViewController: flutterViewController)
          result(textureId)
        } catch {
          result(
            FlutterError(
              code: "INITIALIZE_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }

      case "decode_frame":
        do {
          let payload = try Self.decodeFramePayload(from: call.arguments)
          guard let player = self.hevcPlayer else {
            throw HevcPlayerChannelError.playerNotInitialized
          }

          player.decodeAnnexBFrame(payload.data, ptsUs: payload.ptsUs)
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "DECODE_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func initializePlayer(flutterViewController: FlutterViewController) throws -> Int64 {
    if let hevcTextureId {
      return hevcTextureId
    }

    let textureRegistry = flutterViewController.engine.textureRegistry
    let player = HevcPlayer(textureRegistry: textureRegistry, syncClock: playbackSyncClock)
    let textureId = textureRegistry.register(player)

    guard textureId != 0 else {
      throw HevcPlayerChannelError.textureRegistryUnavailable
    }

    player.setTextureId(textureId)
    hevcPlayer = player
    hevcTextureId = textureId

    return textureId
  }

  private static func decodeFramePayload(from arguments: Any?) throws -> (data: Data, ptsUs: UInt64) {
    if let typedData = arguments as? FlutterStandardTypedData {
      return (typedData.data, 0)
    }

    if
      let args = arguments as? [String: Any],
      let typedData = args["bytes"] as? FlutterStandardTypedData
    {
      let ptsUs = Self.decodePtsUs(args["pts"])
      return (typedData.data, ptsUs)
    }

    throw HevcPlayerChannelError.invalidArguments
  }

  private func registerAudioPlayerChannel(flutterViewController: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: "com.nomikai.sankaku/audio_player",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "DEALLOCATED",
            message: "MainFlutterWindow is unavailable.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "initialize_audio":
        do {
          try self.initializeAudioPlayer()
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "AUDIO_INITIALIZE_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "push_audio_frame":
        do {
          let payload = try Self.decodeAudioPayload(from: call.arguments)
          guard let player = self.audioPlayer else {
            throw HevcPlayerChannelError.audioPlayerNotInitialized
          }
          player.decodeAndPlay(opusData: payload.data, ptsUs: payload.ptsUs)
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "AUDIO_PUSH_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func initializeAudioPlayer() throws {
    if audioPlayer != nil {
      return
    }

    let player = try AudioPlayer(syncClock: playbackSyncClock)
    try player.start()
    audioPlayer = player
  }

  private static func decodeAudioPayload(from arguments: Any?) throws -> (data: Data, ptsUs: UInt64) {
    if let typedData = arguments as? FlutterStandardTypedData {
      return (typedData.data, 0)
    }

    if
      let args = arguments as? [String: Any],
      let typedData = args["bytes"] as? FlutterStandardTypedData
    {
      let ptsUs = Self.decodePtsUs(args["pts"])
      return (typedData.data, ptsUs)
    }

    throw HevcPlayerChannelError.invalidAudioArguments
  }

  private static func decodePtsUs(_ rawValue: Any?) -> UInt64 {
    if let value = rawValue as? NSNumber {
      let int64Value = value.int64Value
      if int64Value > 0 {
        return UInt64(int64Value)
      }
      return 0
    }
    if let value = rawValue as? Int, value > 0 {
      return UInt64(value)
    }
    if let value = rawValue as? Int64, value > 0 {
      return UInt64(value)
    }
    return 0
  }
}
