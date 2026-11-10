// lib/core/soleux/soleux_tls.dart
//
// TLS support for the Soleux Control API command channel on port 5008
// (doc/Soleux_Mobile_Control_API_TLS_Integration.md).
//
// The enrolled Hub advertises `API_TLS:1` during UDP discovery and serves the
// Control API port with TLS 1.2+, offering ALPN `soleux-json` for the raw
// JSON command stream. This module decides **whether** a given module's 5008
// port is dialled with TLS and installs the trust rules for **how**:
//
//   - the Soleux root CA is bundled with the app as an asset (never fetched
//     from the discovered Hub) and becomes the only trust anchor of a
//     dedicated [SecurityContext];
//   - connecting by IP always fails standard hostname validation (the Hub
//     certificate has a DNS SAN but no IP SAN), so
//     [SoleuxTlsOptions.accept] performs the manual identity check for the
//     hostname-mismatch case: DNS SAN == saved device ID (case-insensitive),
//     leaf issuer DN byte-identical to the installed root's subject DN and a
//     holding validity window. An untrusted leaf (unknown CA) also reaches
//     this callback and fails these checks, so the handshake fails closed;
//   - fail-closed everywhere: a misconfigured CA asset or an unconfirmable
//     identity breaks the connection instead of downgrading to plaintext
//     (doc §"Connection sequence" step 2: never fall back after a TLS
//     failure).
//
// The global enable/disable switch is code-level and sits in
// [AppConfig.apiTlsEnabled]; by default (null) each module's own
// discovery-advertised `API_TLS` flag decides (see [moduleWantsTls]).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/config/env.dart';
import '../../models/models.dart';
import 'soleux_x509.dart';

/// Thrown when the Soleux root CA asset is configured but unusable (missing
/// asset, placeholder file, no CERTIFICATE block). TLS connects fail closed
/// with this error instead of silently degrading trust.
class SoleuxTlsProvisionError extends Error implements Exception {
  final String message;

  SoleuxTlsProvisionError(this.message);

  @override
  String toString() => 'SoleuxTlsProvisionError: $message';
}

/// TLS dial options for one module's Control API port.
///
/// Constructed synchronously at every connection site ([moduleTlsOptions]);
/// the [SecurityContext] and the root-certificate parse are provisioned
/// lazily by the connect path ([provision]) so the synchronous
/// [SoleuxTlsOptions.accept] handshake callback has everything it needs.
class SoleuxTlsOptions {
  /// The expected certificate identity: the saved device ID the Hub
  /// certificate must present as its DNS SAN
  /// (`<ModelNumber>-<SerialNumber>`). Null (identity unknown / not yet
  /// confirmed) means the hostname-mismatch path can never be accepted:
  /// the doc requires the exact saved device ID, not merely a valid chain.
  final String? expectedDeviceId;

  /// Asset path of the independently provisioned Soleux root CA PEM
  /// ([AppConfig.soleuxRootCaAsset]). Null keeps the platform trust store
  /// (no manual hostname-mismatch acceptance is then possible, since the
  /// root-based issuer check cannot run).
  final String? caAsset;

  SoleuxTlsOptions({required this.expectedDeviceId, required this.caAsset});

  Future<void>? _provisionFuture;
  SecurityContext? _context;
  Uint8List? _rootSubjectDer;

  /// Acceptable leaf issuer subjects: the root's subject plus (when the
  /// CA chain asset carries them) its directly-issued intermediates'
  /// subjects. Null before a successful install.
  List<Uint8List>? _trustedIssuerSubjects;

  String? _provisionError;

  /// Prepares everything the handshake needs: loads the CA asset, builds the
  /// single-anchor [SecurityContext] and parses the root for the issuer
  /// matching in [accept]. Idempotent; a failure is sticky so every
  /// reconnect logs the same root-cause instead of re-reading the asset.
  ///
  /// Throws [SoleuxTlsProvisionError] when the configured asset is unusable.
  Future<void> provision() {
    return _provisionFuture ??= Future(() async {
      try {
        install(await rootBundle.loadString(caAsset!));
      } catch (e, st) {
        _context = null;
        _rootSubjectDer = null;
        _provisionError =
            'root CA asset "$caAsset" could not be provisioned: $e\n$st';
        debugPrint('SoleuxTLS: $_provisionError');
        throw SoleuxTlsProvisionError(_provisionError!);
      }
    });
  }

  /// Installs [pemText] (the PEM content of the configured CA asset) as the
  /// single trust anchor. Synchronous so tests can drive it directly.
  ///
  /// The asset may carry the full CA chain (issuing intermediate + root, the
  /// "CA chain (.pem)" download): only the self-signed root becomes a trust
  /// anchor ([SecurityContext]); any intermediate below the root is parsed
  /// and allowed as a leaf's issuer ([SoleuxTlsOptions.accept]) **without**
  /// being trusted itself - a compromised intermediate cannot be trusted
  /// directly (doc §"What the app needs").
  ///
  /// A failed install records the cause in [provisionError] and rethrows.
  @visibleForTesting
  void install(String pemText) {
    try {
      final certificates = parsePemCertificates(pemText);
      if (certificates.isEmpty) {
        throw SoleuxTlsProvisionError(
            'root CA asset "$caAsset" contains no CERTIFICATE block '
            '(placeholder or wrong file?); install the Soleux root CA '
            '(.pem) downloaded from the CA portal');
      }
      final root = selectRootCertificateDer(certificates);
      if (root == null) {
        throw SoleuxTlsProvisionError(
            'root CA asset "$caAsset" has no root certificate');
      }
      final subject = extractSubjectDer(root);
      if (subject == null) {
        throw SoleuxTlsProvisionError(
            'root CA asset "$caAsset" is not a parseable certificate');
      }
      final context = SecurityContext();
      context.setTrustedCertificatesBytes(
          Uint8List.fromList(utf8.encode(pemText)));
      _trustedIssuerSubjects = [
        subject,
        // Intermediates issued by the root (leaf issuer candidates parsed
        // for identity matching only - never added as trust anchors). The
        // root itself qualifies too, which is harmless duplication.
        for (final candidate in certificates)
          if (_bytesEquals(
              extractIssuerDer(candidate) ?? Uint8List(0), subject))
            extractSubjectDer(candidate) ?? Uint8List(0),
      ];
      _context = context;
      _rootSubjectDer = subject;
      _provisionError = null;
    } on SoleuxTlsProvisionError catch (e) {
      _context = null;
      _rootSubjectDer = null;
      _trustedIssuerSubjects = null;
      _provisionError = e.message;
      debugPrint('SoleuxTLS: ${e.message}');
      rethrow;
    } catch (e, st) {
      _context = null;
      _rootSubjectDer = null;
      _trustedIssuerSubjects = null;
      _provisionError =
          'root CA asset "$caAsset" could not be installed: $e\n$st';
      debugPrint('SoleuxTLS: $_provisionError');
      throw SoleuxTlsProvisionError(_provisionError!);
    }
  }

