// test/core/soleux/soleux_tls_test.dart
//
// Exercises the TLS decision layer of the Control API command channel
// (doc/Soleux_Mobile_Control_API_TLS_Integration.md):
//
//   - per-module `API_TLS` resolution (module flag vs code-level override);
//   - the fail-closed `accept` verdict a TLS hostname-mismatch lands in:
//     connecting by IP against the Hub's DNS-SAN-only certificate is expected
//     and only accepted when device ID SAN, issuer branding and validity all
//     hold.
//
// Certificate data comes from the real fixtures (test root CA + issued
// leaves); the fake [X509Certificate] implementations stand in for the leaf
// the dart:io handshake hands to `onBadCertificate`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_tls.dart';
import 'package:soleux_device_manager/core/soleux/soleux_x509.dart';
import 'package:soleux_device_manager/models/models.dart';

const String _deviceId = 'modbus_hub-1234567890';

Uint8List _fixtureBytes(String name) =>
    File(['test', 'core', 'soleux', 'fixtures', name]
            .join(Platform.pathSeparator))
        .readAsBytesSync();

String _fixtureText(String name) => utf8.decode(_fixtureBytes(name));

String _shippedCaPath() =>
    ['assets', 'certs', 'soleux_root_ca.pem'].join(Platform.pathSeparator);

/// A [X509Certificate] stand-in built from a fixture PEM (the dart:io class
/// cannot be constructed from test code).
class _FakeCert implements X509Certificate {
  @override
  final Uint8List der;
  @override
  final String subject;
  @override
  final String issuer;
  @override
  final DateTime startValidity;
  @override
  final DateTime endValidity;

  @override
  String get pem => utf8
      .decode(_fixtureBytes(_pemFile), allowMalformed: true)
      .trimRight();
  final String _pemFile;

  @override
  Uint8List get sha1 => Uint8List(0);

  _FakeCert(
    this.der,
    this.subject,
    this.issuer, {
    DateTime? startValidity,
    DateTime? endValidity,
    required String pemFile,
  })  : startValidity = startValidity ?? DateTime.utc(2026, 1, 1),
        endValidity = endValidity ?? DateTime.utc(2036, 1, 1),
        _pemFile = pemFile;

  static _FakeCert leaf(
    String pemFile, {
    String? subject,
    String? issuer,
    DateTime? startValidity,
    DateTime? endValidity,
  }) {
    final der = parsePemCertificates(_fixtureText(pemFile)).first;
    return _FakeCert(
      der,
      subject ?? '/CN=Soleux Hub Device/O=Soleux Test/C=TE',
      issuer ?? 'CN = Soleux Test Root CA, O = Soleux Test, C = TE',
      startValidity: startValidity,
      endValidity: endValidity,
      pemFile: pemFile,
    );
  }
}

DeviceModule _module({
  bool? apiTls,
  String? deviceId,
  ModuleType type = ModuleType.hub,
  String? connectionType,
  bool? tlsEnabled,
}) =>
    DeviceModule(
      id: 'm-1',
      name: 'Hub',
      type: type,
      ipAddress: '192.168.1.10',
      status: ConnectionStatus.offline,
      roomName: 'Plant',
      internalTempC: 25,
      apiTls: apiTls,
      deviceId: deviceId,
      connectionType: connectionType,
      tlsEnabled: tlsEnabled,
    );

