// Tests for the Soleux device-family registry against the identity tables in
// doc/Soleux-Network-Discovery-and-DCP.md and doc/Soleux-Mobile-TCP-Protocol.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_device_family.dart';
import 'package:soleux_device_manager/models/models.dart';

void main() {
  group('SoleuxDeviceFamily guid/device tables', () {
    test('discovery GUIDs match the doc identity table', () {
      expect(SoleuxDeviceFamily.relayModule.guid,
          '579E6EA1-2F64-4CDE-8190-1CD3646EFAA1');
      expect(SoleuxDeviceFamily.dimmer.guid,
          'C47A5A88-03E8-4EC0-9F2D-67A6C43F0D91');
      expect(SoleuxDeviceFamily.pduEnergyMeter.guid,
          '56EC974B-1C9F-48C3-B438-BFE976593072');
      expect(SoleuxDeviceFamily.pdu10kw.guid,
          'A728DD7D-0DEB-49B9-9B8B-A4556771815F');
      expect(SoleuxDeviceFamily.pduV1.guid,
          'B4A6B160-0CBA-4BD8-873D-EDC9DF895C26');
    });

    test('JSON hello device values match the doc table', () {
      expect(SoleuxDeviceFamily.relayModule.jsonDevice, 'relay_module');
      expect(SoleuxDeviceFamily.dimmer.jsonDevice, 'dimmer');
      expect(SoleuxDeviceFamily.pduEnergyMeter.jsonDevice, 'pdu_energy_meter');
      expect(SoleuxDeviceFamily.pdu10kw.jsonDevice, 'pdu_10kw');
      expect(SoleuxDeviceFamily.pduV1.jsonDevice, 'pdu_v1');
    });

    test('fromGuid resolves case-insensitively', () {
      expect(
          SoleuxDeviceFamilies.fromGuid('579E6EA1-2F64-4CDE-8190-1CD3646EFAA1'),
          SoleuxDeviceFamily.relayModule);
      expect(
          SoleuxDeviceFamilies.fromGuid('579e6ea1-2f64-4cde-8190-1cd3646efaa1'),
          SoleuxDeviceFamily.relayModule);
      expect(SoleuxDeviceFamilies.fromGuid(null), isNull);
      expect(SoleuxDeviceFamilies.fromGuid('unknown-guid'), isNull);
    });

    test('fromJsonDevice resolves the pushed hello device value', () {
      expect(SoleuxDeviceFamilies.fromJsonDevice('relay_module'),
          SoleuxDeviceFamily.relayModule);
      expect(SoleuxDeviceFamilies.fromJsonDevice('PDU_10kw'),
          SoleuxDeviceFamily.pdu10kw);
      expect(SoleuxDeviceFamilies.fromJsonDevice('nope'), isNull);
    });
  });

  group('Default app module mapping', () {
    test('relay/PDU families seed as relay, dimmer as dimmerDc', () {
      expect(
          SoleuxDeviceFamily.relayModule.defaultModuleType, ModuleType.relay);
      expect(SoleuxDeviceFamily.dimmer.defaultModuleType, ModuleType.dimmerDc);
      expect(SoleuxDeviceFamily.pduEnergyMeter.defaultModuleType,
          ModuleType.relay);
      expect(SoleuxDeviceFamily.pdu10kw.defaultModuleType, ModuleType.relay);
      expect(SoleuxDeviceFamily.pduV1.defaultModuleType, ModuleType.relay);
    });

    test('energy metering is only exposed by the PDU families', () {
      expect(SoleuxDeviceFamily.relayModule.hasEnergyMeter, isFalse);
      expect(SoleuxDeviceFamily.dimmer.hasEnergyMeter, isFalse);
      expect(SoleuxDeviceFamily.pduEnergyMeter.hasEnergyMeter, isTrue);
      expect(SoleuxDeviceFamily.pdu10kw.hasEnergyMeter, isTrue);
      expect(SoleuxDeviceFamily.pduV1.hasEnergyMeter, isTrue);
    });
  });

  group('Constants', () {
    test('heartbeat port is the fixed well-known 5007', () {
      expect(SoleuxConstants.heartbeatPort(5008), 5007);
      expect(SoleuxConstants.heartbeatPort(8001), 5007);
      expect(SoleuxConstants.defaultHeartbeatPort, 5007);
    });

    test('discovery constants', () {
      expect(SoleuxConstants.discoveryGuid,
          '8C93472D-2EF0-4B82-BE96-4FBBED57783F');
      expect(SoleuxConstants.discoveryVersion, '2.0');
      expect(SoleuxConstants.discoveryPort, 8000);
      expect(SoleuxConstants.defaultCommandPort, 5008);
      expect(SoleuxConstants.maxNonceLength, 64);
    });
  });
}
