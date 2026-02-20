import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nomikai/src/hevc_dumper_service.dart';
import 'package:nomikai/src/rust/api/simple.dart';
import 'package:nomikai/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const NomikaiApp());
}

class NomikaiApp extends StatelessWidget {
  const NomikaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nomikai',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: const BroadcastScreen(),
    );
  }
}

class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  static const String _defaultPskHex =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

  final HevcDumperService _hevcService = HevcDumperService();
  final TextEditingController _destinationController = TextEditingController(
    text: '127.0.0.1:8080',
  );

  StreamSubscription<UiEvent>? _senderEventSubscription;

  bool _isBroadcasting = false;
  bool _isBusy = false;
  double _progress = 0.0;
  String _statusLog = 'Ready.';

  Future<Uint8List> _loadCompressionGraph() async {
    final ByteData graphData = await rootBundle.load('assets/sao_graph.bin');
    return graphData.buffer.asUint8List(
      graphData.offsetInBytes,
      graphData.lengthInBytes,
    );
  }

  Future<void> _toggleBroadcast() async {
    if (_isBusy) return;
    if (_isBroadcasting) {
      await _stopBroadcast();
      return;
    }
    await _startBroadcast();
  }

  Future<void> _startBroadcast() async {
    final destination = _destinationController.text.trim();
    if (destination.isEmpty) {
      setState(() {
        _statusLog = 'Destination address is required.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _progress = 0.0;
      _statusLog = 'Starting broadcast to $destination...';
    });

    try {
      final graphBytes = await _loadCompressionGraph();
      final senderEvents = startSankakuSender(
        dest: destination,
        pskHex: _defaultPskHex,
        graphBytes: graphBytes,
      );

      await _senderEventSubscription?.cancel();
      _senderEventSubscription = senderEvents.listen(
        _onEngineEvent,
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _statusLog = 'Sender stream error: $error';
          });
        },
      );

      await _hevcService.startRecording();

      if (!mounted) return;
      setState(() {
        _isBroadcasting = true;
        _statusLog = 'Broadcast live to $destination.';
      });
    } catch (error) {
      await _senderEventSubscription?.cancel();
      _senderEventSubscription = null;

      if (!mounted) return;
      setState(() {
        _isBroadcasting = false;
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

    Object? stopError;

    try {
      await _hevcService.stopRecording();
    } catch (error) {
      stopError = error;
    }

    try {
      await stopSankakuSender();
    } catch (error) {
      stopError ??= error;
    }

    await _senderEventSubscription?.cancel();
    _senderEventSubscription = null;

    if (!mounted) return;
    setState(() {
      _isBusy = false;
      _isBroadcasting = false;
      _progress = 0.0;
      _statusLog = stopError == null
          ? 'Broadcast stopped.'
          : 'Stop completed with warning: $stopError';
    });
  }

  void _onEngineEvent(UiEvent event) {
    if (!mounted) return;

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
        videoFrameReceived: (data) {
          _statusLog = 'Preview frame received (${data.length} bytes).';
        },
        error: (msg) => _statusLog = 'ERROR: $msg',
      );
    });
  }

  @override
  void dispose() {
    _senderEventSubscription?.cancel();
    _destinationController.dispose();
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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Destination',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _destinationController,
                        enabled: !_isBusy && !_isBroadcasting,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Destination address',
                          hintText: '127.0.0.1:8080',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _isBusy ? null : _toggleBroadcast,
                        icon: Icon(
                          _isBroadcasting ? Icons.stop_circle : Icons.videocam,
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isBroadcasting
                              ? Colors.red.shade300
                              : Theme.of(context).colorScheme.primaryContainer,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        label: Text(
                          _isBroadcasting ? 'Stop Broadcast' : 'Broadcast Live',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                borderRadius: BorderRadius.circular(6),
              ),
              const SizedBox(height: 12),
              Text(
                _statusLog,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
