// lib/services/module_status/module_heartbeat_service.dart
//
// App-side driver for the Soleux UDP heartbeat on **local** devices
// (lib/core/soleux/soleux_heartbeat.dart, doc/
// Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §4).
//
// Role split with the other monitors (deliberately narrow):
//
//   - Online/offline stays owned by the 5008 Control API check
//     ([ModuleApiHealthService]); the heartbeat availability stream is NOT
//     wired into [ConnectionStatus] (a pong proves recent UDP reachability,
//     not a working Control API).
//   - Every valid pong refreshes the module's **additive identity fields**:
//     `last_seen_at` (its documented semantic is "last heartbeat pong"), the
//     advertised `api_port` / `api_version`, and - the reason this service
//     exists - the `API_TLS` advisory (doc/
//     Soleux_Mobile_Control_API_TLS_Integration.md). A TLS-flag flip takes
//     effect on the next 5008 dial: the transient health-check socket is
//     rebuilt per cycle and the persistent unit is replaced on the next
//     refresh ([ModuleStatusService._ensureJsonUnit] compares the TLS
//     options).
//   - `device_id` (the TLS certificate's DNS SAN) is only **filled when the
//     module has none saved**: the pong is unauthenticated, and an attacker
//     on the LAN must not be able to rebind a saved device's TLS identity -
//     a wrong ID fails the handshake closed, never a credential leak.
//   - User-owned fields (name, tcpPort, channels, ...) are never touched by
//     a pong.
//
// Local devices only: a module is heartbeat-eligible when it is not
// explicitly remote/cloud (`connectionType`) and its entered address is a
// literal IP (UDP unicast to a known LAN host).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/soleux/soleux_heartbeat.dart';
import '../../models/models.dart';
import '../module_host_resolver.dart';
import '../module_store.dart';

/// Periodic UDP heartbeat for the local part of the fleet.
class ModuleHeartbeatService {
  final SoleuxHeartbeatMonitor _monitor;

  ModuleHeartbeatService._({SoleuxHeartbeatMonitor? monitor})
      : _monitor = monitor ?? SoleuxHeartbeatMonitor();

  /// App-wide shared instance, started/stopped by the lifecycle scheduler.
  static ModuleHeartbeatService shared = ModuleHeartbeatService._();

  /// Isolated instance for tests (an injected [monitor] allows a short ping
  /// cadence).
  @visibleForTesting
  static ModuleHeartbeatService forTesting({
    required ModuleStore store,
    SoleuxHeartbeatMonitor? monitor,
  }) =>
      ModuleHeartbeatService._(monitor: monitor).._store = store;

  ModuleStore _store = ModuleStore.shared;
  ModuleStore get store => _store;

  bool _listenerAttached = false;
  Timer? _commitDebounce;

  /// Whether the heartbeat is currently pinging the local fleet.
  bool get running => _monitor.running;

  /// Starts pinging every local module every 30 s and keeps the target set
  /// in sync with the store (added/edited/removed modules). Idempotent.
  void start() {
    if (!_listenerAttached) {
      _listenerAttached = true;
      _store.addListener(_refreshTargets);
    }
    _monitor
      ..onPong = _onPong
      ..startTargets(buildTargets());
  }

  /// Stops the pings and detaches the store listener. Target state is kept
  /// for a later restart.
  void stop() {
    if (_listenerAttached) {
      _listenerAttached = false;
      _store.removeListener(_refreshTargets);
    }
    _commitDebounce?.cancel();
    _commitDebounce = null;
    _monitor.stop();
    _monitor.clearTargets();
  }

  /// Rebuilds the target set from the current fleet (also fired on store
  /// changes while running).
  void _refreshTargets() {
    if (!_monitor.running) return;
    _monitor.refreshTargets(buildTargets());
  }

  /// One [HeartbeatTarget] per local module, keyed by module id so per-target
  /// monitor state survives fleet refreshes. The availability is seeded from
  /// the persisted status so an offline module never bounces through suspect.
  @visibleForTesting
  List<HeartbeatTarget> buildTargets() {
    return [
      for (final module in _store.modules)
        if (isLocalHeartbeatDevice(module))
          HeartbeatTarget(
            host: module.host,
            tcpPort: module.tcpPort,
            heartbeatPort: module.effectiveHeartbeatPort,
            key: module.id,
            initialAvailability: switch (module.status) {
              ConnectionStatus.online => HeartbeatAvailability.online,
              ConnectionStatus.offline => HeartbeatAvailability.offline,
              ConnectionStatus.unknown => null,
            },
          ),
    ];
  }

  /// Whether [module] participates in the LAN heartbeat: anything not
  /// explicitly remote/cloud whose entered address is a literal IP (a
  /// hostname-addressed module is remote mode - UDP unicast needs a LAN
  /// host).
  @visibleForTesting
  static bool isLocalHeartbeatDevice(DeviceModule module) {
    final type = module.connectionType;
    if (type == 'remote' || type == 'cloud') return false;
    return isLiteralIpAddress(module.ipAddress);
  }

  /// Applies one valid pong to its module (additive identity refresh - see
  /// the file header for the ownership rules). Exposed for tests.
  @visibleForTesting
  void applyPong(DeviceModule module, SoleuxPong pong) {
    var changed = false;

    // `last_seen_at` semantics: last answered heartbeat pong.
    module.lastSeenAt = DateTime.now();
    changed = true;

    // The TLS advisory is the heartbeat's job: apply every advertised value
    // (the module's flag may have changed through the Hub's Security page or
    // a certificate renewal). Unauthenticated, but fail-safe: a spoofed
    // `api_tls:1` only makes the 5008 dial fail the handshake closed.
    if (pong.apiTls != null && module.apiTls != pong.apiTls) {
      debugPrint('ModuleHeartbeat: ${module.name} (${module.id}) API_TLS -> '
          '${pong.apiTls! ? 1 : 0}');
      module.apiTls = pong.apiTls;
      changed = true;
    }

    // Additive endpoint/identity fields: advertised values win over stale
    // ones; the device ID is only filled on first use (never rebind a saved
    // TLS identity from an unauthenticated datagram).
    if (pong.apiPort != null && module.apiPort != pong.apiPort) {
      module.apiPort = pong.apiPort;
      changed = true;
    }
    if (pong.apiVersion != null && module.apiVersion != pong.apiVersion) {
      module.apiVersion = pong.apiVersion;
      changed = true;
    }
    final pongDeviceId = pong.deviceId;
    if (pongDeviceId != null &&
        pongDeviceId.isNotEmpty &&
        (module.deviceId == null || module.deviceId!.isEmpty)) {
      debugPrint('ModuleHeartbeat: ${module.name} (${module.id}) device id '
          'filled from pong: $pongDeviceId');
      module.deviceId = pongDeviceId;
      changed = true;
    }

    if (changed) _scheduleCommit();
  }

  void _onPong(HeartbeatTarget target, SoleuxPong pong) {
    final module = _store.byId(target.stabilizationKey);
    if (module == null) return;
    applyPong(module, pong);
  }

  /// Coalesces pong-driven store writes (one commit per 150 ms window, the
  /// same debounce the status service uses) instead of persisting on every
  /// 30 s ping.
  void _scheduleCommit() {
    _commitDebounce?.cancel();
    _commitDebounce = Timer(const Duration(milliseconds: 150), () {
      _store.commit().ignore();
    });
  }
}
