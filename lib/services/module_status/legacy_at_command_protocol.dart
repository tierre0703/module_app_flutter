// lib/services/module_status/legacy_at_command_protocol.dart
//
// DEPRECATED — legacy TCP AT protocol (doc/PROTOCOLS.md §1). Current modules
// speak only the Control API (JSON) on port 5008; this class is never selected
// by a production path any more and is retained solely so the legacy `AT+` stack
// can be deleted in one follow-up step.
//
// [ModuleCommandProtocol] implementation over the legacy TCP AT protocol.
// Commands end with `\r`; success is a `\r\nOK\r\n` terminator.
//
// Control mapping (see PROTOCOLS.md §1 command table):
//   - set on/off   -> AT+ON:<pin> / AT+OFF:<pin>   (commands #8 / #9)
//   - toggle       -> AT+TOGGLE:<pin>              (command #7)
//   - restart      -> AT+RESTART:<pin>             (command #13)
//   - ping         -> AT                           (command #1)
//
// Dimmer brightness has no PROTOCOLS.md entry; the reference web app uses
// `AT+BRIGH:<pin>:<level>`.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'module_command_protocol.dart';
import 'module_command_service.dart';

@Deprecated('The legacy AT protocol is no longer supported; the Control API '
    '(TCP 5008) is the only protocol. Retained for the staged removal.')
class LegacyAtCommandProtocol implements ModuleCommandProtocol {
  final ModuleCommandService _service;

  LegacyAtCommandProtocol(this._service);

  @override
  ModuleCommandProtocolKind get kind => ModuleCommandProtocolKind.legacyAt;

  @override
  String get name => 'legacy-at';

  @override
  bool get isConnected => _service.isConnected;

  @override
  Future<bool> ping() async {
    try {
      return await _service.ping();
    } catch (e, st) {
      debugPrint('LegacyAtCommandProtocol: ping failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> setOutputState(int channel, bool on) async {
    try {
      return on
          ? await _service.turnOnRelay(channel)
          : await _service.turnOffRelay(channel);
    } catch (e, st) {
      debugPrint('LegacyAtCommandProtocol: set_output_state($channel, $on) '
          'failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> toggleOutput(int channel) async {
    try {
      return await _service.toggleRelay(channel);
    } catch (e, st) {
      debugPrint('LegacyAtCommandProtocol: toggle_output($channel) failed: '
          '$e\n$st');
      return false;
    }
  }

  @override
  Future<bool> restartOutput(int channel) async {
    try {
      return await _service.restartRelay(channel);
    } catch (e, st) {
      debugPrint('LegacyAtCommandProtocol: restart_output($channel) failed: '
          '$e\n$st');
      return false;
    }
  }

  @override
  Future<bool> setDimmerLevel(int channel, int brightnessPct) async {
    try {
      return await _service.command('AT+BRIGH:$channel:$brightnessPct\r');
    } catch (e, st) {
      debugPrint('LegacyAtCommandProtocol: set_dimmer_level($channel, '
          '$brightnessPct) failed: $e\n$st');
      return false;
    }
  }
}
