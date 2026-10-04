// End-to-end tests for ModuleStatusService in HTTP/HTTPS command-protocol mode
// (doc/Soleux_Control_API_Command_Specification_v0.2.md §"Transport mapping"):
// a Control API device is refreshed and controlled through
// `POST /api/v1/command` instead of the persistent TCP session on port 5008.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/module_status/module_status_service.dart';
import 'package:soleux_device_manager/services/module_status/soleux_http_service.dart';
import 'package:soleux_device_manager/services/settings_store.dart';

/// Fake Control API device served over HTTP: handles `POST /api/v1/command`
/// (hello / get_relay_configuration / set_output_state / ping).
class _FakeHttpDevice {
  final HttpServer server;
  final List<String> receivedActions = [];
  final Map<int, bool> outputs = {};

  _FakeHttpDevice._(this.server);

  static Future<_FakeHttpDevice> start() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: true);
    final device = _FakeHttpDevice._(server);
    server.listen(device._handle);
    return device;
  }

  int get port => server.port;

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final envelope = jsonDecode(body) as Map<String, dynamic>;
    final action = envelope['action'] as String;
    final id = envelope['id'];
    final params = (envelope['params'] as Map?) ?? const <String, dynamic>{};
    receivedActions.add(action);

    final Map<String, dynamic> result;
    switch (action) {
      case 'hello':
        result = {
          'protocol': 2,
          'device': 'relay_module',
          'name': 'Plant Room Relays',
          'input_count': 2,
          'virtual_input_count': 0,
          'output_count': 2,
        };
      case 'get_relay_configuration':
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
              }
          ],
          'inputs': const [],
          'mapping': const [],
        };
      case 'set_output_state':
        final ch = (params['channel'] as num).toInt();
        final st = params['state'] as bool;
        outputs[ch] = st;
        result = {
          'channel': ch,
          'requested_state': st,
          'actual_state': st,
          'pending': false,
        };
      case 'ping':
        result = {'server_time': '2026-09-03T10:00:00+00:00', 'uptime_ms': 1};
      default:
        result = {};
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'protocol': 2,
      'id': id,
      'ok': true,
      'result': result,
    }));
    await request.response.close();
  }
}

