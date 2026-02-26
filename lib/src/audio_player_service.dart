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

  Future<void> pushAudioFrame(
    Uint8List bytes, {
    required int ptsUs,
    int framesPerPacketHint = 0,
  }) async {
    if (!isSupported || bytes.isEmpty) {
      return;
    }

    if (!_initialized) {
      await initializeAudio();
    }

    await _channel.invokeMethod<void>('push_audio_frame', <String, Object>{
      'bytes': bytes,
      'pts': ptsUs,
      'frames_per_packet': framesPerPacketHint,
    });
  }

  Future<void> suspendAudio() async {
    if (!isSupported || !_initialized) {
      return;
    }
    await _channel.invokeMethod<void>('suspend_audio');
  }

  Future<void> resumeAudio() async {
    if (!isSupported) {
      return;
    }
    if (!_initialized) {
      await initializeAudio();
      return;
    }
    await _channel.invokeMethod<void>('resume_audio');
  }

  Future<List<String>> getAudioDebugLogs() async {
    if (!isSupported) {
      return const <String>[];
    }
    final dynamic result = await _channel.invokeMethod<dynamic>(
      'get_audio_debug_logs',
    );
    if (result is List) {
      return result
          .map((dynamic value) => value.toString())
          .toList(growable: false);
    }
    return const <String>[];
  }

  Future<void> clearAudioDebugLogs() async {
    if (!isSupported) {
      return;
    }
    await _channel.invokeMethod<void>('clear_audio_debug_logs');
  }
}
