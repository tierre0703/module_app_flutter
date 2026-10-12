// lib/services/module_status/module_protocol_selector.dart
//
// Pure policy for choosing the TCP command protocol of a module.
//
// Current modules speak ONLY the Soleux Control API (JSON envelope) on the TCP
// Control API port (5008). The legacy `AT+` protocol (doc/PROTOCOLS.md §1) is
// DEPRECATED and no longer selected for any current module; the branch that
// still returns [ModuleCommandProtocolKind.legacyAt] for pre-7.12 firmware is
// retained only so the remaining legacy files compile and can be deleted in a
// single follow-up step.
//
// Policy today:
//   - firmware >= 7.12 (the Control API release gate) -> controlApi;
//   - firmware <  7.12                                -> retained legacyAt
//     (deprecated; no such module is supported by the app);
//   - unknown / unparseable firmware                  -> controlApi, not
//     pinned, so the status service probes the 5008 Control API.
//
// Dimmer modules are a Control API family: per the spec "Implemented AC/DC
// Dimmer profile", the active dimmer firmware exposes the protocol 2 command
// subset on the Control API port (5008 by default) independently of the relay
// >= 7.12 gate, so a dimmer's version string must never pin it to legacy AT.
import '../../core/soleux/soleux_firmware_version.dart';
import '../../models/models.dart';
import 'module_command_protocol.dart';

/// The chosen wire protocol plus whether the choice is authoritative.
class ModuleProtocolDecision {
  /// The wire protocol to use.
  final ModuleCommandProtocolKind kind;

  /// True when [kind] is forced by a known firmware version. Pinned selections
  /// must not be probed or fallbacked across the boundary.
  final bool pinned;

  const ModuleProtocolDecision({required this.kind, required this.pinned});

  @override
  String toString() => 'ModuleProtocolDecision(${kind.label}, pinned: $pinned)';
}

/// Selects the [ModuleCommandProtocolKind] for a module.
class ModuleProtocolSelector {
  const ModuleProtocolSelector();

  /// Resolves the protocol for [module] per the firmware/discovery policy.
  ///
  /// [ModuleCommandProtocolKind.legacyAt] is a deprecated result: current
  /// modules always resolve to [ModuleCommandProtocolKind.controlApi] (5008).
  ModuleProtocolDecision decide(DeviceModule module) {
    // Dimmers are a Control API device family (spec v0.3 "Implemented AC/DC
    // Dimmer profile"): their active firmware answers the protocol 2 JSON on
    // the Control API port (5008 by default) regardless of the relay >= 7.12
    // release gate, so a dimmer's own (non-relay) version string must not pin
    // it to the deprecated legacy AT protocol.
    if (_isDimmerFamily(module)) {
      return const ModuleProtocolDecision(
        kind: ModuleCommandProtocolKind.controlApi,
        pinned: false,
      );
    }

    final fromFirmware = decideForFirmware(module.firmware);
    if (fromFirmware != null) return fromFirmware;

    // Unknown or unparseable firmware: the Control API is the only supported
    // protocol, so it is the probe starting point.
    return const ModuleProtocolDecision(
      kind: ModuleCommandProtocolKind.controlApi,
      pinned: false,
    );
  }

  /// A lighting dimmer module (DC PWM or AC phase-cut) - the
  /// [SoleuxDeviceFamily.dimmer] family.
  bool _isDimmerFamily(DeviceModule module) =>
      module.type == ModuleType.dimmerDc || module.type == ModuleType.dimmerAc;

  /// Distinguishes between a pinned controlApi / legacyAt for a *known*
  /// firmware version. Returns null when the firmware is unknown or
  /// unparseable, leaving the caller free to probe.
  ///
  /// The pre-7.12 branch is deprecated: legacy `AT+` modules are no longer
  /// supported (see the file header).
  ModuleProtocolDecision? decideForFirmware(String? firmware) {
    final version = SoleuxFirmwareVersion.tryParse(firmware);
    if (version == null) return null;
    return ModuleProtocolDecision(
      kind: version.supportsControlApi
          ? ModuleCommandProtocolKind.controlApi
          : ModuleCommandProtocolKind.legacyAt,
      pinned: true,
    );
  }
}
