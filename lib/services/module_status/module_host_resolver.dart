// lib/services/module_status/module_host_resolver.dart
//
// Shared host resolution for module connections.
//
// A module is addressed either by a literal IP address (local network) or by a
// hostname (remote mode, which resolves to IPv4), so every TCP path must not
// assume `Socket.connect(host, port)` behaves the same for both:
//
//   - IP literals connect directly, no DNS;
//   - a hostname is resolved to IPv4 (A records) first, and *every* resolved
//     address is tried until one opens. IPv4 is preferred because the module
//     endpoints are IPv4-only, so a hostname that also publishes an AAAA record
//     must not be attempted over IPv6 (an unreachable IPv6 address would
//     otherwise make the connection look dead even though IPv4 works).
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Opens a TCP socket to [host]:[port]. [host] may be a literal IPv4/IPv6
/// address or a hostname; a hostname is resolved (IPv4 first) and each address
/// is tried until one connects. Returns null when no address could be reached.
Future<Socket?> connectModuleSocket(
  String host,
  int port, {
  required Duration timeout,
  String debugTag = 'ModuleSocket',
}) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) {
    try {
      return await Socket.connect(literal, port, timeout: timeout);
    } catch (e) {
      debugPrint('$debugTag: socket ${literal.address}:$port failed: $e');
      return null;
    }
  }

  final addresses = await resolveModuleAddresses(host, debugTag: debugTag);
  if (addresses.isEmpty) return null;

  Object? lastError;
  for (final address in addresses) {
    try {
      final socket = await Socket.connect(address, port, timeout: timeout);
      debugPrint('$debugTag: connected to $host (${address.address}):$port');
      return socket;
    } catch (e) {
      lastError = e;
    }
  }
  debugPrint('$debugTag: no address of "$host" reachable on port $port '
      '(last error: $lastError)');
  return null;
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
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return [literal];

  List<InternetAddress> resolved;
  try {
    resolved = await InternetAddress.lookup(host);
  } catch (e) {
    debugPrint('$debugTag: DNS lookup for "$host" failed: $e');
    return const [];
  }
  if (resolved.isEmpty) {
    debugPrint('$debugTag: "$host" resolved to no addresses');
    return const [];
  }

  // IPv4 first: the endpoints are IPv4-only, so an AAAA record must not be
  // attempted before a working A record.
  final ipv4 = resolved.where((a) => a.type == InternetAddressType.IPv4);
  final ordered = [...ipv4, ...resolved.where((a) => a.type != InternetAddressType.IPv4)];
  if (ipv4.isEmpty) {
    debugPrint('$debugTag: "$host" has no IPv4 record; trying '
        '${ordered.first.address}');
  }
  return ordered;
}