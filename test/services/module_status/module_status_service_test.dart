// End-to-end tests for ModuleStatusService: a successful ON/OFF control
// command must reflect in the store (and therefore on the relay screen) even
// when the device does not push an unsolicited `OUT:` broadcast line.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/module_status/module_status_service.dart';

/// Tracks a live fake-device socket so tests can push unsolicited lines
/// (Control API device events) over the same TCP connection.
class _FakeSocket {
  final Socket socket;
  bool destroyed = false;

  _FakeSocket(this.socket);
}

/// Fake Control API device: answers `hello` / `get_relay_configuration`, and
/// acknowledges `set_output_state` with a plain `ok:true` JSON response but
/// never broadcasts an `OUT:` line (the exact scenario that used to leave the
/// relay screen stale).
class _FakeDevice {
  final ServerSocket server;
  final List<String> received = [];
  final Map<int, bool> outputs = {};
  final bool staleActual;
  final List<_FakeSocket> _sockets = [];

  _FakeDevice._(this.server, {this.staleActual = false});

  static Future<_FakeDevice> start({bool staleActual = false}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _FakeDevice._(server, staleActual: staleActual);
    server.listen((socket) => device._handle(socket));
    return device;
  }

  int get port => server.port;

  void broadcast(String line) {
    for (final entry in List.of(_sockets)) {
      if (!entry.destroyed) entry.socket.write('$line\r\n');
    }
  }

  void _handle(Socket socket) {
    final entry = _FakeSocket(socket);
    _sockets.add(entry);
    socket.done.then((_) => entry.destroyed = true);
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
        received.add(line);
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
    final action = request['action'];
    Map<String, dynamic> result;
    if (action == 'hello') {
      result = {
        'protocol': 2,
        'device': 'relay_module',
        'name': 'Plant Room Relays',
        'input_count': 2,
        'virtual_input_count': 0,
        'output_count': 2,
      };
    } else if (action == 'get_relay_configuration') {
      result = {
        'input_count': 2,
        'virtual_input_count': 0,
        'output_count': 2,
        'outputs': [
          for (var ch = 0; ch < 2; ch++)
            {
              'channel': ch,
              'output_name': 'Output ${ch + 1}',
              'output_state': outputs[ch] ?? false,
              'output_on_delay': 0,
              'output_off_delay': 0,
              'output_on_run_time': 0,
              'output_off_run_time': 0,
              'start_delay': 0,
              'initial_state': 0,
              'turn_off_disable': false,
              'restart_disable': false,
            }
        ],
        'inputs': [
          for (var ch = 0; ch < 2; ch++)
            {
              'channel': ch,
              'input_name': 'Input ${ch + 1}',
              'input_state': false,
              'input_enabled': 1,
            }
        ],
        'mapping': const [],
      };
    } else if (action == 'set_output_state') {
      final ch = request['params']['channel'] as int;
      final st = request['params']['state'] as bool;
      // A device whose `actual_state` lags the requested state: it acknowledges
      // the command with the state *before* the output settles (the scenario
      // that used to force a second press before the relay screen updated).
      final actual = staleActual ? (outputs[ch] ?? false) : st;
      outputs[ch] = st;
      result = {
        'channel': ch,
        'requested_state': st,
        'actual_state': actual,
        'pending': false,
        'revision': 1,
      };
    } else {
      result = {};
    }
    final envelope = {
      'protocol': 2,
      'id': id,
      'ok': true,
      'result': result,
    };
    socket.write('${jsonEncode(envelope)}\r\n');
  }
}

