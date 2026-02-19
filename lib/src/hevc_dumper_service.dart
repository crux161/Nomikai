import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class HevcDumperService {
  static const MethodChannel _channel = MethodChannel(
    'com.nomikai.sankaku/hevc_dumper',
  );

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> startRecording() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    await _channel.invokeMethod<void>('startRecording');
  }

  Future<String> stopRecording() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    final outputPath = await _channel.invokeMethod<String>('stopRecording');
    if (outputPath == null || outputPath.isEmpty) {
      throw StateError('iOS returned an empty HEVC output path.');
    }
    return outputPath;
  }
}
