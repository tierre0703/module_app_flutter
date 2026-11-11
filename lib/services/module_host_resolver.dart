// lib/services/module_host_resolver.dart
//
// Shared host resolution for module connections.
//
// A module is addressed either by a literal IP address (local network) or by a
// hostname (remote mode, which resolves to IPv4).
//
// To avoid a DNS lookup on every TCP connection, hostnames are resolved ONCE
// and the resulting IPv4 address is cached on the module
// (`DeviceModule.resolvedIp`, see `ModuleAddressResolver` in
// `widgets/common_widgets.dart`). The cache is refreshed only:
//   - when the app first loads (launch fleet resolution),
//   - when a module is added,
//   - when a module is edited.
// Every connection then dials `DeviceModule.host` (the cached IP), so this
// file's lookup is the fallback rather than the hot path.
//
// Resolution is IPv4-first because the module endpoints are IPv4-only: a
// hostname that also publishes an AAAA record must not be attempted over IPv6.
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/soleux/soleux_tls.dart';

/// ALPN protocol requested on a TLS Control API connection: the raw-JSON
/// command stream (doc/Soleux_Mobile_Control_API_TLS_Integration.md
/// §"Recommended transport": `http/1.1` for HTTPS, `soleux-json` for the raw
/// JSON stream; the 5008 TCP command channel uses the latter).
const String soleuxTlsAlpn = 'soleux-json';

/// True when [host] is a literal IP address (no lookup needed).
bool isLiteralIpAddress(String host) =>
    InternetAddress.tryParse(host.trim()) != null;

/// Opens a TCP (or TLS) socket to [host]:[port]. [host] is normally a
/// module's cached endpoint (`DeviceModule.host`, an IP literal); a hostname
/// is still accepted and resolved IPv4-first, trying each address until one
/// connects. Returns null when no address could be reached.
///
/// With non-null [tls] the socket is upgraded to TLS 1.2+ with ALPN
/// `soleux-json` before any data flows
/// (doc/Soleux_Mobile_Control_API_TLS_Integration.md):
///   - the trust anchor is the bundled Soleux root CA
///     ([SoleuxTlsOptions.caAsset]); validation failure or a
///     [SoleuxTlsProvisionError] fails the connect (closed), and
///   - connecting by IP against the Hub's DNS-SAN-only certificate fails the
///     standard hostname check, which [SoleuxTlsOptions.accept] then
///     re-judges by issuer match + validity, plus the device-ID DNS SAN
///     when hostname verification is enabled
///     ([AppConfig.tlsVerifyHostname], disabled by default).
///
/// There is deliberately **no plaintext fallback** after a TLS failure
/// (doc §"Connection sequence" step 2).
Future<Socket?> connectModuleSocket(
  String host,
  int port, {
  required Duration timeout,
  String debugTag = 'ModuleSocket',
  SoleuxTlsOptions? tls,
}) async {
  final trimmed = host.trim();
  final literal = InternetAddress.tryParse(trimmed);
  if (literal != null) {
    return _dialSingle(
      literal,
      port,
      timeout: timeout,
      debugTag: debugTag,
      displayHost: trimmed,
      tls: tls,
    );
  }

  final addresses = await resolveModuleAddresses(trimmed, debugTag: debugTag);
  if (addresses.isEmpty) return null;

  Object? lastError;
  for (final address in addresses) {
    final socket = await _dialSingle(
      address,
      port,
      timeout: timeout,
      debugTag: debugTag,
      displayHost: trimmed,
      tls: tls,
    );
    if (socket != null) return socket;
    lastError = 'no address accepted';
  }
  debugPrint('$debugTag: no address of "$trimmed" reachable on port $port '
      '(last error: $lastError)');
  return null;
}

/// Dials one [address]; returns null (never a plaintext fallback) when the
/// plain or TLS connect fails.
Future<Socket?> _dialSingle(
  InternetAddress address,
  int port, {
  required Duration timeout,
  required String debugTag,
  required String displayHost,
  SoleuxTlsOptions? tls,
}) async {
  try {
    if (tls == null) {
      return await Socket.connect(address, port, timeout: timeout);
    }
    // Provision the trust anchor before the handshake; provisioning errors
    // are surfaced as a failed connect (fail-closed).
    await tls.provision();
    if (tls.hasProvisionError) return null;
    final socket = await SecureSocket.connect(
      address,
      port,
      context: tls.context,
      // The Hub cert has a DNS SAN but no IP SAN, so the stack rejects it
      // first and [accept] re-judges it against the saved device ID.
      onBadCertificate: tls.accept,
      supportedProtocols: const [soleuxTlsAlpn],
      timeout: timeout,
    );
    debugPrint('$debugTag: connected to $displayHost (${address.address}:'
        '$port) over TLS');
    return socket;
  } catch (e) {
    debugPrint(
        '$debugTag: socket ${address.address}:$port failed: $e '
        '(${tls == null ? 'plaintext' : 'tls'})');
    return null;
  }
}

/// Resolves [host] to the IPv4 address to cache on the module, or null when it
/// does not resolve. An IP literal is returned as-is.
Future<String?> resolveModuleAddress(
  String host, {
  String debugTag = 'ModuleSocket',
}) async {
  final trimmed = host.trim();
  final literal = InternetAddress.tryParse(trimmed);
  if (literal != null) return literal.address;
  final addresses = await resolveModuleAddresses(trimmed, debugTag: debugTag);
  if (addresses.isEmpty) return null;
  return addresses.first.address;
}

/// Resolves a hostname to the addresses to try, IPv4 (A records) first.
///
/// Module endpoints are IPv4-only, so when a hostname publishes both A and AAAA
/// records only the IPv4 addresses are used; the IPv6 records are kept only as
/// a last resort when the hostname has no IPv4 address at all. An IP literal is
/// returned as-is without a lookup. Returns an empty list when the hostname
/// does not resolve.
Future<List<InternetAddress>> resolveModuleAddresses(
  String host, {
  String debugTag = 'ModuleSocket',
}) async {
  final trimmed = host.trim();
  final literal = InternetAddress.tryParse(trimmed);
  if (literal != null) return [literal];

  List<InternetAddress> resolved;
  try {
    resolved = await InternetAddress.lookup(trimmed);
  } catch (e) {
    debugPrint('$debugTag: DNS lookup for "$trimmed" failed: $e');
    return const [];
  }
  if (resolved.isEmpty) {
    debugPrint('$debugTag: "$trimmed" resolved to no addresses');
    return const [];
  }

  // IPv4 first: the endpoints are IPv4-only, so an AAAA record must not be
  // attempted before a working A record.
  final ipv4 = resolved.where((a) => a.type == InternetAddressType.IPv4);
  final ordered = [
    ...ipv4,
    ...resolved.where((a) => a.type != InternetAddressType.IPv4),
  ];
  if (ipv4.isEmpty) {
    debugPrint('$debugTag: "$trimmed" has no IPv4 record; trying '
        '${ordered.first.address}');
  }
  return ordered;
}
