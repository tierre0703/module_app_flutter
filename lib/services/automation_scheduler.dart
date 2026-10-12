// lib/services/automation_scheduler.dart
//
// Runtime that turns the persisted IF...THEN... automation rules (brief
// section 2.4) into real, scheduled behaviour:
//
//   - Time-of-day rules arm a single-shot [Timer] for the next occurrence of
//     their scheduled HH:MM and re-arm for the following day after firing.
//   - Device-state rules watch [ModuleStore] for a watched output changing
//     state and fire exactly once on the edge transition matching the rule
//     (ON→fires for "turns ON", OFF→fires for "turns OFF"). The state observed
//     at launch/arm time is treated as a baseline so a rule never fires for a
//     condition that already existed.
//
// Every firing runs the automation's actions through [ScenarioRunner] (the
// same execution path used by tap-to-run scenarios) and records both the
// trigger and each action's outcome in the 30-day [EventLogStore], which also
// raises a local notification when the "Automation triggered" preference is
// enabled (NotificationSettingsScreen).
//
// The scheduler reacts to the [AutomationStore] too: enabling/disabling,
// editing or deleting a rule re-arms/releases its timers and watch baselines
// automatically.
//
// The watched module/output/input is resolved by *index* (fleet position +
// channel/input position), with the saved names kept only as a legacy
// fallback, so renaming a device never breaks a rule.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import 'automation_store.dart';
import 'event_log_store.dart';
import 'module_store.dart';
import 'scenario_runner.dart';

/// A single armed daily time rule for one automation.
class _TimeRule {
  _TimeRule({
    required this.hour,
    required this.minute,
    required this.timer,
  });

  final int hour;
  final int minute;
  final Timer timer;
}

/// Evaluates enabled automation rules and fires them on their triggers.
class AutomationScheduler {
  AutomationScheduler._({
    AutomationStore? automationStore,
    ModuleStore? moduleStore,
    EventLogStore? eventLogStore,
    DateTime Function()? now,
  })  : automationStore = automationStore ?? AutomationStore.shared,
        moduleStore = moduleStore ?? ModuleStore.shared,
        eventLogStore = eventLogStore ?? EventLogStore.shared,
        _now = now ?? DateTime.now;

  /// App-wide shared instance started from the launch path (lib/main.dart).
  static AutomationScheduler shared = AutomationScheduler._();

  /// Creates an isolated scheduler bound to explicit stores for tests.
  @visibleForTesting
  static AutomationScheduler forTesting({
    AutomationStore? automationStore,
    ModuleStore? moduleStore,
    EventLogStore? eventLogStore,
    DateTime Function()? now,
  }) =>
      AutomationScheduler._(
        automationStore: automationStore,
        moduleStore: moduleStore,
        eventLogStore: eventLogStore,
        now: now,
      );

  final AutomationStore automationStore;
  final ModuleStore moduleStore;
  final EventLogStore eventLogStore;
  final DateTime Function() _now;

  bool _started = false;

  /// Armed daily timers, keyed by automation id.
  final Map<String, _TimeRule> _timeRules = {};

  /// Last observed on-state of the watched output per automation id (used for
  /// edge detection of device-state rules).
  final Map<String, bool> _lastWatchState = {};

  /// Identity of the watched target ("<channel>:<watchState>") per automation
  /// id; when it changes the baseline is re-seeded.
  final Map<String, String> _watchSignature = {};

  /// Number of rules that have fired while this instance runs (tests rely on
  /// it; kept public for diagnostics).
  int firedCount = 0;

  /// True once [start] has been called.
  bool get started => _started;

