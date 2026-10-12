// lib/services/notification_monitor.dart
//
// Watches the app-wide [ModuleStore] and turns real state changes into local
// notifications (through [LocalNotificationService]), gated by the
// notification preferences in Settings -> Notifications:
//
//   1. Module online/offline transitions - fires when a module's persisted
//      connection status changes (transitions are settled for a short window
//      so short-lived flapping during a status refresh does not spam alerts,
//      and never fires for the baseline state on launch).
//   2. Temperature threshold - fires once when a module leaves its
//      [DeviceModule.tempMinC..tempMaxC] range and again when it re-enters
//      it (each over-threshold episode produces one alert).
//   3. Output left ON too long - tracks when each output turned ON and fires
//      after the threshold configured in Settings -> Notifications (default
//      12 hours); turning the output OFF resets the timer.
//
// An instance runs in every isolate that touches module state (the app
// foreground isolate via main() and the background status worker isolate),
// so alerts surface both while the app is open and while it is suspended.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'module_store.dart';
import 'notification_service.dart';
import 'settings_store.dart';
import 'status_log_store.dart';

/// Observes [ModuleStore.shared] and emits local notifications for status,
/// temperature and output-duration events.
class NotificationMonitor {
  NotificationMonitor._({
    ModuleStore? store,
    this.settleDuration = NotificationMonitor.settleDurationDefault,
    Duration? outputThreshold,
    StatusLogStore? statusLog,
  })  : store = store ?? ModuleStore.shared,
        _outputThresholdOverride = outputThreshold,
        _statusLog = statusLog ?? StatusLogStore.shared;

  /// App-wide shared instance used by the launch path and the background
  /// worker. Each isolate gets its own instance.
  static NotificationMonitor shared = NotificationMonitor._();

  /// Creates an isolated monitor bound to an explicit store for tests.
  @visibleForTesting
  static NotificationMonitor forTesting(
    ModuleStore store, {
    Duration? settleDuration,
    Duration? outputThreshold,
    StatusLogStore? statusLog,
  }) =>
      NotificationMonitor._(
        store: store,
        settleDuration: settleDuration ?? settleDurationDefault,
        outputThreshold: outputThreshold,
        statusLog: statusLog,
      );

  /// How long a status change must hold before it is notified, so a quick
  /// offline->online flap during a refresh is not reported as an outage.
  static const Duration settleDurationDefault = Duration(seconds: 2);

  /// How often the output-duration check runs even when no state changed.
  static const Duration outputCheckPeriod = Duration(minutes: 1);

  /// Fallback threshold used when no [SettingsStore] override is available
  /// (tests without a configured store).
  static const Duration defaultOutputThreshold = Duration(hours: 12);

  /// How long a status change hold is required before notifying (tests can
  /// shorten it).
  final Duration settleDuration;

  /// Optional explicit override of the output threshold (used by tests).
  /// When null the monitor reads the live value from [SettingsStore].
  final Duration? _outputThresholdOverride;

  /// Active output-left-ON threshold the monitor evaluates against.
  Duration get outputThreshold {
    final override = _outputThresholdOverride;
    if (override != null) return override;
    final hours = SettingsStore.shared.outputOnThresholdHours;
    return Duration(hours: hours);
  }

  final ModuleStore store;

  /// Where confirmed status / firmware events are recorded (the Notification
  /// History persistence layer).
  final StatusLogStore _statusLog;

  bool _started = false;
  bool _seeded = false;

  /// Last observed connection status per module id (baseline / seed state).
  final Map<String, ConnectionStatus> _lastStatus = {};

  /// Last observed firmware version per module id (for FIRMWARE history
  /// entries). Keys are seeded together with the status baseline.
  final Map<String, String?> _lastFirmware = {};

  /// Whether the module's temperature was out of range in the last pass.
  final Map<String, bool> _lastOverTemp = {};

  /// Status transitions waiting to be confirmed settled.
  final Map<String, ConnectionStatus> _pending = {};

  /// Timestamp each output was switched ON (moduleId:channelId -> time).
  final Map<String, DateTime> _outputOnSince = {};

  /// Outputs already reported as left-ON, so each episode alerts once.
  final Set<String> _outputNotified = {};

  Timer? _settleTimer;
  Timer? _outputTimer;

  /// Number of notifications raised while monitoring (useful for tests).
  int notificationCount = 0;

  /// True once [start] has been called.
  bool get started => _started;

