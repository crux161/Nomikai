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

  StreamSubscription<dynamic>? _hevcStreamSubscription;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> startRecording() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    await _ensureHevcStreamSubscription();
    try {
      await _channel.invokeMethod<void>('startRecording');
    } catch (_) {
      await _cancelHevcStreamSubscription();
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
      await _cancelHevcStreamSubscription();
    }
  }

  Future<void> _ensureHevcStreamSubscription() async {
    if (_hevcStreamSubscription != null) {
      return;
    }

    _hevcStreamSubscription = _hevcStreamChannel
        .receiveBroadcastStream()
        .listen(
          _handleHevcPayload,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('HEVC stream error: $error');
          },
          cancelOnError: false,
        );
  }

  Future<void> _cancelHevcStreamSubscription() async {
    await _hevcStreamSubscription?.cancel();
    _hevcStreamSubscription = null;
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
