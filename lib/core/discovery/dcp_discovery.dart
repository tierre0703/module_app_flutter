// lib/core/discovery/dcp_discovery.dart
//
// Soleux Layer-2 (Ethernet) commissioning protocol, described in
// doc/Soleux-Network-Discovery-and-DCP.md §2. This is a custom DCP-like
// protocol: a Soleux JSON payload inside Ethernet frames with experimental
// EtherType 0x88B5. It is NOT wire-compatible with PROFINET DCP.
//
// It works without IPv4, can save a static IPv4 address, and can reboot a
// specifically targeted device. Frames stay inside the local broadcast domain.
//
// PLATFORM NOTE: sending/capturing raw Ethernet frames requires Npcap on
// Windows, CAP_NET_RAW on Linux, and is normally NOT exposed by Android/iOS
// sandboxes. Per the spec, a standard mobile app must NOT depend on DCP:
// it uses UDP discovery, and when a device has no usable IP it asks the user
// to commission it with the Windows Soleux tool (or a privileged helper).
// Failure to start DCP must never disable standard UDP discovery.
//
// This file therefore ships the wire encoding (builders + parsers, unit-test
// friendly) alongside a capability gate ([DcpSupport.available]) that reports
// whether a raw-Ethernet backend is present. The running app surfaces a
// "commission with the desktop tool" hint when DCP is unavailable.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../soleux/soleux_device_family.dart';
import '../soleux/soleux_heartbeat.dart' show SoleuxNonce;

/// EtherType of Soleux DCP frames, network byte order.
const int kSoleuxEtherType = 0x88B5;

/// Broadcast destination MAC for `identify` frames.
const String kDcpBroadcastMac = 'FF:FF:FF:FF:FF:FF';

/// Ethernet minimum frame size; payloads shorter than this get zero padding.
const int kEthernetMinimumFrameSize = 60;

/// Protocol operations in the Soleux L2 JSON envelope.
abstract final class DcpOperations {
  DcpOperations._();

  static const String identify = 'identify';
  static const String identity = 'identity';
  static const String setIpv4 = 'set_ipv4';
  static const String setResult = 'set_result';
  static const String reboot = 'reboot';
  static const String rebootResult = 'reboot_result';
}

/// Normalizes a MAC address to `AA:BB:CC:DD:EE:FF` uppercase, tolerating `:`
/// or `-` separators and mixed case. Returns null for malformed input.
String? normalizeMac(String mac) {
  final cleaned =
      mac.trim().toUpperCase().replaceAll('-', ':').replaceAll(' ', '');
  if (RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(cleaned)) {
    return cleaned;
  }
  // Also accept the 12-hex-digit bare form.
  if (RegExp(r'^[0-9A-F]{12}$').hasMatch(cleaned)) {
    return [for (var i = 0; i < 12; i += 2) cleaned.substring(i, i + 2)]
        .join(':');
  }
  return null;
}

/// Parses a `AA:BB:...` MAC string into a 6-byte big-endian list.
List<int> macToBytes(String mac) {
  final normalized = normalizeMac(mac);
  if (normalized == null) {
    throw ArgumentError.value(mac, 'mac', 'invalid MAC address');
  }
  return [for (final part in normalized.split(':')) int.parse(part, radix: 16)];
}

/// Builds and parses the JSON carried inside Soleux L2 frames.
abstract final class DcpMessage {
  DcpMessage._();

  /// `{ "soleux_l2": 1, "op": "identify", "nonce": ... }` - broadcast frame.
  static String identify({String? nonce}) => jsonEncode({
        'soleux_l2': 1,
        'op': DcpOperations.identify,
        'nonce': nonce ?? SoleuxNonce.generate(),
      });

  /// `{ ..., "op": "set_ipv4", "target": <mac>, "ip": ..., "mask": ...,
  /// "gateway": ... }` - unicast frame to the device MAC.
  static String setIpv4({
    required String targetMac,
    required String ip,
    required String mask,
    required String gateway,
    String? nonce,
  }) =>
      jsonEncode({
        'soleux_l2': 1,
        'op': DcpOperations.setIpv4,
        'nonce': nonce ?? SoleuxNonce.generate(),
        'target': normalizeMac(targetMac),
        'ip': ip,
        'mask': mask,
        'gateway': gateway,
      });

  /// `{ ..., "op": "reboot", "target": <mac> }` - unicast frame.
  static String reboot({
    required String targetMac,
    String? nonce,
  }) =>
      jsonEncode({
        'soleux_l2': 1,
        'op': DcpOperations.reboot,
        'nonce': nonce ?? SoleuxNonce.generate(),
        'target': normalizeMac(targetMac),
      });
}

/// Parsed L2 protocol JSON (any operation).
class DcpFrame {
  final String op;
  final String nonce;
  final Map<String, dynamic> fields;

  const DcpFrame({required this.op, required this.nonce, required this.fields});

  /// Decodes a raw frame payload (zero padding already removed). Returns null
  /// for non-protocol or malformed payloads.
  static DcpFrame? parsePayload(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['soleux_l2'] != 1) return null;
    final op = decoded['op'];
    if (op is! String) return null;
    return DcpFrame(
      op: op,
      nonce: decoded['nonce'] as String? ?? '',
      fields: Map<String, dynamic>.from(decoded),
    );
  }
}

