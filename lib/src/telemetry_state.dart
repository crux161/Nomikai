import 'package:flutter/foundation.dart';

@immutable
class NetworkStats {
  const NetworkStats({
    this.rttMs = 0,
    this.packetLossPpm = 0,
    this.bitrateBps = 0,
    this.packetsDropped = 0,
  });

  final int rttMs;
  final int packetLossPpm;
  final int bitrateBps;
  final int packetsDropped;

  NetworkStats copyWith({
    int? rttMs,
    int? packetLossPpm,
    int? bitrateBps,
    int? packetsDropped,
  }) {
    return NetworkStats(
      rttMs: rttMs ?? this.rttMs,
      packetLossPpm: packetLossPpm ?? this.packetLossPpm,
      bitrateBps: bitrateBps ?? this.bitrateBps,
      packetsDropped: packetsDropped ?? this.packetsDropped,
    );
  }
}

final ValueNotifier<NetworkStats> networkStatsNotifier =
    ValueNotifier<NetworkStats>(const NetworkStats());

void resetNetworkStats() {
  networkStatsNotifier.value = const NetworkStats();
}

void updateNetworkStatsFromTelemetry({
  required String name,
  required int value,
}) {
  final stats = networkStatsNotifier.value;
  switch (name) {
    case 'path.rtt':
    case 'path.rtt_ms':
    case 'rtt_ms':
      networkStatsNotifier.value = stats.copyWith(rttMs: value);
      return;
    case 'packet_loss_ppm':
      networkStatsNotifier.value = stats.copyWith(packetLossPpm: value);
      return;
    case 'udp_tx.dropped':
      networkStatsNotifier.value = stats.copyWith(packetsDropped: value);
      return;
    default:
      return;
  }
}

void updateNetworkBitrate(int bitrateBps) {
  networkStatsNotifier.value = networkStatsNotifier.value.copyWith(
    bitrateBps: bitrateBps,
  );
}
