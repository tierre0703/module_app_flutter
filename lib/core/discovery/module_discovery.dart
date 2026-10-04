// lib/core/discovery/module_discovery.dart
//
// Implements the Soleux UDP discovery protocol described in
// doc/Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §1
// (protocol version 2.0):
//
//  1. The app broadcasts a JSON request to UDP port 8000:
//       { "GUID": "8C93472D-2EF0-4B82-BE96-4FBBED57783F",
//         "VER": "2.0",
//         "PORT": <client_tcp_port>,
//         "CLIENT": "Soleux Device Manager",
//         "WANT": ["MAC","API_PORT","HEARTBEAT_PORT","API_VER"] }
//  2. Each Soleux device validates the GUID, dedups the broadcast, and opens a
//     NEW TCP connection back to the app's IP on the advertised callback
//     <client_tcp_port>.
//  3. Over that TCP connection the device sends its identity response:
//       GUID:<family-guid>
//       VER:<firmware>
//       PORT:<tcp_port>
//       SN:<serial_number>
//       NAME:<app_name>
//       MAC:<mac>              (additive)
//       API_PORT:<5008>        (additive)
//       HEARTBEAT_PORT:<5007>  (additive)
//       API_VER:<3>            (additive)
//       CAPS:control_api_v3,heartbeat,l2  (additive)
//
// The TCP peer address is authoritative for the device IP; unknown fields are
// ignored for forward compatibility. Clients parse fields by name (not line
// order) and never trust a separately reported IP more than the peer address.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/module_store.dart';
import '../logger/network_debug_logger.dart';
import '../soleux/soleux_device_family.dart';
import 'dcp_discovery.dart' show normalizeMac;

/// Platform channel for the Android WifiManager.MulticastLock (see
/// MainActivity.kt). WiFi NICs filter out broadcast/multicast traffic unless
/// the app holds this lock, which silently kills device discovery on Android
/// phones. No-op on every other platform.
const MethodChannel _androidWifiLock =
    MethodChannel('soleux.device_manager/wifi_lock');

/// The identity fields a responding device reports during discovery
/// (doc/Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §1.2).
class DiscoveredModule {
  /// Device-family GUID (spec §1.2 identity table). Distinct from the app's
  /// discovery-request GUID.
  final String guid;

  /// Installed device firmware version.
  final String version;

  /// TCP command HostPort returned by the device.
  final int tcpPort;

  /// Device serial number (identifies an individual physical device).
  final String serial;

  /// User-configured device name.
  final String name;

  /// Device IPv4 address (the TCP callback peer address).
  final String ip;

  /// Ethernet MAC address when advertised (additive; authoritative value is
  /// the frame source).
  final String? mac;

  /// Control API v3 TCP port when advertised (additive, normally 5008).
  final int? apiPort;

  /// Highest advertised Control API version (additive, current 3).
  final int? apiVersion;

  /// Advertised UDP heartbeat port (additive, normally 5007). When absent the
  /// monitor uses the fixed well-known heartbeat port (5007).
  final int? advertisedHeartbeatPort;

  /// Compact advertised capability identifiers (additive), e.g.
  /// `control_api_v3`, `heartbeat`, `l2`.
  final List<String> caps;

  /// Resolved [SoleuxDeviceFamily] from [guid], or null when unknown.
  final SoleuxDeviceFamily? family;

  /// UDP heartbeat port for reachability checks: the advertised
  /// HEARTBEAT_PORT when present, otherwise the fixed well-known heartbeat
  /// port (5007).
  int get heartbeatPort =>
      advertisedHeartbeatPort ?? SoleuxConstants.heartbeatPort(tcpPort);

  /// True when this record carries a usable peer IPv4 address and at least one
  /// usable control endpoint (spec §1.2 `connectable`).
  bool get connectable {
    final peer = InternetAddress.tryParse(ip);
    if (peer == null || peer.type != InternetAddressType.IPv4) return false;
    return apiPort != null || tcpPort > 0;
  }

