// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

class NomikaiDiscoveryService {
  NomikaiDiscoveryService({void Function(String message)? logger})
    : _logger = logger;

  static const String serviceType = '_nomikai._udp';
  static const String _serviceNamePrefix = 'Nomikai Receiver';

  final ValueNotifier<List<nsd.Service>> discoveredServices =
      ValueNotifier<List<nsd.Service>>(const <nsd.Service>[]);
  final void Function(String message)? _logger;

  nsd.Discovery? _discovery;
  nsd.Registration? _registration;
  final Map<String, nsd.Service> _serviceByKey = <String, nsd.Service>{};
  bool _isDisposed = false;

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  void _log(String message) {
    print(message);
    _logger?.call(message);
  }

  Future<void> startBroadcasting(int port) async {
    if (!isSupported || _isDisposed) {
      return;
    }

    _log('DEBUG: Starting mDNS Broadcast registration on port $port...');
    await stopBroadcasting();
    final service = nsd.Service(
      name: '$_serviceNamePrefix $port',
      type: serviceType,
      port: port,
    );
    try {
      _registration = await nsd.register(service);
      _log('DEBUG: mDNS Broadcast successfully registered on port $port');
    } catch (error) {
      _log('DEBUG: mDNS Broadcast registration failed on port $port: $error');
    }
  }

  Future<void> stopBroadcasting() async {
    final registration = _registration;
    _registration = null;
    if (registration == null) {
      return;
    }
    await nsd.unregister(registration);
  }

  Future<void> startScanning() async {
    if (!isSupported || _discovery != null || _isDisposed) {
      return;
    }

    _log('DEBUG: Starting mDNS scan for type $serviceType...');
    _serviceByKey.clear();
    _publish();

    try {
      final discovery = await nsd.startDiscovery(
        serviceType,
        autoResolve: true,
        ipLookupType: nsd.IpLookupType.any,
      );
      _discovery = discovery;
      discovery.addServiceListener(_onServiceChanged);
      _log('DEBUG: mDNS scanner running for type $serviceType');

      for (final service in discovery.services) {
        await _registerFoundService(service);
      }
    } catch (error) {
      _log('DEBUG: mDNS scanner failed to start: $error');
      rethrow;
    }
  }

  Future<void> stopScanning({bool clear = true}) async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      discovery.removeServiceListener(_onServiceChanged);
      await nsd.stopDiscovery(discovery);
    }

    if (clear) {
      _serviceByKey.clear();
      _publish();
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await stopScanning(clear: true);
    await stopBroadcasting();
    discoveredServices.dispose();
  }

  Future<void> _onServiceChanged(
    nsd.Service service,
    nsd.ServiceStatus status,
  ) async {
    if (_isDisposed) {
      return;
    }

    if (status == nsd.ServiceStatus.lost) {
      _serviceByKey.remove(_serviceKey(service));
      _publish();
      return;
    }

    await _registerFoundService(service);
  }

  Future<void> _registerFoundService(nsd.Service service) async {
    final resolved = await _resolveService(service);
    final hasAddress =
        resolved.addresses != null && resolved.addresses!.isNotEmpty;
    if (resolved.port == null || !hasAddress) {
      return;
    }

    _serviceByKey[_serviceKey(resolved)] = resolved;
    _log(
      'DEBUG: Discovered new mDNS service: ${resolved.name ?? 'unknown'} at ${resolved.host ?? 'unknown-host'}:${resolved.port}',
    );
    _publish();
  }

  Future<nsd.Service> _resolveService(nsd.Service service) async {
    if (service.port != null &&
        service.addresses != null &&
        service.addresses!.isNotEmpty) {
      return service;
    }

    try {
      return await nsd.resolve(service);
    } catch (_) {
      return service;
    }
  }

  String _serviceKey(nsd.Service service) {
    return '${service.name ?? ''}|${service.type ?? ''}|${service.host ?? ''}|${service.port ?? 0}';
  }

  void _publish() {
    if (_isDisposed) {
      return;
    }

    final services = _serviceByKey.values.toList()
      ..sort((left, right) {
        final leftName = left.name ?? '';
        final rightName = right.name ?? '';
        return leftName.compareTo(rightName);
      });
    discoveredServices.value = List<nsd.Service>.unmodifiable(services);
  }
}
