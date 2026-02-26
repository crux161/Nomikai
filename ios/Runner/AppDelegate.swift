import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let hevcDumper = HevcDumper()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let flutterViewController = window?.rootViewController as? FlutterViewController {
      let methodChannel = FlutterMethodChannel(
        name: "com.nomikai.sankaku/hevc_dumper",
        binaryMessenger: flutterViewController.binaryMessenger
      )
      let eventChannel = FlutterEventChannel(
        name: "com.nomikai.sankaku/hevc_stream",
        binaryMessenger: flutterViewController.binaryMessenger
      )
      let audioEventChannel = FlutterEventChannel(
        name: "com.nomikai.sankaku/audio_stream",
        binaryMessenger: flutterViewController.binaryMessenger
      )

      eventChannel.setStreamHandler(hevcDumper)
      audioEventChannel.setStreamHandler(hevcDumper.audioStreamHandler)

      methodChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(
            FlutterError(
              code: "DEALLOCATED",
              message: "AppDelegate is no longer available.",
              details: nil
            )
          )
          return
        }

        switch call.method {
        case "startRecording":
          if self.hevcDumper.isRecording {
            result(
              FlutterError(
                code: "ALREADY_RECORDING",
                message: "HEVC recording is already running.",
                details: nil
              )
            )
            return
          }

          let videoEnabled: Bool
          if
            let payload = call.arguments as? [String: Any],
            let requested = payload["videoEnabled"] as? Bool
          {
            videoEnabled = requested
          } else if
            let payload = call.arguments as? [String: Any],
            let requested = payload["video_enabled"] as? Bool
          {
            videoEnabled = requested
          } else if
            let payload = call.arguments as? [String: Any],
            let requestedAudioOnly = payload["audio_only"] as? Bool
          {
            videoEnabled = !requestedAudioOnly
          } else {
            videoEnabled = true
          }

          self.hevcDumper.startRecording(videoEnabled: videoEnabled) { error in
            if let error {
              result(
                FlutterError(
                  code: "START_FAILED",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            } else {
              result(nil)
            }
          }

        case "stopRecording":
          if !self.hevcDumper.isRecording {
            result(
              FlutterError(
                code: "NOT_RECORDING",
                message: "No HEVC recording is active.",
                details: nil
              )
            )
            return
          }

          self.hevcDumper.stopRecording { error in
            if let error {
              result(
                FlutterError(
                  code: "STOP_FAILED",
                  message: error.localizedDescription,
                  details: nil
                )
              )
              return
            }

            result(nil)
          }

        case "set_bitrate":
          guard self.hevcDumper.isRecording else {
            result(
              FlutterError(
                code: "NOT_RECORDING",
                message: "No HEVC recording is active.",
                details: nil
              )
            )
            return
          }

          let requestedBitrate: Int?
          if let bitrate = call.arguments as? Int {
            requestedBitrate = bitrate
          } else if
            let payload = call.arguments as? [String: Any],
            let bitrate = payload["bitrate"] as? Int
          {
            requestedBitrate = bitrate
          } else {
            requestedBitrate = nil
          }

          guard let bitrate = requestedBitrate, bitrate > 0 else {
            result(
              FlutterError(
                code: "INVALID_ARGUMENT",
                message: "set_bitrate expects a positive integer bitrate.",
                details: nil
              )
            )
            return
          }

          self.hevcDumper.setBitrate(bitrate: bitrate) { error in
            if let error {
              result(
                FlutterError(
                  code: "SET_BITRATE_FAILED",
                  message: error.localizedDescription,
                  details: nil
                )
              )
              return
            }
            result(nil)
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