  const DiscoveredModule({
    required this.guid,
    required this.version,
    required this.tcpPort,
    required this.serial,
    required this.name,
    required this.ip,
    this.mac,
    this.apiPort,
    this.apiVersion,
    this.advertisedHeartbeatPort,
    this.caps = const [],
    this.family,
  });

  /// Stable identity key used for deduplication (spec §3.1 merge priority).
  ///
  /// Preference order: stable serial number, then normalized Ethernet MAC,
  /// then family GUID plus observed IPv4 plus legacy TCP port.
  String get dedupeKey {
    if (serial.isNotEmpty) return 'sn:$serial';
    final normalizedMac = normalizeMac(mac ?? '');
    if (normalizedMac != null) return 'mac:$normalizedMac';
    return 'ip:$guid@$ip:$tcpPort';
  }

  /// Parses a `KEY:value` identity response (one value per line), matched by
  /// field name rather than line order. Unknown fields are ignored for
  /// forward compatibility. Exposed for tests and alternative transports.
  static DiscoveredModule? parseIdentityResponse(String text, String ip) {
    if (text.isEmpty) return null;
    final map = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]'))) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toUpperCase();
      final value = line.substring(idx + 1).trim();
      if (value.isNotEmpty) map[key] = value;
    }
    if (map['GUID'] == null) return null;
    // `PORT` is the canonical field; PDU V1.0 also answers legacy `Port`.
    final portRaw = map['PORT'] ?? map['Port'];
    final guid = map['GUID']!;
    return DiscoveredModule(
      guid: guid,
      version: map['VER'] ?? '',
      tcpPort:
          int.tryParse(portRaw ?? '') ?? SoleuxConstants.defaultCommandPort,
      serial: map['SN'] ?? '',
      name: map['NAME'] ?? '',
      ip: ip,
      mac: map['MAC'],
      apiPort: int.tryParse(map['API_PORT'] ?? ''),
      apiVersion: int.tryParse(map['API_VER'] ?? ''),
      advertisedHeartbeatPort: int.tryParse(map['HEARTBEAT_PORT'] ?? ''),
      caps: _parseCaps(map['CAPS']),
      family: SoleuxDeviceFamilies.fromGuid(guid),
    );
  }

  /// Splits a `CSV`/`string[]` capability value into compact identifiers.
  /// Malformed or empty values yield an empty list (additive, never fatal).
  static List<String> _parseCaps(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return [
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim().toLowerCase(),
    ];
  }
}

/// Sends the UDP discovery broadcast and collects PDU identity responses.
///
/// Simple implementation: bound to a fresh local TCP listener, broadcasts the
/// request, then accepts the inbound identity connections until [timeout].
class ModuleDiscovery {
  /// Broadcast request target port (doc §1): UDP 8000.
  static const int discoveryPort = SoleuxConstants.discoveryPort;

  /// Client-side discovery-request identity expected by every device.
  static const String requestGuid = SoleuxConstants.discoveryGuid;

  /// Discovery protocol version carried in the broadcast request.
  static const String requestVersion = SoleuxConstants.discoveryVersion;

  /// Additive client name sent for diagnostics (spec §1.1 `CLIENT`).
  static const String requestClientName = 'Soleux Device Manager';

  /// Additive fields requested from responding devices (spec §1.1 `WANT`).
  /// Devices may ignore the list entirely.
  static const List<String> requestedFields = [
    'MAC',
    'API_PORT',
    'HEARTBEAT_PORT',
    'API_VER',
  ];

  /// Legacy global broadcast address; sent alongside per-subnet broadcasts.
  static const _globalBroadcast = '255.255.255.255';

  /// How long to keep listening for identity responses after broadcasting.
  static const Duration defaultTimeout = Duration(seconds: 4);

  /// Number of times each broadcast target is pinged.
  static const int _broadcastRepetitions = 3;

  /// Encodes the UDP discovery request for [callbackPort] (spec §1.1).
  ///
  /// `PORT` is an `integer|string` in the range 1-65535; it is sent as an
  /// integer per the canonical example payload. `CLIENT` and `WANT` are
  /// additive diagnostics that devices must ignore when unrecognized.
  static String buildRequestPayload(int callbackPort) => jsonEncode({
        'GUID': requestGuid,
        'VER': requestVersion,
        'PORT': callbackPort,
        'CLIENT': requestClientName,
        'WANT': requestedFields,
      });

