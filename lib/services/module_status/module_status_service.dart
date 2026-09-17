// lib/services/module_status/module_status_service.dart
//
// App-level service that, on launch, connects to every configured module and
// keeps its live status flowing into the app-wide [ModuleStore] (which
// persists + notifies every screen).
//
// Restructured around the reference architecture (`at_command_service.dart` +
// `tcp_service.dart`): instead of opening a fresh socket per refresh and
// closing it again, each module keeps a persistent, auto-reconnecting session
// alive for the app's lifetime.
//
// Which wire protocol a module speaks is decided by [ModuleProtocolSelector]
// from its firmware version (doc/Soleux_Control_API_Command_Specification_v0.3.md):
//
//   - firmware >= 7.12              -> Control API (JSON) on legacy port + 3;
//   - firmware <  7.12              -> legacy TCP AT (doc/PROTOCOLS.md §1);
//   - firmware unknown/advertised   -> probed, falling back to the transport
//     the device really answers (Control API -> legacy `J:` -> AT).
//
// Live control is always issued through the [ModuleCommandProtocol] facade for
// the module's active session, so screens / scenario runner never depend on the
// wire details. One such session is held per module:
//
//   - on connect the module pushes its full status dump; it is parsed
//     continuously and streamed into the store,
//   - unsolicited push broadcasts (state changes published by the module)
//     arrive on the same stream and update the module live,
//   - [refreshAll] / [refreshOne] remain the explicit "please re-ask for a
//     fresh dump now" entry points and also coalesce concurrent calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logger/network_debug_logger.dart';
import '../../core/soleux/soleux_device_event.dart';
import '../../core/soleux/soleux_json_protocol.dart';
import '../../models/models.dart';
import '../module_store.dart';
import '../settings_store.dart';
import 'control_api_command_protocol.dart';
import 'legacy_at_command_protocol.dart';
import 'module_command_protocol.dart';
import 'module_command_service.dart';
import 'module_protocol_selector.dart';
import 'module_status_fetcher.dart';
import 'module_tcp_service.dart';
import 'soleux_control_api_service.dart';
import 'soleux_http_service.dart';
import 'soleux_json_fetcher.dart';
import 'soleux_json_service.dart';

/// Formats a [DateTime] for the device's system-log filters
/// (`log_from`/`log_to`, `YYYY-MM-DD HH:MM:SS`).
String _formatLogDateTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)} ${two(time.hour)}:${two(time.minute)}:'
      '${two(time.second)}';
}

/// Resolves the app's chosen Control API command transport (TCP 5008 vs
/// HTTP/HTTPS POST /api/v1/command) at call time, so a Settings change is
/// picked up by the next refresh without restarting the service.
typedef CommandTransportResolver = CommandTransportMode Function();

/// Outcome of a single status pass over the fleet.
class ModuleStatusResult {
  /// Modules reachable and that answered every command with `OK`.
  final List<DeviceModule> online;

  /// Modules whose connection failed (offline / unreachable / unsupported).
  final List<DeviceModule> offline;

  const ModuleStatusResult({required this.online, required this.offline});

  bool get allOnline => offline.isEmpty;
  int get total => online.length + offline.length;
}

/// One dimmer channel's set/actual PWM level and logical state, parsed from a
/// `get_device_state` output entry (`set_pwm`/`actual_pwm`) of the Control API
/// specification.
class DimmerStateSnapshot {
  final int channel;
  final bool state;
  final double requestedLevel;
  final double actualLevel;
  final bool transitioning;

  const DimmerStateSnapshot({
    required this.channel,
    required this.state,
    required this.requestedLevel,
    required this.actualLevel,
    required this.transitioning,
  });

  /// Parses the flat `{channel, state, set_pwm, actual_pwm}` object returned by
  /// `get_device_state` output entries (previously `{requested_level,
  /// actual_level}` from the retired dimmer commands). `set_pwm` is the set
  /// (target) level and `actual_pwm` the currently produced level. Null when
  /// `channel` is absent or not numeric.
  static DimmerStateSnapshot? fromMap(Map<String, dynamic> map) {
    final channel = (map['channel'] as num?)?.toInt();
    if (channel == null) return null;
    final rawState = map['state'];
    final rawTransitioning = map['transitioning'];
    return DimmerStateSnapshot(
      channel: channel,
      state: rawState is bool ? rawState : false,
      requestedLevel: (map['set_pwm'] as num?)?.toDouble() ??
          (map['requested_level'] as num?)?.toDouble() ??
          0,
      actualLevel: (map['actual_pwm'] as num?)?.toDouble() ??
          (map['actual_level'] as num?)?.toDouble() ??
          0,
      transitioning: rawTransitioning is bool ? rawTransitioning : false,
    );
  }
}

/// Dimmer PWM/drive frequency as returned by `get_dimmer_frequency` (§6.8).
class DimmerFrequencyInfo {
  final int frequencyHz;

  /// Supported values, or the enumerated range from the `allowed_hz` span
  /// `{min,max}` form the spec allows.
  final List<int> allowedHz;
  final bool applyRequired;

  const DimmerFrequencyInfo({
    required this.frequencyHz,
    required this.allowedHz,
    required this.applyRequired,
  });

  /// Parses the §6.8 result; null when `frequency_hz` is missing.
  static DimmerFrequencyInfo? fromMap(Map<String, dynamic> map) {
    final hz = (map['frequency_hz'] as num?)?.toInt();
    if (hz == null) return null;
    final allowed = <int>[];
    final raw = map['allowed_hz'];
    if (raw is List) {
      for (final value in raw) {
        if (value is num) allowed.add(value.toInt());
      }
    } else if (raw is Map) {
      final min = (raw['min'] as num?)?.toInt();
      final max = (raw['max'] as num?)?.toInt();
      if (min != null && max != null) {
        for (var value = min; value <= max; value++) {
          allowed.add(value);
        }
      }
    }
    final rawApply = map['apply_required'];
    return DimmerFrequencyInfo(
      frequencyHz: hz,
      allowedHz: allowed,
      applyRequired: rawApply is bool ? rawApply : false,
    );
  }
}

class ModuleStatusService {
  /// Per-module timeout for the whole exchange.
  static const Duration defaultTimeout = Duration(seconds: 2);

  final ModuleStore store;
  final Duration timeout;

  /// Decides, from the module's firmware, which TCP command protocol to use.
  final ModuleProtocolSelector _protocolSelector;

  /// Resolves the Control API command transport (TCP 5008, HTTP 80 or HTTPS
  /// 443) at call time from the app settings.
  final CommandTransportResolver _commandTransport;

  final ModuleStatusFetcherRegistry _fetchers = ModuleStatusFetcherRegistry();

  bool _refreshing = false;
  ModuleStatusResult? _lastResult;
  Timer? _commitDebounce;

  /// Persistent per-module legacy AT command/status units (transport + parsing).
  final Map<String, ModuleCommandService> _units = {};

  /// Persistent per-module Soleux Control API units. A unit is either a
  /// [SoleuxJsonService] (persistent TCP socket) or a [SoleuxHttpService]
  /// (stateless HTTP/HTTPS `POST /api/v1/command`), per the app's
  /// [SettingsStore.commandTransport] selection.
  final Map<String, SoleuxControlApiService> _jsonUnits = {};

