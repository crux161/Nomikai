import 'package:flutter/material.dart';
import 'package:nomikai/src/telemetry_state.dart';

class NetworkDebugOverlay extends StatelessWidget {
  const NetworkDebugOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 44,
      left: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ValueListenableBuilder<NetworkStats>(
            valueListenable: networkStatsNotifier,
            builder: (context, stats, child) {
              final mbps = (stats.bitrateBps / 1_000_000).toStringAsFixed(2);
              final lossPercent = (stats.packetLossPpm / 10_000)
                  .toStringAsFixed(2);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'QUIC / Sankaku RT',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'RTT: ${stats.rttMs} ms',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Text(
                    'Bitrate: $mbps Mbps',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Text(
                    'Loss: $lossPercent%',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Text(
                    'Dropped (QUIC): ${stats.packetsDropped}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
