// lib/services/module_status/module_status_scheduler.dart
//
// Lifecycle-aware online/offline scheduler for the module fleet.
//
// The module addressability strategy depends on where the app is:
//
//   - Foreground (resumed): persistent TCP sockets are kept alive per module
//     (see [ModuleStatusService]) so pushed state changes and full status
//     dumps flow into the store in real time. The periodic 5008 Control API
//     check (see [ModuleApiHealthService]) also runs here and owns each
//     module's online / unknown / offline status.
//   - Background (paused/inactive/hidden/detached): keeping sockets open
//     wastes battery and the OS may suspend the app anyway, so every socket is
//     dropped and the in-app API polling is stopped; the fleet is instead
//     polled by the OS's native background worker (see
//     [BackgroundStatusWorker]: Android WorkManager / iOS BGAppRefreshTask),
//     which survives the process being suspended or killed.
//
// The scheduler simply reacts to [AppLifecycleState] changes and switches
// between the two modes - it no longer runs any in-Dart polling [Timer], so
// background status checks are exclusively driven by the native worker.
import 'package:flutter/widgets.dart';

import 'background_status_worker.dart';
import 'module_api_health_service.dart';
import 'module_keep_alive.dart';
import 'module_status_service.dart';

/// Toggles the module status strategy between persistent-socket (foreground)
/// and native-worker polling (background).
class ModuleStatusScheduler with WidgetsBindingObserver {
  final ModuleStatusService service;

  AppLifecycleState? _state;
  bool _foreground = true;

  static ModuleStatusScheduler? _shared;
  static ModuleStatusScheduler get shared =>
      _shared ??= ModuleStatusScheduler(service: ModuleStatusService.shared);

  ModuleStatusScheduler({required this.service});

  /// True while the app is in the persistent-socket (foreground) mode.
  bool get foreground => _foreground;

  /// Registers the observer and applies the current lifecycle state so the
  /// correct mode is active immediately. Idempotent.
  void start() {
    WidgetsBinding.instance.addObserver(this);
    final initial = _state ?? WidgetsBinding.instance.lifecycleState;
    if (initial != null) {
      _onLifecycleChanged(initial);
    } else {
      _enterForeground();
    }
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    debugPrint('ModuleStatusScheduler: app backgrounded ($_state) => ($state)');

    if (state == _state) return;
    _state = state;
    if (state == AppLifecycleState.resumed) {
      _enterForeground();
    } else {
      _enterBackground();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onLifecycleChanged(state);
  }

  void _enterForeground() {
    _foreground = true;
    // Ask the OS to stop handing this work to the background worker; we are
    // back to real-time sockets.
    BackgroundStatusWorker.cancel().ignore();
    // Re-open any sockets that were dropped while backgrounded and re-ask for
    // a fresh status dump. Coalesced / no-op when sockets are already live.
    service.resumeAll().ignore();
    // Begin the periodic 5008 Control API reachability check (online /
    // unknown / offline); stopped again when the app backgrounds.
    ModuleApiHealthService.shared.start().ignore();
  }

  void _enterBackground() {
    _foreground = false;
    // On Android the native foreground service (see [ModuleKeepAlive]) keeps
    // the process - and with it the persistent sockets and the UDP heartbeat
    // monitor - alive while the app is backgrounded or the screen is off. In
    // that mode the sockets must NOT be dropped and the worker must NOT take
    // over: the keep-alive *is* the continuous monitoring. Only the legacy
    // teardown path runs for non-Android builds and for Android when the
    // keep-alive service has been stopped.
    if (ModuleKeepAlive.supported && ModuleKeepAlive.shared.running.value) {
      return;
    }
    // Stop the in-app 5008 API polling: the OS may suspend the timers anyway.
    // The native worker resumes reachability polling.
    ModuleApiHealthService.shared.stop();
    // Close every persistent socket so they are not held open in the
    // background, then let the OS's native background worker poll the fleet
    // while the app is suspended.
    service.suspendAll().ignore();
    BackgroundStatusWorker.schedule().ignore();
  }

  /// Unregisters the observer. No-op when never started.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
