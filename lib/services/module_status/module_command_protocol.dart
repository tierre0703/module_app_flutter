// lib/services/module_status/module_command_protocol.dart
//
// Uniform live-control surface for a module's TCP session, behind which the two
// wire protocols live:
//
//   - [ControlApiCommandProtocol] - the Soleux Control API (JSON envelope)
//     described in doc/Soleux_Control_API_Command_Specification_v0.3.md, the
//     ONLY protocol current modules speak, on the TCP Control API port (5008);
//   - [LegacyAtCommandProtocol]   - the legacy TCP AT protocol described in
//     doc/PROTOCOLS.md §1. DEPRECATED, never selected for a current module;
//     kept only for the staged removal of the legacy stack.
//
// [ModuleStatusService] controls modules exclusively through this interface, so
// adding a future transport (HTTP REST, MQTT, ...) only requires a new
// implementation - screens, scenario runner and the status service stay
// untouched.

/// The TCP command protocol a module speaks.
enum ModuleCommandProtocolKind {
  /// JSON Control API on the legacy TCP port + 3
  /// (doc/Soleux_Control_API_Command_Specification_v0.3.md "Transport mapping").
  controlApi,

  /// Legacy `AT+` ASCII commands on the legacy TCP port (doc/PROTOCOLS.md §1).
  ///
  /// DEPRECATED: current modules use only the Control API on port 5008. This
  /// value is never selected for a current module; it is retained so the
  /// remaining legacy AT files compile and can be removed in one follow-up.
  @Deprecated('The legacy AT protocol is no longer supported; use controlApi '
      '(TCP 5008). Retained only for the staged removal of the legacy stack.')
  legacyAt,
}

extension ModuleCommandProtocolKindX on ModuleCommandProtocolKind {
  /// Short stable identifier used for logging and diagnostics.
  String get label => switch (this) {
        ModuleCommandProtocolKind.controlApi => 'control-api',
        ModuleCommandProtocolKind.legacyAt => 'legacy-at',
      };
}

/// Live control surface implemented by every module command protocol.
abstract class ModuleCommandProtocol {
  /// Which wire protocol this implementation speaks.
  ModuleCommandProtocolKind get kind;

  /// Short stable name for logs/debug (e.g. `control-api`).
  String get name;

  /// True while the underlying TCP session is live.
  bool get isConnected;

  /// Reachability round-trip. The Control API uses `ping` (§1.2) and the
  /// legacy protocol uses `AT\r` (PROTOCOLS.md §1, command #1).
  Future<bool> ping();

  /// Turns one output on or off (zero-based channel). The Control API uses
  /// `set_output_state` (§4.3) replacing `AT+ON`/`AT+OFF` (commands #8/#9).
  Future<bool> setOutputState(int channel, bool on);

  /// Inverts one output state. The Control API uses `toggle_output` (§4.4)
  /// replacing `AT+TOGGLE` (command #7).
  Future<bool> toggleOutput(int channel);

  /// Cycles one output off and back on. The Control API uses `restart_output`
  /// (§4.5) replacing `AT+RESTART` (command #13).
  Future<bool> restartOutput(int channel);

  /// Sets a dimmer brightness percentage 0-100. The Control API uses
  /// `set_dimmer_level` (§6.3); the legacy path uses the reference `AT+BRIGH`
  /// command.
  Future<bool> setDimmerLevel(int channel, int brightnessPct);
}
