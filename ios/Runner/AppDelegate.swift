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

      eventChannel.setStreamHandler(hevcDumper)

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

          self.hevcDumper.startRecording { error in
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

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