  /// Registers the store listener and starts the periodic output check.
  /// Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    store.addListener(_onStoreChanged);
    _outputTimer = Timer.periodic(outputCheckPeriod, (_) => _evaluateOutputs());
  }

  /// Cancels timers and detaches from the store. No-op when never started.
  void dispose() {
    if (!_started) return;
    _started = false;
    store.removeListener(_onStoreChanged);
    _settleTimer?.cancel();
    _settleTimer = null;
    _outputTimer?.cancel();
    _outputTimer = null;
  }

  void _onStoreChanged() {
    if (!_seeded) {
      _seed();
      return;
    }
    final modules = store.modules;
    _detectStatusTransitions(modules);
    _evaluateTemperature(modules);
    _evaluateOutputs();
    _detectFirmwareChanges(modules);
  }

  /// Records the current state as the baseline without notifying - this is
  /// what stops launch-time refreshes from being reported as events.
  void _seed() {
    for (final module in store.modules) {
      _lastStatus[module.id] = module.status;
      _lastOverTemp[module.id] = module.isOverTemperature;
      _lastFirmware[module.id] = module.firmware;
    }
    _evaluateOutputs();
    _seeded = true;
  }

  void _detectStatusTransitions(List<DeviceModule> modules) {
    final ids = <String>{for (final m in modules) m.id};

    // Drop state for modules that were removed.
    _lastStatus.removeWhere((id, _) => !ids.contains(id));
    _lastFirmware.removeWhere((id, _) => !ids.contains(id));

    for (final module in modules) {
      final baseline = _lastStatus[module.id];
      if (baseline == null) continue;
      if (module.status != baseline) {
        // A transition away from the confirmed baseline.
        _pending[module.id] = module.status;
      } else {
        // Same as baseline -> any previously pending transition reverted.
        _pending.remove(module.id);
      }
    }
    _pending.removeWhere((id, _) => !ids.contains(id));

    if (_pending.isNotEmpty) {
      _armSettleTimer();
    }
  }

  void _armSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = Timer(settleDuration, _confirmSettledTransitions);
  }

  /// Fires notifications for transitions that are still true after the
  /// settle window; flapped (now reverted) transitions are discarded.
  void _confirmSettledTransitions() {
    _settleTimer = null;
    final confirmed = Map<String, ConnectionStatus>.of(_pending);
    _pending.clear();
    for (final entry in confirmed.entries) {
      final module = store.byId(entry.key);
      final current = module?.status;
      if (module == null || current == null) {
        _lastStatus.remove(entry.key);
        continue;
      }
      if (current != entry.value) {
        // The transition reverted before settling; just refresh the baseline.
        _lastStatus[entry.key] = current;
        continue;
      }
      // `old` is the pre-transition baseline. Only genuine online<->offline
      // crossings raise a status notification; `unknown` is an intermediate
      // watch state (the module was online but its 5008 API is not answering)
      // that updates the baseline silently so a module does not ping-pong
      // "offline"/"online" alerts while it is merely unknown.
      final old = _lastStatus[entry.key]!;
      _lastStatus[entry.key] = current;
      final wentOffline = current == ConnectionStatus.offline &&
          old != ConnectionStatus.offline;
      final backOnline =
          current == ConnectionStatus.online && old != ConnectionStatus.online;
      if (!wentOffline && !backOnline) continue;
      notificationCount++;
      // Record the real event in the Notification History, then surface the
      // OS notification (gated by the notification preference).
      if (wentOffline) {
        _statusLog.recordOffline(module.name).ignore();
      } else {
        _statusLog.recordRestored(module.name).ignore();
      }
      LocalNotificationService.shared
          .showModuleStatusChanged(module, current == ConnectionStatus.online)
          .ignore();
    }
  }

  /// Compares each module's reported firmware against the last observed
  /// version and raises a `FIRMWARE` history entry (plus the gated
  /// notification) whenever it changes. The first time a version is seen an
  /// "Firmware version reported" entry is written; later updates write a
  /// "Firmware changed from A to B" entry.
  void _detectFirmwareChanges(List<DeviceModule> modules) {
    for (final module in modules) {
      final version = module.firmware;
      if (version == null || version.isEmpty) continue;
      final previous = _lastFirmware[module.id];
      if (version == previous) continue;
      _lastFirmware[module.id] = version;
      if (previous == null || previous.isEmpty) {
        _statusLog.recordFirmwareReported(module.name, version).ignore();
        LocalNotificationService.shared
            .showFirmwareReported(module, version)
            .ignore();
      } else {
        _statusLog
            .recordFirmwareChanged(module.name, previous, version)
            .ignore();
        LocalNotificationService.shared
            .showFirmwareChanged(module, previous, version)
            .ignore();
      }
    }
  }

  /// Notifies once when a module's temperature leaves its configured range
  /// and again when it comes back inside it.
  void _evaluateTemperature(List<DeviceModule> modules) {
    for (final module in modules) {
      final over = module.isOverTemperature;
      final prev = _lastOverTemp[module.id];
      if (prev == null) {
        _lastOverTemp[module.id] = over;
        continue;
      }
      if (over == prev) continue;
      _lastOverTemp[module.id] = over;
      if (!over) continue; // returning inside range: nothing to alert.
      if (_lastStatus[module.id] != ConnectionStatus.online) {
        // Only report temperature for reachable modules.
        continue;
      }
      notificationCount++;
      LocalNotificationService.shared.showTemperatureAlert(module).ignore();
    }
  }

  /// Tracks when outputs turned ON and alerts after they remained ON longer
  /// than the configured threshold (Settings -> Notifications -> Output On
  /// Threshold Duration, default 12 hours).
  void _evaluateOutputs() {
    final threshold = outputThreshold;
    for (final module in store.modules) {
      if (module.status != ConnectionStatus.online) {
        // Do not chase outputs of modules that are offline.
        continue;
      }
      for (final channel in module.channels) {
        final key = '${module.id}:${channel.id}';
        final on = channel.isOn || channel.brightness > 0;
        if (!on) {
          _outputOnSince.remove(key);
          _outputNotified.remove(key);
          continue;
        }
        final since = _outputOnSince.putIfAbsent(key, DateTime.now);
        if (_outputNotified.contains(key)) continue;
        if (DateTime.now().difference(since) >= threshold) {
          _outputNotified.add(key);
          notificationCount++;
          LocalNotificationService.shared
              .showOutputLeftOn(module, channel, duration: threshold)
              .ignore();
        }
      }
    }
  }
}
