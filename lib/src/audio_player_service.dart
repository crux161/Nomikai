import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AudioPlayerService {
  static const MethodChannel _channel = MethodChannel(
    'com.nomikai.sankaku/audio_player',
  );

  bool _initialized = false;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> initializeAudio() async {
    if (!isSupported || _initialized) {
      return;
    }

    await _channel.invokeMethod<void>('initialize_audio');
    _initialized = true;
  }

  Future<void> pushAudioFrame(Uint8List bytes, {required int ptsUs}) async {
    if (!isSupported || bytes.isEmpty) {
      return;
    }

    if (!_initialized) {
      await initializeAudio();
    }

    await _channel.invokeMethod<void>('push_audio_frame', <String, Object>{
      'bytes': bytes,
      'pts': ptsUs,
    });
  }
}
