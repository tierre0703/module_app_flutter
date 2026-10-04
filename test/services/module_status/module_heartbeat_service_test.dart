// Tests for the fleet-wide module heartbeat service, which maps the Soleux
// heartbeat availability state machine onto module online/offline status
// (doc/Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §4).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/core/soleux/soleux_heartbeat.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/module_status/module_heartbeat_service.dart';

/// Local UDP echo that replies a `pong` for every `ping`.
Future<(RawDatagramSocket, int)> startPongServer({
  required int tcpPort,
  required String name,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded['op'] != 'ping') return;
      final nonce = decoded['nonce'] as String;
      socket.send(
          utf8.encode(jsonEncode({
            'soleux_heartbeat': 1,
            'op': 'pong',
            'nonce': nonce,
            'tcp_port': tcpPort,
            'name': name,
          })),
          datagram.address,
          datagram.port);
    } catch (_) {
      // ignore malformed pings
    }
  });
  return (socket, socket.port);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a live module is flipped online and lastSeenAt is recorded', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'relay-1',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      // Heartbeat is the fixed well-known 5007 unless an explicit
      // heartbeatPort is given; point it at the server's ephemeral port.
      tcpPort: 5008,
      heartbeatPort: serverPort,
      status: ConnectionStatus.offline,
      roomName: 'Cabin',
      internalTempC: 25,
      channels: [
        ChannelOutput(id: 'c0', name: 'Light', icon: Icons.power),
      ],
    ));

    final service = ModuleHeartbeatService.forTesting(
      store: store,
      monitor: SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 150),
        acceptWindow: const Duration(milliseconds: 300),
        maxMissedCycles: 3,
      ),
    );

    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final module = store.byId('relay-1')!;
    expect(module.status, ConnectionStatus.online);
    expect(module.lastSeenAt, isNotNull);

    service.stop();
    server.close();
  });

  test('a device that stops answering pings goes offline', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'relay-2',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: serverPort,
      status: ConnectionStatus.online,
      roomName: 'Cabin',
      internalTempC: 25,
    ));

    final service = ModuleHeartbeatService.forTesting(
      store: store,
      monitor: SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 150),
        acceptWindow: const Duration(milliseconds: 100),
        maxMissedCycles: 3,
      ),
    );

    final states = <HeartbeatAvailability>[];
    service.onAvailability = (_, state) => states.add(state);

    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(store.byId('relay-2')!.status, ConnectionStatus.online);

    server.close(); // device disappears
    // Fail cycle is acceptWindow + interval (~250 ms); 3 consecutive misses
    // land around 1000 ms after the last pong, so 1800 ms gives margin.
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    expect(store.byId('relay-2')!.status, ConnectionStatus.offline);
    // The module is seeded online from its persisted status, so the first
    // pongs dedupe (no re-emitted `online`); the degradation to offline is
    // what fires through onState.
    expect(states, contains(HeartbeatAvailability.offline));

    service.stop();
  });

  test(
      'a module stays online while pongs succeed, even if other layers '
      'flip it offline', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'relay-4',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: serverPort,
      status: ConnectionStatus.offline,
      roomName: 'Cabin',
      internalTempC: 25,
    ));

    final service = ModuleHeartbeatService.forTesting(
      store: store,
      monitor: SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 150),
        acceptWindow: const Duration(milliseconds: 300),
        maxMissedCycles: 3,
      ),
    );

    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final module = store.byId('relay-4')!;
    expect(module.status, ConnectionStatus.online);

    // Simulate another layer (e.g. a TCP session disconnect) flipping the
    // module offline while the heartbeat keeps succeeding.
    module.status = ConnectionStatus.offline;
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(store.byId('relay-4')!.status, ConnectionStatus.online);

    service.stop();
    server.close();
  });

  test('pollFleetOnce flips online/offline via a one-shot UDP pass', () async {
    // relay-6 answers (live) while relay-7 has no server (dead).
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'relay-6',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: serverPort,
      status: ConnectionStatus.suspect,
      roomName: 'Cabin',
      internalTempC: 25,
    ));
    await store.upsert(DeviceModule(
      id: 'relay-7',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: 1, // unreachable heartbeat port
      status: ConnectionStatus.suspect,
      roomName: 'Cabin',
      internalTempC: 25,
    ));

    final service = ModuleHeartbeatService.forTesting(store: store);

    final result = await service.pollFleetOnce();

    expect(result.online.map((m) => m.id), contains('relay-6'));
    expect(result.offline.map((m) => m.id), contains('relay-7'));
    final live = store.byId('relay-6')!;
    expect(live.status, ConnectionStatus.online);
    expect(live.lastSeenAt, isNotNull);
    final dead = store.byId('relay-7')!;
    expect(dead.status, ConnectionStatus.offline);

    server.close();
  });

  test('removing a module stops its heartbeat targets', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'relay-3',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: serverPort,
      status: ConnectionStatus.online,
      roomName: 'Cabin',
      internalTempC: 25,
    ));

    final service = ModuleHeartbeatService.forTesting(
      store: store,
      monitor: SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 150),
        acceptWindow: const Duration(seconds: 1),
        maxMissedCycles: 3,
      ),
    );

    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(service.monitor.lastSeenAtFor('relay-3'), isNotNull);

    await store.remove('relay-3');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The target was removed on the store-change listener.
    expect(service.monitor.lastSeenAtFor('relay-3'), isNull);

    service.stop();
    server.close();
  });

  test(
      'a manually-added module that never answers goes offline, not online',
      () async {
    // A module freshly added by IP that is unreachable (no pong server on the
    // heartbeat port): its first few pings miss, so it must degrade to suspect
    // and then offline instead of staying at its seeded online status.
    final store = ModuleStore.forTesting();
    await store.init();

    await store.upsert(DeviceModule(
      id: 'manual-1',
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: 1, // no server -> never seen, always unreachable
      status: ConnectionStatus.online, // seeded like a freshly added module
      roomName: 'Cabin',
      internalTempC: 25,
    ));

    final states = <HeartbeatAvailability>[];
    final service = ModuleHeartbeatService.forTesting(
      store: store,
      monitor: SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 150),
        acceptWindow: const Duration(milliseconds: 60),
        maxMissedCycles: 3,
      ),
    );
    service.onAvailability = (_, state) => states.add(state);

    await service.start();
    // 3 consecutive misses land around 3 * (acceptWindow + interval) ~ 630 ms.
    await Future<void>.delayed(const Duration(milliseconds: 1400));

    final module = store.byId('manual-1')!;
    expect(module.status, ConnectionStatus.offline,
        reason: 'an unreachable never-seen module must not stay online');
    expect(states, contains(HeartbeatAvailability.offline));
    expect(states, contains(HeartbeatAvailability.suspect));
    expect(states.indexOf(HeartbeatAvailability.suspect),
        lessThan(states.indexOf(HeartbeatAvailability.offline)));

    service.stop();
  });
}
