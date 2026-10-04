// End-to-end tests for the dimmer Control API catalogue facade on
// ModuleStatusService (doc/Soleux_Control_API_Command_Specification_v0.3.md
// §6): every dimmer command dispatches the spec action with the spec params,
// and success reflects the resulting level/state into the store so the dimmer
// screens update without a full re-fetch.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/module_status/module_status_service.dart';

/// Fake Control API dimmer device answering the dimmer catalogue (§6) commands
/// with the common `ok:true` envelope.
class _FakeDimmerDevice {
  final ServerSocket server;
  final List<Map<String, dynamic>> received = [];
  final Map<int, int> levels = {};
  final Map<int, bool> states = {};

  _FakeDimmerDevice._(this.server);

  static Future<_FakeDimmerDevice> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _FakeDimmerDevice._(server);
    server.listen((socket) => device._handle(socket));
    return device;
  }

  int get port => server.port;

  void _handle(Socket socket) {
    final buffer = StringBuffer();
    socket.listen((bytes) {
      buffer.write(utf8.decode(bytes));
      var text = buffer.toString();
      var idx = text.indexOf('\n');
      while (idx >= 0) {
        var line = text.substring(0, idx);
        while (line.endsWith('\r')) {
          line = line.substring(0, line.length - 1);
        }
        _reply(line, socket);
        final rest = text.substring(idx + 1);
        buffer.clear();
        buffer.write(rest);
        text = rest;
        idx = text.indexOf('\n');
      }
    }, onDone: () => socket.destroy());
  }

  void _reply(String line, Socket socket) {
    if (!line.startsWith('{')) return;
    final request = jsonDecode(line) as Map<String, dynamic>;
    final id = request['id'];
    final action = request['action'] as String;
    final params =
        (request['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    received.add(request);

    final Map<String, dynamic> result = _resultFor(action, params) ??
        {
          'channel': params['channel'],
        };
    socket.write('${jsonEncode({
          'protocol': 2,
          'id': id,
          'ok': true,
          'result': result,
        })}\r\n');
  }

  Map<String, dynamic>? _resultFor(String action, Map<String, dynamic> params) {
    switch (action) {
      case 'hello':
        return {
          'protocol': 2,
          'device': 'dimmer',
          'name': 'Dimmer',
          'input_count': 0,
          'virtual_input_count': 0,
          'output_count': 2,
        };
      case 'get_relay_configuration':
        return {
          'input_count': 0,
          'virtual_input_count': 0,
          'output_count': 2,
          'outputs': [
            for (var ch = 0; ch < 2; ch++)
              {
                'channel': ch,
                'output_name': 'Output ${ch + 1}',
                'output_state': states[ch] ?? false,
                'pwm': levels[ch] ?? 0,
              },
          ],
          'inputs': const [],
          'mapping': const [],
        };
      case 'set_dimmer_level':
        final ch = params['channel'] as int;
        final level = (params['value'] as num).toInt();
        levels[ch] = level;
        states[ch] = level > 0;
        return {
          'channel': ch,
          'requested_level': level,
          'actual_level': level,
          'transitioning': false,
          'operation_id': 'op-$ch',
        };
      case 'set_output_state':
        final ch = params['channel'] as int;
        final on = params['state'] as bool;
        states[ch] = on;
        // set_pwm keeps the saved set level; only the state flips. Off drops the
        // actual to 0, on without a set level defaults to full brightness.
        if (on && levels[ch] == null) {
          levels[ch] = 100;
        }
        return {
          'channel': ch,
          'requested_state': on,
          'actual_state': on,
          'pending': false,
          'revision': 1,
        };
      case 'toggle_dimmer':
        final ch = params['channel'] as int;
        states[ch] = !(states[ch] ?? false);
        return {
          'dimmer': {
            'channel': ch,
            'state': states[ch],
            'set_pwm': levels[ch] ?? 0,
            'actual_pwm': (states[ch] ?? false) ? (levels[ch] ?? 0) : 0,
            'transitioning': false,
            'revision': 1,
          },
        };
      case 'get_device_state':
        return {
          'revision': 1,
          'outputs': [
            for (var ch = 0; ch < 2; ch++)
              {
                'channel': ch,
                'state': states[ch] ?? false,
                'set_pwm': levels[ch] ?? 0,
                'actual_pwm': (states[ch] ?? false) ? (levels[ch] ?? 0) : 0,
                'pending': false,
              },
          ],
          'inputs': const [],
          'virtual_inputs': const [],
          'sensors': const [],
          'faults': const [],
        };
      case 'set_multiple_dimmer_levels':
        final outputs = params['outputs'] as List;
        final results = <Map<String, dynamic>>[];
        for (final target in outputs) {
          final map = (target as Map).cast<String, dynamic>();
          final ch = map['channel'] as int;
          final level = (map['level'] as num).toInt();
          levels[ch] = level;
          states[ch] = level > 0;
          results.add({'channel': ch, 'level': level});
        }
        return {'results': results, 'operation_id': 'group'};
      case 'get_dimmer_frequency':
        return {
          'frequency_hz': 1000,
          'allowed_hz': [1000, 2000, 4000],
          'apply_required': false,
        };
      case 'set_dimmer_frequency':
        return {
          'frequency_hz': (params['frequency_hz'] as num).toInt(),
          'applied': true,
          'restart_required': false,
        };
    }
    return null;
  }
}

