// Tests for the 5008 Control API reachability service that owns each module's
// online / unknown / offline status (the UDP heartbeat port 5007 is no longer
// part of the decision).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/module_status/module_api_health_service.dart';
import 'package:soleux_device_manager/services/module_status/module_host_resolver.dart';

/// Fake Control API device: answers the JSON `hello` while [answering] is true,
/// and keeps the connection open when [socketAccepts] is true (simulating a
/// device whose TCP port is up but whose API is broken).
class _FakeApiDevice {
  final ServerSocket server;
  final List<Socket> _sockets = [];
  bool answering;
  bool socketAccepts;

  _FakeApiDevice._(this.server,
      {this.answering = true, this.socketAccepts = true});

  static Future<_FakeApiDevice> start(
      {bool answering = true, bool socketAccepts = true}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _FakeApiDevice._(server,
        answering: answering, socketAccepts: socketAccepts);
    server.listen(device._handle);
    return device;
  }

  int get port => server.port;

  void _handle(Socket socket) {
    _sockets.add(socket);
    if (!socketAccepts) {
      socket.destroy();
      return;
    }
    final buffer = StringBuffer();
    socket.listen((bytes) {
      buffer.write(utf8.decode(bytes));
      var text = buffer.toString();
      var idx = text.indexOf('\n');
      while (idx >= 0) {
        final line = text.substring(0, idx).replaceAll('\r', '');
        text = text.substring(idx + 1);
        buffer.clear();
        buffer.write(text);
        _reply(line, socket);
        idx = text.indexOf('\n');
      }
    }, onDone: () => socket.destroy());
  }

  void _reply(String line, Socket socket) {
    if (!answering || !line.startsWith('{')) return;
    final request = jsonDecode(line) as Map<String, dynamic>;
    if (request['action'] != 'hello') return;
    socket.write('${jsonEncode({
          'protocol': 2,
          'id': request['id'],
          'ok': true,
          'result': {'device': 'relay_module', 'output_count': 2},
        })}\r\n');
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  DeviceModule buildModule({required Object host, String id = 'm1'}) =>
      DeviceModule(
        id: id,
        name: 'Relay',
        type: ModuleType.relay,
        ipAddress: host is int ? '127.0.0.1' : host as String,
        status: ConnectionStatus.offline,
        roomName: 'Cabin',
        internalTempC: 25,
        tcpPort: host is int ? host : 5008,
      );

  test('a module is seeded offline and flips online when the 5008 API answers',
      () async {
    final device = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    final module = buildModule(host: device.port);
    await store.replaceAll([module]);
    expect(store.byId('m1')!.status, ConnectionStatus.offline);

    final service = ModuleApiHealthService.forTesting(store: store);
    final status = await service.checkOne(module);

    expect(status, ConnectionStatus.online);
    expect(store.byId('m1')!.status, ConnectionStatus.online);
    expect(store.byId('m1')!.lastSeenAt, isNotNull);

    await device.close();
  });

  test('a dead API socket flags the module offline', () async {
    final store = ModuleStore.forTesting();
    // Port 1 is unreachable: the socket cannot be opened.
    final module = buildModule(host: 1);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    final status = await service.checkOne(module);

    expect(status, ConnectionStatus.offline);
    expect(store.byId('m1')!.status, ConnectionStatus.offline);
  });

  test('an online module whose 5008 API breaks becomes unknown', () async {
    final device = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    final module = buildModule(host: device.port);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.online);

    // The device is still reachable on the network (its TCP port accepts
    // connections) but stops answering the API: it must become unknown, not
    // offline.
    device.answering = false;
    expect(await service.checkOne(module), ConnectionStatus.unknown);
    expect(store.byId('m1')!.status, ConnectionStatus.unknown);

    await device.close();
  });

  test('an unknown module goes back online as soon as the API answers',
      () async {
    final device = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    final module = buildModule(host: device.port);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.online);

    // API breaks -> unknown.
    device.answering = false;
    expect(await service.checkOne(module), ConnectionStatus.unknown);

    // API recovers -> the module must switch straight back to online.
    device.answering = true;
    expect(await service.checkOne(module), ConnectionStatus.online);
    expect(store.byId('m1')!.status, ConnectionStatus.online);

    await device.close();
  });

  test('an offline module goes back online as soon as the API answers',
      () async {
    final store = ModuleStore.forTesting();
    final module = buildModule(host: 1);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.offline);

    // The module comes back on a live API port.
    final device = await _FakeApiDevice.start();
    store.byId('m1')!.tcpPort = device.port;
    expect(await service.checkOne(store.byId('m1')!), ConnectionStatus.online);

    await device.close();
  });

  test('an online module that disappears entirely becomes offline', () async {
    final device = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    final module = buildModule(host: device.port);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.online);

    await device.close(); // device gone: nothing listens on the port anymore
    expect(await service.checkOne(module), ConnectionStatus.offline);
    expect(store.byId('m1')!.status, ConnectionStatus.offline);
  });

  test('a module that never answered never becomes unknown', () async {
    final store = ModuleStore.forTesting();
    final module = buildModule(host: 1);
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.offline);
    expect(await service.checkOne(module), ConnectionStatus.offline);
  });

  test('a module addressed by hostname connects and reports online', () async {
    final device = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    // "localhost" exercises the hostname path (resolved IPv4-first, then each
    // address is tried until one opens).
    final module = DeviceModule(
      id: 'remote',
      name: 'Remote',
      type: ModuleType.relay,
      ipAddress: 'localhost',
      status: ConnectionStatus.offline,
      roomName: 'Remote',
      internalTempC: 25,
      tcpPort: device.port,
      connectionType: 'remote',
    );
    await store.replaceAll([module]);

    final service = ModuleApiHealthService.forTesting(store: store);
    expect(await service.checkOne(module), ConnectionStatus.online);
    expect(store.byId('remote')!.lastSeenAt, isNotNull);

    await device.close();
  });

  test('resolveModuleAddresses prefers IPv4 and passes IP literals through',
      () async {
    final addresses = await resolveModuleAddresses('localhost');
    expect(addresses, isNotEmpty);
    expect(addresses.first.type, InternetAddressType.IPv4,
        reason: 'module endpoints are IPv4-only, so A records must be tried '
            'before AAAA records');

    final literal = await resolveModuleAddresses('192.168.1.50');
    expect(literal.single.address, '192.168.1.50');

    final unknown = await resolveModuleAddresses('no-such-host.invalid');
    expect(unknown, isEmpty);
  });

  test('checkAll checks every module concurrently', () async {
    final live = await _FakeApiDevice.start();
    final store = ModuleStore.forTesting();
    await store.replaceAll([
      buildModule(host: live.port, id: 'live'),
      buildModule(host: 1, id: 'dead'),
    ]);

    final service = ModuleApiHealthService.forTesting(store: store);
    await service.checkAll();

    expect(store.byId('live')!.status, ConnectionStatus.online);
    expect(store.byId('dead')!.status, ConnectionStatus.offline);

    await live.close();
  });
}
