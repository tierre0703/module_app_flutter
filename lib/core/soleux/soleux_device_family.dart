// lib/core/soleux/soleux_device_family.dart
//
// Soleux device-family registry shared by every protocol client in the app.
// It mirrors the identity and constants tables in:
//
//   - doc/Soleux-Network-Discovery-and-DCP.md          (discovery GUIDs)
//   - doc/Soleux-Mobile-TCP-Protocol.md                (JSON `hello` device)
//
// A Soleux device reports two identities on the wire:
//
//   - a family GUID during UDP discovery / DCP identity
//     (`GUID:` field, doc/Soleux-Network-Discovery-and-DCP.md §1);
//   - a JSON `device` value in the `J:` `hello` response
//     (doc/Soleux-Mobile-TCP-Protocol.md, JSON protocol section).
//
// The GUID identifies a device family; the serial number and Ethernet MAC
// identify an individual physical device.
library;

import '../../models/models.dart';

/// The five Soleux device families supported by the firmware.
enum SoleuxDeviceFamily {
  relayModule,
  dimmer,
  pduEnergyMeter,
  pdu10kw,
  pduV1;

  /// The family's discovery GUID (doc/Soleux-Network-Discovery-and-DCP.md,
  /// "Device identities" table).
  String get guid => switch (this) {
        SoleuxDeviceFamily.relayModule =>
          '579E6EA1-2F64-4CDE-8190-1CD3646EFAA1',
        SoleuxDeviceFamily.dimmer => 'C47A5A88-03E8-4EC0-9F2D-67A6C43F0D91',
        SoleuxDeviceFamily.pduEnergyMeter =>
          '56EC974B-1C9F-48C3-B438-BFE976593072',
        SoleuxDeviceFamily.pdu10kw => 'A728DD7D-0DEB-49B9-9B8B-A4556771815F',
        SoleuxDeviceFamily.pduV1 => 'B4A6B160-0CBA-4BD8-873D-EDC9DF895C26',
      };

  /// The JSON `hello` `device` value
  /// (doc/Soleux-Mobile-TCP-Protocol.md, Discovery table).
  String get jsonDevice => switch (this) {
        SoleuxDeviceFamily.relayModule => 'relay_module',
        SoleuxDeviceFamily.dimmer => 'dimmer',
        SoleuxDeviceFamily.pduEnergyMeter => 'pdu_energy_meter',
        SoleuxDeviceFamily.pdu10kw => 'pdu_10kw',
        SoleuxDeviceFamily.pduV1 => 'pdu_v1',
      };

  /// A human-readable family label (used in the Configuration list).
  String get label => switch (this) {
        SoleuxDeviceFamily.relayModule => 'Relay Module',
        SoleuxDeviceFamily.dimmer => 'AC/DC Dimmer',
        SoleuxDeviceFamily.pduEnergyMeter => 'PDU Energy Meter',
        SoleuxDeviceFamily.pdu10kw => 'PDU 10 kW',
        SoleuxDeviceFamily.pduV1 => 'PDU V1.0',
      };

  /// The generic app module type a freshly discovered unit should be seeded
  /// as. The JSON `hello`/configuration can refine this later.
  ModuleType get defaultModuleType => switch (this) {
        SoleuxDeviceFamily.relayModule => ModuleType.relay,
        SoleuxDeviceFamily.dimmer => ModuleType.dimmerDc,
        SoleuxDeviceFamily.pduEnergyMeter => ModuleType.relay,
        SoleuxDeviceFamily.pdu10kw => ModuleType.relay,
        SoleuxDeviceFamily.pduV1 => ModuleType.relay,
      };

  /// Whether the family exposes live energy metering
  /// (`AT+GETENERGY` / legacy `OVERRIDE` paths).
  bool get hasEnergyMeter => switch (this) {
        SoleuxDeviceFamily.pduEnergyMeter ||
        SoleuxDeviceFamily.pdu10kw ||
        SoleuxDeviceFamily.pduV1 =>
          true,
        _ => false,
      };

  /// Whether the family still answers legacy `AT+...` control commands.
  /// All five families do; PDU V1.0 is the strictest (documented subset).
  bool get supportsLegacyAt => true;
}

/// Protocol-wide Soleux constants
/// (doc/Soleux-Network-Discovery-and-DCP.md §1, §3).
abstract final class SoleuxConstants {
  SoleuxConstants._();

  /// UDP discovery-request identity, sent in every discovery broadcast.
  static const String discoveryGuid = '8C93472D-2EF0-4B82-BE96-4FBBED57783F';

  /// Discovery protocol version carried in the broadcast request.
  static const String discoveryVersion = '2.0';

  /// Well-known UDP port every Soleux device listens on for discovery.
  static const int discoveryPort = 8000;

  /// Default/typical TCP command HostPort (the Control API port).
  static const int defaultCommandPort = 5008;

  /// Well-known UDP heartbeat port every Soleux device listens on.
  static const int defaultHeartbeatPort = 5007;

  /// Maximum length of a heartbeat (or DCP) nonce, per the discovery spec.
  static const int maxNonceLength = 64;

  /// The UDP heartbeat port to ping. The migration removed the legacy
  /// `HostPort + 2` derivation: heartbeat is a fixed well-known port
  /// (default 5007) independent of the TCP command port.
  static int heartbeatPort(int tcpPort) => defaultHeartbeatPort;
}

/// Lookup helpers for the family registry.
abstract final class SoleuxDeviceFamilies {
  SoleuxDeviceFamilies._();

  static final Map<String, SoleuxDeviceFamily> _byGuid = {
    for (final family in SoleuxDeviceFamily.values) family.guid: family,
  };

  static final Map<String, SoleuxDeviceFamily> _byJsonDevice = {
    for (final family in SoleuxDeviceFamily.values) family.jsonDevice: family,
  };

  /// Resolves the family from a discovery/DCP `GUID` value. Case-insensitive;
  /// returns null for unknown GUIDs (forward compatibility).
  static SoleuxDeviceFamily? fromGuid(String? guid) {
    if (guid == null || guid.isEmpty) return null;
    return _byGuid[guid.trim().toUpperCase()];
  }

  /// Resolves the family from a JSON `hello` `device` value.
  static SoleuxDeviceFamily? fromJsonDevice(String? device) {
    if (device == null || device.isEmpty) return null;
    return _byJsonDevice[device.trim().toLowerCase()];
  }

  /// All known family GUIDs, lower-cased (for logging/dedup keys).
  static Set<String> get knownGuids => _byGuid.keys.toSet();
}
