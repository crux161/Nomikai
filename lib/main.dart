// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:nomikai/src/audio_player_service.dart';
import 'package:nomikai/src/discovery_service.dart';
import 'package:nomikai/src/hevc_dumper_service.dart';
import 'package:nomikai/src/hevc_player_service.dart';
import 'package:nomikai/src/rust/api/simple.dart';
import 'package:nomikai/src/rust/frb_generated.dart';
import 'package:nomikai/src/telemetry_state.dart';
import 'package:nomikai/src/widgets/debug_overlay.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

const int _sankakuUdpPort = NomikaiDiscoveryService.defaultSankakuPort;
const String _sankakuBindHost = '[::]';
const String _sankakuReceiverBindAddr = '$_sankakuBindHost:$_sankakuUdpPort';
const String _manualDialPrefsKey = 'broadcast.manual_destination';
const String _manualDialPlaceholder = '<Your_Public_IP>:$_sankakuUdpPort';
const int _audioCodecDebugReport = 0x7E;
const List<int> _debugReportMagic = <int>[0x4E, 0x52, 0x50, 0x54]; // "NRPT"
const int _debugReportProtocolVersion = 1;
const int _debugReportPacketBegin = 0x01;
const int _debugReportPacketChunk = 0x02;
const int _debugReportPacketEnd = 0x03;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const NomikaiApp());
}

