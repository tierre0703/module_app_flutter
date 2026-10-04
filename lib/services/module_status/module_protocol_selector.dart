// lib/services/module_status/module_protocol_selector.dart
//
// Pure policy for choosing the TCP command protocol of a module - the single
// source of truth for the migration boundary described in
// doc/Soleux_Control_API_Command_Specification_v0.3.md:
//
//   - firmware >= 7.12 (the Control API release gate) -> controlApi;
//   - firmware <  7.12                                -> legacyAt;
//   - unknown / unparseable firmware                  -> falls back to the
//     transport the module advertised during discovery (Control API port /
//     version / capabilities), else legacy AT, and is NOT pinned so the status
//     service can probe for the protocol the device actually speaks.
//
// Pinned selections are authoritative: a 7.12+ module is never spoken to with
// AT, and a pre-7.12 module is never spoken to with Control API JSON.
//
// Dimmer modules are the exception: per the spec "Implemented AC/DC Dimmer
// profile", the active dimmer firmware exposes the protocol 2 command subset
// on the Control API port (5008 by default) independently of the relay >= 7.12
// gate, so a dimmer's version string must never pin it to legacy AT. Dimmers
// are always left probeable and reach the 5008 Control API first.
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
  ModuleProtocolDecision decide(DeviceModule module) {
    // Dimmers are a Control API device family (spec v0.3 "Implemented AC/DC
    // Dimmer profile"): their active firmware answers the protocol 2 JSON on
    // the Control API port (5008 by default) regardless of the relay >= 7.12
    // release gate, so a dimmer's own (non-relay) version string must not pin
    // it to legacy AT. Keep the choice probeable so the status service probes
    // 5008 first and only falls back to AT for genuinely pre-Control-API
    // units.
    if (_isDimmerFamily(module)) {
      return ModuleProtocolDecision(
        kind: module.isControlApiAdvertised
            ? ModuleCommandProtocolKind.controlApi
            : ModuleCommandProtocolKind.legacyAt,
        pinned: false,
      );
    }

    final fromFirmware = decideForFirmware(module.firmware);
    if (fromFirmware != null) return fromFirmware;

    // Unknown or unparseable firmware: trust discovery advertisement when the
    // device announced the Control API transport; otherwise default to the
    // legacy AT protocol as the probe starting point.
    return ModuleProtocolDecision(
      kind: module.isControlApiAdvertised
          ? ModuleCommandProtocolKind.controlApi
          : ModuleCommandProtocolKind.legacyAt,
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
