// lib/services/module_status/pdu_protocol.dart
//
// DEPRECATED — legacy PDU ASCII (`AT+`) protocol parser and constants. Current
// modules speak only the Control API (JSON) on port 5008; nothing in a
// production path parses these lines any more. Retained solely so the legacy
// `AT+` stack can be deleted in one follow-up step.
//
// Parser + shared constants for the TCP ASCII protocol described in
// doc/PROTOCOLS.md §1 ("PDUCore Socket Communication Protocols").
//
// Wire format (per the spec):
//   - Commands use the `AT+` prefix and end with `\r`.
//   - Responses are line-oriented `KEY:value` text ending in `\r\n` and
//     terminated by a final `\r\nOK\r\n` (or `\r\nERROR\r\n`) line.
//   - Multi-value commands use a triplet form, e.g. `OUT:<pin>:<ON|OFF>`.
//
// Only the commands meaningful for a *standard relay* module are enumerated
// here (see PROTOCOLS.md §1 table). This file is deliberately protocol-focus;
// per-module-type mapping lives in the ModuleStatusFetcher hierarchy so other
// module types (dimmer / temperature / blind) can reuse the same transport.
library;

/// The `AT` command set relevant to a standard relay, mirrored from
/// PROTOCOLS.md §1. Referential only.
@Deprecated('The legacy AT protocol is no longer supported; the Control API '
    '(TCP 5008) is the only protocol. Retained for the staged removal.')
class PduAtCommands {
  PduAtCommands._();

  static const String ping = 'AT\r';
  static const String version = 'AT+VER\r';
  static const String temperature = 'AT+TEMP\r';
  static const String allOutputStates = 'AT+OUTSTAT\r';
  static const String allInputStates = 'AT+INSTAT\r';
  static const String channelNames = 'AT+CHNAMES\r';
}

/// A parsed single-command response from a PDU.
///
/// A line-oriented response may contain five kinds of payload, all of which
/// are extracted here:
///   - `KEY:value` scalar lines        -> [kv]        (e.g. `SYSTEMP:34`)
///   - `OUT:<pin>:<ON|OFF>`            -> [outputs]
///   - `IN:<pin>:<ON|OFF>`             -> [inputs]
///   - `CHNAME_OUT:<pin>:<name>`       -> [outputNames]
///   - `CHNAME_IN:<pin>:<name>`        -> [inputNames]
@Deprecated('The legacy AT protocol is no longer supported; the Control API '
    '(TCP 5008) is the only protocol. Retained for the staged removal.')
class PduResponse {
  /// True when the response was terminated by `OK`, false for `ERROR`.
  final bool ok;

  /// Scalars keyed by uppercased line key (`SYSTEMP`, `VER`, `RELAY_COUNT`...).
  final Map<String, String> kv;

  /// Output pin -> ON state (0-indexed pins, per PROTOCOLS.md §Pin Constants).
  final Map<int, bool> outputs;

  /// Input pin -> ON state (0-indexed pins).
  final Map<int, bool> inputs;

  /// Output pin -> device-reported channel name (`CHNAME_OUT:<pin>:<name>`).
  final Map<int, String> outputNames;

  /// Input pin -> device-reported channel name (`CHNAME_IN:<pin>:<name>`).
  final Map<int, String> inputNames;

  const PduResponse({
    required this.ok,
    this.kv = const {},
    this.outputs = const {},
    this.inputs = const {},
    this.outputNames = const {},
    this.inputNames = const {},
  });

  /// Parses the raw (line-terminator-free) response body into a [PduResponse].
  factory PduResponse.parse(String raw, {bool ok = true}) {
    final kv = <String, String>{};
    final outputs = <int, bool>{};
    final inputs = <int, bool>{};
    final outputNames = <int, String>{};
    final inputNames = <int, String>{};

    // OUT:pin:ON|OFF  and  IN:pin:ON|OFF triplets.
    final triplet = RegExp(r'^(OUT|IN):(\d+):(ON|OFF)$');
    // CHNAME_OUT:pin:name  and  CHNAME_IN:pin:name triplets.
    final chname = RegExp(r'^CHNAME_(OUT|IN):(\d+):(.*)$');
    final scalar = RegExp(r'^([A-Z_]+):(.*)$');

    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final t = triplet.firstMatch(trimmed);
      if (t != null) {
        final pin = int.parse(t.group(2)!);
        final state = t.group(3) == 'ON';
        if (t.group(1) == 'OUT') {
          outputs[pin] = state;
        } else {
          inputs[pin] = state;
        }
        continue;
      }

      final c = chname.firstMatch(trimmed);
      if (c != null) {
        final pin = int.parse(c.group(2)!);
        final name = c.group(3)!.trim();
        if (name.isNotEmpty) {
          if (c.group(1) == 'OUT') {
            outputNames[pin] = name;
          } else {
            inputNames[pin] = name;
          }
        }
        continue;
      }

      final s = scalar.firstMatch(trimmed);
      if (s != null) {
        final key = s.group(1)!;
        final value = s.group(2)!.trim();
        if (value.isNotEmpty && !kv.containsKey(key)) kv[key] = value;
      }
    }

    return PduResponse(
      ok: ok,
      kv: kv,
      outputs: outputs,
      inputs: inputs,
      outputNames: outputNames,
      inputNames: inputNames,
    );
  }

  /// Parses a numeric value out of a scalar, tolerating units/postfix
  /// (e.g. `34(0)` or `34.5 C`). Returns null when the value is absent or is
  /// not a number. Helpers for fetchers.
  static double? numeric(String? value) {
    if (value == null) return null;
    final m = RegExp(r'[-+]?[0-9]*\.?[0-9]+').firstMatch(value);
    return m == null ? null : double.tryParse(m.group(0)!);
  }
}
