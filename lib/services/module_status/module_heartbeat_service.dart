// lib/services/module_status/module_heartbeat_service.dart
//
// Fleet-level UDP heartbeat monitor that drives each module's online/offline
// status from the Soleux heartbeat protocol
// (doc/Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §4).
//
// This is the "implement heartbeat logic for modules" layer: it keeps a
// stateful [SoleuxHeartbeatMonitor] for the currently configured fleet,
// refreshes the target set whenever the [ModuleStore] changes (module added,
// removed or re-addressed), records `lastSeenAt` on every valid pong, and
// maps the monitor's availability (online / suspect / offline) onto the app's
// [ConnectionStatus] whenever it transitions.
//
// Lifecycle mirror of [ModuleStatusScheduler]: it is started while the app is
// in the foreground (a UDP ping is far cheaper than a TCP socket and gives
// independent reachability evidence per spec §4.5) and stopped when the app
// backgrounds, where native background workers take over instead of
// aggressive 5-second background polling.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/soleux/soleux_heartbeat.dart';
import '../../models/models.dart';
import '../module_store.dart';
import 'module_status_service.dart';

/// Owns the heartbeat monitor for the configured module fleet.
class ModuleHeartbeatService {
  static ModuleHeartbeatService? _shared;
  static ModuleHeartbeatService get shared =>
      _shared ??= ModuleHeartbeatService(store: ModuleStore.shared);

  /// Creates an isolated service for tests (backed by the same monitor).
  @visibleForTesting
  static ModuleHeartbeatService forTesting(
          {required ModuleStore store, SoleuxHeartbeatMonitor? monitor}) =>
      ModuleHeartbeatService(store: store, monitor: monitor);

  final ModuleStore store;
  final SoleuxHeartbeatMonitor _monitor;

  bool _running = false;
  Timer? _commitDebounce;

  /// Exposed for tests that want to observe the raw availability transitions.
  void Function(HeartbeatTarget, HeartbeatAvailability)? onAvailability;

  /// The monitor backing this service (read-only access for tests that want
  /// to inject targets or query last-seen).
  SoleuxHeartbeatMonitor get monitor => _monitor;

  ModuleHeartbeatService({required this.store, SoleuxHeartbeatMonitor? monitor})
      : _monitor = monitor ?? SoleuxHeartbeatMonitor() {
    _monitor.onState = _onState;
    _monitor.onPong = _onPong;
  }

  bool get running => _running;

