// Tests for the scenario runner's action resolution and tracing path.
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
