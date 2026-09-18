// lib/services/module_status/control_api_command_protocol.dart
//
// [ModuleCommandProtocol] implementation over the Soleux Control API
// (doc/Soleux_Control_API_Command_Specification_v0.3.md), used for modules whose
// firmware is at or above 7.12. Commands use the transport-neutral Control API
// envelope: one JSON object per line on the legacy TCP port + 3 (5008 by
// default), or the same envelope POSTed to /api/v1/command over HTTP/HTTPS
// ([SoleuxHttpService]); responses are matched by `id` on TCP and by the common
// envelope on HTTP.
//
// Control mapping (spec "Outputs" §4 and "Dimmer control" §6):
//   - set on/off   -> set_output_state    (§4.3, replaces AT+ON/AT+OFF)
//   - toggle       -> toggle_output       (§4.4, replaces AT+TOGGLE)
//   - restart      -> restart_output      (§4.5, replaces AT+RESTART)
//   - set level    -> set_dimmer_level    (§6.3, replaces the dimmer AT command)
//   - ping         -> ping                (§1.2, replaces `AT\r`)
//
// When a catalogue action is not implemented the device returns the common
// `unsupported_command`/`unknown_action` error (spec "Common error catalogue");
// the spec says clients must not assume every catalogued action is available.
// In that case we fall back to the legacy AT command only on a pre-Control-API
// `J:` device, whose framing lives on the legacy TCP port where AT is accepted.
// The Control API port itself accepts JSON only (compatibility rule in the
// spec), so no AT fallback is ever attempted there.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/soleux/soleux_json_protocol.dart';
import 'module_command_protocol.dart';
import 'soleux_control_api_service.dart';

class ControlApiCommandProtocol implements ModuleCommandProtocol {
  final SoleuxControlApiService _service;

  ControlApiCommandProtocol(this._service);

  @override
  ModuleCommandProtocolKind get kind => ModuleCommandProtocolKind.controlApi;

  @override
  String get name => 'control-api';

  @override
  bool get isConnected => _service.isConnected;

  @override
  Future<bool> ping() async {
    try {
      return (await _service.ping()).ok;
    } catch (e, st) {
      debugPrint('ControlApiCommandProtocol: ping failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> setOutputState(int channel, bool on) async {
    try {
      final response = await _service.setOutputState(channel, on);
      return _applyResult(response);
    } catch (e, st) {
      debugPrint('ControlApiCommandProtocol: set_output_state($channel, $on) '
          'failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> toggleOutput(int channel) async {
    try {
      final response = await _service.toggleOutput(channel);
      return _applyResult(response);
    } catch (e, st) {
      debugPrint('ControlApiCommandProtocol: toggle_output($channel) failed: '
          '$e\n$st');
      return false;
    }
  }

  @override
  Future<bool> restartOutput(int channel) async {
    try {
      final response = await _service.restartOutput(channel);
      return _applyResult(response);
    } catch (e, st) {
      debugPrint('ControlApiCommandProtocol: restart_output($channel) failed: '
          '$e\n$st');
      return false;
    }
  }

  @override
  Future<bool> setDimmerLevel(int channel, int brightnessPct) async {
    try {
      final response =
          await _service.setDimmerLevel(channel, brightnessPct.clamp(0, 100));
      return _applyResult(response);
    } catch (e, st) {
      debugPrint('ControlApiCommandProtocol: set_dimmer_level($channel, '
          '$brightnessPct) failed: $e\n$st');
      return false;
    }
  }

  /// Applies a Control API response: true only when the device accepted it.
  ///
  /// NOTE: the legacy AT fallback (re-sending `AT+ON`/`AT+OFF`/`AT+TOGGLE`/
  /// `AT+RESTART`/`AT+BRIGH` on the legacy 5005 `J:` port when the Control API
  /// answers `unsupported_command`/`unknown_action`) is intentionally left out
  /// here. All current modules speak the Control API over the 5008 JSON port
  /// and must not be driven through the retired AT-command path.
  bool _applyResult(SoleuxJsonResponse response) => response.ok;
}
