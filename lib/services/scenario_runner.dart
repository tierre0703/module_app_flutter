// lib/services/scenario_runner.dart
//
// Executes the actions of a tap-to-run scenario against the live command
// service and reports the per-action outcome so the event history can log not
// just that a scenario ran but the detail and success/failure of each action
// (brief section 2.4).
//
// Actions target their module and output/input by *index* (a position in the
// app-wide fleet + a channel/input position), so renaming a module or an
// output never breaks the link. Actions saved before index wiring existed
// (`moduleIndex`/`channelIndex`/`inputIndex` == -1) still resolve by name as a
// fallback.
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'module_status/module_status_service.dart';
import 'module_store.dart';

/// Outcome of a single scenario action dispatch.
@immutable
class ScenarioActionResult {
  /// Human-readable description of the action (e.g. `Cabin Light -> ON`).
  final String description;

  /// True when the module acknowledged the command with `OK`.
  final bool success;

  /// Extra detail (target module/output, failure reason). Populated on failure
  /// and on success with a minimal confirmation.
  final String detail;

  const ScenarioActionResult({
    required this.description,
    required this.success,
    required this.detail,
  });

  @override
  String toString() => '$description [${success ? 'OK' : 'FAILED'}]';
}

/// Result of running a whole scenario.
@immutable
class ScenarioRunResult {
  final String scenarioName;
  final List<ScenarioActionResult> actions;

  const ScenarioRunResult({required this.scenarioName, required this.actions});

  int get succeeded => actions.where((a) => a.success).length;
  int get failed => actions.length - succeeded;
  String get summary => failed == 0
      ? 'All ${actions.length} action(s) OK'
      : '$failed of ${actions.length} action(s) failed';
}

class ScenarioRunner {
  ScenarioRunner._();

  /// App-wide shared instance used by screens that run scenarios.
  static ScenarioRunner shared = ScenarioRunner._();

  /// Runs every action in [scenario] sequentially, collecting per-action
  /// results. Never throws - each unresolvable action becomes a failed result.
  Future<ScenarioRunResult> run(Scenario scenario) async {
    await ModuleStore.shared.init();
    final results = <ScenarioActionResult>[];
    for (final action in scenario.actions) {
      results.add(await _runAction(scenario, action));
    }
    return ScenarioRunResult(scenarioName: scenario.name, actions: results);
  }

  Future<ScenarioActionResult> _runAction(
      Scenario scenario, ScenarioAction action) async {
    final modules = ModuleStore.shared.modules;
    final description = '${action.moduleName}: ${action.summary}';

    final module = _resolveModule(modules, action);
    if (module == null) {
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Module "${action.moduleName}" not found in this location',
      );
    }

    final channelIndex =
        action.isInputAction ? -1 : _resolveChannelIndex(module, action);
    final inputIndex =
        action.isInputAction ? _resolveInputIndex(module, action) : -1;
    if (!action.isInputAction && channelIndex < 0) {
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Output "${action.channelName}" not found on ${module.name}',
      );
    }
    if (action.isInputAction && inputIndex < 0) {
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Input "${action.inputName}" not found on ${module.name}',
      );
    }
    // A disabled input is not controllable from anywhere in the app, even if a
    // scenario still references it.
    if (action.isInputAction && !module.inputs[inputIndex].enabled) {
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Input "${action.inputName}" is disabled on ${module.name}',
      );
    }

    final service = ModuleStatusService.shared;
    final protocol = service.commandProtocolFor(module.id);
    if (protocol == null || !protocol.isConnected) {
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: '${module.name} is not connected',
      );
    }

    if (action.isInputAction) {
      return _runInputAction(description, action, module, inputIndex, service);
    }

    final channel = module.channels[channelIndex];

    try {
      final bool ok = switch ((action.isDimmerAction, action.turnOn)) {
        (true, _) => await service.setDimmerLevel(
            module.id, channelIndex, action.brightnessPct),
        (false, true) => await service.turnOnOutput(module.id, channelIndex),
        (false, false) => await service.turnOffOutput(module.id, channelIndex),
      };
      return ScenarioActionResult(
        description: description,
        success: ok,
        detail: ok
            ? 'ACK on ${channel.name}'
            : 'Command rejected by ${module.name}',
      );
    } catch (e, st) {
      debugPrint('ScenarioRunner: action "$description" failed: $e\n$st');
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Command failed on ${module.name}: $e',
      );
    }
  }

  /// Runs an input action: drives the module's virtual input ON, OFF or with a
  /// PULSE (`set_virtual_input_state` `true`, 100 ms, `false`).
  Future<ScenarioActionResult> _runInputAction(
    String description,
    ScenarioAction action,
    DeviceModule module,
    int index,
    ModuleStatusService service,
  ) async {
    final input = module.inputs[index];

    try {
      final bool ok = switch (action.inputState) {
        InputActionState.on =>
          await service.setVirtualInputState(module.id, index, true),
        InputActionState.off =>
          await service.setVirtualInputState(module.id, index, false),
        InputActionState.pulse => await _pulseInput(service, module.id, index),
      };
      return ScenarioActionResult(
        description: description,
        success: ok,
        detail:
            ok ? 'ACK on ${input.name}' : 'Command rejected by ${module.name}',
      );
    } catch (e, st) {
      debugPrint('ScenarioRunner: action "$description" failed: $e\n$st');
      return ScenarioActionResult(
        description: description,
        success: false,
        detail: 'Command failed on ${module.name}: $e',
      );
    }
  }

  /// Sends `set_virtual_input_state` `true`, waits 100 ms, then sends `false`.
  /// All three steps must succeed for the pulse to count as a success.
  Future<bool> _pulseInput(
      ModuleStatusService service, String moduleId, int index) async {
    final set = await service.setVirtualInputState(moduleId, index, true);
    if (!set) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return service.setVirtualInputState(moduleId, index, false);
  }

  DeviceModule? _resolveModule(
      List<DeviceModule> modules, ScenarioAction action) {
    // Prefer the stored fleet index (stable across renames); fall back to the
    // saved name for actions created before index wiring existed.
    final byIndex = moduleAtIndex(modules, action.moduleIndex);
    if (byIndex != null) return byIndex;
    for (final m in modules) {
      if (m.name.toLowerCase() == action.moduleName.toLowerCase()) return m;
    }
    return null;
  }

  /// Resolves the output index an action targets: its stored [channelIndex]
  /// when valid, otherwise a legacy match on the saved output name.
  int _resolveChannelIndex(DeviceModule module, ScenarioAction action) {
    if (action.channelIndex >= 0 &&
        action.channelIndex < module.channels.length) {
      return action.channelIndex;
    }
    return module.channels.indexWhere((c) => c.name == action.channelName);
  }

  /// Resolves the input index an action targets: its stored [inputIndex] when
  /// valid, otherwise a legacy match on the saved input name.
  int _resolveInputIndex(DeviceModule module, ScenarioAction action) {
    if (action.inputIndex >= 0 && action.inputIndex < module.inputs.length) {
      return action.inputIndex;
    }
    return module.inputs.indexWhere((i) => i.name == action.inputName);
  }
}
