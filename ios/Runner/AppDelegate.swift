import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var hevcDumper: HevcDumper?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let flutterViewController = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.nomikai.sankaku/hevc_dumper",
        binaryMessenger: flutterViewController.binaryMessenger
      )

      channel.setMethodCallHandler { [weak self] call, result in
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
          if self.hevcDumper?.isRecording == true {
            result(
              FlutterError(
                code: "ALREADY_RECORDING",
                message: "HEVC recording is already running.",
                details: nil
              )
            )
            return
          }

          let dumper = HevcDumper()
          self.hevcDumper = dumper
          dumper.startRecording { error in
            if let error {
              self.hevcDumper = nil
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
          guard let dumper = self.hevcDumper else {
            result(
              FlutterError(
                code: "NOT_RECORDING",
                message: "No HEVC recording is active.",
                details: nil
              )
            )
            return
          }

          dumper.stopRecording { path, error in
            self.hevcDumper = nil

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

            result(path)
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