  ModuleStatusService({
    required this.store,
    this.timeout = defaultTimeout,
    ModuleProtocolSelector moduleProtocolSelector =
        const ModuleProtocolSelector(),
    CommandTransportResolver commandTransport = _defaultCommandTransport,
  })  : _protocolSelector = moduleProtocolSelector,
        _commandTransport = commandTransport;

  /// The default resolver reads the app preference (TCP 5008 unless the user
  /// picked HTTP/HTTPS in Settings).
  static CommandTransportMode _defaultCommandTransport() =>
      SettingsStore.shared.commandTransport;

  /// Shared service wired to the shared store, used by the launch path.
  static ModuleStatusService? _shared;
  static ModuleStatusService get shared =>
      _shared ??= ModuleStatusService(store: ModuleStore.shared);

  /// The outcome of the last completed pass, or null before the first refresh.
  ModuleStatusResult? get lastResult => _lastResult;

  bool get refreshing => _refreshing;

  /// Whether there is a fetcher for [type] (false = "not yet implemented").
  bool supports(ModuleType type) => _fetchers.forType(type) != null;

  /// Registers an additional module-type fetcher for future support. Existing
  /// sessions are unaffected; new sessions pick up the new fetcher.
  void registerFetcher(ModuleStatusFetcher fetcher) =>
      _fetchers.register(fetcher);

  /// The live legacy AT command/status unit driving [moduleId], or null when
  /// the module uses the JSON protocol (or has no unit yet).
  ModuleCommandService? commandServiceFor(String moduleId) => _units[moduleId];

  /// The live Soleux Control API unit driving [moduleId] (a [SoleuxJsonService]
  /// for the persistent TCP transport or a [SoleuxHttpService] for the
  /// HTTP/HTTPS transport), or null when the module has no live Control API unit
  /// (legacy AT device / not yet probed).
  SoleuxControlApiService? jsonCommandServiceFor(String moduleId) =>
      _jsonUnits[moduleId];

  /// The command protocol facade for the module's *active* session, or null
  /// when the module has no live unit (never refreshed / offline).
  ///
  /// Control commands go through this facade so the underlying wire protocol
  /// (Control API vs legacy AT) is an implementation detail.
  ModuleCommandProtocol? commandProtocolFor(String moduleId) {
    final jsonUnit = _jsonUnits[moduleId];
    if (jsonUnit != null && jsonUnit.isConnected) {
      return ControlApiCommandProtocol(jsonUnit);
    }
    final atUnit = _units[moduleId];
    if (atUnit != null && atUnit.isConnected) {
      return LegacyAtCommandProtocol(atUnit);
    }
    return null;
  }

  /// Sends a raw legacy `AT+...` control command through the legacy AT unit (or
  /// a `J:` device's legacy helper on the legacy port). Returns true when the
  /// device acknowledged with `OK`.
  ///
  /// Modern live control should use the Control API catalogue commands
  /// ([turnOnOutput], [toggleOutput], [setDimmerLevel], ...); this method is
  /// the fallback for legacy devices and for catalogue actions the firmware has
  /// not implemented yet. AT lines are only sent to ports that accept them
  /// (the legacy TCP port; never the Control API port or the HTTP/HTTPS
  /// endpoint, which are JSON-only).
  Future<bool> sendLegacyCommand(String moduleId, String command) async {
    final jsonUnit = _jsonUnits[moduleId];
    if (jsonUnit != null && jsonUnit.isConnected) {
      // Only a legacy `J:` device on the legacy TCP port accepts raw AT lines
      // (its legacy helper). The Control API port and the HTTP/HTTPS endpoint
      // accept JSON only (spec compatibility rule); the AT protocol, if
      // present, is served on the legacy TCP port instead.
      if (jsonUnit is SoleuxJsonService &&
          jsonUnit.framing == SoleuxJsonFraming.legacyJ) {
        try {
          final raw = await jsonUnit.legacy(command);
          return raw.endsWith('OK');
        } catch (e, st) {
          debugPrint('ModuleStatusService: legacy command "$command" on '
              '$moduleId failed: $e\n$st');
          return false;
        }
      }
      final atUnit = _units[moduleId];
      if (atUnit != null) return atUnit.command(command);
      return false;
    }
    final atUnit = _units[moduleId];
    if (atUnit != null) {
      return atUnit.command(command);
    }
    return false;
  }

  /// Turns an output on (zero-based channel) through the module's active
  /// protocol (`set_output_state` on the Control API, `AT+ON` on legacy AT).
  Future<bool> turnOnOutput(String moduleId, int index) =>
      _setOutputState(moduleId, index, true);

  /// Turns an output off (zero-based channel) through the module's active
  /// protocol (`set_output_state` on the Control API, `AT+OFF` on legacy AT).
  Future<bool> turnOffOutput(String moduleId, int index) =>
      _setOutputState(moduleId, index, false);

