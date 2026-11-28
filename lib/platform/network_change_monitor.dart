//
//  network_change_monitor.dart
//
//  Re-asserts TDLib's network type when the device's interfaces change.
//
//  TDLib retries a failed connection by itself, but a socket orphaned by a
//  network change — Wi-Fi dropping for mobile data, a VPN going down, a new
//  default route — can sit in its retry backoff for a long time, and the
//  client then reads as "never reconnects" until the app is restarted.
//  `setNetworkType` is the lever that makes TDLib close what it holds and dial
//  again, so this monitor watches the address set and nudges it on every
//  change, and again when a connection has been dialling for too long on a
//  device that does have an address.
//

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../tdlib/td_client.dart';

class NetworkChangeMonitor with WidgetsBindingObserver {
  NetworkChangeMonitor({
    Future<String?> Function()? readInterfaces,
    void Function()? refreshNetwork,
    String? Function()? connectionState,
    DateTime Function()? clock,
    this.pollInterval = const Duration(seconds: 4),
    this.stalledAfter = const Duration(seconds: 20),
  }) : _readInterfaces = readInterfaces ?? _deviceInterfaceSignature,
       _refreshNetwork = refreshNetwork ?? TdClient.shared.refreshNetwork,
       _connectionState =
           connectionState ?? (() => TdClient.shared.activeConnectionState),
       _now = clock ?? DateTime.now;

  static final NetworkChangeMonitor shared = NetworkChangeMonitor();

  /// How often the interface set is sampled. A Wi-Fi or VPN hand-off takes a
  /// few seconds, so a shorter sample only spends syscalls.
  final Duration pollInterval;

  /// How long a dialling/waiting connection may sit before it is redialled.
  final Duration stalledAfter;

  final Future<String?> Function() _readInterfaces;
  final void Function() _refreshNetwork;
  final String? Function() _connectionState;
  final DateTime Function() _now;

  Timer? _timer;
  String? _signature;
  DateTime? _diallingSince;
  DateTime? _lastRefreshAt;
  bool _started = false;

  bool get isRunning => _started;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(poll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Interface changes that happened while the app was paused are only
    // visible now; a background timer can also have been throttled.
    if (state == AppLifecycleState.resumed) unawaited(poll());
  }

  /// Samples the interface set once, then re-dials on a change or a stall.
  @visibleForTesting
  Future<void> poll() async {
    final signature = await _readInterfaces();
    if (signature == null) return;
    final previous = _signature;
    _signature = signature;
    if (previous != null && signature != previous) {
      debugPrint('network change: $previous -> $signature');
      _redial();
      return;
    }
    _checkStalledDialling(signature.isNotEmpty);
  }

  void _checkStalledDialling(bool hasAddress) {
    final state = _connectionState();
    final dialling =
        state == 'connectionStateConnecting' ||
        state == 'connectionStateWaitingForNetwork';
    if (!dialling || !hasAddress) {
      _diallingSince = null;
      return;
    }
    final now = _now();
    _diallingSince ??= now;
    if (now.difference(_diallingSince!) < stalledAfter) return;
    final last = _lastRefreshAt;
    if (last != null && now.difference(last) < stalledAfter) return;
    debugPrint('network change: connection stalled in $state, redialling');
    _redial();
  }

  void _redial() {
    _diallingSince = null;
    _lastRefreshAt = _now();
    _refreshNetwork();
  }

  /// Every non-loopback address the device currently holds, sorted so the
  /// same set always signs the same string. An empty device (airplane mode,
  /// no route) signs an empty string.
  static Future<String?> _deviceInterfaceSignature() async {
    try {
      final interfaces = await NetworkInterface.list();
      final parts = <String>[
        for (final interface in interfaces)
          for (final address in interface.addresses)
            '${interface.name}|${address.address}',
      ]..sort();
      return parts.join(',');
    } catch (_) {
      return null;
    }
  }
}
