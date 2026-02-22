// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nomikai/src/audio_player_service.dart';
import 'package:nomikai/src/discovery_service.dart';
import 'package:nomikai/src/hevc_dumper_service.dart';
import 'package:nomikai/src/hevc_player_service.dart';
import 'package:nomikai/src/rust/api/simple.dart';
import 'package:nomikai/src/rust/frb_generated.dart';
import 'package:nsd/nsd.dart' as nsd;

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

class _ReceiverScreenState extends State<ReceiverScreen> {
  final HevcPlayerService _playerService = HevcPlayerService();
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  late final NomikaiDiscoveryService _discoveryService;

  final List<double> _byteSamples = <double>[];
  final List<String> _debugLines = <String>[];

  StreamSubscription<UiEvent>? _receiverEventSubscription;
  Timer? _metricsTicker;

  bool _isReceiving = false;
  bool _isBusy = false;
  bool _audioPlaybackEnabled = true;
  bool _debugConsoleExpanded = false;

  int? _textureId;
  int _totalBytes = 0;
  int _frameDrops = 0;
  int _bytesSinceTick = 0;
  int _framesSinceTick = 0;

  double _currentFps = 0;
  double _packetLossPercent = 0;

  String _handshakeState = 'idle';
  String _statusLog = 'Ready to receive HEVC stream.';

  static const int _maxDebugLines = 240;

