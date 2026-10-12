import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/data/module_repository.dart';
import 'package:soleux_device_manager/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DeviceModule relay(String id, String name) => DeviceModule(
        id: id,
        name: name,
        type: ModuleType.relay,
        ipAddress: '192.168.1.10',
        status: ConnectionStatus.online,
        roomName: 'Cabin',
        internalTempC: 30,
        tempMinC: 0,
        tempMaxC: 70,
        channels: [
          ChannelOutput(
              id: '$id-c1', name: 'Light', icon: Icons.lightbulb, isOn: true),
        ],
        inputs: [
          PhysicalInput(
              id: '$id-i1', name: 'Switch 1', mode: InputMode.maintained),
        ],
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ModuleRepository> repo() async =>
      ModuleRepository(await SharedPreferences.getInstance());

  test('fetch returns empty list when nothing persisted', () async {
    final r = await repo();
    expect(r.fetch(), isEmpty);
  });

  test('add persists a module and can be fetched back', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    final modules = r.fetch();
    expect(modules, hasLength(1));
    expect(modules.first.name, 'Relay A');
    expect(modules.first.type, ModuleType.relay);
    expect(modules.first.channels.single.name, 'Light');
    expect(modules.first.channels.single.icon, Icons.lightbulb);
    expect(modules.first.inputs.single.mode, InputMode.maintained);
  });

  test('add replaces an existing module with the same id', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.add(relay('m1', 'Relay B'));
    final modules = r.fetch();
    expect(modules, hasLength(1));
    expect(modules.first.name, 'Relay B');
  });

  test('update edits an existing module', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.update('m1', relay('m1', 'Relay Renamed'));
    expect(r.fetch().single.name, 'Relay Renamed');
  });

  test('update throws when the module does not exist', () async {
    final r = await repo();
    expect(
      () => r.update('missing', relay('m1', 'X')),
      throwsA(isA<ModuleNotFoundException>()),
    );
  });

  test('delete removes a module', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.add(relay('m2', 'Relay B'));
    await r.delete('m1');
    expect(r.fetch().map((m) => m.id), ['m2']);
  });

  test('delete of a missing id is a no-op', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.delete('nope');
    expect(r.fetch(), hasLength(1));
  });

  test('saveAll replaces the whole list', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.saveAll([relay('m2', 'Relay B'), relay('m3', 'Relay C')]);
    expect(r.fetch().map((m) => m.id), ['m2', 'm3']);
  });

  test('clear empties storage', () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.clear();
    expect(r.fetch(), isEmpty);
  });

  test('persisted modules survive a new repository instance', () async {
    await (await repo()).add(relay('m1', 'Relay A'));
    final fresh = await repo();
    expect(fresh.fetch().single.name, 'Relay A');
  });

  test('channel enabled + initial state round-trip through persistence',
      () async {
    final r = await repo();
    await r.add(relay('m1', 'Relay A'));
    await r.update(
        'm1',
        DeviceModule(
          id: 'm1',
          name: 'Relay A',
          type: ModuleType.relay,
          ipAddress: '192.168.1.10',
          status: ConnectionStatus.online,
          roomName: 'Cabin',
          internalTempC: 30,
          channels: [
            ChannelOutput(
              id: 'm1-c1',
              name: 'Light',
              icon: Icons.lightbulb,
              isOn: true,
              initialState: OutputInitialState.on,
            ),
          ],
        ));
    final channel = r.fetch().single.channels.single;
    expect(channel.isOn, isTrue);
    expect(channel.initialState, OutputInitialState.on);
  });
}
