// test/services/module_host_resolver_tls_test.dart
//
// Verifies the hostname-mismatch classifier that gates the TLS retry in
// module_host_resolver.dart: with hostname verification disabled, a dial may
// only be retried (accepting the leaf) when the verification failure was
// caused *only* by the hostname/IP check - which the TLS stack reports after
// the certificate chain already validated to the installed trust anchor.
// Any other reason (unknown CA, expired, self-signed, ...) must not match,
// so those keep failing closed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/services/module_host_resolver.dart';

HandshakeException _handshake(String reason) =>
    HandshakeException('Handshake error in client (OS Error:\n'
        '\tCERTIFICATE_VERIFY_FAILED: $reason(handshake.cc:320))');

void main() {
  test('the live hub failure ("IP address mismatch") matches', () {
    // The exact error the enrolled Modbus Hub produced on Android.
    expect(isHostnameMismatchHandshake(_handshake('IP address mismatch')),
        isTrue);
  });

  test('a generic hostname mismatch matches', () {
    expect(isHostnameMismatchHandshake(_handshake('hostname mismatch')),
        isTrue);
  });

  test('a chain failure (unknown issuer) does not match', () {
    expect(
        isHostnameMismatchHandshake(
            _handshake('unable to get local issuer certificate')),
        isFalse);
  });

  test('a self-signed certificate failure does not match', () {
    expect(
        isHostnameMismatchHandshake(
            _handshake('self-signed certificate in certificate chain')),
        isFalse);
  });

  test('an expiry failure does not match', () {
    expect(
        isHostnameMismatchHandshake(_handshake('certificate has expired')),
        isFalse);
  });

  test('a wrong key-usage/signature failure does not match', () {
    expect(
        isHostnameMismatchHandshake(
            _handshake('certificate signature failure')),
        isFalse);
  });
}