void main() {
  group('moduleWantsTls', () {
    test('follows the module-advertised API_TLS flag', () {
      expect(moduleWantsTls(_module(apiTls: true)), isTrue);
      expect(moduleWantsTls(_module(apiTls: false)), isFalse);
    });

    test('an absent API_TLS field resolves to the device default 0 '
        '(plaintext)', () {
      expect(moduleWantsTls(_module(apiTls: null)), isFalse);
    });

    test('the code-level AppConfig switch overrides the module flag', () {
      expect(moduleWantsTls(_module(apiTls: false), forced: true), isTrue);
      expect(moduleWantsTls(_module(apiTls: true), forced: false), isFalse);
      // null keeps the per-module decision.
      expect(moduleWantsTls(_module(apiTls: true), forced: null), isTrue);
    });

    test('a remote-connection module is dialled TLS-first regardless of '
        'the advertised API_TLS flag', () {
      expect(
          moduleWantsTls(_module(apiTls: null, connectionType: 'remote')),
          isTrue);
      expect(moduleWantsTls(_module(apiTls: false, connectionType: 'remote')),
          isTrue);
      expect(moduleWantsTls(_module(apiTls: true, connectionType: 'remote')),
          isTrue);
      // Local-network and cloud modules keep the advertised-flag decision.
      expect(
          moduleWantsTls(_module(apiTls: false, connectionType: 'local_network')),
          isFalse);
      expect(
          moduleWantsTls(_module(apiTls: false, connectionType: 'cloud')),
          isFalse);
    });

    test('the code-level switch still wins over the remote TLS-first rule',
        () {
      expect(
          moduleWantsTls(_module(apiTls: true, connectionType: 'remote'),
              forced: false),
          isFalse);
    });

    test('the explicit configuration-screen toggle overrides every '
        'per-module default', () {
      // Toggle ON forces TLS even for a plaintext-flagged local module.
      expect(moduleWantsTls(_module(apiTls: false, tlsEnabled: true)), isTrue);
      // Toggle OFF forces plaintext even for a remote module (no automatic
      // fallback/downgrade in either direction).
      expect(
          moduleWantsTls(
              _module(apiTls: true, connectionType: 'remote',
                  tlsEnabled: false)),
          isFalse);
      // An untouched toggle (null) keeps the previous decision chain.
      expect(
          moduleWantsTls(_module(apiTls: false, tlsEnabled: null)), isFalse);
    });
  });

  group('moduleTlsOptions', () {
    test('returns options carrying the saved device ID for a TLS module',
        () {
      final options =
          moduleTlsOptions(_module(apiTls: true, deviceId: _deviceId));
      expect(options, isNotNull);
      expect(options!.expectedDeviceId, _deviceId);
      expect(options.caAsset, isNotNull);
      // The shipped configuration disables hostname verification
      // (AppConfig.tlsVerifyHostname).
      expect(options.verifyHostname, isFalse);
    });

    test('returns null (plaintext) for an API_TLS:0 module', () {
      expect(moduleTlsOptions(_module(apiTls: false, deviceId: _deviceId)),
          isNull);
    });

    test('a remote module with the toggle OFF stays plaintext (no automatic '
        'fallback)', () {
      expect(
          moduleTlsOptions(_module(
              apiTls: false,
              deviceId: _deviceId,
              connectionType: 'remote',
              tlsEnabled: false)),
          isNull);
    });

    test('the CA asset is resolved from the app configuration', () {
      final options = moduleTlsOptions(
        _module(apiTls: true, deviceId: _deviceId),
        forced: true,
      );
      // Env/AppConfig ships a default asset path; an override of the
      // code-level switch must not disturb it.
      expect(options!.caAsset, isNotNull);
    });
  });

  group('SoleuxTlsOptions.accept (fail-closed hostname-mismatch verdict)',
      () {
    late SoleuxTlsOptions options;
    setUp(() {
      options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: true);
      options.install(_fixtureText('test_root_ca.pem'));
      expect(options.identityCheckReady, isTrue);
    });

    test('accepts a chained leaf whose DNS SAN matches the saved device ID',
        () {
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(options.accept(leaf), isTrue);
      expect(options.hasProvisionError, isFalse);
    });

    test('rejects a leaf with a different device ID in the DNS SAN', () {
      final leaf = _FakeCert.leaf('test_leaf_wrong_san.pem');
      expect(options.accept(leaf), isFalse);
    });

    test('no acceptance without a usable installed root', () {
      final bare = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/none.pem',
          verifyHostname: true);
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(bare.accept(leaf), isFalse);
      expect(bare.context, isNull);
    });

    test('rejects when no device ID is saved for the module', () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: null,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: true);
      options.install(_fixtureText('test_root_ca.pem'));
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(options.accept(leaf), isFalse);
    });

    test('is case-insensitive on the DNS SAN match', () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId.toUpperCase(),
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: true);
      options.install(_fixtureText('test_root_ca.pem'));
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(options.accept(leaf), isTrue);
    });

    test('rejects an expired leaf even when the identity matches', () {
      final leaf = _FakeCert.leaf(
        'test_leaf.pem',
        startValidity: DateTime.utc(2020, 1, 1),
        endValidity: DateTime.utc(2021, 1, 1),
      );
      expect(options.accept(leaf), isFalse);
    });

    test('rejects a not-yet-valid leaf', () {
      final leaf = _FakeCert.leaf(
        'test_leaf.pem',
        startValidity: DateTime.now().toUtc().add(const Duration(days: 3650)),
        endValidity: DateTime.utc(2050, 1, 1),
      );
      expect(options.accept(leaf), isFalse);
    });
  });

  group('SoleuxTlsOptions.accept (hostname verification disabled)', () {
    late SoleuxTlsOptions options;
    setUp(() {
      options = SoleuxTlsOptions(
          expectedDeviceId: null,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      options.install(_fixtureText('test_root_ca.pem'));
      expect(options.identityCheckReady, isTrue);
    });

    test('accepts a chained leaf without requiring the device-ID DNS SAN',
        () {
      // No saved device ID, and the leaf's SAN carries a different
      // identity: chain trust (issuer match) and validity are sufficient.
      final leaf = _FakeCert.leaf('test_leaf_wrong_san.pem');
      expect(options.accept(leaf), isTrue);
    });

    test('still rejects a leaf whose issuer cannot be matched to the '
        'installed chain', () {
      final bare = SoleuxTlsOptions(
          expectedDeviceId: null,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(bare.accept(leaf), isFalse);
      expect(bare.context, isNull);
    });

    test('still rejects an expired leaf', () {
      final leaf = _FakeCert.leaf(
        'test_leaf.pem',
        startValidity: DateTime.utc(2020, 1, 1),
        endValidity: DateTime.utc(2021, 1, 1),
      );
      expect(options.accept(leaf), isFalse);
    });

    test('rejects a leaf issued via an intermediate that is not shipped',
        () {
      // The live failure mode: the device leaf chains through an issuing
      // intermediate the device does not present and the app does not
      // install. Root-only asset -> the issuer cannot be matched.
      final leaf = _FakeCert.leaf('test_leaf_via_intermediate.pem');
      expect(options.accept(leaf), isFalse);
    });
  });

  group('SoleuxTlsOptions.install (CA asset provisioning)', () {
    test('builds a single-anchor SecurityContext and the root identity data',
        () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      options.install(_fixtureText('test_root_ca.pem'));
      expect(options.context, isNotNull);
      expect(options.provisionError, isNull);
      expect(options.identityCheckReady, isTrue);
    });

    test('a placeholder asset (no CERTIFICATE block) fails provisioning',
        () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      expect(() => options.install('# placeholder comments only\n'),
          throwsA(isA<SoleuxTlsProvisionError>()));
      expect(options.hasProvisionError, isTrue);
      expect(options.context, isNull);
    });

    test('the shipped Soleux development root installs as a single anchor',
        () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      options.install(File(_shippedCaPath()).readAsStringSync());
      expect(options.provisionError, isNull);
      expect(options.context, isNotNull);
      expect(options.identityCheckReady, isTrue);
    });

    test('developer can also feed the CA chain (intermediate + root) and '
        'only the root becomes the anchor', () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      final chain = [_fixtureText('test_root_ca.pem'), _fixtureText('test_leaf.pem')]
          .join('\n');
      options.install(chain);
      expect(options.provisionError, isNull);
      expect(options.context, isNotNull);
      expect(options.identityCheckReady, isTrue);
      // The root remains the direct issuer candidate in this chain.
      final leaf = _FakeCert.leaf('test_leaf.pem');
      expect(options.accept(leaf), isTrue);
    });

    test('an intermediate in the chain asset is an issuer candidate (never '
        'an anchor)', () {
      final options = SoleuxTlsOptions(
          expectedDeviceId: _deviceId,
          caAsset: 'assets/certs/soleux_root_ca.pem',
          verifyHostname: false);
      // The "CA chain (.pem)" layout: issuing intermediate followed by the
      // root.
      final chain = [
        _fixtureText('test_intermediate.pem'),
        _fixtureText('test_root_ca.pem'),
      ].join('\n');
      options.install(chain);
      expect(options.provisionError, isNull);
      expect(options.identityCheckReady, isTrue);
      expect(options.intermediateCount, 1);

      // A device leaf issued by the intermediate is accepted even when the
      // device does not present the intermediate itself: the issuer match
      // runs against the shipped intermediate's subject.
      final leaf = _FakeCert.leaf('test_leaf_via_intermediate.pem');
      expect(options.accept(leaf), isTrue);
      // Hostname verification is still off, so an unrelated SAN is fine.
      final wrongSanLeaf = _FakeCert.leaf('test_leaf_wrong_san.pem');
      expect(options.accept(wrongSanLeaf), isTrue);
    });
  });
}
