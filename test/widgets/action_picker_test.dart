// Tests for the shared Add/Edit-action bottom sheet: editing an action must
// pre-populate the module/target/state (and hub Vars tag + value) controls
// with the values actually stored in the action being edited.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/widgets/action_picker.dart';

DeviceModule _relay() => DeviceModule(
      id: 'r1',
      name: 'Cabin Relay',
      type: ModuleType.relay,
      ipAddress: '192.168.1.10',
      status: ConnectionStatus.offline,
      roomName: 'Cabin',
      internalTempC: 0,
      channels: [
        ChannelOutput(id: 'r1c1', name: 'Cabin Light', icon: Icons.lightbulb),
        ChannelOutput(id: 'r1c2', name: 'Fan', icon: Icons.air),
      ],
    );

DeviceModule _hub() => DeviceModule(
      id: 'hub1',
      name: 'Modbus Hub',
      type: ModuleType.hub,
      ipAddress: '192.168.1.20',
      status: ConnectionStatus.offline,
      roomName: 'Engine Room',
      internalTempC: 0,
      channels: [
        ChannelOutput(
            id: 'hub1h0', name: 'Server', icon: Icons.electrical_services),
        ChannelOutput(
            id: 'hub1h1',
            name: 'Bilge Pump',
            icon: Icons.electrical_services,
            isModbusPower: true),
      ],
      virtualTags: const [
        HubVirtualTag(tag: 'Var_y', tagName: 'Var_y', name: 'Var Y', value: '5'),
        HubVirtualTag(tag: 'Var_x', tagName: 'Var_x', value: '0'),
      ],
    );

Future<void> _pumpSheet(
  WidgetTester tester, {
  required ScenarioAction? initial,
  required List<DeviceModule> modules,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () =>
                showAddActionSheet(context, modules, initial: initial),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('editing a relay output prepopulates module, output and state',
      (tester) async {
    await _pumpSheet(
      tester,
      modules: [_relay()],
      initial: ScenarioAction(
        moduleName: 'Cabin Relay',
        moduleIndex: 0,
        channelName: 'Fan',
        channelIndex: 1,
        icon: Icons.air,
        isDimmerAction: false,
        turnOn: false,
      ),
    );

    // The saved output appears in the (selected) output dropdown and the
    // saved OFF state is the selected state segment.
    expect(find.text('Cabin Relay'), findsWidgets);
    expect(find.text('Fan'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('ON'), findsOneWidget);
  });

  testWidgets('editing a hub Modbus output prepopulates bank and output',
      (tester) async {
    await _pumpSheet(
      tester,
      modules: [_hub()],
      initial: ScenarioAction(
        moduleName: 'Modbus Hub',
        moduleIndex: 0,
        channelName: 'Bilge Pump',
        channelIndex: 1,
        icon: Icons.electrical_services,
        isDimmerAction: false,
        turnOn: true,
        isHubAction: true,
        hubOutputBank: HubOutputBank.modbusPower,
      ),
    );

    expect(find.text('Modbus Hub'), findsWidgets);
    // Selected Modbus bank segment shows its modbus output, not a normal one.
    expect(find.text('Bilge Pump'), findsOneWidget);
    expect(find.text('Modbus'), findsOneWidget);
    expect(find.text('Server'), findsNothing);
  });

  testWidgets('editing a hub Vars action prepopulates tag and value',
      (tester) async {
    await _pumpSheet(
      tester,
      modules: [_hub()],
      initial: ScenarioAction(
        moduleName: 'Modbus Hub',
        moduleIndex: 0,
        channelName: 'Var Y',
        channelIndex: -1,
        icon: Icons.tune,
        isDimmerAction: false,
        turnOn: true,
        isHubAction: true,
        hubOutputBank: HubOutputBank.variables,
        hubVariableTag: 'Var_x',
        hubVariableValue: '7',
      ),
    );

    expect(find.text('Modbus Hub'), findsWidgets);
    // The Vars segment is selected; no output or state UI is shown.
    expect(find.text('Vars'), findsOneWidget);
    expect(find.text('Bilge Pump'), findsNothing);
    expect(find.text('Server'), findsNothing);
    expect(find.text('ON'), findsNothing);
    expect(find.text('OFF'), findsNothing);
    // The saved tag is selected (label is the stored tag name here) and the
    // saved value shows in the value field.
    expect(find.text('Var_x'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets(
      'editing a hub Vars action keeps the hub selected even when other '
      'output modules come first in the fleet', (tester) async {
    // Regression: the channel fallback used to switch the dialog to the
    // fleet's first output module because a Vars action resolves no channel.
    await _pumpSheet(
      tester,
      modules: [_relay(), _hub()],
      initial: ScenarioAction(
        moduleName: 'Modbus Hub',
        moduleIndex: 1,
        channelName: 'Var Y',
        channelIndex: -1,
        icon: Icons.tune,
        isDimmerAction: false,
        turnOn: true,
        isHubAction: true,
        hubOutputBank: HubOutputBank.variables,
        hubVariableTag: 'Var_y',
        hubVariableValue: '3',
      ),
    );

    // The hub stays selected: 'Modbus Hub' is the selected module value (the
    // relay name is not rendered — a closed dropdown builds only its selected
    // item's child).
    expect(find.text('Modbus Hub'), findsOneWidget);
    expect(find.text('Cabin Relay'), findsNothing);
    // Variables UI reflects the hub's tags + saved value, the state section
    // stays hidden.
    expect(find.text('Var Y'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Fan'), findsNothing);
    expect(find.text('Cabin Light'), findsNothing);
    expect(find.text('ON'), findsNothing);
    expect(find.text('OFF'), findsNothing);
  });

  testWidgets(
      'editing a hub Modbus action keeps the hub selected with other modules '
      'in the fleet', (tester) async {
    await _pumpSheet(
      tester,
      modules: [_relay(), _hub()],
      initial: ScenarioAction(
        moduleName: 'Modbus Hub',
        moduleIndex: 1,
        channelName: 'Bilge Pump',
        channelIndex: 1,
        icon: Icons.electrical_services,
        isDimmerAction: false,
        turnOn: true,
        isHubAction: true,
        hubOutputBank: HubOutputBank.modbusPower,
      ),
    );

    expect(find.text('Modbus Hub'), findsOneWidget);
    expect(find.text('Bilge Pump'), findsOneWidget);
    expect(find.text('Server'), findsNothing);
    expect(find.text('Fan'), findsNothing);
  });

  testWidgets('editing a legacy blank Vars value shows the 0 default',
      (tester) async {
    await _pumpSheet(
      tester,
      modules: [_hub()],
      initial: ScenarioAction(
        moduleName: 'Modbus Hub',
        moduleIndex: 0,
        channelName: 'Var Y',
        channelIndex: -1,
        icon: Icons.tune,
        isDimmerAction: false,
        turnOn: true,
        isHubAction: true,
        hubOutputBank: HubOutputBank.variables,
        hubVariableTag: 'Var_y',
        hubVariableValue: '',
      ),
    );

    expect(find.text('Var Y'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
}