  /// Starts monitoring the persisted fleet. Idempotent. Existing per-target
  /// state is preserved across re-starts because [SoleuxHeartbeatMonitor]
  /// keeps it keyed by module id.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    store.addListener(_onStoreChanged);
    // Keep the monitor in its running state so refreshTargets (below) is
    // allowed to schedule the fleet; targets arrive with the next refresh.
    _monitor.start(const []);
    await _refreshTargets();
  }

  /// Stops monitoring and drops every target (used when the app backgrounds).
  void stop() {
    if (!_running) return;
    _running = false;
    store.removeListener(_onStoreChanged);
    _monitor.clearTargets();
    _monitor.stop();
  }

  /// Re-runs a monitoring pass now (after a network change), without toggling
  /// the lifecycle state.
  Future<void> refresh() async {
    if (!_running) return;
    await _refreshTargets();
  }

  /// Most recent valid pong time for the module with [id], or null.
  DateTime? lastSeenFor(String moduleId) => _monitor.lastSeenAtFor(moduleId);

  /// One-shot UDP heartbeat pass over the persisted fleet, used by the native
  /// background worker. Pings every module's heartbeat port once - concurrently
  /// to respect the OS's limited background execution window - and maps each
  /// result onto the same [ConnectionStatus] used by the periodic foreground
  /// monitor, but without starting the periodic [Timer]. Returns the
  /// reachability split for callers that need it.
  ///
  /// This is what keeps offline/online status fresh (and drives background
  /// notifications) while the app is suspended, where the periodic
  /// [SoleuxHeartbeatMonitor] cannot run.
  Future<ModuleStatusResult> pollFleetOnce() async {
    await store.init();
    final modules = store.modules;
    final targets = <HeartbeatTarget>[
      for (final module in modules)
        HeartbeatTarget(
          host: module.ipAddress,
          tcpPort: module.tcpPort,
          heartbeatPort: module.effectiveHeartbeatPort,
          key: module.id,
        ),
    ];

    final client = SoleuxHeartbeat();
    final results = await Future.wait(targets.map((target) async {
      try {
        final heartbeat = await client.ping(
          target.host,
          target.tcpPort,
          heartbeatPort: target.heartbeatPort,
        );
        return (target: target, alive: heartbeat.alive);
      } catch (_) {
        return (target: target, alive: false);
      }
    }));

    final online = <DeviceModule>[];
    final offline = <DeviceModule>[];
    final byId = {for (final m in modules) m.id: m};
    for (final entry in results) {
      final module = byId[entry.target.key];
      if (module == null) continue;
      final live = store.byId(module.id) ?? module;
      if (entry.alive) {
        live.lastSeenAt = DateTime.now();
        live.status = ConnectionStatus.online;
        online.add(live);
      } else {
        live.status = ConnectionStatus.offline;
        offline.add(live);
      }
    }

    await store.commit();
    return ModuleStatusResult(online: online, offline: offline);
  }

  void _onStoreChanged() {
    if (!_running) return;
    _refreshTargets().ignore();
  }

  /// Rebuilds the target list from the store. Targets are keyed by module id,
  /// so a module that keeps its id across a re-discovery keeps its counters.
  Future<void> _refreshTargets() async {
    await store.init();
    if (!_running) return;
    final targets = <HeartbeatTarget>[
      for (final module in store.modules)
        HeartbeatTarget(
          host: module.ipAddress,
          tcpPort: module.tcpPort,
          heartbeatPort: module.effectiveHeartbeatPort,
          key: module.id,
          // Seed the monitor from the module's persisted status so an already
          // offline module stays offline while pings keep failing, and an
          // online one degrades to suspect on its first missed ping.
          initialAvailability: switch (module.status) {
            ConnectionStatus.online => HeartbeatAvailability.online,
            ConnectionStatus.suspect => HeartbeatAvailability.suspect,
            ConnectionStatus.offline => HeartbeatAvailability.offline,
          },
        ),
    ];
    if (targets.isEmpty) {
      _monitor.clearTargets();
    } else {
      _monitor.refreshTargets(targets);
    }
  }

  /// Every valid pong refreshes the module's `lastSeenAt` (spec §4.2) and
  /// re-asserts it online: a successful heartbeat is authoritative reachability
  /// evidence, so the module stays online even if another layer (e.g. a
  /// transient TCP disconnect) flipped it offline meanwhile. Persisted with a
  /// short debounce so the 5 s cadence does not hammer disk.
  void _onPong(HeartbeatTarget target, SoleuxPong pong) {
    final module = store.byId(target.key);
    if (module == null) return;
    module.lastSeenAt = DateTime.now();
    if (module.status != ConnectionStatus.online) {
      module.status = ConnectionStatus.online;
    }
    _scheduleCommit();
  }

  /// Maps the monitor's availability onto the app's [ConnectionStatus] only
  /// when the state actually changes (the monitor deduplicates identical
  /// states), keeping the UI stable across the ping interval. `suspect` is a
  /// real app status (shown as a watch-out state); `unknown` never downgrades
  /// a module that another layer (TCP Control API session) still considers
  /// healthy.
  void _onState(HeartbeatTarget target, HeartbeatAvailability state) {
    final module = store.byId(target.key);
    if (module == null) return;
    onAvailability?.call(target, state);
    switch (state) {
      case HeartbeatAvailability.online:
        module.status = ConnectionStatus.online;
        break;
      case HeartbeatAvailability.suspect:
        module.status = ConnectionStatus.suspect;
        break;
      case HeartbeatAvailability.offline:
        module.status = ConnectionStatus.offline;
        break;
      case HeartbeatAvailability.unknown:
        return;
    }
    store.commit().ignore();
  }

  /// Coalesces frequent per-pong writes into a single delayed commit.
  void _scheduleCommit() {
    _commitDebounce?.cancel();
    _commitDebounce =
        Timer(const Duration(milliseconds: 200), () => store.commit().ignore());
  }
}