/// Lets the debounced store commit (`_scheduleCommit`) run its course.
Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  late _FakeDimmerDevice fake;
  late ModuleStore store;
  late ModuleStatusService service;
  late DeviceModule module;

  setUp(() async {
    fake = await _FakeDimmerDevice.start();
    store = ModuleStore.forTesting();
    // controlApiPort = tcpPort -> point it at the fake server.
    module = DeviceModule(
      id: 'dim1',
      name: 'Dimmer',
      type: ModuleType.dimmerDc,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port,
    );
    await store.replaceAll([module]);
    service = ModuleStatusService(store: store);
  });

  tearDown(() async {
    service.dispose();
    await fake.server.close();
  });

  test('refreshOne reaches the JSON probe and seeds dimmer channels', () async {
    expect(await service.refreshOne(module), isTrue,
        reason: 'dimmer fetcher + Control API probe must succeed');
    await _flush();
    expect(store.byId('dim1')!.channels, hasLength(2));
  });

  test('refreshOne also fetches get_device_state and hydrates level/state',
      () async {
    // Device reports ch0 at 55 ON and ch1 at 70 ON before the refresh.
    fake.levels[0] = 55;
    fake.states[0] = true;
    fake.levels[1] = 70;
    fake.states[1] = true;

    expect(await service.refreshOne(module), isTrue);
    await _flush();

    expect(fake.received.any((r) => r['action'] == 'get_device_state'), isTrue,
        reason: 'module-info refresh must read dimmer levels via '
            'get_device_state');
    final live = store.byId('dim1')!;
    expect(live.channels[0].isOn, isTrue);
    expect(live.channels[0].brightness, 55);
    expect(live.channels[1].isOn, isTrue);
    expect(live.channels[1].brightness, 70);
  });

  test(
      'set_dimmer_level / dimmer_on / dimmer_off / toggle_dimmer dispatch '
      'the spec actions and reflect state', () async {
    await service.refreshOne(module);
    await _flush();

    // §6.3 set_dimmer_level -> set_dimmer_level with channel + value.
    expect(await service.setDimmerLevel('dim1', 0, 35), isTrue);
    await _flush();
    expect(fake.received.last['action'], 'set_dimmer_level');
    expect(fake.received.last['params'], {'channel': 0, 'value': 35});

    // dimmer_on -> set_output_state(state: true).
    expect(await service.dimmerOn('dim1', 0), isTrue);
    await _flush();
    expect(fake.received.last['action'], 'set_output_state');
    expect(fake.received.last['params'], {'channel': 0, 'state': true});
    final live = store.byId('dim1')!;
    expect(live.channels[0].isOn, isTrue);

    // dimmer_off -> set_output_state(state: false).
    expect(await service.dimmerOff('dim1', 0), isTrue);
    await _flush();
    expect(fake.received.last['action'], 'set_output_state');
    expect(fake.received.last['params'], {'channel': 0, 'state': false});
    expect(store.byId('dim1')!.channels[0].isOn, isFalse);

    // §6.7 toggle_dimmer inverts state and reports the set/actual PWM.
    expect(await service.toggleDimmer('dim1', 0), isTrue);
    await _flush();
    expect(fake.received.last['action'], 'toggle_dimmer');
    expect(store.byId('dim1')!.channels[0].isOn, isTrue);
    expect(store.byId('dim1')!.channels[0].brightness, 35,
        reason: 'toggle reports set_pwm 35, keeping the earlier set level');
  });

  test(
      'get_dimmer_state / get_dimmer_levels return parsed snapshots and '
      'syncDimmerLevels applies them to the store', () async {
    await service.refreshOne(module);
    await _flush();
    expect(await service.setDimmerLevel('dim1', 0, 40), isTrue);
    expect(await service.setDimmerLevel('dim1', 1, 80), isTrue);

    // Single-channel snapshot via get_device_state's output entry.
    final snapshot = await service.getDimmerState('dim1', 0);
    expect(snapshot, isNotNull);
    expect(snapshot!.channel, 0);
    expect(snapshot.state, isTrue);
    expect(snapshot.requestedLevel, 40);

    // All levels from the same get_device_state outputs list.
    final all = await service.getDimmerLevels('dim1');
    expect(all, isNotNull);
    expect(all, hasLength(2));
    expect(all![0].requestedLevel, 40);
    expect(all[1].requestedLevel, 80);
  });

  test('syncDimmerLevels hydrates the live channels from get_device_state',
      () async {
    await service.refreshOne(module);
    await _flush();
    // Device reports ch0 at 55 ON and ch1 at 0 OFF (no prior app set).
    fake.levels[0] = 55;
    fake.states[0] = true;
    fake.levels[1] = 0;
    fake.states[1] = false;

    await service.syncDimmerLevels('dim1');
    await _flush();
    final live = store.byId('dim1')!;
    expect(live.channels[0].isOn, isTrue);
    expect(live.channels[0].brightness, 55);
    expect(live.channels[1].isOn, isFalse);
    expect(live.channels[1].brightness, 0);
  });

  test('set_multiple_dimmer_levels sends the target list and reflects results',
      () async {
    await service.refreshOne(module);
    await _flush();

    expect(
      await service.setMultipleDimmerLevels('dim1', [
        {'channel': 0, 'level': 25},
        {'channel': 1, 'level': 60},
      ]),
      isTrue,
    );
    await _flush();
    expect(fake.received.last['action'], 'set_multiple_dimmer_levels');
    expect(fake.received.last['params']['outputs'], [
      {'channel': 0, 'level': 25},
      {'channel': 1, 'level': 60},
    ]);
    final live = store.byId('dim1')!;
    expect(live.channels[0].brightness, 25);
    expect(live.channels[0].isOn, isTrue);
    expect(live.channels[1].brightness, 60);
    expect(live.channels[1].isOn, isTrue);
  });

  test('get/set_dimmer_frequency dispatch §6.8/§6.9 and parse allowed values',
      () async {
    await service.refreshOne(module);
    await _flush();

    final frequency = await service.getDimmerFrequency('dim1');
    expect(frequency, isNotNull);
    expect(frequency!.frequencyHz, 1000);
    expect(frequency.allowedHz, [1000, 2000, 4000]);

    expect(await service.setDimmerFrequency('dim1', 2000), isTrue);
    await _flush();
    expect(fake.received.last['action'], 'set_dimmer_frequency');
    expect(fake.received.last['params'], {'frequency_hz': 2000});
  });

  test(
      'dimmer commands fall back to false when the module has no Control API '
      'unit', () async {
    // No refresh ran, so no JSON unit exists yet.
    expect(await service.dimmerOn('dim1', 0), isFalse);
    expect(await service.toggleDimmer('dim1', 0), isFalse);
    expect(await service.getDimmerLevels('dim1'), isNull);
    expect(await service.getDimmerFrequency('dim1'), isNull);
  });

  test('DimmerStateSnapshot / DimmerFrequencyInfo parse the wire shapes', () {
    // A get_device_state output entry: set_pwm/actual_pwm.
    final snapshot = DimmerStateSnapshot.fromMap(const {
      'channel': 2,
      'state': true,
      'set_pwm': 70.0,
      'actual_pwm': 40.0,
    });
    expect(snapshot, isNotNull);
    expect(snapshot!.channel, 2);
    expect(snapshot.state, isTrue);
    expect(snapshot.requestedLevel, 70.0);
    expect(snapshot.actualLevel, 40.0);

    // Backward compatibility: requested_level/actual_level still parse.
    final legacy = DimmerStateSnapshot.fromMap(const {
      'channel': 3,
      'state': false,
      'requested_level': 55.0,
      'actual_level': 0.0,
      'transitioning': false,
    });
    expect(legacy, isNotNull);
    expect(legacy!.requestedLevel, 55.0);
    expect(legacy.actualLevel, 0.0);
    expect(legacy.transitioning, isFalse);

    final freq = DimmerFrequencyInfo.fromMap(const {
      'frequency_hz': 2000,
      'allowed_hz': [1000, 2000, 4000],
      'apply_required': false,
    });
    expect(freq, isNotNull);
    expect(freq!.frequencyHz, 2000);
    expect(freq.allowedHz, [1000, 2000, 4000]);

    // allowed_hz as a {min,max} range is also accepted (§6.8).
    final ranged = DimmerFrequencyInfo.fromMap(const {
      'frequency_hz': 3,
      'allowed_hz': {'min': 1, 'max': 4},
      'apply_required': true,
    });
    expect(ranged!.allowedHz, [1, 2, 3, 4]);
    expect(ranged.applyRequired, isTrue);
  });
}
