import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/data/scenario_repository.dart';
import 'package:soleux_device_manager/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Scenario scenario(String id, {Color? backgroundColor}) => Scenario(
        id: id,
        name: 'Movie Night',
        icon: Icons.movie,
        type: ScenarioType.tapToRun,
        roomName: 'Living Room',
        showInHome: true,
        backgroundColor: backgroundColor,
        actions: [
          ScenarioAction(
            moduleName: 'Relay A',
            channelName: 'Light',
            icon: Icons.lightbulb,
            isDimmerAction: false,
            turnOn: true,
          ),
        ],
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ScenarioRepository> repo() async =>
      ScenarioRepository(await SharedPreferences.getInstance());

  test('background color persists and round-trips through storage', () async {
    final color = kScenarioBackgroundPresets.first;
    await repo()
        .then((r) => r.saveAll([scenario('s1', backgroundColor: color)]));
    final fetched = (await repo()).fetch().single;
    expect(fetched.id, 's1');
    expect(fetched.backgroundColor, color);
  });

  test('custom background color round-trips exactly', () async {
    const color = Color(0xFF28455F);
    await repo()
        .then((r) => r.saveAll([scenario('s1', backgroundColor: color)]));
    final fetched = (await repo()).fetch().single;
    expect(fetched.backgroundColor, color);
  });

  test('null background color stays null and actions are kept', () async {
    await repo().then((r) => r.saveAll([scenario('s1')]));
    final fetched = (await repo()).fetch().single;
    expect(fetched.backgroundColor, isNull);
    expect(fetched.actions, hasLength(1));
    expect(fetched.actions.single.moduleName, 'Relay A');
    expect(fetched.showInHome, isTrue);
  });

  test('hub variable action round-trips through storage', () async {
    final action = ScenarioAction(
      moduleName: 'Modbus Hub',
      channelName: 'All_Lights_Off',
      icon: Icons.tune,
      isDimmerAction: false,
      turnOn: true,
      isHubAction: true,
      hubOutputBank: HubOutputBank.variables,
      hubVariableTag: 'All_Lights_Off',
      hubVariableValue: '1',
    );
    expect(action.summary, 'All_Lights_Off -> 1');
    await repo().then((r) => r.saveAll([
          Scenario(
            id: 's1',
            name: 'All Lights Off',
            icon: Icons.play_arrow,
            type: ScenarioType.tapToRun,
            actions: [action],
          ),
        ]));
    final fetched = (await repo()).fetch().single.actions.single;
    expect(fetched.isHubAction, isTrue);
    expect(fetched.hubOutputBank, HubOutputBank.variables);
    expect(fetched.hubVariableTag, 'All_Lights_Off');
    expect(fetched.hubVariableValue, '1');
    expect(fetched.summary, 'All_Lights_Off -> 1');
  });
}
