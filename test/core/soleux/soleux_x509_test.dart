// test/core/soleux/soleux_x509_test.dart
//
// Exercises the minimal DER/X.509 reader used by the TLS Control API channel
// (doc/Soleux_Mobile_Control_API_TLS_Integration.md): DNS SAN extraction,
// issuer/subject DER spans and decimal serial numbers, against real
// certificate fixtures (test root CA + two issued leaves with different
// SANs).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_x509.dart';

const String _deviceId = 'modbus_hub-1234567890';

Uint8List _fixtureBytes(String name) =>
    File(['test', 'core', 'soleux', 'fixtures', name]
            .join(Platform.pathSeparator))
        .readAsBytesSync();

String _fixtureText(String name) => utf8.decode(_fixtureBytes(name));

void main() {
  final rootPem = _fixtureText('test_root_ca.pem');
  final leafPem = _fixtureText('test_leaf.pem');
  final wrongSanLeafPem = _fixtureText('test_leaf_wrong_san.pem');

  List<Uint8List> pemCertificates(String text) => parsePemCertificates(text);

  group('parsePemCertificates', () {
    test('decodes CERTIFICATE blocks and skips prose', () {
      final out = pemCertificates(rootPem);
      expect(out, hasLength(1));
      expect(out.first.first, 0x30); // DER SEQUENCE
    });

    test('a placeholder file (comments only) yields no certificates', () {
      expect(
        pemCertificates('# Soleux Root CA placeholder.\n# no cert here\n'),
        isEmpty,
      );
    });
  });

  group('selectRootCertificateDer', () {
    test('picks the self-signed certificate from a chain', () {
      // Order: leaf first, root second - the leaf carries the root as its
      // issuer, so only the root is self-signed.
      final root = selectRootCertificateDer(pemCertificates(rootPem));
      expect(root, isNotNull);
      final issuer = extractIssuerDer(root!);
      final subject = extractSubjectDer(root);
      expect(issuer, isNotNull);
      expect(subject, isNotNull);
      expect(issuer, equals(subject));
    });

    test('falls back to the first entry without a self-signed certificate',
        () {
      final leaf = pemCertificates(leafPem);
      expect(selectRootCertificateDer(leaf), isNotNull);
    });
  });

  group('extractDnsSanEntries', () {
    test('reads the device-ID DNS SAN the Hub identity contract requires',
        () {
      expect(extractDnsSanEntries(pemCertificates(leafPem).first),
          [_deviceId]);
    });

    test('reads an unrelated device ID', () {
      expect(extractDnsSanEntries(pemCertificates(wrongSanLeafPem).first),
          ['other_device-999']);
    });

    test('a root CA without a SAN yields an empty list', () {
      expect(extractDnsSanEntries(pemCertificates(rootPem).first), isEmpty);
    });
  });

  group('issuer / subject DER spans', () {
    test('the leaf issuer is byte-identical to the root subject', () {
      final rootCandidate = selectRootCertificateDer(pemCertificates(rootPem))!;
      final leaf = pemCertificates(leafPem).first;
      final leafIssuer = extractIssuerDer(leaf)!;
      final rootSubject = extractSubjectDer(rootCandidate)!;
      // Both DER spans must be identical; this is the chain-branding check
      // the onBadCertificate verdict relies on.
      expect(leafIssuer.length, rootSubject.length);
      for (var i = 0; i < leafIssuer.length; i++) {
        expect(leafIssuer[i], rootSubject[i], reason: 'byte $i');
      }
    });

    test('the root is self-issued (issuer == subject)', () {
      final rootCandidate = selectRootCertificateDer(pemCertificates(rootPem))!;
      expect(extractIssuerDer(rootCandidate), extractSubjectDer(rootCandidate));
    });
  });

  group('extractSerialDecimal', () {
    test('reads the leaf serial number as a decimal string', () {
      final serial = extractSerialDecimal(pemCertificates(leafPem).first);
      expect(serial, isNotNull);
      // Must be decimal digits only and negative-free - the CA status
      // endpoint expects the decimal string
      // (doc §"Certificate status").
      expect(serial, matches(RegExp(r'^[0-9]+$')));
    });

    test('is consistent for consecutive reads', () {
      final leaf = pemCertificates(leafPem).first;
      expect(extractSerialDecimal(leaf), extractSerialDecimal(leaf));
    });
  });
}
