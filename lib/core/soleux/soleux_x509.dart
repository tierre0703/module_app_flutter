// lib/core/soleux/soleux_x509.dart
//
// Minimal DER/X.509 helpers for the Soleux TLS command channel
// (doc/Soleux_Mobile_Control_API_TLS_Integration.md).
//
// The Hub presents its device identity certificate with the permanent device
// ID as its DNS SAN (`<ModelNumber>-<SerialNumber>`) and a
// `urn:soleux:device:<device-id>` URI SAN, but **no IP SAN**. The app connects
// by IP address, so the standard hostname check always fails and the identity
// must be confirmed manually: extract the certificate's DNS SANs and compare
// them with the saved device ID (case-insensitive, doc §"Recommended
// transport").
//
// `dart:io`'s `X509Certificate` (the object handed to `onBadCertificate`)
// exposes subject/issuer/validity but not the SAN extension, so the SANs and
// the issuer DN are read straight out of the DER bytes with a small header-tag
// walk. This is deliberately a narrow reader (SAN + Name DER spans + serial):
// chain and validity-period validation stay with the TLS stack
// ([SecurityContext] trust anchors + `X509Certificate` validity fields);
// nothing here decides chain trust on its own.
library;

import 'dart:convert';
import 'dart:typed_data';

/// ASN.1 universal/context tags used below.
const int _tagSequence = 0x30;
const int _tagInteger = 0x02;
const int _tagObjectIdentifier = 0x06;
const int _tagOctetString = 0x04;
const int _tagContextThree = 0xA3; // explicit [3] extensions
const int _tagContextZero = 0xA0; // explicit [0] version
// GeneralName context tag for dNSName ([RFC 5280] §4.2.1.6 GeneralNames).
const int _tagGeneralNameDns = 0x82;

/// One DER-encoded ASN.1 element (header + content span).
class _Asn1Element {
  final int tag;
  final Uint8List data;
  final int firstByte;
  final int contentStart;
  final int end;

  const _Asn1Element({
    required this.tag,
    required this.data,
    required this.firstByte,
    required this.contentStart,
    required this.end,
  });

  int get contentLength => end - contentStart;

  Uint8List get der => Uint8List.sublistView(data, firstByte, end);

  Iterable<_Asn1Element> children() sync* {
    var offset = contentStart;
    while (offset < end) {
      final child = _readElement(data, offset);
      if (child == null) break;
      yield child;
      offset = child.end;
    }
  }
}

/// Reads one TLV element at [offset]; null on malformed input (positive-[]
/// length-override guard keeps a hostile certificate from looping forever).
_Asn1Element? _readElement(Uint8List data, int offset) {
  if (offset + 2 > data.length) return null;
  final tag = data[offset];
  final firstLengthByte = data[offset + 1];
  var length = firstLengthByte;
  var contentStart = offset + 2;
  if (firstLengthByte & 0x80 != 0) {
    final count = firstLengthByte & 0x7F;
    // Long form only for the sizes an X.509 name uses (<= 4 bytes).
    if (count == 0 || count > 4) return null;
    if (offset + 2 + count > data.length) return null;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | data[offset + 2 + i];
    }
    contentStart = offset + 2 + count;
  }
  final end = contentStart + length;
  if (end > data.length) return null;
  return _Asn1Element(
      tag: tag, data: data, firstByte: offset, contentStart: contentStart,
      end: end);
}

bool _isOid(_Asn1Element element, List<int> value) =>
    element.tag == _tagObjectIdentifier &&
    element.contentLength == value.length &&
    () {
      for (var i = 0; i < value.length; i++) {
        if (element.data[element.contentStart + i] != value[i]) return false;
      }
      return true;
    }();

/// OID 2.5.29.17 - Subject Alternative Name extension.
List<_Asn1Element> _sanGeneralNames(_Asn1Element tbs) {
  final out = <_Asn1Element>[];
  for (final child in tbs.children()) {
    if (child.tag != _tagContextThree) continue;
    // extensions ::= SEQUENCE OF Extension
    for (final extensions in child.children()) {
      if (extensions.tag != _tagSequence) continue;
      for (final extension in extensions.children()) {
        if (extension.tag != _tagSequence) continue;
        _Asn1Element? oid;
        _Asn1Element? value;
        for (final field in extension.children()) {
          if (field.tag == _tagObjectIdentifier) {
            oid = field;
          } else if (field.tag == _tagOctetString) {
            value = field;
          }
        }
        if (oid == null || value == null) continue;
        if (!_isOid(oid, const [0x55, 0x1D, 0x11])) continue; // 2.5.29.17
        // extnValue content = DER of GeneralNames SEQUENCE.
        final generalNames =
            _readElement(value.data, value.contentStart);
        if (generalNames == null) continue;
        out.addAll(generalNames.children());
      }
    }
  }
  return out;
}