/// Lets the debounced store commit (`_scheduleCommit`) run its course.
Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The widget-test binding installs a mock HttpClient (HttpOverrides.global)
    // that answers every request with HTTP 400; restore the real network stack
    // so the fake device HTTP endpoint is actually reachable.
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('HTTP mode refreshes and controls a pinned Control API module',
      () async {
    final fake = await _FakeHttpDevice.start();
    final store = ModuleStore.forTesting();
    final module = DeviceModule(
      id: 'm-http',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: 5008,
      firmware: '7.12 Build :1',
      apiHttpPort: fake.port,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(
      store: store,
      commandTransport: () => CommandTransportMode.http,
    );
    expect(await service.refreshOne(module), isTrue);
    await _flush();

    // Configuration was fetched over HTTP and rendered onto the module.
    expect(store.byId('m-http')!.status, ConnectionStatus.offline,
        reason: 'online/offline status is owned by the heartbeat monitor, '
            'not the status refresh');
    expect(store.byId('m-http')!.channels, hasLength(2));
    expect(fake.receivedActions, contains('get_relay_configuration'));

    // The live unit is an HTTP/HTTPS Control API client, not a legacy AT or
    // TCP JSON unit.
    final unit = service.jsonCommandServiceFor('m-http');
    expect(unit, isA<SoleuxHttpService>());
    expect(service.commandServiceFor('m-http'), isNull);

    // Live control flows through POST /api/v1/command and reflects in the
    // store immediately (the device does not push any broadcast).
    expect(await service.turnOnOutput('m-http', 0), isTrue);
    await _flush();
    expect(store.byId('m-http')!.channels[0].isOn, isTrue);

    expect(await service.turnOffOutput('m-http', 1), isTrue);
    await _flush();
    expect(store.byId('m-http')!.channels[1].isOn, isFalse);

    expect(fake.receivedActions, contains('set_output_state'));

    service.dispose();
    await fake.server.close();
  });

  test('pollAll() pings a Control API device over HTTP when configured',
      () async {
    final fake = await _FakeHttpDevice.start();
    final store = ModuleStore.forTesting();
    await store
        .init(); // load (and seed) persistence before replacing the fleet
    final module = DeviceModule(
      id: 'm-poll',
      name: 'Relays',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 30,
      tcpPort: 5008,
      firmware: '7.12 Build :1',
      apiHttpPort: fake.port,
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(
      store: store,
      commandTransport: () => CommandTransportMode.http,
    );
    final result = await service.pollAll();
    expect(result.online, hasLength(1));
    expect(store.byId('m-poll')!.status, ConnectionStatus.offline,
        reason: 'online/offline status is owned by the heartbeat monitor, '
            'not the status refresh');
    expect(fake.receivedActions, contains('ping'));

    service.dispose();
    await fake.server.close();
  });

  test('unknown-firmware modules fall back to legacy AT in HTTP mode',
      () async {
    final fake = await _HttpStubDevice.start();
    final store = ModuleStore.forTesting();
    // Legacy AT-only device on the legacy TCP port (no HTTP Control API).
    final module = DeviceModule(
      id: 'm-at-http',
      name: 'Legacy',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 0,
      tcpPort: fake.port,
      apiHttpPort: 1, // unreachable HTTP endpoint -> falls through to AT
    );
    await store.replaceAll([module]);

    final service = ModuleStatusService(
      store: store,
      commandTransport: () => CommandTransportMode.http,
    );
    expect(await service.refreshOne(module), isTrue);
    await _flush();
    expect(store.byId('m-at-http')!.status, ConnectionStatus.offline,
        reason: 'online/offline status is owned by the heartbeat monitor, '
            'not the status refresh');
    expect(store.byId('m-at-http')!.channels, hasLength(2));
    // No HTTP Control API unit survived; the AT unit drives the module.
    expect(service.jsonCommandServiceFor('m-at-http'), isNull);
    expect(service.commandServiceFor('m-at-http'), isNotNull);

    service.dispose();
    await fake.server.close();
  });

  test('controlApiHttpEndpoint resolves spec ports and overrides', () {
    final module = DeviceModule(
      id: 'm',
      name: 'M',
      type: ModuleType.relay,
      ipAddress: '192.168.1.10',
      status: ConnectionStatus.offline,
      roomName: '',
      internalTempC: 0,
    );
    expect(
      ModuleStatusService.controlApiHttpEndpoint(
          module, CommandTransportMode.http),
      Uri.parse('http://192.168.1.10:80/api/v1/command'),
    );
    expect(
      ModuleStatusService.controlApiHttpEndpoint(
          module, CommandTransportMode.https),
      Uri.parse('https://192.168.1.10:443/api/v1/command'),
    );
    module.apiHttpPort = 8080;
    expect(
      ModuleStatusService.controlApiHttpEndpoint(
          module, CommandTransportMode.http),
      Uri.parse('http://192.168.1.10:8080/api/v1/command'),
    );
    expect(
      ModuleStatusService.controlApiHttpEndpoint(
          module, CommandTransportMode.https),
      Uri.parse('https://192.168.1.10:8080/api/v1/command'),
    );
  });
}

/// A minimal TCP stub that answers legacy `AT+VER`/`AT+OUTSTAT` with `OK` so
/// the unknown-firmware HTTP fallback lands on the legacy AT path.
class _HttpStubDevice {
  final ServerSocket server;

  _HttpStubDevice._(this.server);

  static Future<_HttpStubDevice> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _HttpStubDevice._(server);
    server.listen((socket) {
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
          device._reply(command, socket);
          idx = text.indexOf('\r');
        }
      }, onDone: () => socket.destroy());
    });
    return device;
  }

  int get port => server.port;

  void _reply(String command, Socket socket) {
    final String body;
    switch (command) {
      case 'AT+VER':
        body = 'DEVICE:Soleux Test\r\nVER:1.0 Build :1\r\nRELAY_COUNT:2';
      case 'AT+TEMP':
        body = 'SYSTEMP:25';
      case 'AT+OUTSTAT':
        body = 'OUT:0:OFF\r\nOUT:1:ON';
      default:
        body = '';
    }
    socket.write('${body.isEmpty ? '' : '$body\r\n'}\r\nOK\r\n');
  }
}
