import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:nomikai/src/rust/api/simple.dart';
import 'package:nomikai/src/rust/frb_generated.dart';
import 'package:nomikai/src/hevc_dumper_service.dart';

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
      title: 'Nomikai',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: const TransferScreen(),
    );
  }
}

class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  String _statusLog = "Ready.";
  double _progress = 0.0;
  bool _isEngineActive = false;
  String? _selectedFilePath;
  final HevcDumperService _hevcDumperService = HevcDumperService();
  bool _isHevcRecording = false;
  String? _hevcOutputPath;

  // ---------------------------------------------------------------------------
  // SENDER LOGIC
  // ---------------------------------------------------------------------------
  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedFilePath = result.files.single.path;
        _statusLog = "Ready to send: ${result.files.single.name}";
        _progress = 0.0;
      });
    }
  }

  void _startTransfer() async {
    if (_selectedFilePath == null) return;
    setState(() {
      _isEngineActive = true;
      _progress = 0.0;
      _statusLog = "Initializing Sender Engine...";
    });

    try {
      final stream = sendFiles(
        dest: "127.0.0.1:8080",
        relayRoutes: ["127.0.0.1:8081"],
        pskHex:
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        filePaths: [_selectedFilePath!],
        redundancy: 1.2,
        maxBytesPerSec: BigInt.from(5000000),
      );

      await _listenToEngine(stream);
    } catch (e) {
      setState(() => _statusLog = "Sender Crashed: $e");
    } finally {
      setState(() => _isEngineActive = false);
    }
  }

  // ---------------------------------------------------------------------------
  // RECEIVER LOGIC
  // ---------------------------------------------------------------------------
  void _startReceiving() async {
    // 1. Pick a folder to save incoming files
    String? outDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "Select Download Folder for Nomikai",
    );

    if (outDir == null) return;

    setState(() {
      _isEngineActive = true;
      _progress = 0.0;
      _statusLog = "Listening on 0.0.0.0:8080...\nSaving to: $outDir";
    });

    try {
      final stream = recvFiles(
        bindAddr: "0.0.0.0:8080",
        outDir: outDir,
        pskHex:
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
      );

      await _listenToEngine(stream);
    } catch (e) {
      setState(() => _statusLog = "Receiver Crashed: $e");
    } finally {
      setState(() => _isEngineActive = false);
    }
  }

  // ---------------------------------------------------------------------------
  // SHARED EVENT LOOP
  // ---------------------------------------------------------------------------
  Future<void> _listenToEngine(Stream<UiEvent> stream) async {
    await for (final event in stream) {
      setState(() {
        event.when(
          log: (msg) => _statusLog = msg,
          handshakeInitiated: () => _statusLog = "Handshake Initiated...",
          handshakeComplete: () => _statusLog = "Secure Tunnel Established.",
          fileDetected: (streamId, traceId, name, size) =>
              _statusLog = "Incoming: $name",
          progress: (streamId, traceId, current, total) {
            if (total > BigInt.zero) {
              _progress = current.toDouble() / total.toDouble();
            }
            _statusLog =
                "Transferring: ${(current.toDouble() / 1024 / 1024).toStringAsFixed(2)} MB";
          },
          transferComplete: (streamId, traceId, path) {
            _progress = 1.0;
            _statusLog = "Transfer Complete! 🎉\nSaved at: $path";
          },
          earlyTermination: (streamId, traceId) {
            _statusLog = "Early Termination: Bandwidth Saved.";
          },
          fault: (code, msg) => _statusLog = "FAULT [$code]: $msg",
          metric: (name, value) => {},
          error: (msg) => _statusLog = "ERROR: $msg",
        );
      });
    }
  }

  Future<void> _toggleHevcRecording() async {
    if (_isHevcRecording) {
      await _stopHevcRecording();
      return;
    }
    await _startHevcRecording();
  }

  Future<void> _startHevcRecording() async {
    try {
      await _hevcDumperService.startRecording();
      if (!mounted) return;
      setState(() {
        _isHevcRecording = true;
        _hevcOutputPath = null;
        _statusLog = "HEVC recording started.";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusLog = "HEVC start failed: $e";
      });
    }
  }

  Future<void> _stopHevcRecording() async {
    try {
      final outputPath = await _hevcDumperService.stopRecording();
      debugPrint("HEVC dump file: $outputPath");
      if (!mounted) return;
      setState(() {
        _isHevcRecording = false;
        _hevcOutputPath = outputPath;
        _statusLog = "HEVC recording saved at:\n$outputPath";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusLog = "HEVC stop failed: $e";
      });
    }
  }

  // ---------------------------------------------------------------------------
  // UI BUILDER
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nomikai UI')),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _statusLog,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            LinearProgressIndicator(
              value: _progress,
              minHeight: 12,
              borderRadius: BorderRadius.circular(6),
            ),
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Sender Controls
                Column(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isEngineActive ? null : _pickFile,
                      icon: const Icon(Icons.attach_file),
                      label: const Text("1. Select File"),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: (_isEngineActive || _selectedFilePath == null)
                          ? null
                          : _startTransfer,
                      icon: const Icon(Icons.send),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                      ),
                      label: const Text("2. Send File"),
                    ),
                  ],
                ),

                // Divider
                Container(height: 80, width: 1, color: Colors.grey.shade300),

                // Receiver Controls
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isEngineActive ? null : _startReceiving,
                      icon: const Icon(Icons.downloading),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.tertiaryContainer,
                        padding: const EdgeInsets.all(24.0),
                      ),
                      label: const Text("Listen for Files"),
                    ),
                  ],
                ),

                // Divider
                Container(height: 80, width: 1, color: Colors.grey.shade300),

                // HEVC Capture Controls
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: !_hevcDumperService.isSupported
                          ? null
                          : _toggleHevcRecording,
                      icon: Icon(
                        _isHevcRecording ? Icons.stop : Icons.videocam,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isHevcRecording
                            ? Colors.red.shade300
                            : Theme.of(context).colorScheme.secondaryContainer,
                        padding: const EdgeInsets.all(24.0),
                      ),
                      label: Text(
                        _isHevcRecording
                            ? "Stop HEVC Capture"
                            : "Start HEVC Capture",
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _hevcOutputPath == null
                          ? "No .h265 file saved yet"
                          : "Last HEVC file:\n$_hevcOutputPath",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