/// Lets the debounced store commit (`_scheduleCommit`) run its course.
Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  test('successful ON/OFF command reflects in the store without a broadcast',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    // controlApiPort defaults to tcpPort + 3 -> point it at the fake server.
    final module = DeviceModule(
      id: 'm1',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    final refreshed = await service.refreshOne(module);
    expect(refreshed, isTrue,
        reason: 'Control API probe + configuration fetch must succeed');
    await _flush();
    expect(store.byId('m1')!.channels, hasLength(2));
    expect(store.byId('m1')!.channels[0].isOn, isFalse);

    // No OUT: line is ever sent by the fake; only then does the store reflect.
    expect(await service.turnOnOutput('m1', 0), isTrue);
    await _flush();
    expect(store.byId('m1')!.channels[0].isOn, isTrue,
        reason: 'relay screen must reflect a successful ON command');

    expect(await service.turnOffOutput('m1', 0), isTrue);
    await _flush();
    expect(store.byId('m1')!.channels[0].isOn, isFalse,
        reason: 'relay screen must reflect a successful OFF command');

    // Unrelated channels are untouched.
    expect(store.byId('m1')!.channels[1].isOn, isFalse);

    service.dispose();
    await fake.server.close();
  });

  test(
      'ON command reflects immediately even when the device reports a stale '
      'actual_state (no second press required)', () async {
    final fake = await _FakeDevice.start(staleActual: true);
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-stale',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-stale')!.channels[0].isOn, isFalse);

    // The device acked while still reporting the OLD state; the store must
    // still reflect the requested ON on this very first press.
    expect(await service.turnOnOutput('m-stale', 0), isTrue);
    await _flush();
    expect(store.byId('m-stale')!.channels[0].isOn, isTrue,
        reason:
            'first press must flip the relay ON despite a stale actual_state');

    expect(await service.turnOffOutput('m-stale', 0), isTrue);
    await _flush();
    expect(store.byId('m-stale')!.channels[0].isOn, isFalse,
        reason:
            'first press must flip the relay OFF despite a stale actual_state');

    service.dispose();
    await fake.server.close();
  });

  test('toggle_output reflects the inverted local state on the first call',
      () async {
    final fake = await _FakeDevice.start(staleActual: true);
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-tgl',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-tgl')!.channels[0].isOn, isFalse);

    expect(await service.toggleOutput('m-tgl', 0), isTrue);
    await _flush();
    expect(store.byId('m-tgl')!.channels[0].isOn, isTrue,
        reason: 'toggle must invert the local state on the first call');

    service.dispose();
    await fake.server.close();
  });

  test('set_output_configuration pushes name, enabled and initial_state',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-cfg',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    expect(
      await service.updateOutputConfiguration(
        'm-cfg',
        0,
        name: 'Server',
        enabled: false,
        initialState: OutputInitialState.on,
      ),
      isTrue,
    );
    await _flush();

    final sent = fake.received.last;
    expect(sent, contains('"action":"set_output_configuration"'));
    expect(sent, contains('"name":"Server"'));
    expect(sent, contains('"enabled":false'));
    expect(sent, contains('"initial_state":"on"'));

    service.dispose();
    await fake.server.close();
  });

  test('set_output_configuration omits initial_state for Last State', () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-cfg2',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    expect(
      await service.updateOutputConfiguration(
        'm-cfg2',
        0,
        name: 'Server',
        initialState: OutputInitialState.lastState,
      ),
      isTrue,
    );
    await _flush();

    final sent = fake.received.last;
    expect(sent, contains('"action":"set_output_configuration"'));
    expect(sent, isNot(contains('initial_state')));

    service.dispose();
    await fake.server.close();
  });

  test(
      'a module pinned to the Control API (firmware >= 7.12) is refreshed '
      'directly over JSON without probing or an AT unit', () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-712',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3, // controlApiPort resolves to the fake server
      firmware: '7.12 Build :1',
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    expect(store.byId('m-712')!.channels, hasLength(2));
    // A successful hello pins the Control API version for later polling.
    expect(store.byId('m-712')!.apiVersion, isNotNull);
    expect(service.jsonCommandServiceFor('m-712'), isNotNull);
    expect(service.commandServiceFor('m-712'), isNull,
        reason: 'a pinned Control API module must not carry an AT unit');
    // Control commands flow over the Control API.
    expect(await service.turnOnOutput('m-712', 0), isTrue);
    await _flush();
    expect(store.byId('m-712')!.channels[0].isOn, isTrue);

    service.dispose();
    await fake.server.close();
  });

  test(
      'a module pinned to legacy (firmware < 7.12) is refreshed and '
      'controlled over the TCP AT protocol only', () async {
    final fake = await _FakeAtDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-at',
      name: 'Legacy',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 0,
      tcpPort: fake.port,
      firmware: '7.10 Build :1',
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    expect(store.byId('m-at')!.status, ConnectionStatus.offline,
        reason: 'online/offline status is owned by the heartbeat monitor, '
            'not the status refresh');
    expect(store.byId('m-at')!.firmware, '7.10 Build :1');
    expect(store.byId('m-at')!.channels, hasLength(2));
    expect(store.byId('m-at')!.channels[1].isOn, isTrue);
    // A pinned legacy module is never probed with JSON.
    expect(service.jsonCommandServiceFor('m-at'), isNull,
        reason: 'a pinned legacy module must not create a JSON unit');
    // Live control goes over the legacy AT path.
    expect(await service.turnOffOutput('m-at', 1), isTrue);
    await _flush();
    expect(store.byId('m-at')!.channels[1].isOn, isFalse);

    service.dispose();
    await fake.server.close();
  });

  test('unsolicited output/input device events update the module on screen',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-events',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-events')!.channels, hasLength(2));
    expect(store.byId('m-events')!.inputs, hasLength(2));

    // Device broadcasts output_state_changed for channel 1 over the same TCP
    // socket; the relay screen must flip without a manual refresh.
    fake.broadcast('{"protocol":3,"event":"output_state_changed",'
        '"subscription_id":"sub-1","data":{"channel":1,"previous_state":false,'
        '"state":true,"pending":false,"source":"windows-app","revision":10,'
        '"timestamp":"2026-08-31T10:20:30+00:00"}}');
    await _flush();
    expect(store.byId('m-events')!.channels[1].isOn, isTrue,
        reason: 'output_state_changed must flip the relay output on screen');

    // Device broadcasts input_state_changed for channel 0; the input indicator
    // on the module screen must light.
    fake.broadcast(
        '{"protocol":3,"event":"input_state_changed","data":{"kind":"physical",'
        '"channel":0,"previous_state":false,"state":true,"source":"input",'
        '"revision":11,"timestamp":"2026-08-31T10:20:31+00:00"}}');
    await _flush();
    expect(store.byId('m-events')!.inputs[0].state, isTrue,
        reason: 'input_state_changed must light the input indicator on screen');

    service.dispose();
    await fake.server.close();
  });

  test('protocol-2 broadcasts (result payload) replace the need to poll',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-bcast',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    // Soleux-Mobile-TCP-Protocol.md broadcast envelope: id:null, ok:true, and
    // the payload under `result`. output_state_changed must flip the channel
    // without any get_device_state polling.
    fake.broadcast('{"protocol":2,"id":null,"ok":true,'
        '"event":"output_state_changed",'
        '"result":{"channel":1,"state":true,"revision":1789531200123}}');
    await _flush();
    expect(store.byId('m-bcast')!.channels[1].isOn, isTrue,
        reason: 'protocol-2 output_state_changed must flip the relay output');

    fake.broadcast('{"protocol":2,"id":null,"ok":true,'
        '"event":"input_state_changed",'
        '"result":{"channel":0,"state":true,"revision":1789531200000}}');
    await _flush();
    expect(store.byId('m-bcast')!.inputs[0].state, isTrue,
        reason: 'protocol-2 input_state_changed must light the input');

    // Periodic system_status broadcasts surface system/network + temperature,
    // replacing the device-state poll the temperature screen used to run.
    fake.broadcast('{"protocol":2,"id":null,"ok":true,"event":"system_status",'
        '"result":{"revision":1789531205000,'
        '"captured_at":"2026-09-16T12:00:05.123456",'
        '"sensors":[{"sensor_id":"external","value_c":25.4},'
        '{"sensor_id":"cpu","value_c":47.0}],'
        '"system":{"time":"2026/09/16 12:00:05","uptime":"2 hours",'
        '"external_temp_c":25.4,"cpu_temp_c":47.0,'
        '"memory_usage_percent":64.06,"cpu_usage_percent":12.5},'
        '"network":{"lan_ip":"192.168.1.50","wifi_ssid":"Office WiFi"}}}');
    await _flush();
    final live = store.byId('m-bcast')!;
    expect(live.systemInfo, isNotNull);
    expect(live.systemInfo!.cpuUsagePercent, 12.5);
    expect(live.systemInfo!.network?.lanIp, '192.168.1.50');
    expect(live.internalTempC, 25.4,
        reason: 'system_status must mirror the external temp to internalTempC');

    service.dispose();
    await fake.server.close();
  });

  test('output_level_changed sets the dimmer brightness on the target module',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-dimmer',
      name: 'Dimmer',
      type: ModuleType.dimmerDc,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-dimmer')!.channels, hasLength(2));

    fake.broadcast('{"protocol":3,"event":"output_level_changed",'
        '"data":{"channel":1,"requested_level":70,"actual_level":70,'
        '"transitioning":false,"source":"windows-app","revision":12,'
        '"timestamp":"2026-08-31T10:20:32+00:00"}}');
    await _flush();
    final live = store.byId('m-dimmer')!;
    expect(live.channels[1].brightness, 70,
        reason: 'output_level_changed must update the dimmer brightness');
    expect(live.channels[1].isOn, isTrue);

    service.dispose();
    await fake.server.close();
  });

  test('pwm_state_changed sets the dimmer brightness to actual_pwm', () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-dimmer',
      name: 'Dimmer',
      type: ModuleType.dimmerDc,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-dimmer')!.channels, hasLength(2));

    // Protocol-2 broadcast: the dimmer settled at actual_pwm 83 (set 100).
    fake.broadcast('{"protocol":2,"id":null,"ok":true,'
        '"event":"pwm_state_changed",'
        '"result":{"channel":1,"direction":"UP","confirmed":true,'
        '"set_pwm":100,"actual_pwm":83,"revision":1789633582100}}');
    await _flush();
    final live = store.byId('m-dimmer')!;
    expect(live.channels[1].brightness, 100,
        reason: 'pwm_state_changed must reflect the set PWM level');
    expect(live.channels[1].isOn, isTrue);

    service.dispose();
    await fake.server.close();
  });

  test('temperature_changed keeps the module temperature reading live',
      () async {
    final fake = await _FakeDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-temp',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 25,
      tcpPort: fake.port - 3,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(store: store);
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    fake.broadcast('{"protocol":3,"event":"temperature_changed",'
        '"data":{"sensor_id":0,"value_c":27.4,"status":"ok",'
        '"timestamp":"2026-08-31T10:20:33+00:00"}}');
    await _flush();
    expect(store.byId('m-temp')!.internalTempC, closeTo(27.4, 0.05),
        reason: 'temperature_changed must update the module temperature');

    service.dispose();
    await fake.server.close();
  });
}