/// All `dNSName` entries of the certificate's SAN extension (ASCII-decoded).
List<String> extractDnsSanEntries(Uint8List der) {
  final names = <String>[];
  final certificate = _readElement(der, 0);
  if (certificate == null || certificate.tag != _tagSequence) return names;
  final tbs = certificate.children().firstOrNull;
  if (tbs == null || tbs.tag != _tagSequence) return names;
  for (final generalName in _sanGeneralNames(tbs)) {
    if (generalName.tag != _tagGeneralNameDns) continue;
    final text = utf8.decode(
      Uint8List.sublistView(
          generalName.data, generalName.contentStart, generalName.end),
      allowMalformed: false,
    );
    if (text.isNotEmpty) names.add(text);
  }
  return names;
}

/// The raw DER of the certificate's issuer (index 3) or subject (index 5)
/// Name element. Comparing raw DER bytes is a stronger identity claim than a
/// normalized DN string: two byte-identical Names were produced by the same
/// encoder, and the Soleux leaf certificates are issued by the CA whose
/// subject is recorded in the installed root certificate.
///
/// TBS layout: [0] version?, serial NUMBER, sigAlg SEQUENCE, issuer
/// SEQUENCE, validity SEQUENCE, subject SEQUENCE, ... So with a version
/// present the issuer sits at child index 3 and the subject at 5; without it
/// at 2 and 4.
Uint8List? _nameDer(Uint8List der, int nameIndexWithVersion) {
  final certificate = _readElement(der, 0);
  if (certificate == null || certificate.tag != _tagSequence) return null;
  final tbs = certificate.children().firstOrNull;
  if (tbs == null || tbs.tag != _tagSequence) return null;
  final children = tbs.children().toList();
  // [0] explicit version is optional.
  final hasVersion =
      children.isNotEmpty && children.first.tag == _tagContextZero;
  final index = nameIndexWithVersion - (hasVersion ? 0 : 1);
  if (index < 0 || index >= children.length) return null;
  final element = children[index];
  return element.tag == _tagSequence ? element.der : null;
}

/// Raw DER of the certificate's issuer Name, or null on malformed input.
Uint8List? extractIssuerDer(Uint8List der) => _nameDer(der, 3);

/// Raw DER of the certificate's subject Name, or null on malformed input.
Uint8List? extractSubjectDer(Uint8List der) => _nameDer(der, 5);

/// The certificate serial number as a decimal string
/// (doc/Soleux_Mobile_Control_API_TLS_Integration.md §"Certificate status":
/// the CA status endpoint expects the decimal string). Null on malformed
/// input.
String? extractSerialDecimal(Uint8List der) {
  final certificate = _readElement(der, 0);
  if (certificate == null || certificate.tag != _tagSequence) return null;
  final tbs = certificate.children().firstOrNull;
  if (tbs == null || tbs.tag != _tagSequence) return null;
  for (final child in tbs.children()) {
    if (child.tag != _tagInteger) continue;
    final bytes = Uint8List.sublistView(
        child.data, child.contentStart, child.end);
    if (bytes.isEmpty) continue;
    // ASN.1 INTEGERs are two's-complement; certificates are positive, so the
    // only valid case here is no leading sign bit (or a single 0x00 pad).
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final parsed = BigInt.tryParse(hex, radix: 16);
    if (parsed == null || parsed < BigInt.zero) return null;
    return parsed.toString();
  }
  return null;
}

/// Decodes every PEM `CERTIFICATE` block in [text]; entries that are not
/// valid Base64 bodies are skipped. Returns an empty list when no block is
/// found (placeholder/misconfigured CA file).
List<Uint8List> parsePemCertificates(String text) {
  final pattern = RegExp(
      r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)'
      r'-----END CERTIFICATE-----',
      multiLine: true);
  final out = <Uint8List>[];
  for (final match in pattern.allMatches(text)) {
    final base64Body =
        match.group(1)!.replaceAll(RegExp(r'\s'), '');
    if (base64Body.isEmpty) continue;
    try {
      final decoded = base64Decode(base64Body);
      if (decoded.isNotEmpty) out.add(Uint8List.fromList(decoded));
    } on FormatException {
      // Skip the malformed block; a CA chain file may carry a torn entry.
    }
  }
  return out;
}

/// Picks the root certificate to trust from a bundle of DER certificates:
/// the self-signed (subject == issuer) certificate, else the first entry.
/// Even a chain PEM ("CA chain .pem") must only ever instal its root as a
/// trust anchor (doc §"What the app needs").
Uint8List? selectRootCertificateDer(List<Uint8List> certificates) {
  for (final der in certificates) {
    final issuer = extractIssuerDer(der);
    final subject = extractSubjectDer(der);
    if (issuer != null && subject != null && _bytesEqual(issuer, subject)) {
      return der;
    }
  }
  return certificates.isEmpty ? null : certificates.first;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
