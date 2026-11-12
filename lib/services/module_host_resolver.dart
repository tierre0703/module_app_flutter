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
import 'dart:async';
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
/// (doc §"Connection sequence" step 2) - except when [tls] carries
/// [SoleuxTlsOptions.allowPlaintextFallback] (modules with connection type
/// `remote`): those are dialled TLS-first and a failed TLS connect is
/// retried over plaintext so the remote endpoint stays reachable.
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

/// Dials one [address]; returns null when the plain or TLS connect fails.
///
/// TLS strategy (doc/Soleux_Mobile_Control_API_TLS_Integration.md):
///   1. strict dial - the trust anchor is the bundled Soleux root CA and
///      [SoleuxTlsOptions.accept] re-judges the hostname-mismatched leaf
///      (issuer match + validity, plus the device-ID SAN when hostname
///      verification is enabled);
///   2. when hostname verification is disabled
///      ([AppConfig.tlsVerifyHostname]) and the strict dial failed with a
///      **hostname-only** verification error, the dial is retried accepting
///      the leaf: the chain was already proven to the installed root by the
///      platform (a hostname mismatch is only reported after chain
///      validation succeeds), so this is exactly "hostname verification
///      off" - chain and validity stay enforced, and any other failure
///      reason (unknown CA, expired, ...) still fails closed;
///   3. plaintext fallback - only when [SoleuxTlsOptions]
///      `.allowPlaintextFallback` is set (modules with connection type
///      `remote`): a failed TLS connect (handshake, unprovisionable trust
///      anchor, ...) is retried over plaintext so the remote endpoint stays
///      reachable. Without that flag a TLS failure never downgrades to
///      plaintext (doc §"Connection sequence" step 2).
Future<Socket?> _dialSingle(
  InternetAddress address,
  int port, {
  required Duration timeout,
  required String debugTag,
  required String displayHost,
  SoleuxTlsOptions? tls,
}) async {
  if (tls == null) {
    try {
      return await Socket.connect(address, port, timeout: timeout);
    } catch (e) {
      debugPrint(
          '$debugTag: socket ${address.address}:$port failed: $e (plaintext)');
      return null;
    }
  }

  // TLS-first dial. A failure is remembered instead of aborting so a
  // permitted fallback ([SoleuxTlsOptions.allowPlaintextFallback]) can
  // retry over plaintext below.
  Object? tlsError;
  try {
    // Provision the trust anchor before the handshake; provisioning errors
    // are surfaced as a failed connect (fail-closed).
    await tls.provision();
    if (tls.hasProvisionError) {
      tlsError = tls.provisionError;
    } else {
      try {
        final socket = await _tlsDialWithDeadline(
            address, port, timeout, tls, tls.accept);
        debugPrint('$debugTag: connected to $displayHost '
            '(${address.address}:$port) over TLS');
        return socket;
      } on HandshakeException catch (e) {
        if (!tls.verifyHostname && isHostnameMismatchHandshake(e)) {
          debugPrint('$debugTag: TLS chain verified to the installed root '
              'but the hostname check failed; hostname verification is '
              'disabled - accepting the verified chain');
          final socket = await _tlsDialWithDeadline(
              address, port, timeout, tls, (_) => true);
          debugPrint('$debugTag: connected to $displayHost '
              '(${address.address}:$port) over TLS (hostname bypass)');
          return socket;
        }
        rethrow;
      }
    }
  } catch (e) {
    tlsError = e;
  }
  debugPrint('$debugTag: TLS ${address.address}:$port failed: $tlsError');
  if (!tls.allowPlaintextFallback) return null;

  // Remote modules: the endpoint may not serve TLS on this port yet, so
  // downgrade rather than lose the module (connection type `remote` only).
  debugPrint('$debugTag: ${address.address}:$port falling back to plaintext '
      'after the TLS failure');
  try {
    final socket = await Socket.connect(address, port, timeout: timeout);
    debugPrint('$debugTag: connected to $displayHost (${address.address}:'
        '$port) over plaintext (TLS fallback)');
    return socket;
  } catch (e) {
    debugPrint('$debugTag: plaintext fallback ${address.address}:$port '
        'failed: $e');
    return null;
  }
}

Future<SecureSocket> _tlsDial(
  InternetAddress address,
  int port,
  Duration timeout,
  SoleuxTlsOptions tls,
  bool Function(X509Certificate) onBadCertificate,
) =>
    SecureSocket.connect(
      address,
      port,
      context: tls.context,
      // The Hub cert has a DNS SAN but no IP SAN, so the stack rejects it
      // first and the callback re-judges it.
      onBadCertificate: onBadCertificate,
      supportedProtocols: const [soleuxTlsAlpn],
      timeout: timeout,
    );

/// dart:io's [SecureSocket.connect] `timeout` only bounds the TCP connect -
/// the TLS handshake itself would hang forever against a listener that
/// never answers (a plaintext endpoint silently discards the ClientHello
/// without closing). The deadline therefore bounds the **whole** dial, so
/// the remote TLS-first policy can actually reach its plaintext fallback.
Future<Socket> _tlsDialWithDeadline(
  InternetAddress address,
  int port,
  Duration timeout,
  SoleuxTlsOptions tls,
  bool Function(X509Certificate) onBadCertificate,
) {
  final dial = _tlsDial(address, port, timeout, tls, onBadCertificate);
  return dial.timeout(timeout, onTimeout: () {
    // When the abandoned handshake completes (or errors) later, close the
    // socket so a stalled dial does not leak a connection.
    dial.then<void>((socket) => socket.destroy(),
        onError: (Object error, StackTrace stackTrace) {});
    throw TimeoutException('TLS dial did not complete (handshake deadline)',
        timeout);
  });
}

/// Whether [error] is a TLS verification failure caused *only* by the
/// hostname/IP check. OpenSSL (BoringSSL) verifies the certificate chain
/// first, so this reason only surfaces when the chain already validated to
/// the installed trust anchor - accepting the peer afterwards is a hostname
/// bypass, not a chain bypass.
@visibleForTesting
bool isHostnameMismatchHandshake(HandshakeException error) {
  final text =
      '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  return text.contains('ip address mismatch') ||
      text.contains('hostname mismatch');
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
