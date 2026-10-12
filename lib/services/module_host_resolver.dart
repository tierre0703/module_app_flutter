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

/// True when [host] is a literal IP address (no lookup needed).
bool isLiteralIpAddress(String host) =>
    InternetAddress.tryParse(host.trim()) != null;

/// Opens a TCP socket to [host]:[port]. [host] is normally a module's cached
/// endpoint (`DeviceModule.host`, an IP literal); a hostname is still accepted
/// and resolved IPv4-first, trying each address until one connects. Returns
/// null when no address could be reached.
Future<Socket?> connectModuleSocket(
  String host,
  int port, {
  required Duration timeout,
  String debugTag = 'ModuleSocket',
}) async {
  final trimmed = host.trim();
  final literal = InternetAddress.tryParse(trimmed);
  if (literal != null) {
    try {
      return await Socket.connect(literal, port, timeout: timeout);
    } catch (e) {
      debugPrint('$debugTag: socket ${literal.address}:$port failed: $e');
      return null;
    }
  }

  final addresses = await resolveModuleAddresses(trimmed, debugTag: debugTag);
  if (addresses.isEmpty) return null;

  Object? lastError;
  for (final address in addresses) {
    try {
      final socket = await Socket.connect(address, port, timeout: timeout);
      debugPrint('$debugTag: connected to $trimmed (${address.address}):$port');
      return socket;
    } catch (e) {
      lastError = e;
    }
  }
  debugPrint('$debugTag: no address of "$trimmed" reachable on port $port '
      '(last error: $lastError)');
  return null;
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