  @override
  void initState() {
    super.initState();
    _discoveryService = NomikaiDiscoveryService(logger: _debugLog);
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
      });
    });
  }

  void _stopMetricsTicker() {
    _metricsTicker?.cancel();
    _metricsTicker = null;
    _bytesSinceTick = 0;
    _framesSinceTick = 0;
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
    const bindAddr = '0.0.0.0:8080';
    _debugLog('DEBUG: Receiver startup requested. bindAddr=$bindAddr');

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
        await _discoveryService.startBroadcasting(8080);
        _debugLog('DEBUG: mDNS Broadcast started.');
      } catch (error) {
        _debugLog(
          'DEBUG: mDNS Broadcast failed, continuing receiver without discovery: $error',
        );
      }

      _stopMetricsTicker();
      _byteSamples.clear();
      _totalBytes = 0;
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

    await _receiverEventSubscription?.cancel();
    _receiverEventSubscription = null;
    _stopMetricsTicker();
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
  }

  void _onReceiverEvent(UiEvent event) {
    if (!mounted) {
      return;
    }

    event.when(
      log: (msg) {
        setState(() {
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
        setState(() {
          _statusLog =
              'stream=$streamId frame=$frameIndex bytes=$bytes totalFrames=$frames';
        });
      },
      telemetry: (name, value) {
        setState(() {
          if (name == 'packet_loss_ppm') {
            _packetLossPercent = value.toDouble() / 10_000.0;
          }
          _statusLog = 'Telemetry: $name=$value';
        });
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
        setState(() {
          _statusLog =
              'Sender bitrate updated to ${(bitrateBps / 1_000_000).toStringAsFixed(2)} Mbps';
        });
      },
      videoFrameReceived: (data) {
        _bytesSinceTick += data.length;
        _framesSinceTick += 1;

        setState(() {
          _totalBytes += data.length;
        });

        unawaited(
          _playerService.pushFrame(data).catchError((Object error) {
            if (!mounted) {
              return;
            }

            setState(() {
              _statusLog = 'Player decode push failed: $error';
            });
          }),
        );
      },
      audioFrameReceived: (data) {
        if (!_audioPlaybackEnabled) {
          return;
        }
        unawaited(
          _audioPlayerService.pushAudioFrame(data).catchError((Object error) {
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    final double kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }

    final double mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
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
              'Listening on 0.0.0.0:8080 and advertising via mDNS.',
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
              Text('Total Bytes Received: ${_formatBytes(_totalBytes)}'),
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
    _metricsTicker?.cancel();
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

  StreamSubscription<UiEvent>? _senderEventSubscription;

  bool _isBroadcasting = false;
  bool _isBusy = false;
  bool _isMicrophoneMuted = false;
  bool _isCaptureActive = false;
  bool _debugConsoleExpanded = false;
  double _progress = 0.0;
  int _currentBitrateBps = 0;
  String? _activeDestination;
  String _statusLog = 'Ready.';

  static const int _maxDebugLines = 240;

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

  @override
  void initState() {
    super.initState();
    _discoveryService = NomikaiDiscoveryService(logger: _debugLog);
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
    _debugLog('DEBUG: Sender startup requested. destination=$destination');
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
      final senderEvents = startSankakuSender(
        dest: destination,
        graphBytes: graphBytes,
      );
      _debugLog('DEBUG: Sankaku sender stream created.');

      _debugLog('DEBUG: Cancelling previous sender event subscription...');
      await _senderEventSubscription?.cancel();
      _debugLog('DEBUG: Previous sender event subscription cancelled.');

      _debugLog('DEBUG: Subscribing to sender events...');
      _senderEventSubscription = senderEvents.listen(
        _onEngineEvent,
        onError: (Object error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _statusLog = 'Sender stream error: $error';
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
        await _hevcService.startRecording();
        _isCaptureActive = true;
        _debugLog('DEBUG: Native capture initialized.');
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
            ? 'Broadcast live to $destination.'
            : 'Broadcast control channel live to $destination. Capture unavailable: $audioInitError';
      });
      _debugLog('DEBUG: Sender startup complete.');
    } catch (error) {
      _debugLog('DEBUG: Sender startup failed: $error');
      await _senderEventSubscription?.cancel();
      _senderEventSubscription = null;

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

  Future<void> _stopBroadcast() async {
    setState(() {
      _isBusy = true;
      _statusLog = 'Stopping broadcast...';
    });
    _debugLog('DEBUG: Stopping sender broadcast...');

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
      _progress = 0.0;
      _activeDestination = null;
      _statusLog = stopError == null
          ? 'Broadcast stopped.'
          : 'Stop completed with warning: $stopError';
    });
  }

  void _onEngineEvent(UiEvent event) {
    if (!mounted) {
      return;
    }

    int? bitrateToApply;
    setState(() {
      event.when(
        log: (msg) => _statusLog = msg,
        connectionState: (state, detail) {
          _statusLog = 'Connection [$state]: $detail';
        },
        handshakeInitiated: () => _statusLog = 'Handshake initiated...',
        handshakeComplete: (sessionId, bootstrapMode) {
          _statusLog =
              'Broadcast connected. Session=$sessionId Mode=$bootstrapMode';
        },
        progress: (streamId, frameIndex, bytes, frames) {
          _progress = ((frameIndex.toInt() + 1) % 100) / 100.0;
          _statusLog =
              'Broadcast stream=$streamId frame=$frameIndex bytes=$bytes frames=$frames';
        },
        telemetry: (name, value) => _statusLog = 'Telemetry: $name=$value',
        frameDrop: (streamId, reason) {
          _statusLog = 'Frame drop on stream $streamId: $reason';
        },
        fault: (code, message) => _statusLog = 'FAULT [$code]: $message',
        bitrateChanged: (bitrateBps) {
          _currentBitrateBps = bitrateBps;
          bitrateToApply = bitrateBps;
          _statusLog =
              'Adaptive bitrate set to ${(bitrateBps / 1_000_000).toStringAsFixed(2)} Mbps';
        },
        videoFrameReceived: (data) {
          _statusLog = 'Preview frame received (${data.length} bytes).';
        },
        audioFrameReceived: (data) {
          _statusLog = 'Audio packet sent (${data.length} bytes).';
        },
        error: (msg) => _statusLog = 'ERROR: $msg',
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
    final addresses = service.addresses;
    final port = service.port;
    if (addresses == null || addresses.isEmpty || port == null) {
      return null;
    }

    final addressStrings = addresses.map((entry) => entry.address).toList();
    final host = addressStrings.firstWhere(
      (value) => value.contains('.'),
      orElse: () => addressStrings.first,
    );
    final formattedHost = host.contains(':') ? '[$host]' : host;
    return '$formattedHost:$port';
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
                  final destination = _destinationFromService(service)!;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FilledButton.tonalIcon(
                      onPressed: _isBusy || _isBroadcasting
                          ? null
                          : () => _startBroadcastTo(destination),
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
    _senderEventSubscription?.cancel();
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
              else
                _buildDiscoveryCard(context),
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
                  title: const Text('Mute Microphone'),
                  subtitle: const Text(
                    'Stop forwarding iOS microphone AAC packets to Rust.',
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
