// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nomikai/src/rust/api/simple.dart';

class HevcDumperService {
  static const int _videoCodecHevc = 0x01;
  static const int _audioCodecOpus = 0x03;
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
  void Function(String message)? _debugLogger;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void setDebugLogger(void Function(String message)? logger) {
    _debugLogger = logger;
  }

  void setMicrophoneMuted(bool muted) {
    _microphoneMuted = muted;
  }

  Future<void> startRecording({
    bool videoEnabled = true,
    bool? audioOnly,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('HEVC dumper is only supported on iOS.');
    }

    await _ensureStreamSubscriptions();
    try {
      final bool resolvedVideoEnabled = audioOnly == null
          ? videoEnabled
          : !audioOnly;
      await _channel.invokeMethod<void>('startRecording', <String, Object>{
        'videoEnabled': resolvedVideoEnabled,
      });
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
            final ptsUs = _decodePts(event['pts']) ?? 0;
            final codec = _decodeCodec(event['codec']) ?? _videoCodecHevc;
            _log(
              'DEBUG: Dart received VIDEO chunk: $bytesLength bytes (Keyframe: ${event['is_keyframe']}, pts_us=$ptsUs, codec=0x${codec.toRadixString(16).padLeft(2, '0')})',
            );
          } else {
            _log('DEBUG: Dart received VIDEO chunk: 0 bytes (Keyframe: null)');
          }
          _handleHevcPayload(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          _log('HEVC stream error: $error');
        },
        cancelOnError: false,
      );
    }

    if (_audioStreamSubscription != null) {
      return;
    }

    _audioStreamSubscription = _audioStreamChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        final audioEvent = _decodeAudioFrameEvent(event);
        final bytesLength = audioEvent?.bytes.length ?? 0;
        final ptsUs = audioEvent?.ptsUs ?? 0;
        final framesPerPacket = audioEvent?.framesPerPacket ?? 0;
        _log(
          'DEBUG: Dart received AUDIO chunk: $bytesLength bytes (pts_us=$ptsUs, frames_per_packet=$framesPerPacket, codec=0x${_audioCodecOpus.toRadixString(16).padLeft(2, '0')})',
        );
        _handleAudioPayload(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        _log('Audio stream error: $error');
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
      pushVideoFrame(
        frameBytes: frameEvent.bytes,
        isKeyframe: frameEvent.isKeyframe,
        pts: BigInt.from(frameEvent.ptsUs),
        codec: frameEvent.codec,
      ).catchError((Object error, StackTrace stackTrace) {
        _log('pushVideoFrame failed: $error');
      }),
    );
  }

  void _handleAudioPayload(dynamic event) {
    if (_microphoneMuted) {
      return;
    }

    final audioEvent = _decodeAudioFrameEvent(event);
    if (audioEvent == null || audioEvent.bytes.isEmpty) {
      return;
    }

    unawaited(
      pushAudioFrame(
        frameBytes: audioEvent.bytes,
        pts: BigInt.from(audioEvent.ptsUs),
        codec: _audioCodecOpus,
        framesPerPacket: audioEvent.framesPerPacket,
      ).catchError((Object error, StackTrace stackTrace) {
        _log('pushAudioFrame failed: $error');
      }),
    );
  }

  void _log(String message) {
    print(message);
    _debugLogger?.call(message);
  }

  _HevcFrameEvent? _decodeFrameEvent(dynamic event) {
    if (event is! Map) {
      return null;
    }

    final rawBytes = event['bytes'];
    final rawIsKeyframe = event['is_keyframe'];
    final rawPts = event['pts'];
    final rawCodec = event['codec'];
    final bytes = _decodeBytes(rawBytes);
    if (bytes == null) {
      return null;
    }

    final isKeyframe = rawIsKeyframe is bool ? rawIsKeyframe : false;
    final ptsUs = _decodePts(rawPts) ?? 0;
    final codec = _decodeCodec(rawCodec) ?? _videoCodecHevc;
    return _HevcFrameEvent(
      bytes: bytes,
      isKeyframe: isKeyframe,
      ptsUs: ptsUs,
      codec: codec,
    );
  }

  _AudioFrameEvent? _decodeAudioFrameEvent(dynamic event) {
    if (event is Map) {
      final bytes = _decodeBytes(event['bytes']);
      if (bytes == null) {
        return null;
      }
      final ptsUs = _decodePts(event['pts']) ?? 0;
      final framesPerPacket =
          _decodeFramesPerPacket(
            event['frames_per_packet'] ?? event['framesPerPacket'],
          ) ??
          0;
      return _AudioFrameEvent(
        bytes: bytes,
        ptsUs: ptsUs,
        framesPerPacket: framesPerPacket,
      );
    }

    final bytes = _decodeBytes(event);
    if (bytes == null) {
      return null;
    }
    return _AudioFrameEvent(bytes: bytes, ptsUs: 0, framesPerPacket: 0);
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

  int? _decodePts(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  int? _decodeCodec(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  int? _decodeFramesPerPacket(dynamic value) {
    if (value is int) {
      return value > 0 ? value : 0;
    }
    if (value is num) {
      final int parsed = value.toInt();
      return parsed > 0 ? parsed : 0;
    }
    return null;
  }
}

class _HevcFrameEvent {
  const _HevcFrameEvent({
    required this.bytes,
    required this.isKeyframe,
    required this.ptsUs,
    required this.codec,
  });

  final Uint8List bytes;
  final bool isKeyframe;
  final int ptsUs;
  final int codec;
}

class _AudioFrameEvent {
  const _AudioFrameEvent({
    required this.bytes,
    required this.ptsUs,
    required this.framesPerPacket,
  });

  final Uint8List bytes;
  final int ptsUs;
  final int framesPerPacket;
}