  /// Registers the store listeners, establishes the device-state baselines and
  /// arms every enabled rule. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    automationStore.addListener(_onAutomationsChanged);
    moduleStore.addListener(_onModulesChanged);
    // Seed baselines so arming never fires a rule for a state that already
    // holds. Store loads are async, so reconcile also runs again when the
    // automation store finishes loading and notifies.
    _onModulesChanged();
    reconcile();
  }

  /// Detaches listeners and cancels every armed timer. No-op when never
  /// started.
  void dispose() {
    if (!_started) return;
    _started = false;
    automationStore.removeListener(_onAutomationsChanged);
    moduleStore.removeListener(_onModulesChanged);
    _cancelAllTimeRules();
  }

  /// Re-evaluates the rule set from the current [automationStore] snapshot:
  /// arms daily timers for enabled time rules and clears baselines for rules
  /// that are disabled, removed or no longer device-state driven.
  void reconcile() {
    final automations = automationStore.automations;
    final ids = <String>{for (final a in automations) a.id};

    _timeRules.removeWhere((id, rule) {
      if (!ids.contains(id)) return true;
      final a = automationById(id);
      return a == null ||
          !a.enabled ||
          a.triggerType != AutomationTriggerType.time;
    });
    for (final a in automations) {
      if (a.enabled && a.triggerType == AutomationTriggerType.time) {
        _armTimeRule(a);
      }
    }

    _watchSignature.removeWhere((id, signature) {
      if (!ids.contains(id)) return true;
      final a = automationById(id);
      return a == null ||
          !a.enabled ||
          a.triggerType != AutomationTriggerType.deviceState;
    });
  }

  /// Arms (or re-arms when the scheduled time changed) the daily timer for
  /// [automation].
  void _armTimeRule(Automation automation) {
    final hour = automation.effectiveScheduleHour;
    final minute = automation.effectiveScheduleMinute;

    final existing = _timeRules[automation.id];
    if (existing != null &&
        existing.hour == hour &&
        existing.minute == minute) {
      return;
    }
    existing?.timer.cancel();

    final timer = Timer(
      nextOccurrence(hour, minute, _now()).difference(_now()),
      () {
        _timeRules.remove(automation.id);
        _handleTimeElapsed(automation.id);
      },
    );
    _timeRules[automation.id] = _TimeRule(
      hour: hour,
      minute: minute,
      timer: timer,
    );
  }

  /// Fires [automationId]'s rule (if still valid) then re-arms it for the
  /// following day.
  void _handleTimeElapsed(String automationId) {
    final a = automationById(automationId);
    if (a != null && a.enabled && a.triggerType == AutomationTriggerType.time) {
      _fire(a).ignore();
    }
    final fresh = automationById(automationId);
    if (fresh != null &&
        fresh.enabled &&
        fresh.triggerType == AutomationTriggerType.time) {
      _armTimeRule(fresh);
    }
  }

  /// Rebuilds the watch baselines when the automation list changes so edited
  /// rules (new watch target) seed fresh instead of firing on an existing
  /// state.
  void _onAutomationsChanged() => reconcile();

  /// Re-evaluates every enabled device-state rule against the current module
  /// fleet and fires on fresh edge transitions.
  void _onModulesChanged() {
    for (final a in automationStore.automations) {
      if (!a.enabled || a.triggerType != AutomationTriggerType.deviceState) {
        _lastWatchState.remove(a.id);
        _watchSignature.remove(a.id);
        continue;
      }

      final on = _resolveWatchOn(a);
      if (on == null) continue;
      final signature =
          '${a.watchModuleIndex}|${a.watchModuleName}|${a.watchIsInput}|'
          '${a.watchInputIndex}|${a.watchInputName}|'
          '${a.watchChannelIndex}|${a.watchChannelName}|${a.watchState}';

      // First observation (or a changed watch target): record the baseline so
      // the rule never fires for a state that already existed.
      if (_watchSignature[a.id] != signature) {
        _watchSignature[a.id] = signature;
        _lastWatchState[a.id] = on;
        continue;
      }
      final prev = _lastWatchState[a.id];
      if (prev == null) {
        _lastWatchState[a.id] = on;
        continue;
      }

      _lastWatchState[a.id] = on;
      final shouldFire = a.watchState ? (on && !prev) : (!on && prev);
      if (shouldFire) _fire(a).ignore();
    }
  }

  /// Resolves the live on-state of the output or input [automation] watches
  /// across the fleet, or null when the target cannot be found.
  bool? _resolveWatchOn(Automation a) {
    final modules = moduleStore.modules;
    final module = _resolveWatchModule(modules, a);
    if (a.watchIsInput) {
      final index = _resolveInputIndex(module, modules, a);
      if (index < 0) return null;
      final input = module!.inputs[index];
      // A disabled input is not watched anywhere in the app.
      if (!input.enabled) return null;
      return input.state;
    }
    final index = _resolveChannelIndex(module, modules, a);
    if (index < 0) return null;
    final channel = module!.channels[index];
    return channel.isOn || channel.brightness > 0;
  }

  /// The module a device-state rule watches: by fleet index when wired,
  /// otherwise (legacy) by the saved module name. A null result means "any
  /// module" (legacy rules saved before module selection existed).
  DeviceModule? _resolveWatchModule(List<DeviceModule> modules, Automation a) {
    final byIndex = moduleAtIndex(modules, a.watchModuleIndex);
    if (byIndex != null) return byIndex;
    if (a.watchModuleName == null) return null;
    for (final m in modules) {
      if (m.name == a.watchModuleName) return m;
    }
    return null;
  }

  /// The watched output index on [module]: the stored index when valid, a
  /// legacy name match on the module, or a fleet-wide name match when the
  /// automation has no module (legacy). Returns -1 when nothing matches.
  int _resolveChannelIndex(
      DeviceModule? module, List<DeviceModule> modules, Automation a) {
    if (module != null) {
      if (a.watchChannelIndex >= 0 &&
          a.watchChannelIndex < module.channels.length) {
        return a.watchChannelIndex;
      }
      return module.channels
          .indexWhere((c) => c.name == a.watchChannelName);
    }
    if (a.watchChannelName == null) return -1;
    for (final m in modules) {
      final index = m.channels.indexWhere((c) => c.name == a.watchChannelName);
      if (index >= 0) return index;
    }
    return -1;
  }

  /// The watched input index on [module]; see [_resolveChannelIndex].
  int _resolveInputIndex(
      DeviceModule? module, List<DeviceModule> modules, Automation a) {
    if (module != null) {
      if (a.watchInputIndex >= 0 && a.watchInputIndex < module.inputs.length) {
        return a.watchInputIndex;
      }
      return module.inputs.indexWhere((i) => i.name == a.watchInputName);
    }
    if (a.watchInputName == null) return -1;
    for (final m in modules) {
      final index = m.inputs.indexWhere((i) => i.name == a.watchInputName);
      if (index >= 0) return index;
    }
    return -1;
  }

  /// Executes [automation]'s actions, records the trigger and per-action
  /// outcome in the event history and raises the (preference-gated) local
  /// notification.
  @visibleForTesting
  Future<void> fire(Automation automation) => _fire(automation);

  /// Simulates the daily timer of [automationId] elapsing: cancels any armed
  /// timer, fires the rule (if still valid) and re-arms it for the next day.
  /// Used by tests so the fire path is exercised without real timers.
  @visibleForTesting
  void fireTimeRule(String automationId) {
    _timeRules.remove(automationId)?.timer.cancel();
    _handleTimeElapsed(automationId);
  }

  /// True when a daily timer is currently armed for [automationId].
  @visibleForTesting
  bool isTimeRuleArmed(String automationId) =>
      _timeRules.containsKey(automationId);

  Future<void> _fire(Automation automation) async {
    if (!automation.enabled || automation.actions.isEmpty) return;
    firedCount++;
    await eventLogStore.recordAutomation(automationName: automation.name);
    final scenario = Scenario(
      id: 'automation-${automation.id}',
      name: automation.name,
      icon: Icons.flash_on,
      type: ScenarioType.tapToRun,
      actions: automation.actions,
    );
    final result = await ScenarioRunner.shared.run(scenario);
    await eventLogStore.recordScenarioResult(result);
  }

  Automation? automationById(String id) {
    for (final a in automationStore.automations) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _cancelAllTimeRules() {
    for (final rule in _timeRules.values) {
      rule.timer.cancel();
    }
    _timeRules.clear();
  }

  /// Returns the next daily occurrence of [hour]:[minute] strictly after
  /// [from]. Exposed for tests.
  @visibleForTesting
  static DateTime nextOccurrence(int hour, int minute, DateTime from) {
    var next = DateTime(from.year, from.month, from.day, hour, minute);
    if (!next.isAfter(from)) next = next.add(const Duration(days: 1));
    return next;
  }
}
