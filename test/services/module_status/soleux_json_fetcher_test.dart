// Tests for the Soleux JSON status fetcher rendering `hello` +
// `get_relay_configuration` onto a DeviceModule
// (doc/Soleux-Mobile-TCP-Protocol.md §"JSON protocol").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_status/soleux_json_fetcher.dart';

void main() {
  DeviceModule relayModule([int channels = 0]) => DeviceModule(
        id: 'm1',
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.offline,
        roomName: 'Cabin',
        internalTempC: 0,
        channels: [
          for (var i = 0; i < channels; i++)
            ChannelOutput(
                id: 'm1c${i + 1}', name: 'Out ${i + 1}', icon: Icons.power),
        ],
      );

  const fetcher = SoleuxJsonFetcher();

  test('parses the doc hello result', () {
    final hello = SoleuxHelloData.fromResult({
      'protocol': 2,
      'device': 'relay_module',
      'name': 'Plant Room Relays',
      'input_count': 8,
      'virtual_input_count': 2,
      'output_count': 8,
    });
    expect(hello.device, 'relay_module');
    expect(hello.name, 'Plant Room Relays');
    expect(hello.inputCount, 8);
    expect(hello.outputCount, 8);
    expect(hello.family, isNotNull);
  });

  test('apply() sets the advertised device name', () {
    final module = relayModule(8);
    fetcher.apply(
        module,
        SoleuxHelloData.fromResult({
          'protocol': 2,
          'device': 'relay_module',
          'name': 'Plant Room Relays',
          'output_count': 8
        }));
    expect(module.name, 'Plant Room Relays');
  });

  test('applyConfiguration extends outputs to the count with device names', () {
    final module = relayModule(1);
    const config = SoleuxRelayConfiguration(
      outputCount: 3,
      inputs: [
        SoleuxInputState(channel: 0, name: 'Door', state: true),
      ],
      outputs: [
        SoleuxOutputState(channel: 0, name: 'Server', state: true),
        SoleuxOutputState(channel: 2, name: 'Floodlight', state: true),
      ],
    );
    fetcher.applyConfiguration(module, config);

    expect(module.channels.length, 3);
    // The device is authoritative: channel 0 adopts the device-reported name.
    expect(module.channels[0].name, 'Server');
    expect(module.channels[0].isOn, isTrue);
    // Newly created channels adopt device-reported names (or defaults).
    expect(module.channels[1].name, 'Output 2');
    expect(module.channels[2].name, 'Floodlight');
    expect(module.channels[2].isOn, isTrue);
    expect(module.inputs.length, 1);
    expect(module.inputs[0].name, 'Door');
  });

  test('dimmer outputs take PWM brightness from the configuration', () {
    final module = DeviceModule(
      id: 'd1',
      name: 'Dimmer',
      type: ModuleType.dimmerDc,
      ipAddress: '192.168.1.20',
      status: ConnectionStatus.online,
      roomName: 'Lobby',
      internalTempC: 0,
      channels: [
        ChannelOutput(id: 'd1c1', name: 'Lobby Lights', icon: Icons.lightbulb),
      ],
    );
    const config = SoleuxRelayConfiguration(
      outputCount: 1,
      outputs: [
        SoleuxOutputState(channel: 0, name: 'Lobby Lights', pwm: 60),
      ],
    );
    fetcher.applyConfiguration(module, config);
    expect(module.channels[0].brightness, 60);
  });

  test('dimmer outputs take the brightness step from output_off_delay', () {
    final module = DeviceModule(
      id: 'd1',
      name: 'Dimmer',
      type: ModuleType.dimmerDc,
      ipAddress: '192.168.1.20',
      status: ConnectionStatus.online,
      roomName: 'Lobby',
      internalTempC: 0,
      channels: [
        ChannelOutput(id: 'd1c1', name: 'Lobby Lights', icon: Icons.lightbulb),
        ChannelOutput(id: 'd1c2', name: 'Ceiling', icon: Icons.lightbulb),
      ],
    );
    const config = SoleuxRelayConfiguration(
      outputCount: 2,
      outputs: [
        SoleuxOutputState(channel: 0, name: 'Lobby Lights', stepSize: 5),
        SoleuxOutputState(channel: 1, name: 'Ceiling'),
      ],
    );
    fetcher.applyConfiguration(module, config);
    expect(module.channels[0].stepSize, 5);
    expect(module.channels[0].brightnessSliderDivisions, 20);
    expect(module.channels[0].snapBrightness(58), 60);
    // Missing output_off_delay defaults to step 1.
    expect(module.channels[1].stepSize, 1);
    expect(module.channels[1].brightnessSliderDivisions, 100);
  });

  test('slider target name resolves back to its dimmer channel', () {
    final module = DeviceModule(
      id: 'd1',
      name: 'Cabin Dimmer 12V',
      type: ModuleType.dimmerDc,
      ipAddress: '192.168.1.20',
      status: ConnectionStatus.online,
      roomName: 'Cabin',
      internalTempC: 0,
      channels: [
        ChannelOutput(
            id: 'd1c1', name: 'Mood Light', icon: Icons.lightbulb, stepSize: 5),
      ],
    );
    final channel =
        dimmerTargetChannel([module], 'Mood Light - Cabin Dimmer 12V');
    expect(channel, isNotNull);
    expect(channel!.stepSize, 5);
    expect(dimmerTargetChannel([module], 'Mood Light - Other'), isNull);
  });

  test('trims channels beyond the reported count', () {
    final module = relayModule(8);
    fetcher.applyConfiguration(
        module, const SoleuxRelayConfiguration(outputCount: 2));
    expect(module.channels.length, 2);
  });

  test('device-reported output names overwrite existing local names', () {
    final module = relayModule(2);
    const config = SoleuxRelayConfiguration(
      outputCount: 2,
      outputs: [
        SoleuxOutputState(channel: 0, name: 'Device name', state: false),
      ],
    );
    fetcher.applyConfiguration(module, config);
    expect(module.channels[0].name, 'Device name');
  });

  test('device-reported output names are adopted on refresh', () {
    final module = relayModule(2);
    module.channels[0].name = 'Pump';
    const config = SoleuxRelayConfiguration(
      outputCount: 2,
      outputs: [
        SoleuxOutputState(channel: 0, name: 'Water Pump', state: false),
      ],
    );
    fetcher.applyConfiguration(module, config);
    expect(module.channels[0].name, 'Water Pump');
  });

  test('device-reported input names are adopted on refresh', () {
    final module = DeviceModule(
      id: 'i1',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '192.168.1.10',
      status: ConnectionStatus.online,
      roomName: 'Cabin',
      internalTempC: 0,
      inputs: [
        PhysicalInput(id: 'i1i1', name: 'Input 1'),
        PhysicalInput(id: 'i1i2', name: 'My Switch'),
      ],
    );
    const config = SoleuxRelayConfiguration(
      inputs: [
        SoleuxInputState(channel: 0, name: 'Front Door'),
        SoleuxInputState(channel: 1, name: 'Engine Room'),
      ],
    );
    fetcher.applyConfiguration(module, config);
    expect(module.inputs[0].name, 'Front Door');
    expect(module.inputs[1].name, 'Engine Room');
  });

  test('parses PDU V1.0 outer-protocol-free hello gracefully', () {
    final hello = SoleuxHelloData.fromResult(
        {'device': 'pdu_v1', 'name': 'Legacy Rack PDU', 'output_count': 7});
    expect(hello.device, 'pdu_v1');
    expect(hello.outputCount, 7);
    expect(hello.family?.jsonDevice, 'pdu_v1');
  });
}