  /// Broadcasts the discovery request and returns every PDU that answers.
  Future<List<DiscoveredModule>> discover({
    Duration timeout = defaultTimeout,
  }) async {
    final results = <DiscoveredModule>[];
    if (timeout.inMilliseconds <= 0) return results;

    // On Android this guarantees the runtime nearby-devices grant and holds a
    // WifiManager.MulticastLock (see _prepareAndroidDiscovery for why).
    await _prepareAndroidDiscovery();
    try {
      // Advertise a fresh TCP listener; PDUs dial back into this port.
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);

      server.listen((socket) {
        _readIdentity(socket, results);
      }, onError: (err) {
        debugPrint(
            'ModuleDiscovery: error occurred while listening for identity responses: $err');
      });

      final localPort = server.port;
      // Broadcast and keep the listener accepting identity responses for the
      // full timeout window (_broadcast awaits the timeout), then close.
      await _broadcast(localPort, timeout);
      await server.close();
    } catch (e, st) {
      debugPrint('ModuleDiscovery: discovery pass failed: $e\n$st');
      rethrow;
    } finally {
      await _releaseAndroidWifiLock();
    }
    return results;
  }

  /// On Android: grants the runtime `NEARBY_WIFI_DEVICES` permission (Android
  /// 13+ requires it; from Android 14 `WifiManager.createMulticastLock` throws
  /// a `SecurityException` without it) and then holds a `WifiManager.MulticastLock`
  /// - without the lock the NIC filters the broadcast/multicast frames that
  /// carry discovery. Best-effort: failures are logged, never fatal, so
  /// discovery still proceeds (and may work on forgiving networks).
  static Future<void> _prepareAndroidDiscovery() async {
    if (!Platform.isAndroid) return;
    // Android 16 blocks all local network traffic without the runtime grant;
    // without it the UDP discovery broadcast never leaves the phone.
    try {
      await _androidWifiLock.invokeMethod('requestLocalNetworkPermission');
    } catch (e, st) {
      debugPrint('ModuleDiscovery: local network permission request failed: '
          '$e\n$st');
    }
    try {
      await _androidWifiLock.invokeMethod('requestNearbyWifiPermission');
    } catch (e, st) {
      debugPrint('ModuleDiscovery: nearby wifi permission request failed: '
          '$e\n$st');
    }
    try {
      await _androidWifiLock.invokeMethod('acquire');
    } catch (e, st) {
      debugPrint('ModuleDiscovery: wifi lock acquire failed: $e\n$st');
    }
  }

  static Future<void> _releaseAndroidWifiLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _androidWifiLock.invokeMethod('release');
    } catch (e, st) {
      debugPrint('ModuleDiscovery: wifi lock release failed: $e\n$st');
    }
  }

  Future<void> _broadcast(int localTcpPort, Duration timeout) async {
    final udp = await _bindBroadcastSocket();
    final targets = await _broadcastTargets(timeout);
    final request = buildRequestPayload(localTcpPort);
    final payload = utf8.encode(request);
    NetworkDebugLogger.outbound('udp', 'broadcast:$discoveryPort', request);

    for (final target in targets) {
      for (var i = 0; i < _broadcastRepetitions; i++) {
        udp.send(payload, target, discoveryPort);
      }
    }

    await Future<void>.delayed(timeout);
    udp.close();
  }

  /// On Android, binds the broadcast socket to the Wi-Fi interface IPv4 address
  /// so the datagram egresses over Wi-Fi with a LAN-reachable source IP (PDUs
  /// dial back to that source). A socket on 0.0.0.0 can instead be routed via
  /// the cellular default network, whose source address no LAN device can
  /// reach - which is why discovery works on Windows (single NIC) but silently
  /// finds nothing on a phone with mobile data active. Falls back to 0.0.0.0
  /// when the address is unknown or the bind fails.
  static Future<RawDatagramSocket> _bindBroadcastSocket() async {
    final local = await _localIPv4Address();
    if (local != null) {
      try {
        final socket = await RawDatagramSocket.bind(InternetAddress(local), 0);
        socket.broadcastEnabled = true;
        return socket;
      } catch (e, st) {
        debugPrint('ModuleDiscovery: binding broadcast socket to $local failed '
            '(falling back to 0.0.0.0): $e\n$st');
      }
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    return socket;
  }

  /// First usable non-loopback IPv4 address, preferring Wi-Fi / Ethernet
  /// interfaces. Only meaningful on Android; returns null elsewhere or when no
  /// IPv4 lease is available (e.g. while on cellular).
  static Future<String?> _localIPv4Address() async {
    if (!Platform.isAndroid) return null;
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name == 'lo' ||
            name.startsWith('tun') ||
            name.startsWith('dummy') ||
            name.startsWith('p2p')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final ip = addr.address;
          if (addr.isLoopback ||
              ip.startsWith('127.') ||
              ip.startsWith('169.254.') ||
              ip.startsWith('0.')) {
            continue;
          }
          return ip;
        }
      }
    } catch (e, st) {
      debugPrint('ModuleDiscovery: listing local IPv4 addresses failed: '
          '$e\n$st');
    }
    return null;
  }

  /// Directs broadcasts at the global address plus a directed broadcast for
  /// every IPv4 interface, so we reach PDUs on the active LAN. Also unicasts
  /// the discovery request to every already-known module IP: some access
  /// points filter broadcasts (client isolation / VLANs) while direct unicast
  /// to a known LAN address still gets through.
  Future<List<InternetAddress>> _broadcastTargets(Duration timeout) async {
    final result = <InternetAddress>{
      InternetAddress(_globalBroadcast),
    };
    try {
      final interfaces = await NetworkInterface.list().timeout(timeout);
      // Real per-interface netmasks; unknown masks fall back
      // to the /24 assumption with the global broadcast as insurance.
      final netmasks = await _maskByInterface();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          result
              .add(directedSubnetBroadcast(addr.address, netmasks[iface.name]));
        }
      }
    } catch (e, st) {
      debugPrint('ModuleDiscovery: enumerating broadcast interfaces failed '
          '(falling back to global broadcast): $e\n$st');
    }
    try {
      await ModuleStore.shared.init();
      for (final module in ModuleStore.shared.modules) {
        final ip = InternetAddress.tryParse(module.ipAddress);
        if (ip != null && ip.type == InternetAddressType.IPv4) {
          result.add(ip);
        }
      }
    } catch (e, st) {
      debugPrint('ModuleDiscovery: loading known modules for unicast '
          'requests failed: $e\n$st');
    }
    return result.toList();
  }

  /// Resolves the IPv4 subnet mask for each local interface, keyed by
  /// interface name.
  ///
  /// Android cannot read `/proc/net/route` (SELinux denies `getattr` on
  /// `proc_net` for `untrusted_app`, which surfaces as an `avc: denied`
  /// violation in logcat), so the active interface's prefix length is obtained
  /// from `ConnectivityManager` via the native platform channel
  /// (`soleux.device_manager/wifi_lock`, `ipv4LinkInfo`). On other platforms
  /// (Linux desktop) the routing table is still parsed from `/proc/net/route`;
  /// any failure falls back to the /24 assumption.
  static Future<Map<String, int>> _maskByInterface() async {
    if (Platform.isAndroid) {
      return _androidNetmasks();
    }
    return _linuxProcNetmasks();
  }

  /// Android: reads `interface` / `ip` / `prefix` for the active network from
  /// the platform channel; converts the prefix length to a big-endian /proc
  /// style 32-bit mask (e.g. /24 => `0xFFFFFF00`). Returns an empty map when
  /// the channel is unavailable or the network has no IPv4 link address.
  static Future<Map<String, int>> _androidNetmasks() async {
    try {
      final info = await _androidWifiLock
          .invokeMethod<Map<Object?, Object?>>('ipv4LinkInfo');
      if (info == null) return const {};
      final iface = info['interface'] as String?;
      final prefix = info['prefix'];
      if (iface == null || iface.isEmpty || prefix is! int) return const {};
      if (prefix <= 0 || prefix > 32) return const {};
      return {iface: _prefixToMask(prefix)};
    } catch (e, st) {
      debugPrint('ModuleDiscovery: android netmask lookup failed (using /24 '
          'fallback): $e\n$st');
      return const {};
    }
  }

  /// Converts a CIDR prefix length into a big-endian 32-bit netmask value.
  static int _prefixToMask(int prefix) {
    if (prefix <= 0) return 0;
    if (prefix >= 32) return 0xFFFFFFFF;
    return (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  }

  /// Parses `/proc/net/route` (Linux desktop only) for the real netmask of
  /// each interface (default-route entry), so directed broadcasts are
  /// computed against the actual subnet instead of assuming /24. The four
  /// hex bytes are stored little-endian (e.g. /24 => `00FFFFFF`).
  static Map<String, int> _linuxProcNetmasks() {
    final result = <String, int>{};
    try {
      final file = File('/proc/net/route');
      if (!file.existsSync()) return result;
      for (final line in file.readAsLinesSync().skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        // Interface, Destination, Gateway, Flags, RefCnt, Use, Metric, Mask.
        if (fields.length < 9 || fields[1] != '00000000') continue;
        final rawMask = int.tryParse(fields[7], radix: 16);
        if (rawMask == null || rawMask == 0) continue;
        // Byte-swap the little-endian hex value into a big-endian IPv4 mask.
        result[fields[0]] = ((rawMask & 0xFF) << 24) |
            ((rawMask & 0xFF00) << 8) |
            ((rawMask >> 8) & 0xFF00) |
            ((rawMask >> 24) & 0xFF);
      }
    } catch (e, st) {
      debugPrint('ModuleDiscovery: reading /proc/net/route failed (using /24 '
          'fallback): $e\n$st');
    }
    return result;
  }

  /// Computes the directed IPv4 broadcast for [host] given [prefixMask] (as a
  /// big-endian /proc-style 32-bit mask) or the classic /24 subnet when the
  /// mask is null. Exposed for tests; exported as a /24 helper on null.
  static InternetAddress directedSubnetBroadcast(String host,
      [int? prefixMask]) {
    final octets = host.split('.').map(int.tryParse).toList();
    final parts = octets.length == 4
        ? [for (final o in octets) o ?? 0]
        : const [0, 0, 0, 0];
    final ip = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    final mask = prefixMask ?? 0xFFFFFF00;
    final broadcast = (ip & mask) | (~mask & 0xFFFFFFFF);
    return InternetAddress(
        '${(broadcast >> 24) & 0xFF}.${(broadcast >> 16) & 0xFF}.'
        '${(broadcast >> 8) & 0xFF}.${broadcast & 0xFF}');
  }

  void _readIdentity(Socket socket, List<DiscoveredModule> results) {
    final buffer = StringBuffer();
    socket.listen(
      (chunk) {
        buffer.write(utf8.decode(chunk, allowMalformed: true));
        final text = buffer.toString();
        NetworkDebugLogger.inbound('tcp',
            '${socket.remoteAddress.address}:${socket.remotePort}', text);
        debugPrint('ModuleDiscovery: received identity response from '
            '${socket.remoteAddress.address}:${socket.remotePort}:\n'
            '$text');
        final device = DiscoveredModule.parseIdentityResponse(
            text, socket.remoteAddress.address);
        // Deduplicate by serial number first (fallback: MAC, then GUID+IP). A
        // physical device may answer on more than one interface.
        if (device != null &&
            !results.any((r) => r.dedupeKey == device.dedupeKey)) {
          debugPrint(
              'Discovered module: ${device.guid} @ ${device.ip} (${device.name})');
          results.add(device);
        }
      },
      onError: (_) {},
      onDone: () => socket.destroy(),
    );
  }
}
