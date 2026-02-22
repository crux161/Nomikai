// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nomikai/src/rust/api/simple.dart';

class HevcDumperService {
  static const MethodChannel _channel = MethodChannel(
    'com.nomikai.sankaku/hevc_dumper',
  );
  static const EventChannel _hevcStreamChannel = EventChannel(
    'com.nomikai.sankaku/hevc_stream',
  );
  static const EventChannel _audioStreamChannel = EventChannel(
    'com.nomikai.sankaku/audio_stream',
  );

  StreamSubscription<dynamic>? _hevcStreamSubscription;
  StreamSubscription<dynamic>? _audioStreamSubscription;
  bool _microphoneMuted = false;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void setMicrophoneMuted(bool muted) {
    _microphoneMuted = muted;
  }

  Future<void> startRecording() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    await _ensureStreamSubscriptions();
    try {
      await _channel.invokeMethod<void>('startRecording');
    } catch (_) {
      await _cancelStreamSubscriptions();
      rethrow;
    }
  }

  Future<void> stopRecording() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    try {
      await _channel.invokeMethod<void>('stopRecording');
    } finally {
      await _cancelStreamSubscriptions();
    }
  }

  Future<void> setBitrate(int bitrate) async {
    if (!isSupported) {
      return;
    }
    if (bitrate <= 0) {
      throw ArgumentError.value(
        bitrate,
        'bitrate',
        'Bitrate must be positive.',
      );
    }

    await _channel.invokeMethod<void>('set_bitrate', bitrate);
  }

  Future<void> _ensureStreamSubscriptions() async {
    if (_hevcStreamSubscription != null) {
      // already active
    } else {
      _hevcStreamSubscription = _hevcStreamChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Map) {
            final bytesLength = _decodeBytes(event['bytes'])?.length ?? 0;
            print(
              'DEBUG: Dart received VIDEO chunk: $bytesLength bytes (Keyframe: ${event['is_keyframe']})',
            );
          } else {
            print('DEBUG: Dart received VIDEO chunk: 0 bytes (Keyframe: null)');
          }
          _handleHevcPayload(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('HEVC stream error: $error');
        },
        cancelOnError: false,
      );
    }

    if (_audioStreamSubscription != null) {
      return;
    }

    _audioStreamSubscription = _audioStreamChannel
        .receiveBroadcastStream()
        .listen(
          (dynamic event) {
            final bytes = _decodeBytes(event);
            final bytesLength = bytes?.length ?? 0;
            print('DEBUG: Dart received AUDIO chunk: $bytesLength bytes');
            _handleAudioPayload(event);
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Audio stream error: $error');
          },
          cancelOnError: false,
        );
  }

  Future<void> _cancelStreamSubscriptions() async {
    await _hevcStreamSubscription?.cancel();
    _hevcStreamSubscription = null;
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
  }

  void _handleHevcPayload(dynamic event) {
    final frameEvent = _decodeFrameEvent(event);
    if (frameEvent == null || frameEvent.bytes.isEmpty) {
      return;
    }

    unawaited(
      pushHevcFrame(
        frameBytes: frameEvent.bytes,
        isKeyframe: frameEvent.isKeyframe,
      ).catchError((Object error, StackTrace stackTrace) {
        debugPrint('pushHevcFrame failed: $error');
      }),
    );
  }

  void _handleAudioPayload(dynamic event) {
    if (_microphoneMuted) {
      return;
    }

    final bytes = _decodeBytes(event);
    if (bytes == null || bytes.isEmpty) {
      return;
    }

    unawaited(
      pushAudioFrame(frameBytes: bytes).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('pushAudioFrame failed: $error');
      }),
    );
  }

  _HevcFrameEvent? _decodeFrameEvent(dynamic event) {
    if (event is! Map) {
      return null;
    }

    final rawBytes = event['bytes'];
    final rawIsKeyframe = event['is_keyframe'];
    final bytes = _decodeBytes(rawBytes);
    if (bytes == null) {
      return null;
    }

    final isKeyframe = rawIsKeyframe is bool ? rawIsKeyframe : false;
    return _HevcFrameEvent(bytes: bytes, isKeyframe: isKeyframe);
  }

  Uint8List? _decodeBytes(dynamic event) {
    if (event is Uint8List) {
      return event;
    }
    if (event is ByteData) {
      return event.buffer.asUint8List(event.offsetInBytes, event.lengthInBytes);
    }
    if (event is List<int>) {
      return Uint8List.fromList(event);
    }
    return null;
  }
}

class _HevcFrameEvent {
  const _HevcFrameEvent({required this.bytes, required this.isKeyframe});

  final Uint8List bytes;
  final bool isKeyframe;
}
