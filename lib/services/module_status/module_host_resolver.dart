// lib/services/module_status/module_host_resolver.dart
//
// Shared host resolution for module connections.
//
// A module is addressed either by a literal IP address (local network) or by a
// domain name (remote mode), so every TCP path must not assume
// `Socket.connect(host, port)` behaves the same for both:
//
//   - IP literals connect directly, no DNS;
//   - a domain is resolved first, and *every* address is tried until one opens.
//     This matters because a resolution commonly returns both an IPv6 (AAAA)
//     and an IPv4 (A) record, and a plain `Socket.connect(host, port)` uses
//     only the first result (platform-dependent) - an unreachable IPv6 address
//     then makes the connection look dead even though IPv4 works.
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Opens a TCP socket to [host]:[port], resolving domain names and trying each
/// resolved address in turn. Returns null when no address could be reached.
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

  List<InternetAddress> addresses;
  try {
    addresses = await InternetAddress.lookup(host);
  } catch (e) {
    debugPrint('$debugTag: DNS lookup for "$host" failed: $e');
    return null;
  }
  if (addresses.isEmpty) {
    debugPrint('$debugTag: "$host" resolved to no addresses');
    return null;
  }

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