/// Fake legacy PDU (doc/PROTOCOLS.md §1): answers the relay fetch commands
/// with `KEY:value` lines terminated by `\r\nOK\r\n` and acknowledges control
/// commands (`AT+ON`/`AT+OFF`/...) with a bare `OK`.
class _FakeAtDevice {
  final ServerSocket server;
  final List<String> received = [];

  _FakeAtDevice._(this.server);

  static Future<_FakeAtDevice> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _FakeAtDevice._(server);
    server.listen((socket) => device._handle(socket));
    return device;
  }

  int get port => server.port;

  void _handle(Socket socket) {
    final buffer = StringBuffer();
    socket.listen((bytes) {
      buffer.write(utf8.decode(bytes));
      var text = buffer.toString();
      var idx = text.indexOf('\r');
      while (idx >= 0) {
        final command = text.substring(0, idx);
        text = text.substring(idx + 1);
        buffer.clear();
        buffer.write(text);
        received.add(command);
        _reply(command, socket);
        idx = text.indexOf('\r');
      }
    }, onDone: () => socket.destroy());
  }

  void _reply(String command, Socket socket) {
    String body;
    switch (command) {
      case 'AT+VER':
        body = 'DEVICE:Soleux PDU\r\nVER:7.10 Build :1\r\nRELAY_COUNT:2';
      case 'AT+TEMP':
        body = 'SYSTEMP:25';
      case 'AT+OUTSTAT':
        body = 'OUT:0:OFF\r\nOUT:1:ON';
      case 'AT+INSTAT':
      case 'AT+CHNAMES':
        body = '';
      default:
        body = '';
    }
    final response = '${body.isEmpty ? '' : '$body\r\n'}\r\nOK\r\n';
    socket.write(response);
  }
}
