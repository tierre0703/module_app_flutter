// Tests for ModuleProtocolSelector: the firmware-driven protocol choice.
//
// Current modules speak ONLY the Control API (doc/Soleux_Control_API_Command_
// Specification_v0.3.md) on port 5008; the legacy TCP AT protocol
// (doc/PROTOCOLS.md §1) is deprecated and never selected for a current module.
// Only a known pre-7.12 firmware still resolves to the retained (deprecated)
// legacyAt value.
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_status/module_command_protocol.dart';
import 'package:soleux_device_manager/services/module_status/module_protocol_selector.dart';

void main() {
  const selector = ModuleProtocolSelector();

  DeviceModule module({
    String? firmware,
    bool advertised = false,
    ModuleType type = ModuleType.relay,
  }) =>
      DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: type,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.offline,
        roomName: 'Cabin',
        internalTempC: 0,
        firmware: firmware,
        apiPort: advertised ? 5008 : null,
        apiVersion: advertised ? 3 : null,
        caps: advertised ? const ['control_api_v3'] : const [],
      );

  test('pins a >= 7.12 module to the Control API', () {
    for (final fw in ['7.12', '7.15', '8.0', '7.12 Build :2']) {
      final d = selector.decide(module(firmware: fw));
      expect(d.kind, ModuleCommandProtocolKind.controlApi,
          reason: '$fw must select the Control API');
      expect(d.pinned, isTrue, reason: 'known firmware must pin the choice');
    }
  });

  test('pins a < 7.12 module to the legacy AT protocol', () {
    for (final fw in ['7.11', '7.10.9', '6.2', '1.20 Build :9']) {
      final d = selector.decide(module(firmware: fw));
      expect(d.kind, ModuleCommandProtocolKind.legacyAt,
          reason: '$fw must select the legacy AT protocol');
      expect(d.pinned, isTrue, reason: 'known firmware must pin the choice');
    }
  });

  test(
      'unknown firmware + Control API advertisement selects controlApi '
      'without pinning', () {
    final d = selector.decide(module(advertised: true));
    expect(d.kind, ModuleCommandProtocolKind.controlApi);
    expect(d.pinned, isFalse, reason: 'unknown firmware stays probeable');
  });

  test(
      'unknown firmware without advertisement selects the Control API '
      'without pinning (legacy AT is deprecated)', () {
    final d = selector.decide(module());
    expect(d.kind, ModuleCommandProtocolKind.controlApi);
    expect(d.pinned, isFalse,
        reason: 'unknown firmware stays probeable; the Control API on 5008 is '
            'the only supported protocol');
  });

  test('decideForFirmware returns null when the version is unknown', () {
    expect(selector.decideForFirmware(null), isNull);
    expect(selector.decideForFirmware('Build 42'), isNull);
    expect(selector.decideForFirmware(''), isNull);
  });

  group('dimmer family (5008 Control API regardless of firmware)', () {
    for (final type in [ModuleType.dimmerDc, ModuleType.dimmerAc]) {
      test('$type: a sub-7.12 version string must NOT pin the dimmer to AT',
          () {
        // Dimmer firmware does not follow the relay >= 7.12 release gate; a
        // "1.20"-style version would have pinned it to legacy AT and forced
        // AT+BRIGH instead of the 5008 set_dimmer_level command.
        final d =
            selector.decide(module(firmware: '1.20 Build :9', type: type));
        expect(d.pinned, isFalse,
            reason: 'dimmers must stay probeable so the 5008 Control API is '
                'tried first');
      });

      test('$type: advertisement selects the Control API without pinning', () {
        final d = selector
            .decide(module(firmware: '1.20', type: type, advertised: true));
        expect(d.kind, ModuleCommandProtocolKind.controlApi);
        expect(d.pinned, isFalse);
      });

      test('$type: unknown firmware stays probeable', () {
        final d = selector.decide(module(type: type));
        expect(d.pinned, isFalse);
      });
    }
  });
}