  /// The prepared trust anchor. Non-null after a successful [provision];
  /// null when the CA asset is not configured (platform trust store only)
  /// or provisioning failed.
  SecurityContext? get context => _context;

  /// Raw subject DER of the installed root certificate, for the issuer
  /// match in [accept]. Null before a successful [provision].
  Uint8List? get rootSubjectDer => _rootSubjectDer;

  /// The provisioning failure text, or null once installed.
  String? get provisionError => _provisionError;

  /// True once provisioning failed with [provisionError].
  bool get hasProvisionError => _provisionError != null;

  /// True once the root material needed by [accept] is available.
  bool get identityCheckReady => _rootSubjectDer != null;

  /// The verdict for a certificate the TLS stack could not fully validate.
  ///
  /// A hostname mismatch (connecting by IP against a DNS-SAN-only
  /// certificate) is expected on this channel and accepted **only** when
  /// every manual check passes. Anything else (untrusted/expired leaf, wrong
  /// issuer, unconfirmable identity) is rejected so the handshake fails
  /// closed.
  bool accept(X509Certificate certificate) {
    // Without the installed root there is no way to tie the offending
    // certificate to the Soleux CA: reject the leaf rather than window-dress
    // a missing anchor.
    final rootSubject = _rootSubjectDer;
    if (rootSubject == null) {
      debugPrint('SoleuxTLS: rejecting certificate for '
          '${certificate.subject}: no usable Soleux root CA is installed'
          '(${_provisionError ?? 'not provisioned'})');
      return false;
    }

    final now = DateTime.now().toUtc();
    if (now.isBefore(certificate.startValidity.toUtc()) ||
        now.isAfter(certificate.endValidity.toUtc())) {
      debugPrint('SoleuxTLS: rejecting certificate for '
          '${certificate.subject}: validity window does not hold');
      return false;
    }

    // The leaf must be the Soleux CA's: its issuer must be the installed
    // root (direct issuance) or an intermediate of the installed chain. An
    // issuer outside the installed material is an untrusted-branded leaf and
    // must fail even when a hostname were to match.
    final leafIssuer = extractIssuerDer(certificate.der);
    final issuers = _trustedIssuerSubjects;
    if (leafIssuer == null ||
        issuers == null ||
        !issuers.any((subject) => _bytesEquals(leafIssuer, subject))) {
      debugPrint('SoleuxTLS: rejecting certificate for '
          '${certificate.subject}: issuer is not the installed Soleux CA '
          'chain');
      return false;
    }

    final expected = expectedDeviceId?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) {
      debugPrint('SoleuxTLS: rejecting certificate: no saved device ID to '
          'match the DNS SAN against');
      return false;
    }
    final sans = extractDnsSanEntries(certificate.der);
    if (!sans.any((san) => san.trim().toLowerCase() == expected)) {
      debugPrint('SoleuxTLS: rejecting certificate: DNS SAN(s) $sans do not '
          'match device ID "${expectedDeviceId!}"');
      return false;
    }
    debugPrint('SoleuxTLS: accepted certificate identity "$expected" '
        '(SAN(s) ${sans.join(", ")})');
    return true;
  }
}

/// Whether [module]'s `API_TLS` flag selects TLS for its 5008 Control API
/// port.
///
/// Precedence (doc §"What the app needs" / "Compatibility boundaries"):
///   1. [forced] - the code-level `AppConfig.apiTlsEnabled` switch: a
///      non-null value enables/disables TLS for every module, ignoring the
///      advertised flag;
///   2. the module's discovery-advertised `API_TLS` (`1` => true, `0` =>
///      false);
///   3. an absent `API_TLS` field is legacy/unknown, not proof that TLS is
///      off - the current plaintext-migration default false applies.
bool moduleWantsTls(DeviceModule module, {bool? forced}) =>
    forced ?? Env.config.apiTlsEnabled ?? (module.apiTls ?? false);

/// Builds the TLS dial options for [module], or null when the module's 5008
/// port must stay plaintext ([moduleWantsTls] false).
///
/// Cheap to call per connection setup; the [SecurityContext] and root parse
/// are provisioned lazily on the first dial.
SoleuxTlsOptions? moduleTlsOptions(DeviceModule module, {bool? forced}) {
  if (!moduleWantsTls(module, forced: forced)) return null;
  return SoleuxTlsOptions(
    expectedDeviceId: module.deviceId,
    caAsset: Env.config.soleuxRootCaAsset,
  );
}

bool _bytesEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
