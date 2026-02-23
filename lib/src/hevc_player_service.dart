import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class HevcPlayerService {
  static const MethodChannel _channel = MethodChannel(
    'com.nomikai.sankaku/hevc_player',
  );

  int? _textureId;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  int? get textureId => _textureId;

  Future<int> initPlayer() async {
    if (!isSupported) {
      throw UnsupportedError('HEVC player is only supported on macOS.');
    }

    if (_textureId != null) {
      return _textureId!;
    }

    final textureId = await _channel.invokeMethod<int>('initialize');
    if (textureId == null || textureId <= 0) {
      throw StateError(
        'Native HEVC player initialization returned an invalid texture id.',
      );
    }

    _textureId = textureId;
    return textureId;
  }

  Future<void> pushFrame(Uint8List bytes, {required int ptsUs}) async {
    if (!isSupported || bytes.isEmpty) {
      return;
    }

    if (_textureId == null) {
      await initPlayer();
    }

    await _channel.invokeMethod<void>('decode_frame', <String, Object>{
      'bytes': bytes,
      'pts': ptsUs,
    });
  }
}
