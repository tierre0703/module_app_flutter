// Tests for the scenario runner's action resolution and tracing path.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/scenario_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Injects a relay into the shared store so action resolution finds a target
  // module even though there is no demo fleet seeding on a fresh install.
  Future<void> seedRelayFleet() async {
    await ModuleStore.shared.init();
    await ModuleStore.shared.replaceAll([
      DeviceModule(
        id: 'm1',
        name: 'Main Cabin Relay',
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.offline,
        roomName: 'Cabin',
        internalTempC: 30,
        channels: [
          ChannelOutput(
            id: 'm1c1',
            name: 'Cabin Light',
            icon: Icons.lightbulb,
          ),
        ],
        inputs: [
          PhysicalInput(
              id: 'm1i1', name: 'Switch 1', mode: InputMode.maintained),
          PhysicalInput(id: 'm1i2', name: 'Switch 2', mode: InputMode.pulse),
          PhysicalInput(
              id: 'm1i3', name: 'Switch 3', mode: InputMode.momentary),
        ],
      ),
    ]);
  }

  group('ScenarioRunner', () {
    // Injects a hub with both output banks into the shared store.
    Future<void> seedHubFleet() async {
      await ModuleStore.shared.init();
      await ModuleStore.shared.replaceAll([
        DeviceModule(
          id: 'hub1',
          name: 'Modbus Hub',
          type: ModuleType.hub,
          ipAddress: '192.168.1.10',
          status: ConnectionStatus.offline,
          roomName: 'Engine Room',
          internalTempC: 30,
          channels: [
            ChannelOutput(
                id: 'hub1h0',
                name: 'Server',
                icon: Icons.electrical_services,
                isModbusPower: false),
            ChannelOutput(
                id: 'hub1h1',
                name: 'Bilge Pump',
                icon: Icons.electrical_services,
                isModbusPower: true),
          ],
        ),
      ]);
    }

    test('flags an unknown module as a failed action', () async {
      final runner = ScenarioRunner.shared;
      final result = await runner.run(Scenario(
        id: 's1',
        name: 'Test',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'No Such Module',
            channelName: 'X',
            icon: Icons.power,
            isDimmerAction: false,
            turnOn: true,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('not found'));
      expect(result.failed, 1);
    });

    test('resolves a configured module but reports not-connected', () async {
      await seedRelayFleet();
      final runner = ScenarioRunner.shared;

      // The injected relay carries 'Cabin Light' at index 0; with no live
      // socket, dispatch is reported as failed with a "not connected" reason.
      final result = await runner.run(Scenario(
        id: 's2',
        name: 'Test Relay',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Main Cabin Relay',
            channelName: 'Cabin Light',
            icon: Icons.lightbulb,
            isDimmerAction: false,
            turnOn: true,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      // Not connected (no live socket in tests) => reported as failed.
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('not connected'));
    });

    test('flags a bank-mismatched hub action as a failed action', () async {
      await seedHubFleet();
      final runner = ScenarioRunner.shared;

      // The action claims the Modbus Power bank but targets channel index 0,
      // which is a normal output - the runner must not dispatch it.
      final result = await runner.run(Scenario(
        id: 's1h',
        name: 'Test Hub',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Modbus Hub',
            channelName: 'Server',
            icon: Icons.electrical_services,
            isDimmerAction: false,
            turnOn: true,
            isHubAction: true,
            hubOutputBank: HubOutputBank.modbusPower,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('not found'));
      expect(result.failed, 1);
    });

    test('flags a hub action on an absent bank channel as failed', () async {      await seedHubFleet();
      final runner = ScenarioRunner.shared;

      // channelIndex 1 ('Bilge Pump') is a Modbus Power channel, but the
      // action targets the normal bank - the stored index does not resolve
      // within that bank, so the action fails without dialing the device.
      final result = await runner.run(Scenario(
        id: 's2h',
        name: 'Test Hub',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Modbus Hub',
            channelName: 'Bilge Pump',
            moduleIndex: -1,
            channelIndex: 1,
            icon: Icons.electrical_services,
            isDimmerAction: false,
            turnOn: true,
            isHubAction: true,
            hubOutputBank: HubOutputBank.normal,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('not found'));
      expect(result.failed, 1);
    });

    test('flags a hub variable action without a configured tag as failed',
        () async {
      await seedHubFleet();
      final runner = ScenarioRunner.shared;

      final result = await runner.run(Scenario(
        id: 's3h',
        name: 'Test Hub Variable',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Modbus Hub',
            channelName: 'All Lights Off',
            icon: Icons.tune,
            isDimmerAction: false,
            turnOn: true,
            isHubAction: true,
            hubOutputBank: HubOutputBank.variables,
            hubVariableTag: '',
            hubVariableValue: '1',
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('No variable configured'));
      expect(result.failed, 1);
    });

    test('runs a hub variable action through set_tag and refreshes the cache',
        () async {
      // A real fake Hub: greets and answers `set_tag` with ok, recording the
      // request so the fully-qualified vio reference can be asserted.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map<String, dynamic>>[];
      server.listen((socket) {
        final buffer = StringBuffer();
        socket.write('Soleux JSON API Ready\r\n');
        socket.listen((bytes) {
          buffer.write(utf8.decode(bytes));
          var text = buffer.toString();
          var idx = text.indexOf('\n');
          while (idx >= 0) {
            var line = text.substring(0, idx);
            while (line.endsWith('\r')) {
              line = line.substring(0, line.length - 1);
            }
            buffer.clear();
            buffer.write(text.substring(idx + 1));
            text = buffer.toString();
            idx = text.indexOf('\n');
            if (line.isEmpty) continue;
            final request = jsonDecode(line) as Map<String, dynamic>;
            received.add(request);
            socket.write('${jsonEncode({
                  'id': request['id'],
                  'ok': true,
                  'result': {
                    'tag_name': (request['params'] as Map)['tag_name'],
                    'value': (request['params'] as Map)['value'],
                  },
                })}\r\n');
          }
        }, onDone: () => socket.destroy());
      });

      await ModuleStore.shared.init();
      await ModuleStore.shared.replaceAll([
        DeviceModule(
          id: 'hub1',
          name: 'Modbus Hub',
          type: ModuleType.hub,
          ipAddress: InternetAddress.loopbackIPv4.address,
          tcpPort: server.port,
          status: ConnectionStatus.offline,
          roomName: 'Engine Room',
          internalTempC: 30,
          virtualTags: [
            const HubVirtualTag(
                tag: 'All_Lights_Off', tagName: 'All_Lights_Off', value: '0'),
          ],
        ),
      ]);
      final runner = ScenarioRunner.shared;

      final result = await runner.run(Scenario(
        id: 's4h',
        name: 'All Lights Off',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Modbus Hub',
            channelName: 'All_Lights_Off',
            icon: Icons.tune,
            isDimmerAction: false,
            turnOn: true,
            isHubAction: true,
            hubOutputBank: HubOutputBank.variables,
            hubVariableTag: 'All_Lights_Off',
            hubVariableValue: '1',
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isTrue);
      expect(result.actions.first.detail, contains('set to "1"'));
      // The bare stored tag name is sent as the fully-qualified vio reference.
      expect(received.single['action'], 'set_tag');
      expect((received.single['params'] as Map)['tag_name'],
          'vio.All_Lights_Off');
      expect((received.single['params'] as Map)['value'], '1');
      // The cached hub information value is refreshed after the write.
      expect(ModuleStore.shared.byId('hub1')!.virtualTags.single.value, '1');

      server.close();
    });

    test('resolves an input action by input name', () async {
      await seedRelayFleet();
      final runner = ScenarioRunner.shared;

      final result = await runner.run(Scenario(
        id: 's3',
        name: 'Test Input',
        icon: Icons.touch_app_outlined,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Main Cabin Relay',
            channelName: '',
            icon: Icons.touch_app_outlined,
            isDimmerAction: false,
            isInputAction: true,
            inputName: 'Switch 2',
            inputState: InputActionState.pulse,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      // Input resolved on the configured module; no live socket => failed,
      // "not connected" (not "input not found").
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail, contains('not connected'));
    });

    test('resolves an action by index even after the module is renamed',
        () async {
      await seedRelayFleet();
      final runner = ScenarioRunner.shared;

      // Wired by fleet index 0 + channel 0: renaming the module/output no
      // longer orphans the action.
      await ModuleStore.shared.update('m1', (m) {
        m.name = 'Renamed Relay';
        m.channels[0].name = 'Renamed Light';
      });

      final result = await runner.run(Scenario(
        id: 's-index',
        name: 'Index Wired',
        icon: Icons.play_arrow,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Main Cabin Relay',
            moduleIndex: 0,
            channelName: 'Cabin Light',
            channelIndex: 0,
            icon: Icons.lightbulb,
            isDimmerAction: false,
            turnOn: true,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      // Resolved to the (renamed) module and reached the connection check:
      // proof the index wiring survived the rename.
      expect(result.actions.first.detail, contains('Renamed Relay'));
      expect(result.actions.first.detail, contains('not connected'));
    });

    test('reports an unknown input as a failed action', () async {
      await seedRelayFleet();
      final runner = ScenarioRunner.shared;

      final result = await runner.run(Scenario(
        id: 's4',
        name: 'Test Bad Input',
        icon: Icons.touch_app_outlined,
        type: ScenarioType.tapToRun,
        actions: [
          ScenarioAction(
            moduleName: 'Main Cabin Relay',
            channelName: '',
            icon: Icons.touch_app_outlined,
            isDimmerAction: false,
            isInputAction: true,
            inputName: 'No Such Input',
            inputState: InputActionState.on,
          ),
        ],
      ));

      expect(result.actions, hasLength(1));
      expect(result.actions.first.success, isFalse);
      expect(result.actions.first.detail,
          contains('Input "No Such Input" not found'));
    });
  });
}