class NomikaiApp extends StatelessWidget {
  const NomikaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool useReceiverUi =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nomikai',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: useReceiverUi ? const ReceiverScreen() : const BroadcastScreen(),
    );
  }
}

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen>
    with WidgetsBindingObserver {
  final HevcPlayerService _playerService = HevcPlayerService();
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  late final NomikaiDiscoveryService _discoveryService;

  final List<double> _byteSamples = <double>[];
  final List<int> _bitrateWindowBytes = <int>[];
  final List<String> _debugLines = <String>[];

  StreamSubscription<UiEvent>? _receiverEventSubscription;
  Timer? _metricsTicker;

  bool _isReceiving = false;
  bool _isBusy = false;
  bool _audioPlaybackEnabled = true;
  bool _audioPlaybackSuspendedByLifecycle = false;
  bool _debugConsoleExpanded = false;

  int? _textureId;
  int _frameDrops = 0;
  int _bytesSinceTick = 0;
  int _framesSinceTick = 0;
  int _currentReceiveBitrateBps = 0;

  double _currentFps = 0;
  double _packetLossPercent = 0;

  String _handshakeState = 'idle';
  String _statusLog = 'Ready to receive HEVC stream.';
  String? _lastRemoteReportPath;

  static const int _maxDebugLines = 240;
  static final RegExp _remoteReportSavedPathPattern = RegExp(
    r'^\[RemoteReport\] saved file path=(.+?) bytes=',
  );

  void _appendDebugLineInSetState(String message) {
    final String line = '[${DateTime.now().toIso8601String()}] $message';
    _debugLines.add(line);
    if (_debugLines.length > _maxDebugLines) {
      _debugLines.removeRange(0, _debugLines.length - _maxDebugLines);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discoveryService = NomikaiDiscoveryService(logger: _debugLog);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_isReceiving ||
        !_audioPlaybackEnabled ||
        !_audioPlayerService.isSupported) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(
          _setReceiverAudioLifecycleSuspended(true, reason: state.name),
        );
        break;
      case AppLifecycleState.resumed:
        unawaited(
          _setReceiverAudioLifecycleSuspended(false, reason: state.name),
        );
        break;
    }
  }

  void _debugLog(String message) {
    final String line = '[${DateTime.now().toIso8601String()}] $message';
    print(line);
    if (!mounted) {
      return;
    }
    setState(() {
      _debugLines.add(line);
      if (_debugLines.length > _maxDebugLines) {
        _debugLines.removeRange(0, _debugLines.length - _maxDebugLines);
      }
    });
  }

  void _clearDebugLogs() {
    setState(() {
      _debugLines.clear();
    });
  }

  Future<void> _setReceiverAudioLifecycleSuspended(
    bool suspended, {
    required String reason,
  }) async {
    if (_audioPlaybackSuspendedByLifecycle == suspended) {
      return;
    }
    _audioPlaybackSuspendedByLifecycle = suspended;
    try {
      if (suspended) {
        await _audioPlayerService.suspendAudio();
        _debugLog(
          'DEBUG: Receiver audio playback suspended (lifecycle=$reason).',
        );
      } else {
        await _audioPlayerService.resumeAudio();
        _debugLog(
          'DEBUG: Receiver audio playback resumed (lifecycle=$reason).',
        );
      }
    } catch (error) {
      _debugLog(
        'DEBUG: Receiver audio lifecycle ${suspended ? 'suspend' : 'resume'} failed: $error',
      );
    }
  }

  String? _extractRemoteReportPath(String message) {
    final match = _remoteReportSavedPathPattern.firstMatch(message);
    if (match == null) {
      return null;
    }
    return match.group(1);
  }

  Future<void> _exportReceiverDebugLogs() async {
    if (_debugLines.isEmpty) {
      setState(() {
        _statusLog = 'No receiver debug logs to export yet.';
      });
      return;
    }

    final now = DateTime.now().toUtc();
    final safeTs = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final defaultName = 'nomikai_receiver_report_$safeTs.log';
    final String? targetPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Receiver Debug Report',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: const <String>['log', 'txt'],
    );
    if (targetPath == null || targetPath.isEmpty) {
      return;
    }

    final lines = <String>[
      'BEGIN RECEIVER_REPORT_FILE ts=${DateTime.now().toIso8601String()}',
      'platform=$defaultTargetPlatform receiving=$_isReceiving busy=$_isBusy handshake_state=$_handshakeState audio_playback_enabled=$_audioPlaybackEnabled audio_lifecycle_suspended=$_audioPlaybackSuspendedByLifecycle',
      'status=${_statusLog.replaceAll('\n', ' ')}',
      'current_bitrate_bps=$_currentReceiveBitrateBps current_fps=${_currentFps.toStringAsFixed(1)} packet_loss_percent=${_packetLossPercent.toStringAsFixed(3)} frame_drops=$_frameDrops',
      if (_lastRemoteReportPath != null)
        'last_remote_report_path=$_lastRemoteReportPath',
      'debug_lines_total=${_debugLines.length}',
      ..._debugLines,
      'END RECEIVER_REPORT_FILE',
    ];

    try {
      await File(targetPath).writeAsString('${lines.join('\n')}\n');
      _debugLog('DEBUG: Receiver debug report exported to $targetPath');
      if (!mounted) return;
      setState(() {
        _statusLog = 'Receiver debug report exported: $targetPath';
      });
    } catch (error) {
      _debugLog('DEBUG: Receiver debug export failed: $error');
      if (!mounted) return;
      setState(() {
        _statusLog = 'Receiver debug export failed: $error';
      });
    }
  }

  Future<void> _exportLastRemoteReportCopy() async {
    final sourcePath = _lastRemoteReportPath;
    if (sourcePath == null || sourcePath.isEmpty) {
      setState(() {
        _statusLog = 'No sender report has been received yet.';
      });
      return;
    }

    final sourceFile = File(sourcePath);
    final exists = await sourceFile.exists();
    if (!exists) {
      setState(() {
        _statusLog = 'Last sender report file was not found: $sourcePath';
      });
      return;
    }

    final defaultName = sourcePath.split('/').last;
    final String? targetPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Sender Report Copy',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: const <String>['log', 'txt'],
    );
    if (targetPath == null || targetPath.isEmpty) {
      return;
    }

    try {
      final bytes = await sourceFile.readAsBytes();
      await File(targetPath).writeAsBytes(bytes, flush: true);
      _debugLog('DEBUG: Copied last sender report to $targetPath');
      if (!mounted) return;
      setState(() {
        _statusLog = 'Sender report copy exported: $targetPath';
      });
    } catch (error) {
      _debugLog('DEBUG: Sender report copy export failed: $error');
      if (!mounted) return;
      setState(() {
        _statusLog = 'Sender report export failed: $error';
      });
    }
  }

  Future<String> _readLastSenderReportContentsForExport() async {
    final sourcePath = _lastRemoteReportPath;
    if (sourcePath == null || sourcePath.isEmpty) {
      return 'No sender report has been received yet.';
    }
    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        return 'Sender report path recorded but file was not found: $sourcePath';
      }
      return await file.readAsString();
    } catch (error) {
      return 'Failed to read sender report file ($sourcePath): $error';
    }
  }

  Future<void> _copyAllLogsToClipboard() async {
    final now = DateTime.now();
    try {
      final nativeAudioLogs = await _audioPlayerService.getAudioDebugLogs();
      final senderReportText = await _readLastSenderReportContentsForExport();

      final lines = <String>[
        'BEGIN NOMIKAI_COMBINED_DEBUG_EXPORT ts=${now.toIso8601String()}',
        'platform=$defaultTargetPlatform receiving=$_isReceiving busy=$_isBusy handshake_state=$_handshakeState',
        'audio_playback_enabled=$_audioPlaybackEnabled audio_lifecycle_suspended=$_audioPlaybackSuspendedByLifecycle',
        'status=${_statusLog.replaceAll('\n', ' ')}',
        'current_bitrate_bps=$_currentReceiveBitrateBps current_fps=${_currentFps.toStringAsFixed(1)} packet_loss_percent=${_packetLossPercent.toStringAsFixed(3)} frame_drops=$_frameDrops',
        'last_remote_report_path=${_lastRemoteReportPath ?? 'null'}',
        'receiver_debug_lines_total=${_debugLines.length}',
        'native_audio_debug_lines_total=${nativeAudioLogs.length}',
        '--- RECEIVER_FLUTTER_DEBUG_LOGS_BEGIN ---',
        ..._debugLines,
        '--- RECEIVER_FLUTTER_DEBUG_LOGS_END ---',
        '--- RECEIVER_NATIVE_AUDIO_LOGS_BEGIN ---',
        ...nativeAudioLogs,
        '--- RECEIVER_NATIVE_AUDIO_LOGS_END ---',
        '--- LAST_SENDER_REPORT_BEGIN ---',
        senderReportText,
        '--- LAST_SENDER_REPORT_END ---',
        'END NOMIKAI_COMBINED_DEBUG_EXPORT',
      ];

      final combined = '${lines.join('\n')}\n';
      await Clipboard.setData(ClipboardData(text: combined));
      _debugLog(
        'DEBUG: Combined receiver+sender logs copied to clipboard (${combined.length} chars).',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog =
            'Combined logs copied to clipboard (${combined.length} chars).';
      });
    } catch (error) {
      _debugLog('DEBUG: Copy all logs to clipboard failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog = 'Copy all logs to clipboard failed: $error';
      });
    }
  }

  Future<Uint8List> _loadCompressionGraph() async {
    final ByteData graphData = await rootBundle.load('assets/sao_graph.bin');
    return graphData.buffer.asUint8List(
      graphData.offsetInBytes,
      graphData.lengthInBytes,
    );
  }

  void _appendMetricSample(double sample) {
    _byteSamples.add(sample);
    if (_byteSamples.length > 160) {
      _byteSamples.removeAt(0);
    }
  }

  void _startMetricsTicker() {
    _metricsTicker?.cancel();
    _metricsTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_isReceiving) {
        return;
      }

      final int bytes = _bytesSinceTick;
      final int frames = _framesSinceTick;
      _bytesSinceTick = 0;
      _framesSinceTick = 0;

      setState(() {
        _currentFps = frames * 2.0;
        _appendMetricSample(bytes.toDouble());
        _bitrateWindowBytes.add(bytes);
        if (_bitrateWindowBytes.length > 2) {
          _bitrateWindowBytes.removeAt(0);
        }
        final int windowBytes = _bitrateWindowBytes.fold<int>(
          0,
          (sum, sample) => sum + sample,
        );
        _currentReceiveBitrateBps = windowBytes * 8;
      });
    });
  }

  void _stopMetricsTicker() {
    _metricsTicker?.cancel();
    _metricsTicker = null;
    _bytesSinceTick = 0;
    _framesSinceTick = 0;
    _bitrateWindowBytes.clear();
    _currentReceiveBitrateBps = 0;
    _currentFps = 0;
  }

  Future<void> _toggleReceiver() async {
    if (_isBusy) {
      return;
    }

    if (_isReceiving) {
      await _stopReceiver();
      return;
    }

    await _startReceiver();
  }

  Future<void> _startReceiver() async {
    const bindAddr = _sankakuReceiverBindAddr;
    _debugLog('DEBUG: Receiver startup requested. bindAddr=$bindAddr');
    resetNetworkStats();

    if (!_playerService.isSupported) {
      setState(() {
        _statusLog = 'Receiver decode path is only available on macOS.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _statusLog = 'Starting Sankaku receiver on $bindAddr...';
    });

    try {
      _debugLog('DEBUG: Loading compression graph...');
      final graphBytes = await _loadCompressionGraph();
      _debugLog('DEBUG: Compression graph loaded. bytes=${graphBytes.length}');

      _debugLog('DEBUG: Initializing HEVC player...');
      final textureId = await _playerService.initPlayer();
      _debugLog('DEBUG: HEVC player initialized. textureId=$textureId');

      _debugLog('DEBUG: Initializing Audio Player...');
      try {
        await _audioPlayerService.initializeAudio();
        await _audioPlayerService.clearAudioDebugLogs();
        _audioPlaybackEnabled = true;
        _debugLog('DEBUG: Audio Player initialized.');
      } catch (error) {
        _audioPlaybackEnabled = false;
        _debugLog('AUDIO INIT FAILED: $error');
        _debugLog(
          'DEBUG: Continuing receiver startup without native audio playback.',
        );
      }

      _debugLog('DEBUG: Cancelling previous receiver event subscription...');
      try {
        await stopSankakuReceiver();
      } catch (error) {
        _debugLog('DEBUG: Receiver stop request before restart failed: $error');
      }
      await _receiverEventSubscription?.cancel();
      _debugLog('DEBUG: Previous receiver event subscription cancelled.');

      _debugLog('DEBUG: Starting Sankaku receiver stream...');
      _receiverEventSubscription =
          startSankakuReceiver(
            bindAddr: bindAddr,
            graphBytes: graphBytes,
          ).listen(
            _onReceiverEvent,
            onError: (Object error) {
              if (!mounted) {
                return;
              }
              unawaited(_discoveryService.stopBroadcasting());

              setState(() {
                _statusLog = 'Receiver stream error: $error';
                _handshakeState = 'error';
              });
            },
            onDone: () {
              if (!mounted) {
                return;
              }

              unawaited(_discoveryService.stopBroadcasting());
              _stopMetricsTicker();
              setState(() {
                _isReceiving = false;
                _handshakeState = 'stopped';
                _statusLog = 'Receiver stream closed.';
              });
            },
          );
      _debugLog('DEBUG: Sankaku receiver stream started.');

      _debugLog('DEBUG: Starting mDNS Broadcast...');
      try {
        await _discoveryService.startBroadcasting(_sankakuUdpPort);
        _debugLog('DEBUG: mDNS Broadcast started.');
      } catch (error) {
        _debugLog(
          'DEBUG: mDNS Broadcast failed, continuing receiver without discovery: $error',
        );
      }

      _stopMetricsTicker();
      _byteSamples.clear();
      _frameDrops = 0;
      _currentFps = 0;
      _packetLossPercent = 0;
      _handshakeState = 'starting';
      _startMetricsTicker();

      if (!mounted) {
        return;
      }

      setState(() {
        _textureId = textureId;
        _isReceiving = true;
        _statusLog = 'Receiver listening on $bindAddr.';
      });
      _debugLog('DEBUG: Receiver startup complete.');
    } catch (error) {
      _debugLog('DEBUG: Receiver startup failed: $error');
      _stopMetricsTicker();
      await _receiverEventSubscription?.cancel();
      _receiverEventSubscription = null;

      if (!mounted) {
        return;
      }

      setState(() {
        _isReceiving = false;
        _handshakeState = 'error';
        _statusLog = 'Receiver startup failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _stopReceiver() async {
    setState(() {
      _isBusy = true;
      _statusLog = 'Stopping receiver...';
    });

    try {
      await stopSankakuReceiver();
    } catch (error) {
      _debugLog('DEBUG: Receiver stop request failed: $error');
    }
    await _receiverEventSubscription?.cancel();
    _receiverEventSubscription = null;
    _stopMetricsTicker();
    await _audioPlayerService.suspendAudio();
    await _discoveryService.stopBroadcasting();

    if (!mounted) {
      return;
    }

    setState(() {
      _isBusy = false;
      _isReceiving = false;
      _currentFps = 0;
      _handshakeState = 'stopped';
      _statusLog = 'Receiver stopped.';
    });
    resetNetworkStats();
  }

  void _onReceiverEvent(UiEvent event) {
    if (!mounted) {
      return;
    }

    event.when(
      log: (msg) {
        final remoteReportPath = _extractRemoteReportPath(msg);
        setState(() {
          if (remoteReportPath != null) {
            _lastRemoteReportPath = remoteReportPath;
          }
          _appendDebugLineInSetState(msg);
          _statusLog = msg;
        });
      },
      connectionState: (state, detail) {
        setState(() {
          _handshakeState = state;
          _statusLog = '[$state] $detail';
        });
      },
      handshakeInitiated: () {
        setState(() {
          _handshakeState = 'handshake';
          _statusLog = 'Handshake initiated...';
        });
      },
      handshakeComplete: (sessionId, bootstrapMode) {
        setState(() {
          _handshakeState = 'connected';
          _statusLog =
              'Connected session=$sessionId bootstrapMode=$bootstrapMode';
        });
      },
      progress: (streamId, frameIndex, bytes, frames) {
        _debugLog(
          'DEBUG: Receiver progress stream=$streamId frame=$frameIndex bytes=$bytes totalFrames=$frames',
        );
      },
      telemetry: (name, value) {
        updateNetworkStatsFromTelemetry(name: name, value: value.toInt());
        setState(() {
          if (name == 'packet_loss_ppm') {
            _packetLossPercent = value.toDouble() / 10_000.0;
          }
        });
        _debugLog('DEBUG: Receiver telemetry $name=$value');
      },
      frameDrop: (streamId, reason) {
        setState(() {
          _frameDrops += 1;
          _statusLog = 'Frame drop stream=$streamId: $reason';
        });
      },
      fault: (code, message) {
        setState(() {
          _handshakeState = 'fault';
          _statusLog = 'FAULT [$code]: $message';
        });
      },
      bitrateChanged: (bitrateBps) {
        updateNetworkBitrate(bitrateBps);
        setState(() {
          _statusLog =
              'Sender bitrate updated to ${(bitrateBps / 1_000_000).toStringAsFixed(2)} Mbps';
        });
      },
      videoFrameReceived: (data, pts) {
        _bytesSinceTick += data.length;
        _framesSinceTick += 1;

        unawaited(
          _playerService.pushFrame(data, ptsUs: pts.toInt()).catchError((
            Object error,
          ) {
            if (!mounted) {
              return;
            }

            setState(() {
              _statusLog = 'Player decode push failed: $error';
            });
          }),
        );
      },
      audioFrameReceived: (data, pts, framesPerPacket) {
        _bytesSinceTick += data.length;

        if (!_audioPlaybackEnabled || _audioPlaybackSuspendedByLifecycle) {
          return;
        }
        unawaited(
          _audioPlayerService
              .pushAudioFrame(
                data,
                ptsUs: pts.toInt(),
                framesPerPacketHint: framesPerPacket.toInt(),
              )
              .catchError((Object error) {
                if (!mounted) {
                  return;
                }
                setState(() {
                  _audioPlaybackEnabled = false;
                  _statusLog = 'Audio playback push failed: $error';
                });
              }),
        );
      },
      error: (msg) {
        setState(() {
          _handshakeState = 'error';
          _statusLog = 'ERROR: $msg';
        });
      },
    );
  }

  Widget _buildControlCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receiver', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Listening on $_sankakuReceiverBindAddr and advertising via mDNS.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isBusy ? null : _toggleReceiver,
              icon: Icon(_isReceiving ? Icons.stop_circle : Icons.download),
              label: Text(_isReceiving ? 'Stop Receiver' : 'Start Receiver'),
              style: FilledButton.styleFrom(
                backgroundColor: _isReceiving
                    ? Colors.red.shade400
                    : Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(180, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSurface(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: _textureId != null
                      ? Texture(textureId: _textureId!)
                      : Center(
                          child: Text(
                            'Decoder idle',
                            style: TextStyle(
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                ),
              ],
            ),
            Positioned(
              top: 12,
              left: 12,
              child: _OverlayBadge(label: 'State: $_handshakeState'),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: _OverlayBadge(
                label: 'FPS: ${_currentFps.toStringAsFixed(1)}',
              ),
            ),
            if (_isReceiving) const NetworkDebugOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Receiver Metrics',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Incoming payload size (bytes / 500ms)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: CustomPaint(
                  painter: _MetricGraphPainter(samples: _byteSamples),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 12),
              Text('Handshake State: $_handshakeState'),
              Text(
                'Current Bitrate: ${(_currentReceiveBitrateBps / 1_000_000).toStringAsFixed(2)} Mbps',
              ),
              Text('Frame Drops: $_frameDrops'),
              Text('Packet Loss: ${_packetLossPercent.toStringAsFixed(2)}%'),
              Text('Current FPS: ${_currentFps.toStringAsFixed(1)}'),
              const SizedBox(height: 12),
              Text(_statusLog, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDebugConsoleCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Debug Console',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  tooltip: _debugConsoleExpanded ? 'Collapse' : 'Expand',
                  onPressed: () {
                    setState(() {
                      _debugConsoleExpanded = !_debugConsoleExpanded;
                    });
                  },
                  icon: Icon(
                    _debugConsoleExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy All Logs',
                  onPressed: _copyAllLogsToClipboard,
                  icon: const Icon(Icons.content_copy),
                ),
                IconButton(
                  tooltip: 'Export Logs',
                  onPressed: _exportReceiverDebugLogs,
                  icon: const Icon(Icons.save_alt),
                ),
                IconButton(
                  tooltip: 'Export Last Sender Report',
                  onPressed: _lastRemoteReportPath == null
                      ? null
                      : _exportLastRemoteReportCopy,
                  icon: const Icon(Icons.file_upload_outlined),
                ),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: _clearDebugLogs,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (_debugConsoleExpanded) ...[
              const SizedBox(height: 8),
              Container(
                height: 170,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _debugLines.isEmpty
                    ? const Center(
                        child: Text(
                          'No debug logs yet.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: _debugLines.length,
                        itemBuilder: (context, index) {
                          final int lineIndex = _debugLines.length - 1 - index;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: SelectableText(
                              _debugLines[lineIndex],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                height: 1.3,
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _metricsTicker?.cancel();
    unawaited(_audioPlayerService.suspendAudio());
    unawaited(stopSankakuReceiver());
    _receiverEventSubscription?.cancel();
    unawaited(_discoveryService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nomikai Receiver')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildControlCard(context),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final bool stacked = constraints.maxWidth < 980;

                    if (stacked) {
                      return Column(
                        children: [
                          Expanded(flex: 3, child: _buildVideoSurface(context)),
                          const SizedBox(height: 12),
                          Flexible(flex: 2, child: _buildDashboard(context)),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(flex: 3, child: _buildVideoSurface(context)),
                        const SizedBox(width: 12),
                        SizedBox(width: 360, child: _buildDashboard(context)),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: _debugConsoleExpanded ? 236 : 64,
                child: _buildDebugConsoleCard(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayBadge extends StatelessWidget {
  const _OverlayBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _MetricGraphPainter extends CustomPainter {
  _MetricGraphPainter({required this.samples});

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint gridPaint = Paint()
      ..color = const Color(0x33000000)
      ..strokeWidth = 1;

    for (var i = 1; i <= 3; i++) {
      final double y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (samples.isEmpty) {
      return;
    }

    final double maxSample = math.max(1, samples.reduce(math.max));
    final Path linePath = Path();

    for (var i = 0; i < samples.length; i++) {
      final double x = samples.length == 1
          ? size.width
          : (i * size.width / (samples.length - 1));
      final double normalized = (samples[i] / maxSample).clamp(0.0, 1.0);
      final double y = size.height - (normalized * size.height);

      if (i == 0) {
        linePath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
      }
    }

    final Paint linePaint = Paint()
      ..color = const Color(0xFF00BCD4)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(covariant _MetricGraphPainter oldDelegate) {
    return !listEquals(samples, oldDelegate.samples);
  }
}

class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final HevcDumperService _hevcService = HevcDumperService();
  late final NomikaiDiscoveryService _discoveryService;
  final List<String> _debugLines = <String>[];
  final TextEditingController _manualDestinationController =
      TextEditingController(text: _manualDialPlaceholder);

  StreamSubscription<UiEvent>? _senderEventSubscription;
  Timer? _senderHandshakeTimeoutTimer;

  bool _isBroadcasting = false;
  bool _isBusy = false;
  bool _isMicrophoneMuted = false;
  bool _isAudioOnlyCall = false;
  bool _isCaptureActive = false;
  bool _debugConsoleExpanded = false;
  bool _senderHandshakeCompleted = false;
  bool _senderFailureRecoveryInFlight = false;
  bool _discoveryRefreshInFlight = false;
  double _progress = 0.0;
  int _currentBitrateBps = 0;
  String? _activeDestination;
  nsd.Service? _selectedReceiverService;
  String _statusLog = 'Ready.';

  static const int _maxDebugLines = 240;
  static const Duration _senderHandshakeTimeout = Duration(seconds: 5);

  Future<void> _loadManualDestinationPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_manualDialPrefsKey)?.trim();
      if (saved == null || saved.isEmpty || !mounted) {
        return;
      }
      _manualDestinationController.text = saved;
      _debugLog('DEBUG: Restored manual destination from preferences: $saved');
    } catch (error) {
      _debugLog(
        'DEBUG: Failed to restore manual destination preference: $error',
      );
    }
  }

  Future<void> _saveManualDestinationPreference(String destination) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_manualDialPrefsKey, destination);
    } catch (error) {
      _debugLog(
        'DEBUG: Failed to persist manual destination preference: $error',
      );
    }
  }

  void _debugLog(String message) {
    final String line = '[${DateTime.now().toIso8601String()}] $message';
    print(line);
    if (!mounted) {
      return;
    }
    setState(() {
      _debugLines.add(line);
      if (_debugLines.length > _maxDebugLines) {
        _debugLines.removeRange(0, _debugLines.length - _maxDebugLines);
      }
    });
  }

  void _clearDebugLogs() {
    setState(() {
      _debugLines.clear();
    });
  }

  void _appendDebugLineInSetState(String message) {
    final String line = '[${DateTime.now().toIso8601String()}] $message';
    _debugLines.add(line);
    if (_debugLines.length > _maxDebugLines) {
      _debugLines.removeRange(0, _debugLines.length - _maxDebugLines);
    }
  }

  Uint8List _u16le(int value) {
    final ByteData data = ByteData(2)..setUint16(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _u32le(int value) {
    final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _buildDebugReportBeginPacket({
    required int reportId,
    required String filename,
    required int totalChunks,
    required int totalBytes,
  }) {
    final Uint8List filenameBytes = Uint8List.fromList(utf8.encode(filename));
    final BytesBuilder builder = BytesBuilder(copy: false)
      ..add(_debugReportMagic)
      ..add(<int>[_debugReportProtocolVersion, _debugReportPacketBegin])
      ..add(_u32le(reportId))
      ..add(_u32le(totalChunks))
      ..add(_u32le(totalBytes))
      ..add(_u16le(filenameBytes.length))
      ..add(filenameBytes);
    return builder.toBytes();
  }

  Uint8List _buildDebugReportChunkPacket({
    required int reportId,
    required int sequence,
    required Uint8List chunkBytes,
  }) {
    final BytesBuilder builder = BytesBuilder(copy: false)
      ..add(_debugReportMagic)
      ..add(<int>[_debugReportProtocolVersion, _debugReportPacketChunk])
      ..add(_u32le(reportId))
      ..add(_u32le(sequence))
      ..add(_u16le(chunkBytes.length))
      ..add(chunkBytes);
    return builder.toBytes();
  }

  Uint8List _buildDebugReportEndPacket({
    required int reportId,
    required int totalChunks,
    required int totalBytes,
  }) {
    final BytesBuilder builder = BytesBuilder(copy: false)
      ..add(_debugReportMagic)
      ..add(<int>[_debugReportProtocolVersion, _debugReportPacketEnd])
      ..add(_u32le(reportId))
      ..add(_u32le(totalChunks))
      ..add(_u32le(totalBytes));
    return builder.toBytes();
  }

  Future<void> _sendDebugReportToReceiver() async {
    if (_isBusy || !_isBroadcasting) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog = 'Start a call/broadcast before sending a debug report.';
      });
      return;
    }

    final now = DateTime.now();
    final selectedService = _selectedReceiverService;
    final allLogs = List<String>.from(_debugLines);
    final reportLines = <String>[
      'BEGIN SENDER_REPORT_FILE ts=${now.toIso8601String()}',
      'platform=$defaultTargetPlatform audio_only=$_isAudioOnlyCall mic_muted=$_isMicrophoneMuted capture_active=$_isCaptureActive broadcasting=$_isBroadcasting handshake_completed=$_senderHandshakeCompleted',
      'destination=${_activeDestination ?? 'unknown'}',
      'selected_service.name=${selectedService?.name ?? 'null'}',
      'selected_service.host=${selectedService?.host ?? 'null'}',
      'selected_service.port=${selectedService?.port?.toString() ?? 'null'}',
      'selected_service.addresses=${selectedService?.addresses?.join(',') ?? 'null'}',
      'sender_progress=${_progress.toStringAsFixed(3)} current_transport_bitrate_bps=$_currentBitrateBps',
      'status=${_statusLog.replaceAll('\n', ' ')}',
      'debug_lines_total=${_debugLines.length} debug_lines_included=${allLogs.length}',
      ...allLogs,
      'END SENDER_REPORT_FILE',
    ];

    final String safeTs = now
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final String filename = 'nomikai_sender_report_$safeTs.log';
    final Uint8List fileBytes = Uint8List.fromList(
      utf8.encode('${reportLines.join('\n')}\n'),
    );
    const int chunkPayloadBytes = 800;
    final int totalChunks = fileBytes.isEmpty
        ? 0
        : (fileBytes.length / chunkPayloadBytes).ceil();
    final int reportId = now.microsecondsSinceEpoch & 0xFFFFFFFF;

    int packetCount = 0;
    final basePtsUs = now.microsecondsSinceEpoch;

    try {
      await pushAudioFrame(
        frameBytes: _buildDebugReportBeginPacket(
          reportId: reportId,
          filename: filename,
          totalChunks: totalChunks,
          totalBytes: fileBytes.length,
        ),
        pts: BigInt.from(basePtsUs + packetCount),
        codec: _audioCodecDebugReport,
        framesPerPacket: 0,
      );
      packetCount += 1;

      for (int sequence = 0; sequence < totalChunks; sequence++) {
        final int start = sequence * chunkPayloadBytes;
        final int end = math.min(fileBytes.length, start + chunkPayloadBytes);
        final Uint8List chunkBytes = Uint8List.sublistView(
          fileBytes,
          start,
          end,
        );

        await pushAudioFrame(
          frameBytes: _buildDebugReportChunkPacket(
            reportId: reportId,
            sequence: sequence,
            chunkBytes: chunkBytes,
          ),
          pts: BigInt.from(basePtsUs + packetCount),
          codec: _audioCodecDebugReport,
          framesPerPacket: 0,
        );
        packetCount += 1;
      }

      await pushAudioFrame(
        frameBytes: _buildDebugReportEndPacket(
          reportId: reportId,
          totalChunks: totalChunks,
          totalBytes: fileBytes.length,
        ),
        pts: BigInt.from(basePtsUs + packetCount),
        codec: _audioCodecDebugReport,
        framesPerPacket: 0,
      );
      packetCount += 1;

      _debugLog(
        'DEBUG: Sender debug report file sent to receiver (file=$filename bytes=${fileBytes.length} chunks=$totalChunks packets=$packetCount)',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog =
            'Debug report file sent ($packetCount packets, ${fileBytes.length} bytes).';
      });
    } catch (error) {
      _debugLog('DEBUG: Sender debug report send failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog = 'Failed to send debug report: $error';
      });
    }
  }

  void _cancelSenderHandshakeTimeout() {
    _senderHandshakeTimeoutTimer?.cancel();
    _senderHandshakeTimeoutTimer = null;
  }

  void _armSenderHandshakeTimeout(String destination) {
    _cancelSenderHandshakeTimeout();
    if (_senderHandshakeCompleted) {
      return;
    }

    _senderHandshakeTimeoutTimer = Timer(_senderHandshakeTimeout, () {
      unawaited(_handleSenderHandshakeTimeout(destination));
    });
    _debugLog(
      'DEBUG: Sender handshake timeout armed for ${_senderHandshakeTimeout.inSeconds}s (dest=$destination)',
    );
  }

  Future<void> _refreshDiscoveryAfterConnectionFailure(String reason) async {
    if (_discoveryRefreshInFlight || !_discoveryService.isSupported) {
      return;
    }
    _discoveryRefreshInFlight = true;
    try {
      _debugLog(
        'DEBUG: Refreshing mDNS discovery after connection failure: $reason',
      );
      await _discoveryService.restartScanning();

      final selected = _selectedReceiverService;
      if (selected != null) {
        final refreshed = await _discoveryService.resolveServiceFresh(selected);
        _selectedReceiverService = refreshed;
        final refreshedDestination = _destinationFromService(refreshed);
        if (refreshedDestination != null) {
          _debugLog(
            'DEBUG: Fresh mDNS resolve after failure produced destination=$refreshedDestination',
          );
        } else {
          final rawAddresses =
              refreshed.addresses?.map((entry) => entry.address).join(', ') ??
              'none';
          _debugLog(
            'DEBUG: Fresh mDNS resolve after failure produced no usable destination '
            '(host=${refreshed.host ?? 'null'} addresses=$rawAddresses port=${refreshed.port})',
          );
        }
      }
    } catch (error) {
      _debugLog('DEBUG: mDNS refresh after failure failed: $error');
    } finally {
      _discoveryRefreshInFlight = false;
    }
  }

  Future<void> _handleSenderHandshakeTimeout(String destination) async {
    if (!mounted ||
        _senderHandshakeCompleted ||
        !_isBroadcasting ||
        _isBusy ||
        _senderFailureRecoveryInFlight) {
      return;
    }

    _senderFailureRecoveryInFlight = true;
    _debugLog(
      'DEBUG: Handshake timeout: no HandshakeComplete received within '
      '${_senderHandshakeTimeout.inSeconds}s for $destination',
    );

    await _stopBroadcast(
      statusOverride:
          'Handshake timeout after ${_senderHandshakeTimeout.inSeconds}s. Resetting sender and refreshing receiver discovery...',
    );
    await _refreshDiscoveryAfterConnectionFailure('handshake timeout');

    if (mounted && !_isBroadcasting) {
      setState(() {
        _statusLog =
            'Handshake timed out. Sender stopped and mDNS was refreshed. Select the receiver again to retry.';
      });
    }

    _senderFailureRecoveryInFlight = false;
  }

  String? _normalizeManualDestinationInput(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.contains('<') || trimmed.contains('>')) {
      return null;
    }

    final candidate = trimmed.contains(':')
        ? trimmed
        : '$trimmed:$_sankakuUdpPort';
    final uri = Uri.tryParse('udp://$candidate');
    if (uri == null || uri.host.isEmpty || uri.port <= 0 || uri.port > 65535) {
      return null;
    }
    return candidate;
  }

  Future<void> _connectToManualDestination() async {
    if (_isBusy || _isBroadcasting) {
      return;
    }

    final destination = _normalizeManualDestinationInput(
      _manualDestinationController.text,
    );
    if (destination == null) {
      setState(() {
        _statusLog =
            'Enter a valid destination like 203.0.113.45:$_sankakuUdpPort';
      });
      return;
    }

    _manualDestinationController.text = destination;
    _selectedReceiverService = null;
    _debugLog('DEBUG: Manual dial requested. destination=$destination');
    unawaited(_saveManualDestinationPreference(destination));
    await _startBroadcastTo(destination);
  }

  Future<void> _startBroadcastToDiscoveredService(nsd.Service service) async {
    if (_isBusy || _isBroadcasting) {
      return;
    }

    _selectedReceiverService = service;
    _debugLog(
      'DEBUG: Performing fresh mDNS resolve before dialing ${service.name ?? 'receiver'}...',
    );

    try {
      final resolvedService = await _discoveryService.resolveServiceFresh(
        service,
      );
      final destination = _destinationFromService(resolvedService);
      if (destination == null) {
        final rawAddresses =
            resolvedService.addresses
                ?.map((entry) => entry.address)
                .join(', ') ??
            'none';
        throw StateError(
          'Selected receiver is missing a usable resolved address/port '
          '(host=${resolvedService.host ?? 'null'} addresses=$rawAddresses port=${resolvedService.port}).',
        );
      }
      _selectedReceiverService = resolvedService;
      await _startBroadcastTo(destination);
    } catch (error) {
      _debugLog('DEBUG: Fresh mDNS resolve before dial failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _statusLog = 'Receiver resolve failed: $error';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _discoveryService = NomikaiDiscoveryService(logger: _debugLog);
    _hevcService.setDebugLogger(_debugLog);
    unawaited(_loadManualDestinationPreference());
    _debugLog('DEBUG: Starting mDNS Scanner...');
    unawaited(
      _discoveryService
          .startScanning()
          .then((_) {
            _debugLog('DEBUG: mDNS Scanner started.');
          })
          .catchError((Object error) {
            _debugLog('DEBUG: mDNS Scanner failed: $error');
            if (!mounted) {
              return;
            }
            setState(() {
              _statusLog = 'Receiver discovery failed: $error';
            });
          }),
    );
  }

  Future<Uint8List> _loadCompressionGraph() async {
    final ByteData graphData = await rootBundle.load('assets/sao_graph.bin');
    return graphData.buffer.asUint8List(
      graphData.offsetInBytes,
      graphData.lengthInBytes,
    );
  }

  Future<void> _toggleBroadcast() async {
    if (_isBusy) {
      return;
    }
    if (_isBroadcasting) {
      await _stopBroadcast();
    }
  }

  Future<void> _startBroadcastTo(String destination) async {
    if (_isBusy || _isBroadcasting) {
      return;
    }
    _cancelSenderHandshakeTimeout();
    _senderHandshakeCompleted = false;
    _senderFailureRecoveryInFlight = false;
    _debugLog('DEBUG: Sender startup requested. destination=$destination');
    resetNetworkStats();
    setState(() {
      _isBusy = true;
      _progress = 0.0;
      _statusLog = 'Starting broadcast to $destination...';
    });

    try {
      _debugLog('DEBUG: Loading compression graph...');
      final graphBytes = await _loadCompressionGraph();
      _debugLog('DEBUG: Compression graph loaded. bytes=${graphBytes.length}');

      _debugLog('DEBUG: Creating Sankaku sender stream...');
      final senderEvents = (() {
        try {
          return startSankakuSender(
            dest: destination,
            graphBytes: graphBytes,
          );
        } catch (error) {
          _debugLog('DEBUG: QUIC Handshake / Connection Failed: $error');
          rethrow;
        }
      })();
      _debugLog('DEBUG: Sankaku sender stream created.');

      _debugLog('DEBUG: Cancelling previous sender event subscription...');
      await _senderEventSubscription?.cancel();
      _debugLog('DEBUG: Previous sender event subscription cancelled.');

      _debugLog('DEBUG: Subscribing to sender events...');
      _senderEventSubscription = senderEvents.listen(
        _onEngineEvent,
        onError: (Object error) {
          _debugLog('DEBUG: QUIC Handshake / Connection Failed: $error');
          _cancelSenderHandshakeTimeout();
          if (!_senderHandshakeCompleted) {
            unawaited(
              _refreshDiscoveryAfterConnectionFailure('sender stream error'),
            );
          }
          if (!mounted) {
            return;
          }
          setState(() {
            _statusLog = 'QUIC Handshake / Connection Failed: $error';
          });
        },
      );
      _debugLog('DEBUG: Sender event subscription active.');

      _debugLog('DEBUG: Applying microphone mute state: $_isMicrophoneMuted');
      _hevcService.setMicrophoneMuted(_isMicrophoneMuted);
      Object? audioInitError;
      _debugLog(
        'DEBUG: Requesting Mic Permissions / starting native capture...',
      );
      try {
        await _hevcService.startRecording(audioOnly: _isAudioOnlyCall);
        _isCaptureActive = true;
        _debugLog(
          'DEBUG: Native capture initialized (audioOnly=$_isAudioOnlyCall).',
        );
      } catch (error) {
        _isCaptureActive = false;
        audioInitError = error;
        _debugLog('AUDIO INIT FAILED: $error');
        _debugLog(
          'DEBUG: Continuing sender startup without native capture stream.',
        );
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _isBroadcasting = true;
        _currentBitrateBps = 0;
        _activeDestination = destination;
        _statusLog = audioInitError == null
            ? (_isAudioOnlyCall
                  ? 'Audio-only call live to $destination.'
                  : 'Broadcast live to $destination.')
            : 'Broadcast control channel live to $destination. Capture unavailable: $audioInitError';
      });
      _armSenderHandshakeTimeout(destination);
      _debugLog('DEBUG: Sender startup complete.');
    } catch (error) {
      _debugLog('DEBUG: Sender startup failed: $error');
      _cancelSenderHandshakeTimeout();
      await _senderEventSubscription?.cancel();
      _senderEventSubscription = null;

      if (_selectedReceiverService != null) {
        unawaited(
          _refreshDiscoveryAfterConnectionFailure('sender startup failure'),
        );
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _isBroadcasting = false;
        _activeDestination = null;
        _statusLog = 'Broadcast start failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _stopBroadcast({String? statusOverride}) async {
    setState(() {
      _isBusy = true;
      _statusLog = 'Stopping broadcast...';
    });
    _debugLog('DEBUG: Stopping sender broadcast...');
    _cancelSenderHandshakeTimeout();

    Object? stopError;

    if (_isCaptureActive) {
      _debugLog('DEBUG: Stopping native capture...');
      try {
        await _hevcService.stopRecording();
        _isCaptureActive = false;
        _debugLog('DEBUG: Native capture stopped.');
      } catch (error) {
        stopError = error;
      }
    } else {
      _debugLog(
        'DEBUG: Native capture was not active; skipping stopRecording.',
      );
    }

    _debugLog('DEBUG: Stopping Sankaku sender...');
    try {
      await stopSankakuSender();
      _debugLog('DEBUG: Sankaku sender stop requested.');
    } catch (error) {
      stopError ??= error;
    }

    _debugLog('DEBUG: Cancelling sender event subscription...');
    await _senderEventSubscription?.cancel();
    _senderEventSubscription = null;
    _debugLog('DEBUG: Sender event subscription cancelled.');

    if (!mounted) {
      return;
    }
    setState(() {
      _isBusy = false;
      _isBroadcasting = false;
      _senderHandshakeCompleted = false;
      _progress = 0.0;
      _activeDestination = null;
      _statusLog =
          statusOverride ??
          (stopError == null
              ? 'Broadcast stopped.'
              : 'Stop completed with warning: $stopError');
    });
  }

  void _onEngineEvent(UiEvent event) {
    if (!mounted) {
      return;
    }

    int? bitrateToApply;
    setState(() {
      event.when(
        log: (msg) {
          _appendDebugLineInSetState(msg);
          _statusLog = msg;
        },
        connectionState: (state, detail) {
          _statusLog = 'Connection [$state]: $detail';
        },
        handshakeInitiated: () => _statusLog = 'Handshake initiated...',
        handshakeComplete: (sessionId, bootstrapMode) {
          _senderHandshakeCompleted = true;
          _cancelSenderHandshakeTimeout();
          _statusLog =
              'Broadcast connected. Session=$sessionId Mode=$bootstrapMode';
        },
        progress: (streamId, frameIndex, bytes, frames) {
          _progress = ((frameIndex.toInt() + 1) % 100) / 100.0;
          _debugLog(
            'DEBUG: Sender progress stream=$streamId frame=$frameIndex bytes=$bytes frames=$frames',
          );
        },
        telemetry: (name, value) {
          updateNetworkStatsFromTelemetry(name: name, value: value.toInt());
          _debugLog('DEBUG: Sender telemetry $name=$value');
        },
        frameDrop: (streamId, reason) {
          _debugLog('DEBUG: Sender frame drop stream=$streamId: $reason');
        },
        fault: (code, message) {
          if (!_senderHandshakeCompleted) {
            unawaited(
              _refreshDiscoveryAfterConnectionFailure('sender fault $code'),
            );
          }
          _statusLog = 'FAULT [$code]: $message';
        },
        bitrateChanged: (bitrateBps) {
          updateNetworkBitrate(bitrateBps);
          _currentBitrateBps = bitrateBps;
          if (!_isAudioOnlyCall) {
            bitrateToApply = bitrateBps;
          }
          _statusLog = _isAudioOnlyCall
              ? 'Audio-only call connected. Transport bitrate ${(bitrateBps / 1_000_000).toStringAsFixed(2)} Mbps'
              : 'Adaptive bitrate set to ${(bitrateBps / 1_000_000).toStringAsFixed(2)} Mbps';
        },
        videoFrameReceived: (data, pts) {
          _debugLog(
            'DEBUG: Sender loop observed video frame event (${data.length} bytes, pts=$pts)',
          );
        },
        audioFrameReceived: (data, pts, framesPerPacket) {
          _debugLog(
            'DEBUG: Sender loop observed audio packet event (${data.length} bytes, pts=$pts, frames_per_packet=$framesPerPacket)',
          );
        },
        error: (msg) {
          _cancelSenderHandshakeTimeout();
          if (!_senderHandshakeCompleted) {
            unawaited(
              _refreshDiscoveryAfterConnectionFailure('sender error event'),
            );
          }
          _statusLog = 'ERROR: $msg';
        },
      );
    });

    if (bitrateToApply != null && _isBroadcasting) {
      unawaited(
        _hevcService.setBitrate(bitrateToApply!).catchError((Object error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _statusLog = 'Failed to apply bitrate update: $error';
          });
        }),
      );
    }
  }

  String? _destinationFromService(nsd.Service service) {
    final port = service.port;
    if (port == null) {
      return null;
    }

    final host = _selectDialHost(service);
    if (host == null) {
      return null;
    }

    final formattedHost = host.contains(':') ? '[$host]' : host;
    return '$formattedHost:$port';
  }

  String? _selectDialHost(nsd.Service service) {
    final addresses = service.addresses;
    final addressStrings = (addresses ?? const <dynamic>[])
        .map((entry) => entry.address as String)
        .map(_normalizeHostForDial)
        .whereType<String>()
        .toList();

    final usableAddresses = addressStrings
        .where((address) => _isUsableDialHost(address))
        .toList();

    final preferredIpv4 = usableAddresses.where((value) => value.contains('.'));
    if (preferredIpv4.isNotEmpty) {
      return preferredIpv4.first;
    }

    final preferredIpv6 = usableAddresses.where(
      (value) => value.contains(':') && !_isIpv6LinkLocalWithoutScope(value),
    );
    if (preferredIpv6.isNotEmpty) {
      return preferredIpv6.first;
    }

    if (usableAddresses.isNotEmpty) {
      return usableAddresses.first;
    }

    final host = _normalizeHostForDial(service.host);
    if (host != null && _isUsableDialHost(host)) {
      return host;
    }

    return null;
  }

  String? _normalizeHostForDial(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed.endsWith('.')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  bool _isUsableDialHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }

    const invalidExact = <String>{
      '0.0.0.0',
      '::',
      '::1',
      '0:0:0:0:0:0:0:0',
      'localhost',
      '127.0.0.1',
    };
    if (invalidExact.contains(normalized)) {
      return false;
    }
    if (normalized.startsWith('127.')) {
      return false;
    }
    return true;
  }

  bool _isIpv6LinkLocalWithoutScope(String host) {
    final normalized = host.toLowerCase();
    return normalized.startsWith('fe80:') && !normalized.contains('%');
  }

  String _serviceLabel(nsd.Service service) {
    final destination = _destinationFromService(service);
    if (destination == null) {
      return service.name ?? 'Receiver';
    }
    final name = service.name?.trim();
    if (name == null || name.isEmpty) {
      return destination;
    }
    return '$name ($destination)';
  }

  void _setMicrophoneMuted(bool muted) {
    setState(() {
      _isMicrophoneMuted = muted;
    });
    _hevcService.setMicrophoneMuted(muted);
  }

  void _setAudioOnlyCall(bool enabled) {
    if (_isBusy || _isBroadcasting) {
      return;
    }
    setState(() {
      _isAudioOnlyCall = enabled;
    });
    _debugLog('DEBUG: Audio-only call mode set to $enabled');
  }

  Widget _buildManualDialCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Manual Connection (WAN / Cellular)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Bypass mDNS and dial a public IP/port directly.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _manualDestinationController,
              enabled: !_isBusy && !_isBroadcasting,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) {
                unawaited(_connectToManualDestination());
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Receiver IP:Port',
                hintText: _manualDialPlaceholder,
                prefixIcon: Icon(Icons.public),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _isBusy || _isBroadcasting
                    ? null
                    : _connectToManualDestination,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryCard(BuildContext context) {
    if (!_discoveryService.isSupported) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Receiver discovery is only supported on iOS/macOS.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<List<nsd.Service>>(
          valueListenable: _discoveryService.discoveredServices,
          builder: (context, services, _) {
            final availableServices = services
                .where((service) => _destinationFromService(service) != null)
                .toList();
            if (availableServices.isEmpty) {
              return const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Searching for Receivers...'),
                  SizedBox(height: 12),
                  LinearProgressIndicator(minHeight: 8),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Available Receivers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                ...availableServices.map((service) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FilledButton.tonalIcon(
                      onPressed: _isBusy || _isBroadcasting
                          ? null
                          : () => _startBroadcastToDiscoveredService(service),
                      icon: const Icon(Icons.cast),
                      label: Text(_serviceLabel(service)),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildDebugConsoleCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Debug Console',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  tooltip: _debugConsoleExpanded ? 'Collapse' : 'Expand',
                  onPressed: () {
                    setState(() {
                      _debugConsoleExpanded = !_debugConsoleExpanded;
                    });
                  },
                  icon: Icon(
                    _debugConsoleExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                ),
                IconButton(
                  tooltip: 'Send Report',
                  onPressed: _isBusy || !_isBroadcasting
                      ? null
                      : () {
                          unawaited(_sendDebugReportToReceiver());
                        },
                  icon: const Icon(Icons.upload_file),
                ),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: _clearDebugLogs,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (_debugConsoleExpanded) ...[
              const SizedBox(height: 8),
              Container(
                height: 170,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _debugLines.isEmpty
                    ? const Center(
                        child: Text(
                          'No debug logs yet.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: _debugLines.length,
                        itemBuilder: (context, index) {
                          final int lineIndex = _debugLines.length - 1 - index;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: SelectableText(
                              _debugLines[lineIndex],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                height: 1.3,
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelSenderHandshakeTimeout();
    _senderEventSubscription?.cancel();
    _manualDestinationController.dispose();
    unawaited(_discoveryService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nomikai Broadcast')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isBroadcasting)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Broadcast Live',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text('Destination: ${_activeDestination ?? 'unknown'}'),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: _isBusy ? null : _toggleBroadcast,
                          icon: const Icon(Icons.stop_circle),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade300,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          label: const Text('Stop Broadcast'),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                _buildManualDialCard(context),
                const SizedBox(height: 12),
                _buildDiscoveryCard(context),
              ],
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                borderRadius: BorderRadius.circular(6),
              ),
              const SizedBox(height: 12),
              Text(
                'Current Bitrate: ${(_currentBitrateBps / 1_000_000).toStringAsFixed(2)} Mbps',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile.adaptive(
                  title: const Text('Audio-Only Call'),
                  subtitle: const Text(
                    'Skip camera/HEVC capture and stream microphone Opus only.',
                  ),
                  value: _isAudioOnlyCall,
                  onChanged: _isBusy || _isBroadcasting
                      ? null
                      : _setAudioOnlyCall,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile.adaptive(
                  title: const Text('Mute Microphone'),
                  subtitle: const Text(
                    'Stop forwarding iOS microphone Opus packets to Rust.',
                  ),
                  value: _isMicrophoneMuted,
                  onChanged: _isBusy ? null : _setMicrophoneMuted,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _statusLog,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              _buildDebugConsoleCard(context),
            ],
          ),
        ),
      ),
    );
  }
}
