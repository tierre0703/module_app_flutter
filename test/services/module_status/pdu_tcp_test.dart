// Tests for the PROTOCOLS.md Â§1 TCP status layer:
//   - parsing an `AT+TEMP` / `AT+OUTSTAT` response body into a PduResponse
//   - the standard relay fetcher applying those fields onto a DeviceModule
//   - the registry being expandable to future module types
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_status/module_status_fetcher.dart';
import 'package:soleux_device_manager/services/module_status/pdu_protocol.dart';
import 'package:soleux_device_manager/services/module_status/relay_module_status_fetcher.dart';

void main() {
  group('PduResponse.parse', () {
    test('extracts KEY:value scalars', () {
      const raw = 'DEVICE:Soleux PDU\r\nVER:1.20 Build :42\r\nRELAY_COUNT:8';
      final r = PduResponse.parse(raw);
      expect(r.ok, isTrue);
      expect(r.kv['DEVICE'], 'Soleux PDU');
      expect(r.kv['VER'], '1.20 Build :42');
      expect(r.kv['RELAY_COUNT'], '8');
    });

    test('extracts OUT and IN triplets into 0-indexed maps', () {
      const raw = 'OUT:0:ON\r\nOUT:2:OFF\r\nOUT:7:ON\r\nIN:1:ON';
      final r = PduResponse.parse(raw);
      expect(r.outputs[0], isTrue);
      expect(r.outputs[2], isFalse);
      expect(r.outputs[7], isTrue);
      expect(r.inputs[1], isTrue);
      expect(r.outputs.length, 3);
    });

    test('extracts CHNAME_OUT/CHNAME_IN name triplets (not as scalars)', () {
      const raw =
          'CHNAME_IN:0:Front Door\r\nCHNAME_OUT:2:Kitchen Light\r\nCHNAME_OUT:7:Deck';
      final r = PduResponse.parse(raw);
      expect(r.outputNames[2], 'Kitchen Light');
      expect(r.outputNames[7], 'Deck');
      expect(r.inputNames[0], 'Front Door');
      expect(r.kv.containsKey('CHNAME_OUT'), isFalse);
      expect(r.kv.containsKey('CHNAME_IN'), isFalse);
    });

    test('numeric() tolerates units and parenthesised values', () {
      expect(PduResponse.numeric('34'), 34);
      expect(PduResponse.numeric('34.5 C'), 34.5);
      expect(PduResponse.numeric('62(0)'), 62);
      expect(PduResponse.numeric(null), isNull);
      expect(PduResponse.numeric('N/A'), isNull);
    });
  });

  group('RelayModuleStatusFetcher', () {
    test('is registered for relay and issues PDU protocol commands', () {
      final registry = ModuleStatusFetcherRegistry();
      final fetcher = registry.forType(ModuleType.relay);
      expect(fetcher, isNotNull);
      expect(
          fetcher!.fetchCommands,
          containsAll([
            PduAtCommands.version,
            PduAtCommands.temperature,
            PduAtCommands.allOutputStates
          ]));
    });

    test('applies temperature + output states onto a module', () {
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.offline,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          for (var i = 0; i < 8; i++)
            ChannelOutput(
                id: 'm1c${i + 1}',
                name: 'Out ${i + 1}',
                icon: Icons.power,
                isOn: false),
        ],
      );

      const fetcher = RelayModuleStatusFetcher();
      fetcher.apply(module, [
        PduResponse.parse('SYSTEMP:34'),
        PduResponse.parse('OUT:0:ON\r\nOUT:3:ON\r\nOUT:7:ON'),
      ]);

      expect(module.internalTempC, 34);
      expect(module.channels[0].isOn, isTrue);
      expect(module.channels[3].isOn, isTrue);
      expect(module.channels[7].isOn, isTrue);
      expect(module.channels[2].isOn, isFalse);
    });
  });

  group('BaseModuleStatusFetcher reconciliation', () {
    test('captures module info (firmware) from AT+VER', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = _relayModule();
      fetcher.apply(
          module, [PduResponse.parse('VER:2.1 Build :9\r\nRELAY_COUNT:8')]);
      expect(module.firmware, '2.1 Build :9');
    });

    test('extends outputs to the device count', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          ChannelOutput(id: 'm1c1', name: 'Cabin Light', icon: Icons.power),
        ],
      );

      // Device reports 4 outputs; the device reported no CHNAME for any
      // channel, so the existing name is kept.
      fetcher.apply(module, [
        PduResponse.parse('RELAY_COUNT:4'),
        PduResponse.parse('OUT:0:ON\r\nOUT:3:ON'),
      ]);

      expect(module.channels.length, 4);
      expect(module.channels[0].name, 'Cabin Light');
      expect(module.channels[0].isOn, isTrue);
      expect(module.channels[1].name, 'Output 2'); // default name added
      expect(module.channels[3].isOn, isTrue);
    });

    test('new outputs adopt the device-reported channel names', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          ChannelOutput(id: 'm1c1', name: 'Cabin Light', icon: Icons.power),
        ],
      );

      fetcher.apply(module, [
        PduResponse.parse('RELAY_COUNT:4'),
        PduResponse.parse(
            'CHNAME_OUT:1:Kitchen Light\r\nCHNAME_OUT:3:Deck Floodlight'),
      ]);

      expect(module.channels.length, 4);
      // The device reported no name for channel 0, so its name is kept.
      expect(module.channels[0].name, 'Cabin Light');
      // Newly appended channels fall back to the device name when available.
      expect(module.channels[1].name, 'Kitchen Light');
      expect(module.channels[2].name, 'Output 3'); // no device name
      expect(module.channels[3].name, 'Deck Floodlight');
    });

    test('device-reported output names overwrite existing names', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          ChannelOutput(id: 'm1c1', name: 'Cabin Light', icon: Icons.power),
        ],
      );

      fetcher.apply(
          module, [PduResponse.parse('RELAY_COUNT:1\r\nCHNAME_OUT:0:Pump')]);

      expect(module.channels.single.name, 'Pump');
    });

    test('device-reported output names adopt the device rename', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          ChannelOutput(id: 'm1c1', name: 'Pump', icon: Icons.power),
        ],
      );

      fetcher.apply(
          module, [PduResponse.parse('RELAY_COUNT:1\r\nCHNAME_OUT:0:Water Pump')]);

      expect(module.channels.single.name, 'Water Pump');
    });

    test('device-reported input names adopt the device rename', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        inputs: [
          PhysicalInput(id: 'm1i1', name: 'Front Door'),
        ],
      );

      fetcher.apply(
          module, [PduResponse.parse('IN:0:ON\r\nCHNAME_IN:0:Main Entrance')]);

      expect(module.inputs.single.name, 'Main Entrance');
    });

    test('trims outputs beyond the reported count', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          for (var i = 0; i < 8; i++)
            ChannelOutput(
                id: 'm1c${i + 1}', name: 'Out ${i + 1}', icon: Icons.power),
        ],
      );
      fetcher.apply(module, [PduResponse.parse('RELAY_COUNT:2')]);
      expect(module.channels.length, 2);
    });

    test('appends default inputs to match the reported input count', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = _relayModule();
      fetcher.apply(module, [PduResponse.parse('IN:0:ON\r\nIN:2:ON')]);
      expect(module.inputs.length, 3);
      expect(module.inputs[0].name, 'Switch 1');
      expect(module.inputs[2].name, 'Switch 3');
    });

    test('new inputs adopt the device-reported names', () {
      const fetcher = RelayModuleStatusFetcher();
      final module = _relayModule();
      fetcher.apply(module, [
        PduResponse.parse(
            'IN:0:ON\r\nIN:1:OFF\r\nCHNAME_IN:0:Front Door\r\nCHNAME_IN:1:Engine Room'),
      ]);
      expect(module.inputs.length, 2);
      expect(module.inputs[0].name, 'Front Door');
      expect(module.inputs[1].name, 'Engine Room');
    });
  });

  group('ModuleStatusFetcherRegistry (expandability)', () {
    test('returns null for unimplemented module types', () {
      final registry = ModuleStatusFetcherRegistry();
      expect(registry.forType(ModuleType.temperature), isNull);
      expect(registry.supportedTypes, contains(ModuleType.relay));
    });

    test('accepts additional fetchers without touching existing support', () {
      final registry = ModuleStatusFetcherRegistry();
      registry.register(_FakeTemperatureFetcher());
      expect(registry.forType(ModuleType.temperature), isNotNull);
      // Relay registration is preserved.
      expect(registry.forType(ModuleType.relay), isNotNull);
    });
  });
}

DeviceModule _relayModule() => DeviceModule(
      id: 'm1',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '192.168.1.10',
      status: ConnectionStatus.online,
      roomName: 'Cabin',
      internalTempC: 0,
      channels: [
        for (var i = 0; i < 8; i++)
          ChannelOutput(
              id: 'm1c${i + 1}', name: 'Out ${i + 1}', icon: Icons.power),
      ],
    );

class _FakeTemperatureFetcher implements ModuleStatusFetcher {
  @override
  ModuleType get type => ModuleType.temperature;

  @override
  List<String> get fetchCommands => const [PduAtCommands.temperature];

  @override
  void apply(DeviceModule module, List<PduResponse> responses) {}
}