  /// Inverts one output (zero-based channel) through the module's active
  /// protocol (`toggle_output` on the Control API, `AT+TOGGLE` on legacy AT).
  Future<bool> toggleOutput(String moduleId, int index) async {
    final protocol = commandProtocolFor(moduleId);
    if (protocol == null) return false;
    try {
      final ok = await protocol.toggleOutput(index);
      if (ok) {
        // Reflect the inverted state deterministically instead of trusting a
        // possibly-stale `actual_state` (the device may acknowledge the toggle
        // before the output actually settles), so the screen updates on the
        // first press.
        final current = _channelState(moduleId, index);
        if (current != null) _applyOutputState(moduleId, index, !current);
      }
      return ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: toggle_output on $moduleId failed: '
          '$e\n$st');
      return false;
    }
  }

  /// Cycles one output off and back on through the module's active protocol
  /// (`restart_output` on the Control API, `AT+RESTART` on legacy AT).
  Future<bool> restartOutput(String moduleId, int index) async {
    final protocol = commandProtocolFor(moduleId);
    if (protocol == null) return false;
    try {
      return await protocol.restartOutput(index);
    } catch (e, st) {
      debugPrint('ModuleStatusService: restart_output on $moduleId failed: '
          '$e\n$st');
      return false;
    }
  }

  /// Sets one dimmer brightness percentage (0-100) through the module's active
  /// protocol (`set_dimmer_level` on the Control API, `AT+BRIGH` on legacy AT).
  Future<bool> setDimmerLevel(
      String moduleId, int index, int brightnessPct) async {
    final protocol = commandProtocolFor(moduleId);
    if (protocol == null) return false;
    try {
      return await protocol.setDimmerLevel(index, brightnessPct);
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_dimmer_level on $moduleId failed: '
          '$e\n$st');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Dimmer control catalogue facade (Control API spec §6). These commands are
  // Control-API-only: they need the live [SoleuxControlApiService] unit and
  // return false/null for legacy-AT sessions, whose dimmer control stays on the
  // [setDimmerLevel] protocol facade above.
  // ---------------------------------------------------------------------------

  /// Reads every dimmer set/actual PWM level and state via `get_device_state`
  /// (parsing each output's `set_pwm`/`actual_pwm`), or null when the module has
  /// no live Control API unit or the command was rejected.
  Future<List<DimmerStateSnapshot>?> getDimmerLevels(String moduleId) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return null;
    try {
      final response = await unit.getDimmerLevels();
      if (!response.ok) {
        debugPrint('ModuleStatusService: get_device_state (dimmer levels) on '
            '$moduleId rejected: ${response.error?.summary}');
        return null;
      }
      final raw = response.result?['outputs'];
      if (raw is! List) return null;
      final levels = <DimmerStateSnapshot>[];
      for (final item in raw) {
        if (item is Map) {
          final snapshot =
              DimmerStateSnapshot.fromMap(Map<String, dynamic>.from(item));
          if (snapshot != null) levels.add(snapshot);
        }
      }
      return levels;
    } catch (e, st) {
      debugPrint('ModuleStatusService: get_device_state (dimmer levels) on '
          '$moduleId failed: $e\n$st');
      return null;
    }
  }

  /// Reads one dimmer channel's relay state, set PWM level and actual PWM level
  /// via `get_device_state`.
  Future<DimmerStateSnapshot?> getDimmerState(
      String moduleId, int channel) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return null;
    try {
      final response = await unit.getDimmerState(channel);
      if (!response.ok) {
        debugPrint('ModuleStatusService: get_device_state ($channel) on '
            '$moduleId rejected: ${response.error?.summary}');
        return null;
      }
      final result = response.result;
      if (result == null) return null;
      return DimmerStateSnapshot.fromMap(result);
    } catch (e, st) {
      debugPrint('ModuleStatusService: get_device_state ($channel) on '
          '$moduleId failed: $e\n$st');
      return null;
    }
  }

  /// Applies [getDimmerLevels]' snapshot to the live store channels (set level
  /// -> brightness, state -> on/off), so screens show the module-reported
  /// dimming without a full configuration re-fetch.
  Future<void> syncDimmerLevels(String moduleId) async {
    final levels = await getDimmerLevels(moduleId);
    if (levels == null) return;
    final live = store.byId(moduleId);
    if (live == null) return;
    for (final snapshot in levels) {
      if (snapshot.channel < 0 || snapshot.channel >= live.channels.length) {
        continue;
      }
      final channel = live.channels[snapshot.channel];
      channel.isOn = snapshot.state;
      channel.brightness = snapshot.requestedLevel.round().clamp(0, 100);
    }
    _scheduleCommit();
  }

  /// `set_multiple_dimmer_levels` (§6.4) - sets several brightness levels
  /// together. [targets] holds `{channel, level, transition_ms?}` maps.
  Future<bool> setMultipleDimmerLevels(
    String moduleId,
    List<Map<String, dynamic>> targets, {
    String? execution,
    int? intervalMs,
  }) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response = await unit.setMultipleDimmerLevels(targets,
          execution: execution, intervalMs: intervalMs);
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_multiple_dimmer_levels on '
            '$moduleId rejected: ${response.error?.summary}');
        return false;
      }
      _applyDimmerLevelsToStore(moduleId, response.result);
      return true;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_multiple_dimmer_levels on '
          '$moduleId failed: $e\n$st');
      return false;
    }
  }

  /// Turns one dimmer on via `set_output_state` (`state: true`), replacing the
  /// retired `dimmer_on` command.
  Future<bool> dimmerOn(String moduleId, int channel,
      {int? transitionMs}) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response = await unit.dimmerOn(channel, transitionMs: transitionMs);
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_output_state (on) ($channel) on '
            '$moduleId rejected: ${response.error?.summary}');
        return false;
      }
      _applyDimmerResultToStore(moduleId, response.result);
      return true;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_output_state (on) ($channel) on '
          '$moduleId failed: $e\n$st');
      return false;
    }
  }

  /// Turns one dimmer off via `set_output_state` (`state: false`), replacing
  /// the retired `dimmer_off` command.
  Future<bool> dimmerOff(String moduleId, int channel,
      {int? transitionMs}) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response =
          await unit.dimmerOff(channel, transitionMs: transitionMs);
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_output_state (off) ($channel) on '
            '$moduleId rejected: ${response.error?.summary}');
        return false;
      }
      _applyDimmerResultToStore(moduleId, response.result);
      return true;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_output_state (off) ($channel) on '
          '$moduleId failed: $e\n$st');
      return false;
    }
  }

  /// `toggle_dimmer` (§6.7) - toggles one dimmer while retaining its target
  /// level.
  Future<bool> toggleDimmer(String moduleId, int channel,
      {int? transitionMs}) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response =
          await unit.toggleDimmer(channel, transitionMs: transitionMs);
      if (!response.ok) {
        debugPrint('ModuleStatusService: toggle_dimmer ($channel) on '
            '$moduleId rejected: ${response.error?.summary}');
        return false;
      }
      _applyDimmerResultToStore(moduleId, response.result);
      return true;
    } catch (e, st) {
      debugPrint('ModuleStatusService: toggle_dimmer ($channel) on $moduleId '
          'failed: $e\n$st');
      return false;
    }
  }

  /// `get_dimmer_frequency` (§6.8) - reads the configured dimmer PWM/drive
  /// frequency and its supported values.
  Future<DimmerFrequencyInfo?> getDimmerFrequency(String moduleId) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return null;
    try {
      final response = await unit.getDimmerFrequency();
      if (!response.ok) {
        debugPrint('ModuleStatusService: get_dimmer_frequency on $moduleId '
            'rejected: ${response.error?.summary}');
        return null;
      }
      final result = response.result;
      if (result == null) return null;
      return DimmerFrequencyInfo.fromMap(result);
    } catch (e, st) {
      debugPrint('ModuleStatusService: get_dimmer_frequency on $moduleId '
          'failed: $e\n$st');
      return null;
    }
  }

  /// `set_dimmer_frequency` (§6.9) - changes the dimmer PWM/drive frequency.
  /// [frequencyHz] must be one of the `allowed_hz` reported by
  /// [getDimmerFrequency].
  Future<bool> setDimmerFrequency(String moduleId, int frequencyHz,
      {bool? applyNow}) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response =
          await unit.setDimmerFrequency(frequencyHz, applyNow: applyNow);
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_dimmer_frequency ($frequencyHz) '
            'on $moduleId rejected: ${response.error?.summary}');
        return false;
      }
      return true;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_dimmer_frequency ($frequencyHz) '
          'on $moduleId failed: $e\n$st');
      return false;
    }
  }

  /// Applies a per-channel dimmer result to the live store channel. Accepts
  /// both the `set_output_state` shape (`{channel, actual_state, ...}`) and the
  /// `{dimmer: {...}}` wrapper used by `toggle_dimmer`. The display brightness
  /// follows the level so an OFF dimmer keeps showing its target.
  void _applyDimmerResultToStore(
      String moduleId, Map<String, dynamic>? result) {
    if (result == null) return;
    final wrapped = result['dimmer'];
    final data = wrapped is Map ? Map<String, dynamic>.from(wrapped) : result;
    final channel = (data['channel'] as num?)?.toInt();
    if (channel == null || channel < 0) return;
    final live = store.byId(moduleId);
    if (live == null || channel >= live.channels.length) return;
    final output = live.channels[channel];
    final rawState = data['state'] ?? data['actual_state'];
    if (rawState is bool) output.isOn = rawState;
    final rawLevel = data['set_pwm'] ??
        data['actual_pwm'] ??
        data['requested_level'] ??
        data['actual_level'];
    if (rawLevel is num) output.brightness = rawLevel.round().clamp(0, 100);
    _scheduleCommit();
  }

  /// Applies a `set_multiple_dimmer_levels` result (ordered per-target
  /// `channel`/`level`) to the live store channels.
  void _applyDimmerLevelsToStore(
      String moduleId, Map<String, dynamic>? result) {
    if (result == null) return;
    final raw = result['results'];
    if (raw is! List) return;
    final live = store.byId(moduleId);
    if (live == null) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      final channel = (data['channel'] as num?)?.toInt();
      if (channel == null || channel < 0 || channel >= live.channels.length) {
        continue;
      }
      final output = live.channels[channel];
      final rawLevel =
          data['level'] ?? data['requested_level'] ?? data['actual_level'];
      if (rawLevel is num) {
        output.brightness = rawLevel.round().clamp(0, 100);
        output.isOn = output.brightness > 0;
      }
    }
    _scheduleCommit();
  }

  /// Sets the logical state of a virtual input (`set_virtual_input_state`,
  /// Control API spec §3.4). Pressing-and-holding an input's action button
  /// sends `true`, releasing it sends `false`. Requires a live Control API
  /// unit; returns false when the module is offline.
  Future<bool> setVirtualInputState(
      String moduleId, int index, bool state) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response =
          await unit.setVirtualInputState(index, state, source: 'app');
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_virtual_input_state '
            '($index, $state) on $moduleId rejected: '
            '${response.error?.summary}');
      }
      return response.ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_virtual_input_state '
          '($index, $state) on $moduleId failed: $e\n$st');
      return false;
    }
  }

  /// Saves an input's configuration (`set_input_configuration`, Control API
  /// spec §3.3): its display [name], [enabled] flag (whether it shows up in
  /// the module screen) and behaviour [mode]. Returns whether the module
  /// accepted the change.
  Future<bool> updateInputConfiguration(
    String moduleId,
    int index, {
    String? name,
    bool? enabled,
    InputMode? mode,
  }) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final response = await unit.setInputConfiguration(index, {
        if (name != null) 'name': name,
        if (enabled != null) 'enabled': enabled,
        if (mode != null) 'mode': mode.name,
      });
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_input_configuration '
            '($index) on $moduleId rejected: ${response.error?.summary}');
      }
      return response.ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_input_configuration '
          '($index) on $moduleId failed: $e\n$st');
      return false;
    }
  }

  /// Saves an output's configuration (`set_output_configuration`, Control API
  /// spec §4.9): its display [name], [enabled] flag (whether control /
  /// display is permitted) and startup [initialState] (ON / OFF / Last State).
  /// Last State omits `initial_state` so the module restores its pre-restart
  /// state. Returns whether the module accepted the change.
  Future<bool> updateOutputConfiguration(
    String moduleId,
    int index, {
    String? name,
    bool? enabled,
    OutputInitialState? initialState,
  }) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return false;
    try {
      final wire = initialState?.wireValue;
      final response = await unit.setOutputConfiguration(index, {
        if (name != null) 'name': name,
        if (enabled != null) 'enabled': enabled,
        if (wire != null) 'initial_state': wire,
      });
      if (!response.ok) {
        debugPrint('ModuleStatusService: set_output_configuration '
            '($index) on $moduleId rejected: ${response.error?.summary}');
      }
      return response.ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_output_configuration '
          '($index) on $moduleId failed: $e\n$st');
      return false;
    }
  }

  /// `get_page_configuration` "system" page - fetches one page of the device's
  /// system log (`system_logs` section: [SystemLogPage]). Returns null when the
  /// module has no live Control API unit or the command was rejected.
  ///
  /// [from]/[to] bound the row timestamps (inclusive) and [tag] the output tag;
  /// all are optional and applied device-side before pagination.
  Future<SystemLogPage?> fetchSystemLogPage(
    String moduleId, {
    int page = 1,
    int pageSize = 10,
    DateTime? from,
    DateTime? to,
    String? tag,
  }) async {
    final unit = jsonCommandServiceFor(moduleId);
    if (unit == null || !unit.isConnected) return null;
    try {
      final response = await unit.getPageConfiguration(
        SoleuxJsonPages.system,
        logPage: page,
        logPageSize: pageSize,
        logFrom: from == null ? null : _formatLogDateTime(from),
        logTo: to == null ? null : _formatLogDateTime(to),
        logTag: tag,
      );
      if (!response.ok) {
        debugPrint('ModuleStatusService: get_page_configuration (system log) '
            'on $moduleId rejected: ${response.error?.summary}');
        return null;
      }
      return SystemLogPage.fromResult(response.result);
    } catch (e, st) {
      debugPrint('ModuleStatusService: get_page_configuration (system log) '
          'on $moduleId failed: $e\n$st');
      return null;
    }
  }

  Future<bool> _setOutputState(String moduleId, int index, bool state) async {
    final protocol = commandProtocolFor(moduleId);
    if (protocol == null) return false;
    try {
      final ok = await protocol.setOutputState(index, state);
      if (ok) {
        // Reflect the requested state - not the device's possibly-stale
        // `actual_state` - so the very first press flips the UI immediately
        // even when the device acknowledges before the output settles.
        _applyOutputState(moduleId, index, state);
      }
      return ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: set_output_state on $moduleId failed: '
          '$e\n$st');
      return false;
    }
  }

  /// The live channel's current ON/OFF state, or null when unavailable.
  bool? _channelState(String moduleId, int index) {
    final live = store.byId(moduleId);
    if (live == null) return null;
    if (index < 0 || index >= live.channels.length) return null;
    return live.channels[index].isOn;
  }

  /// Applies a successful control command's outcome to the live module in the
  /// store so screens reflect the (requested/actual) output state immediately,
  /// without depending on an unsolicited device broadcast arriving in time.
  void _applyOutputState(String moduleId, int index, bool state) {
    final live = store.byId(moduleId);
    if (live == null) return;
    if (index < 0 || index >= live.channels.length) return;
    final channel = live.channels[index];
    if (channel.isOn == state) return;
    channel.isOn = state;
    _scheduleCommit();
  }

  /// Ensures every module is connected and re-asks it for a fresh status dump,
  /// committing the fleet once. Concurrent calls are coalesced.
  Future<ModuleStatusResult> refreshAll() async {
    if (_refreshing) {
      return _lastResult ?? const ModuleStatusResult(online: [], offline: []);
    }
    _refreshing = true;

    try {
      await store.init();
      final modules = store.modules;
      final online = <DeviceModule>[];
      final offline = <DeviceModule>[];

      for (final module in modules) {
        final ok = await _refreshOne(module);
        ok ? online.add(module) : offline.add(module);
      }

      await store.commit();
      _lastResult = ModuleStatusResult(online: online, offline: offline);
    } catch (e, st) {
      debugPrint('ModuleStatusService: refreshAll failed: $e\n$st');
      rethrow;
    } finally {
      _refreshing = false;
    }
    return _lastResult!;
  }

  /// Re-asks a single [module] for a fresh status dump and commits. Returns
  /// true when the module answered every command with `OK`.
  Future<bool> refreshOne(DeviceModule module) async {
    final ok = await _refreshOne(module);
    await store.commit();
    return ok;
  }

  /// Tears down the live command/status unit for [moduleId]. Used when a
  /// module is removed so its socket/reconnect timers stop and the fleet
  /// counts reflect exactly the modules that remain.
  void removeModule(String moduleId) {
    _units.remove(moduleId)?.dispose();
    _disposeJsonUnit(moduleId);
  }

  /// Closes every persistent socket (and stops each unit's auto-reconnect)
  /// while keeping the units themselves alive so the app can resume quickly.
  /// Used by the lifecycle scheduler when the app moves to the background,
  /// where keeping sockets open wastes battery.
  Future<void> suspendAll() async {
    for (final unit in _units.values) {
      await unit.disconnect();
    }
    for (final unit in _jsonUnits.values) {
      await unit.disconnect();
    }
  }

  /// Brings every module back to the persistent-socket live mode. Disconnected
  /// sockets are reopened and a fresh status pass is run. Safe to call when
  /// sockets are already live (a no-op reconnect + coalesced refresh).
  Future<ModuleStatusResult> resumeAll() async {
    await store.init();
    for (final module in store.modules) {
      final unit = _units[module.id];
      if (unit != null) {
        await unit.connect();
      }
      final jsonUnit = _jsonUnits[module.id];
      if (jsonUnit != null) {
        await jsonUnit.connect();
      }
    }
    return refreshAll();
  }

  /// Lightweight background poll: for every module, opens a one-shot socket,
  /// pings it and closes it again - no persistent connection is kept. Each
  /// module's online/offline slot is updated in the store and committed once
  /// at the end.
  ///
  /// The ping follows the same firmware-driven protocol selection as a full
  /// refresh: a Control API module is pinged with a JSON `ping` on the Control
  /// API port (legacy port + 3); a legacy module answers `AT\r` on the legacy
  /// TCP port.
  Future<ModuleStatusResult> pollAll() async {
    await store.init();
    final modules = store.modules;
    final online = <DeviceModule>[];
    final offline = <DeviceModule>[];

    for (final module in modules) {
      final ok = await _pollConnectivity(module);
      ok ? online.add(module) : offline.add(module);
    }

    await store.commit();
    _lastResult = ModuleStatusResult(online: online, offline: offline);
    return _lastResult!;
  }

  /// Opens a temporary socket to [module] and pings it for a single success
  /// response, closing it immediately after. Returns whether it answered.
  /// Unsupported module types are treated as offline. The ping honours the
  /// app's Control API transport choice: a TCP mode module is pinged with a
  /// JSON `ping` on legacy port + 3, an HTTP/HTTPS mode module with a JSON
  /// `ping` POSTed to /api/v1/command.
  Future<bool> _pollConnectivity(DeviceModule module) async {
    final live = store.byId(module.id) ?? module;
    if (_fetchers.forType(module.type) == null) {
      return false;
    }
    final mode = _commandTransport();

    // Firmware-pinned protocol: ping exactly the transport the firmware speaks.
    final decision = _protocolSelector.decide(live);
    if (decision.pinned) {
      return decision.kind == ModuleCommandProtocolKind.controlApi
          ? (mode == CommandTransportMode.tcp
              ? await _pollJsonPing(live)
              : await _pollHttpPing(live, mode))
          : await _pollAtPing(live);
    }

    // Unknown firmware: Control API devices (discovery advertised the Control
    // API endpoint) are pinged over the JSON envelope on the configured
    // transport (TCP legacy port + 3, or HTTP/HTTPS /api/v1/command).
    // Everything else - AT-only and legacy `J:` devices - still answers the
    // legacy `AT\r` ping on the legacy TCP port during migration.
    return live.isControlApiAdvertised
        ? (mode == CommandTransportMode.tcp
            ? await _pollJsonPing(live)
            : await _pollHttpPing(live, mode))
        : await _pollAtPing(live);
  }

  /// One-shot legacy `AT\r` ping on the legacy TCP port. Opens a temporary
  /// socket, sends `AT\r`, waits for a single `OK`/`ERROR` terminator and
  /// closes it immediately.
  Future<bool> _pollAtPing(DeviceModule module) async {
    Socket? socket;
    var reachable = false;
    try {
      socket = await Socket.connect(module.ipAddress, module.tcpPort,
          timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      NetworkDebugLogger.outbound(
          'tcp', '${module.ipAddress}:${module.tcpPort}', 'AT\r');
      socket.write('AT\r');

      final buffer = StringBuffer();
      final done = Completer<void>();
      final timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });

      socket.listen(
        (bytes) {
          final text = utf8.decode(bytes);
          NetworkDebugLogger.inbound(
              'tcp', '${module.ipAddress}:${module.tcpPort}', text);
          buffer.write(text);
          final raw = buffer.toString().trimRight();
          if (raw.endsWith('\r\nOK') || raw.endsWith('\r\nERROR')) {
            if (!done.isCompleted) done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future;
      timer.cancel();
      reachable = buffer.toString().trimRight().endsWith('\r\nOK');
    } catch (e, st) {
      debugPrint('ModuleStatusService: polling ${module.ipAddress}:'
          '${module.tcpPort} failed: $e\n$st');
      reachable = false;
    } finally {
      try {
        socket?.destroy();
      } catch (e, st) {
        debugPrint('ModuleStatusService: socket destroy failed: $e\n$st');
      }
    }
    return reachable;
  }

  /// One-shot JSON `ping` on the Control API port. Opens a temporary socket,
  /// sends the Control API `ping` request (plain JSON envelope), waits for a
  /// matching `ok:true` response and closes it immediately.
  Future<bool> _pollJsonPing(DeviceModule module) async {
    Socket? socket;
    var reachable = false;
    final splitter = SoleuxLineSplitter();
    try {
      socket = await Socket.connect(module.ipAddress, module.controlApiPort,
          timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      const request =
          SoleuxJsonRequest(id: 1, action: SoleuxControlApiActions.ping);
      NetworkDebugLogger.outbound('tcp',
          '${module.ipAddress}:${module.controlApiPort}', request.encode());
      socket.write(request.encode());

      final done = Completer<void>();
      final timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });

      socket.listen(
        (bytes) {
          final text = utf8.decode(bytes);
          NetworkDebugLogger.inbound(
              'tcp', '${module.ipAddress}:${module.controlApiPort}', text);
          for (final line in splitter.add(text)) {
            final response = SoleuxJsonResponse.maybeParse(line);
            if (response != null && response.id == 1) {
              reachable = response.ok;
              if (!done.isCompleted) done.complete();
            }
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future;
      timer.cancel();
    } catch (e, st) {
      debugPrint('ModuleStatusService: JSON ping ${module.ipAddress}:'
          '${module.controlApiPort} failed: $e\n$st');
      reachable = false;
    } finally {
      try {
        socket?.destroy();
      } catch (e, st) {
        debugPrint('ModuleStatusService: socket destroy failed: $e\n$st');
      }
    }
    return reachable;
  }

  /// Stateless HTTP/HTTPS `ping` on the Control API command endpoint
  /// (`POST /api/v1/command`, spec §"HTTP transport"). No persistent connection
  /// is kept; the configured port follows the app's transport setting (80 for
  /// HTTP, 443 for HTTPS).
  Future<bool> _pollHttpPing(
      DeviceModule module, CommandTransportMode mode) async {
    final unit = _ensureHttpUnit(module, mode);
    try {
      final response = await unit.ping(timeout: timeout);
      return response.ok;
    } catch (e, st) {
      debugPrint('ModuleStatusService: HTTP ping '
          '${controlApiHttpEndpoint(module, mode)} failed: $e\n$st');
      return false;
    }
  }

  Future<bool> _refreshOne(DeviceModule module) async {
    // The store may hold a newer instance of the same module; operate on that
    // live object so mutations propagate to every screen.
    final live = store.byId(module.id) ?? module;

    final fetcher = _fetchers.forType(module.type);
    if (fetcher == null) {
      // Unsupported module type - no status probe exists, so it cannot be
      // confirmed reachable.
      return false;
    }

    // Firmware-pinned protocol (>= 7.12 -> Control API, < 7.12 -> legacy AT):
    // drive exactly the transport the firmware speaks, without cross-protocol
    // probing. Unknown firmware falls through to the probe below.
    final decision = _protocolSelector.decide(live);
    if (decision.pinned) {
      return decision.kind == ModuleCommandProtocolKind.controlApi
          ? _refreshControlApi(live)
          : _refreshLegacyAt(live, fetcher);
    }

    // Soleux JSON path first for unknown-firmware modules (the recommended
    // protocol for new mobile clients). The probe follows the app's Control API
    // transport setting:
    //   - TCP mode (default): the Control API on legacy port + 3 (plain JSON
    //     envelope) then the legacy `J:` protocol for pre-Control-API devices;
    //   - HTTP/HTTPS mode: the Control API endpoint POST /api/v1/command.
    // Either way it falls back to the legacy AT+ dump when nothing answers.
    final mode = _commandTransport();
    if (mode != CommandTransportMode.tcp) {
      final httpOk = await _probeHttp(live, mode);
      if (httpOk == true) {
        // A Control API device must not keep a duplicate legacy AT+ unit (and
        // its second socket) around.
        _units.remove(live.id)?.dispose();
        return true;
      }
      if (httpOk == false) {
        // The endpoint answered but rejected the Control API hello - not a
        // current Soleux HTTP Control API device; the AT path is not closed.
        return false;
      }
      // Unreachable / no hello in time - a legacy device; fall back to AT+.
      return _refreshLegacyAt(live, fetcher);
    }

    final jsonOk = await _probeSoleuxJson(live);
    if (jsonOk == true) {
      // A JSON-capable device must not keep a duplicate legacy AT+ unit (and
      // its second socket) around.
      _units.remove(live.id)?.dispose();
      return true;
    }
    if (jsonOk == false) {
      // Connected but the JSON protocol was rejected - the device is not a
      // current Soleux JSON device; report unreachable/unsupported so the AT
      // path is not silently closed over.
      return false;
    }

    // Legacy AT+ path.
    return _refreshLegacyAt(live, fetcher);
  }

  /// Refreshes a legacy module (firmware below 7.12, or the AT fallback of a
  /// probe) over the legacy TCP AT protocol.
  Future<bool> _refreshLegacyAt(
      DeviceModule live, ModuleStatusFetcher fetcher) async {
    final unit = _ensureUnit(live, fetcher);
    unit.attach(live);

    try {
      await unit.connect();
      debugPrint('Module ${live.name} (${live.id}) connected');
      if (!unit.isConnected) {
        return false;
      }
      debugPrint('Module ${live.name} (${live.id}) connected, fetching...');
      final allOk = await unit.run(fetcher.fetchCommands);
      debugPrint('Module ${live.name} (${live.id}) refresh: $allOk');
      if (!allOk) {
        return false;
      }
      // A status dump may newly reveal >= 7.12 firmware (e.g. an OTA update):
      // upgrade the session to the Control API immediately so the module is
      // driven over the new command model from now on.
      final decision = _protocolSelector.decide(live);
      if (decision.pinned &&
          decision.kind == ModuleCommandProtocolKind.controlApi) {
        return await _refreshControlApi(live);
      }
      return true;
    } catch (e) {
      debugPrint('Module ${live.name} (${live.id}) refresh failed: $e');
      // Socket / protocol / timeout - module unreachable.
      return false;
    }
  }

  /// Refreshes a Control API module (firmware >= 7.12) over the app's
  /// configured Control API transport: the TCP session on the Control API port
  /// (legacy port + 3) or the stateless HTTP/HTTPS command endpoint. Because
  /// the firmware pins the Control API, no legacy AT probing is performed.
  Future<bool> _refreshControlApi(DeviceModule live) async {
    final unit = _ensureControlApiUnit(live);
    final ok = await _tryJsonHello(unit, live);
    if (ok == true) {
      await _fetchRelayConfiguration(unit, live);
      // A Control API device must not keep a duplicate legacy AT+ unit around.
      _units.remove(live.id)?.dispose();
      return true;
    }
    if (ok == false) {
      _disposeJsonUnit(live.id);
    }
    return false;
  }

  /// Probes a module for the Soleux JSON protocol using both framings and
  /// ports, then fetches the configuration to build the live module state.
  ///
  /// Probe order (per the Control API spec v0.2 transport mapping):
  ///   1. Control API on `legacy port + 3` (plain JSON envelope, no `J:`
  ///      prefix) - the modern Relay transport;
  ///   2. legacy `J:` protocol on the legacy TCP port - pre-Control-API
  ///      devices;
  ///   3. otherwise the module is a legacy AT+ device.
  ///
  /// Returns:
  ///   - `true`  when a JSON protocol answered `hello` and the dump was
  ///             fetched;
  ///   - `false` when the JSON protocol was definitively rejected (connected
  ///             but no `ok` hello, or the sockets are unreachable);
  ///   - `null`  when the TCP path is fine but no JSON `hello` arrived in time
  ///             - a legacy AT+ device, so the caller falls back to AT+.
  Future<bool?> _probeSoleuxJson(DeviceModule live) async {
    // 1) Control API (plain JSON on legacy port + 3). Skipped when the ports
    // coincide so a single-socket legacy device is not double-probed.
    final controlPort = live.controlApiPort;
    if (controlPort != live.tcpPort) {
      final controlUnit = _ensureJsonUnit(live,
          port: controlPort, framing: SoleuxJsonFraming.controlApi);
      final controlOk = await _tryJsonHello(controlUnit, live);
      if (controlOk == true) {
        await _fetchRelayConfiguration(controlUnit, live);
        return true;
      }
      if (controlOk == false) {
        _disposeJsonUnit(live.id);
      }
      // controlOk == null: socket alive but no hello in time - try legacy.
    }

    // 2) Legacy `J:` framing on the legacy TCP port.
    final legacyUnit = _ensureJsonUnit(live,
        port: live.tcpPort, framing: SoleuxJsonFraming.legacyJ);
    final legacyOk = await _tryJsonHello(legacyUnit, live);
    if (legacyOk == true) {
      await _fetchRelayConfiguration(legacyUnit, live);
      return true;
    }
    if (legacyOk == false) {
      _disposeJsonUnit(live.id);
      return false;
    }

    // 3) No JSON `hello` within the window - a legacy AT+ device; drop the
    // JSON unit and let the AT+ path take over.
    debugPrint('Module ${live.name} (${live.id}) did not answer a JSON hello; '
        'falling back to legacy AT+');
    _disposeJsonUnit(live.id);
    return null;
  }

  /// Probes a module for the Soleux Control API over the HTTP/HTTPS command
  /// endpoint (`POST /api/v1/command`), then fetches the configuration.
  ///
  /// Returns:
  ///   - `true`  when the endpoint answered `hello` ok and the dump was
  ///             fetched;
  ///   - `false` when the endpoint answered but rejected the hello (not a
  ///             Control API HTTP device);
  ///   - `null`  when the endpoint was unreachable or no hello arrived in time
  ///             - a legacy device, so the caller falls back to AT+.
  Future<bool?> _probeHttp(DeviceModule live, CommandTransportMode mode) async {
    final unit = _ensureHttpUnit(live, mode);
    final ok = await _tryJsonHello(unit, live);
    if (ok == true) {
      await _fetchRelayConfiguration(unit, live);
      return true;
    }
    final reached = unit.isConnected;
    _disposeJsonUnit(live.id);
    if (ok == false && reached) return false;
    // Unreachable or timed out - not an HTTP Control API device.
    return null;
  }

  /// Connects [unit] and sends `hello`. Returns:
  ///   - `true`  when the device answered with `ok:true`;
  ///   - `false` when the connection failed or the hello was rejected;
  ///   - `null`  when the socket is alive but no hello arrived in time.
  Future<bool?> _tryJsonHello(
      SoleuxControlApiService unit, DeviceModule live) async {
    await unit.connect();
    if (!unit.isConnected) return false;
    try {
      final hello = await unit.hello(timeout: _jsonHelloTimeout);
      if (!hello.ok) return false;
      // A successful Control API hello pins the module to the Control API
      // transport for subsequent polling (spec: rely on hello/capability data
      // instead of a fixed port or assumptions). Legacy `J:` devices are left
      // unadvertised so polling keeps using the legacy ping path.
      if (unit.framing == SoleuxJsonFraming.controlApi) {
        live.apiVersion ??= SoleuxProtocolVersion.implemented;
      }
      const fetcher = SoleuxJsonFetcher();
      fetcher.apply(live, SoleuxHelloData.fromResult(hello.result ?? {}));
      return true;
    } on TimeoutException {
      return null;
    } catch (e, st) {
      debugPrint('Module ${live.name} (${live.id}) JSON hello failed: $e\n$st');
      return false;
    }
  }

  /// Fetches the implemented Relay configuration dump (the currently available
  /// "relay state/configuration operations" subset) and applies it to [live].
  /// The complete live snapshot (`get_device_state`) is then fetched right after
  /// so the store reflects device temperature and, for dimmers, real
  /// brightness/on-off.
  Future<void> _fetchRelayConfiguration(
      SoleuxControlApiService unit, DeviceModule live) async {
    try {
      final config =
          await unit.getRelayConfiguration(timeout: const Duration(seconds: 3));
      if (config.ok) {
        const fetcher = SoleuxJsonFetcher();
        fetcher.applyConfiguration(
            live, SoleuxRelayConfiguration.fromResult(config.result ?? {}));
        _scheduleCommit();
      }
    } catch (e, st) {
      debugPrint('Module ${live.name} (${live.id}) relay configuration fetch '
          'failed: $e\n$st');
    }
    await _fetchDeviceState(unit, live);
  }

  /// `get_device_state` - fetches the complete synchronization snapshot and
  /// applies its live data to [live]:
  ///   - the full system/network info is stored on [DeviceModule.systemInfo] so
  ///     screens can surface CPU/memory/temperature/uptime and network details;
  ///   - the internal module temperature is mirrored onto
  ///     [DeviceModule.internalTempC] (falling back to `external_temp_c`);
  ///   - every output's on/off state and (for dimmers) set/actual PWM level is
  ///     applied to the live store channels.
  Future<void> _fetchDeviceState(
      SoleuxControlApiService unit, DeviceModule live) async {
    try {
      final response =
          await unit.getDeviceState(timeout: const Duration(seconds: 3));
      if (!response.ok) {
        debugPrint('Module ${live.name} (${live.id}) device state fetch '
            'rejected: ${response.error?.summary}');
        return;
      }
      final result = response.result;
      if (result == null) return;
      if (result['system'] is Map || result['network'] is Map) {
        _applySystemSnapshot(live, Map<String, dynamic>.from(result));
      }
      final raw = result['outputs'];
      if (raw is List) _applyDimmerOutputs(live.id, raw);
      _scheduleCommit();
    } catch (e, st) {
      debugPrint('Module ${live.name} (${live.id}) device state fetch '
          'failed: $e\n$st');
    }
  }

  /// Applies a `get_device_state` `outputs` list to the live store channels
  /// (state -> on/off, `set_pwm` -> brightness).
  void _applyDimmerOutputs(String moduleId, List raw) {
    final live = store.byId(moduleId);
    if (live == null) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      final channel = (data['channel'] as num?)?.toInt();
      if (channel == null || channel < 0 || channel >= live.channels.length) {
        continue;
      }
      final output = live.channels[channel];
      final rawState = data['state'];
      if (rawState is bool) output.isOn = rawState;
      final rawLevel = data['set_pwm'] ??
          data['actual_pwm'] ??
          data['requested_level'] ??
          data['actual_level'];
      if (rawLevel is num) output.brightness = rawLevel.round().clamp(0, 100);
    }
    _scheduleCommit();
  }

  /// Per-module timeout for a JSON `hello` round-trip.
  static const Duration _jsonHelloTimeout = Duration(seconds: 2);

  /// Gets the persistent unit for [module], creating (and wiring) it the first
  /// time. Its live streams are routed into the store on creation only.
  ModuleCommandService _ensureUnit(
      DeviceModule module, ModuleStatusFetcher fetcher) {
    final existing = _units[module.id];
    if (existing != null) return existing;

    final unit = ModuleCommandService(
      connection: ModuleTcpConnection(
        host: module.ipAddress,
        port: module.tcpPort,
        timeout: timeout,
      ),
      fetcher: fetcher,
      module: module,
    );
    // Live status parses -> stream into the store (persist + notify).
    unit.moduleStream.listen((_) => _scheduleCommit());

    _units[module.id] = unit;
    return unit;
  }

  /// Gets the persistent Soleux JSON unit for [module], creating (and wiring)
  /// it the first time for the given [port]/[framing]. When an existing unit
  /// targets a different endpoint or framing (e.g. the probe moved from the
  /// Control API port to the legacy port, or the app switched from HTTP to
  /// TCP), the old unit is disposed and replaced so the module never holds two
  /// Control API sessions. Its live event lines are folded into the module's
  /// channel state and its connect/disconnect transitions flip the online
  /// status.
  SoleuxJsonService _ensureJsonUnit(DeviceModule module,
      {required int port, required SoleuxJsonFraming framing}) {
    final existing = _jsonUnits[module.id];
    if (existing is SoleuxJsonService &&
        existing.connection.port == port &&
        existing.framing == framing) {
      return existing;
    }
    if (existing != null) existing.dispose();

    final unit = SoleuxJsonService(
      connection: ModuleTcpConnection(
        host: module.ipAddress,
        port: port,
        timeout: timeout,
      ),
      framing: framing,
    );
    _wireJsonUnit(module, unit);
    _jsonUnits[module.id] = unit;
    return unit;
  }

  /// Gets the persistent Control API unit for [module] per the app's configured
  /// transport: a [SoleuxJsonService] over the Control API TCP port in TCP
  /// mode, or a [SoleuxHttpService] on the HTTP/HTTPS command endpoint.
  /// Switching the Settings transport while the app runs replaces the existing
  /// unit on the next refresh.
  SoleuxControlApiService _ensureControlApiUnit(DeviceModule module) {
    final mode = _commandTransport();
    if (mode != CommandTransportMode.tcp) {
      return _ensureHttpUnit(module, mode);
    }
    return _ensureJsonUnit(module,
        port: module.controlApiPort, framing: SoleuxJsonFraming.controlApi);
  }

  /// Gets the persistent HTTP/HTTPS Control API unit for [module]
  /// (`POST /api/v1/command`). No persistent socket is kept; `connect` is a
  /// reachability probe. When an existing unit targets a different endpoint
  /// (or the module changed IP / the transport setting changed), the old unit
  /// is disposed and replaced.
  SoleuxHttpService _ensureHttpUnit(
      DeviceModule module, CommandTransportMode mode) {
    final baseUri = controlApiHttpEndpoint(module, mode);
    final existing = _jsonUnits[module.id];
    if (existing is SoleuxHttpService && existing.baseUri == baseUri) {
      return existing;
    }
    if (existing != null) existing.dispose();

    final unit = SoleuxHttpService(baseUri: baseUri, timeout: timeout);
    _jsonUnits[module.id] = unit;
    return unit;
  }

  /// Wires the shared TCP unit streams (live state pushes + connectivity).
  void _wireJsonUnit(DeviceModule module, SoleuxJsonService unit) {
    // Unsolicited `OUT:`/`IN:` state pushes keep the channel list live.
    unit.eventStream.listen((event) {
      final live = store.byId(module.id);
      if (live == null) return;
      if (event.channel != null &&
          event.state != null &&
          event.channel! >= 0 &&
          event.channel! < live.channels.length) {
        live.channels[event.channel!].isOn = event.state!;
        _scheduleCommit();
      }
    });
    // Control API device events (output/input/level changes, temperature,
    // system_status, ...) update the live module so its target screen reflects
    // device-initiated changes without a re-fetch.
    unit.deviceEventStream
        .listen((event) => _applyDeviceEvent(module.id, event));
  }

  /// Applies the `system`/`network` part of a snapshot (a `get_device_state`
  /// result or a `system_status` broadcast) to [live]'s
  /// [DeviceModule.systemInfo] and mirrors the sensor temperature onto
  /// [DeviceModule.internalTempC].
  void _applySystemSnapshot(DeviceModule live, Map<String, dynamic> result) {
    live.systemInfo =
        DeviceSystemInfo.fromJson(Map<String, dynamic>.from(result));
    if (live.systemInfo!.internalTempC != null) {
      live.internalTempC = live.systemInfo!.internalTempC!;
    } else if (live.systemInfo!.externalTempC != null) {
      live.internalTempC = live.systemInfo!.externalTempC!;
    }
  }

  /// Applies a Control API device event to the live module in the store (and
  /// therefore to the module's screen, which rebuilds on [ModuleStore]
  /// changes). Events are incremental updates; skipped revisions should be
  /// recovered with a `get_device_state` snapshot, so out-of-range or unknown
  /// events are ignored here.
  void _applyDeviceEvent(String moduleId, SoleuxDeviceEvent event) {
    final live = store.byId(moduleId);
    if (live == null) return;
    final changed = switch (event.type) {
      SoleuxDeviceEventType.outputStateChanged =>
        _applyOutputStateEvent(live, event),
      SoleuxDeviceEventType.outputLevelChanged =>
        _applyOutputLevelEvent(live, event),
      SoleuxDeviceEventType.pwmStateChanged => _applyPwmStateEvent(live, event),
      SoleuxDeviceEventType.inputStateChanged =>
        _applyInputStateEvent(live, event),
      SoleuxDeviceEventType.temperatureChanged =>
        _applyTemperatureEvent(live, event),
      SoleuxDeviceEventType.systemStatus =>
        _applySystemStatusEvent(live, event),
      _ => false,
    };
    if (changed) _scheduleCommit();
  }

  /// `output_state_changed` - the output's on/off state changed.
  bool _applyOutputStateEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final channel = event.channel;
    final state = event.state;
    if (channel == null ||
        state == null ||
        channel < 0 ||
        channel >= live.channels.length) {
      return false;
    }
    final output = live.channels[channel];
    if (output.isOn == state) return false;
    output.isOn = state;
    return true;
  }

  /// `output_level_changed` - a dimmer output's level transitioned.
  bool _applyOutputLevelEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final channel = event.channel;
    if (channel == null || channel < 0 || channel >= live.channels.length) {
      return false;
    }
    final output = live.channels[channel];
    final level = event.requestedLevel ?? event.actualLevel;
    if (level != null) {
      final brightness = level.round().clamp(0, 100);
      if (output.brightness == brightness && output.isOn == (brightness > 0)) {
        return false;
      }
      output.brightness = brightness;
      output.isOn = brightness > 0;
      return true;
    }
    // Some firmware reports only the logical state on a level change.
    final state = event.state;
    if (state != null && output.isOn != state) {
      output.isOn = state;
      return true;
    }
    return false;
  }

  /// `pwm_state_changed` - a dimmer channel's PWM level changed; the display
  /// brightness follows the device-reported set PWM.
  bool _applyPwmStateEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final channel = event.channel;
    final pwm = event.setPwm;
    if (channel == null ||
        pwm == null ||
        channel < 0 ||
        channel >= live.channels.length) {
      return false;
    }
    final output = live.channels[channel];
    final brightness = pwm.round().clamp(0, 100);
    if (output.brightness == brightness && output.isOn == (brightness > 0)) {
      return false;
    }
    output.brightness = brightness;
    output.isOn = brightness > 0;
    return true;
  }

  /// `input_state_changed` - a physical/virtual input changed state.
  bool _applyInputStateEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final channel = event.channel;
    final state = event.state;
    if (channel == null ||
        state == null ||
        channel < 0 ||
        channel >= live.inputs.length) {
      return false;
    }
    final input = live.inputs[channel];
    if (input.state == state) return false;
    input.state = state;
    return true;
  }

  /// `temperature_changed` - mirror the sensor reading onto the module's
  /// internal temperature so the temperature module screen stays live.
  bool _applyTemperatureEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final value = event.valueC;
    if (value == null) return false;
    final rounded = double.parse(value.toStringAsFixed(1));
    if ((live.internalTempC - rounded).abs() < 0.05) return false;
    live.internalTempC = rounded;
    return true;
  }

  /// `system_status` - periodic (~5 s while a client is connected) full
  /// system/network snapshot. Applies the same system info a `get_device_state`
  /// result would, so CPU/memory/temperature/uptime and LAN/Wi-Fi stay live
  /// without polling. Returns true whenever the device reported a system or
  /// network block (the store commit is debounced).
  bool _applySystemStatusEvent(DeviceModule live, SoleuxDeviceEvent event) {
    final system = event.system;
    final network = event.network;
    if (system == null && network == null) return false;
    _applySystemSnapshot(live, {
      if (system != null) 'system': system,
      if (network != null) 'network': network,
    });
    return true;
  }

  /// The Control API command endpoint for [module] per the app's HTTP/HTTPS
  /// transport choice (spec §"Transport mapping"): HTTP port 80, HTTPS port
  /// 443, path `/api/v1/command`. [DeviceModule.apiHttpPort] overrides the
  /// port when set (development / non-standard deployments).
  static Uri controlApiHttpEndpoint(
      DeviceModule module, CommandTransportMode mode) {
    final https = mode == CommandTransportMode.https;
    return Uri(
      scheme: https ? 'https' : 'http',
      host: module.ipAddress,
      port: module.apiHttpPort ?? (https ? 443 : 80),
      path: '/api/v1/command',
    );
  }

  void _disposeJsonUnit(String moduleId) {
    _jsonUnits.remove(moduleId)?.dispose();
  }

  /// Coalesces the frequent, unsolicited stream updates into a single delayed
  /// store commit instead of persisting on every byte burst.
  void _scheduleCommit() {
    _commitDebounce?.cancel();
    _commitDebounce =
        Timer(const Duration(milliseconds: 150), () => store.commit().ignore());
  }

  void dispose() {
    _commitDebounce?.cancel();
    _commitDebounce = null;
    for (final unit in _units.values) {
      unit.dispose();
    }
    _units.clear();
    for (final unit in _jsonUnits.values) {
      unit.dispose();
    }
    _jsonUnits.clear();
  }
}