/// A decoded `identity` response.
class DcpIdentity {
  final String nonce;
  final String? guid;
  final String mac;
  final String name;
  final String serial;
  final String firmware;
  final int port;
  final String ip;
  final String mask;
  final String gateway;

  const DcpIdentity({
    required this.nonce,
    this.guid,
    required this.mac,
    this.name = '',
    this.serial = '',
    this.firmware = '',
    this.port = SoleuxConstants.defaultCommandPort,
    this.ip = '0.0.0.0',
    this.mask = '0.0.0.0',
    this.gateway = '0.0.0.0',
  });

  /// The device family reported by `guid`, when known.
  SoleuxDeviceFamily? get family => SoleuxDeviceFamilies.fromGuid(guid);

  /// True when the device reports no usable IPv4 address (must be commissioned
  /// over DCP before it can be opened over TCP).
  bool get hasUsableIp => !_isZero(ip);

  static bool _isZero(String value) => value == '0.0.0.0' || value.isEmpty;

  factory DcpIdentity.fromFrame(DcpFrame frame) {
    final fields = frame.fields;
    return DcpIdentity(
      nonce: frame.nonce,
      guid: fields['guid'] as String?,
      mac: fields['mac'] as String? ?? '',
      name: fields['name'] as String? ?? '',
      serial: fields['serial'] as String? ?? '',
      firmware: fields['firmware'] as String? ?? '',
      port: fields['port'] is num
          ? (fields['port'] as num).toInt()
          : SoleuxConstants.defaultCommandPort,
      ip: fields['ip'] as String? ?? '0.0.0.0',
      mask: fields['mask'] as String? ?? '0.0.0.0',
      gateway: fields['gateway'] as String? ?? '0.0.0.0',
    );
  }
}

/// A decoded acknowledgement (`set_result` / `reboot_result`).
class DcpResult {
  final String op;
  final bool ok;
  final String message;

  const DcpResult({required this.op, required this.ok, this.message = ''});

  factory DcpResult.fromFrame(DcpFrame frame) {
    final status = frame.fields['status'] as String?;
    return DcpResult(
      op: frame.op,
      ok: status == 'ok',
      message: frame.fields['message'] as String? ?? '',
    );
  }
}

/// Assembles a raw Ethernet frame carrying a Soleux L2 JSON payload.
class DcpFrameBuilder {
  /// Minimum frame size; shorter payloads are zero-padded.
  final int minimumFrameSize;

  const DcpFrameBuilder({this.minimumFrameSize = kEthernetMinimumFrameSize});

  /// Builds the frame bytes: 6-byte dst MAC, 6-byte src MAC, 2-byte EtherType
  /// (0x88B5, network byte order), then the UTF-8 JSON payload, zero-padded to
  /// [minimumFrameSize].
  List<int> build({
    required String destinationMac,
    required String sourceMac,
    required String jsonPayload,
  }) {
    final header = <int>[
      ...macToBytes(destinationMac),
      ...macToBytes(sourceMac),
      (kSoleuxEtherType >> 8) & 0xFF,
      kSoleuxEtherType & 0xFF,
    ];
    final body = utf8.encode(jsonPayload);
    final payloadLength = header.length + body.length;
    final padded =
        payloadLength < minimumFrameSize ? minimumFrameSize - payloadLength : 0;
    return [...header, ...body, ...List<int>.filled(padded, 0)];
  }
}

/// Whether raw-Ethernet DCP is usable from this process.
abstract final class DcpSupport {
  DcpSupport._();

  /// A platform channel the native side can expose when a
  /// raw-socket/Npcap backend is linked in. No native implementation is
  /// currently wired up, so this always reports false.
  static const MethodChannel _rawSocketChannel =
      MethodChannel('soleux.device_manager/raw_eth');

  static bool? _resolved;

  /// True when a privileged raw-Ethernet backend is present and usable.
  /// On stock Android/iOS (and Flutter without a native helper) this is false;
  /// callers must then keep UDP discovery alive and direct the user to a
  /// commissioning tool. Never throws.
  static Future<bool> available() async {
    if (_resolved != null) return _resolved!;
    if (kIsWeb) return false;
    // Only Windows/Npcap-backed builds would resolve a native handler today.
    // Absent a registration, probe the channel: an unimplemented channel
    // throws MissingPluginException -> false.
    try {
      final ok =
          await _rawSocketChannel.invokeMethod<bool>('isAvailable') ?? false;
      _resolved = ok;
    } catch (e, st) {
      debugPrint('DcpSupport: raw ethernet backend unavailable: $e\n$st');
      _resolved = false;
    }
    return _resolved!;
  }

  /// Short reason a platform cannot run DCP (shown in the commissioning UI).
  static String unavailableReason() {
    if (Platform.isAndroid || Platform.isIOS) {
      return 'Mobile sandboxes do not expose raw Ethernet frames; use the '
          'Windows Soleux tool (or a privileged commissioning helper) to '
          'assign an address.';
    }
    if (Platform.isWindows) {
      return 'Raw Ethernet requires the Npcap runtime; it is not loaded.';
    }
    if (Platform.isLinux) {
      return 'Raw Ethernet requires root / CAP_NET_RAW.';
    }
    return 'This platform does not expose raw Ethernet frames.';
  }
}
