// test/services/module_status/module_heartbeat_service_test.dart
//
// Exercises the local-device UDP heartbeat service
// (lib/services/module_status/module_heartbeat_service.dart):
//
//   - pong-applied additive identity refresh (API_TLS advisory, api_port,
//     api_version, device_id fill-on-first-use, last_seen_at);
//   - local-device target selection (remote/cloud and hostname-addressed
//     modules excluded);
//   - an end-to-end monitor round-trip against a real UDP pong server that
//     advertises API_TLS, flipping the stored module's TLS flag.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_heartbeat.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_status/module_heartbeat_service.dart';
import 'package:soleux_device_manager/services/module_store.dart';

DeviceModule _module({
  String id = 'm1',
  String ipAddress = '192.168.1.10',
  String? connectionType,
  bool? apiTls,
  String? deviceId,
  int? apiPort,
  int? apiVersion,
}) =>
    DeviceModule(
      id: id,
      name: 'Relay',
      type: ModuleType.relay,
      ipAddress: ipAddress,
      status: ConnectionStatus.offline,
      roomName: 'Plant',
      internalTempC: 25,
      connectionType: connectionType,
      apiTls: apiTls,
      deviceId: deviceId,
      apiPort: apiPort,
      apiVersion: apiVersion,
    );

void main() {
  group('applyPong (additive identity refresh)', () {
    test('an advertised API_TLS advisory flips the module TLS flag', () {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      final module = _module(apiTls: false);

      service.applyPong(module, _pong(apiTls: true));
      expect(module.apiTls, isTrue);

      service.applyPong(module, _pong(apiTls: false));
      expect(module.apiTls, isFalse);
    });

    test('an absent api_tls field does not clobber the saved flag', () {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      final module = _module(apiTls: true);

      service.applyPong(module, _pong());
      expect(module.apiTls, isTrue);
    });

    test('api_port / api_version follow the advertised values', () {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      final module = _module(apiPort: 5008, apiVersion: 3);

      service.applyPong(
          module, _pong(apiPort: 5010, apiVersion: 4, apiTls: true));
      expect(module.apiPort, 5010);
      expect(module.apiVersion, 4);
      expect(module.controlApiPort, 5010);
    });

    test('device_id is only filled when the module has none saved', () {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      final module = _module();

      service.applyPong(module, _pong(deviceId: 'modbus_hub-1'));
      expect(module.deviceId, 'modbus_hub-1');

      // A later pong (unauthenticated datagram) must never rebind it.
      service.applyPong(module, _pong(deviceId: 'attacker-device-2'));
      expect(module.deviceId, 'modbus_hub-1');
    });

    test('the pong refreshes last_seen_at (its documented semantic)', () {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      final module = _module();

      expect(module.lastSeenAt, isNull);
      service.applyPong(module, _pong());
      expect(module.lastSeenAt, isNotNull);
    });

    test('a store module is located and refreshed through the monitor path',
        () async {
      final store = ModuleStore.forTesting();
      final module = _module(apiTls: false, deviceId: 'modbus_hub-9');
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onPong
          ?.call(HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
              _pong(apiTls: true));
      service.stop();

      expect(store.byId('m1')!.apiTls, isTrue);
    });
  });

  group('local-device target selection', () {
    test('includes a plain local module with the advertised heartbeat port',
        () async {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      await store.replaceAll([
        _module(id: 'local', ipAddress: '192.168.1.10', apiTls: true),
      ]);

      final targets = service.buildTargets();
      expect(targets, hasLength(1));
      expect(targets.first.stabilizationKey, 'local');
      expect(targets.first.heartbeatPort, 5007);
      // Seeded from the persisted status: an offline module starts offline.
      expect(targets.first.initialAvailability, HeartbeatAvailability.offline);
      service.stop();
    });

    test('excludes remote/cloud and hostname-addressed modules', () async {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      await store.replaceAll([
        _module(id: 'local', ipAddress: '192.168.1.10'),
        _module(
            id: 'remote',
            ipAddress: 'vpn.example.com',
            connectionType: 'remote'),
        _module(id: 'cloud', ipAddress: '192.168.1.11',
            connectionType: 'cloud'),
        _module(id: 'hostname', ipAddress: 'relay.lan'),
      ]);

      final targets = service.buildTargets();
      expect(
        targets.map((t) => t.stabilizationKey),
        ['local'],
      );
      service.stop();
    });

    test('an advertised heartbeat port wins over the well-known 5007',
        () async {
      final store = ModuleStore.forTesting();
      final service = ModuleHeartbeatService.forTesting(store: store);
      await store.replaceAll([
        _module(id: 'advertised', ipAddress: '192.168.1.10'),
      ]);
      store.byId('advertised')!.heartbeatPort = 5017;

      expect(service.buildTargets().first.heartbeatPort, 5017);
      service.stop();
    });
  });

  group('online/offline policy (mirrors ModuleApiHealthService.checkOne)',
      () {
    test('a valid pong is recovery: offline -> online (lastSeenAt set)',
        () async {
      final store = ModuleStore.forTesting();
      final module = _module();
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onState?.call(
        HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
        HeartbeatAvailability.online,
      );
      service.stop();

      final live = store.byId('m1')!;
      expect(live.status, ConnectionStatus.online);
      expect(live.lastSeenAt, isNotNull);
    });

    test('a pong also recovers an unknown module straight to online',
        () async {
      final store = ModuleStore.forTesting();
      final module = _module()..status = ConnectionStatus.unknown;
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onState?.call(
        HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
        HeartbeatAvailability.online,
      );
      service.stop();

      expect(store.byId('m1')!.status, ConnectionStatus.online);
    });

    test('one missed ping degrades an online module to unknown', () async {
      final store = ModuleStore.forTesting();
      final module = _module()..status = ConnectionStatus.online;
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onState?.call(
        HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
        HeartbeatAvailability.suspect,
      );
      service.stop();

      expect(store.byId('m1')!.status, ConnectionStatus.unknown);
    });

    test('one missed ping keeps an offline module offline', () async {
      final store = ModuleStore.forTesting();
      final module = _module()..status = ConnectionStatus.offline;
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onState?.call(
        HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
        HeartbeatAvailability.suspect,
      );
      service.stop();

      expect(store.byId('m1')!.status, ConnectionStatus.offline);
    });

    test('maxMissedCycles consecutive misses flag the device gone: offline',
        () async {
      final store = ModuleStore.forTesting();
      final module = _module()..status = ConnectionStatus.unknown;
      await store.replaceAll([module]);

      final monitor = SoleuxHeartbeatMonitor();
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();
      monitor.onState?.call(
        HeartbeatTarget(host: '192.168.1.10', tcpPort: 5008, key: 'm1'),
        HeartbeatAvailability.offline,
      );
      service.stop();

      expect(store.byId('m1')!.status, ConnectionStatus.offline);
    });
  });

  group('end-to-end monitor round-trip (real UDP pong with API_TLS)', () {
    test('the stored module flips to TLS on an advertised pong', () async {
      final server = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4, 0);
      server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = server.receive();
        if (datagram == null) return;
        try {
          final decoded = jsonDecode(utf8.decode(datagram.data));
          if (decoded['op'] != 'ping') return;
          final nonce = decoded['nonce'] as String;
          final reply = utf8.encode(jsonEncode({
            'soleux_heartbeat': 1,
            'op': 'pong',
            'nonce': nonce,
            'tcp_port': 5008,
            'api_port': 5008,
            'api_version': 3,
            'api_tls': 1,
            'device_id': 'modbus_hub-123',
          }));
          server.send(reply, datagram.address, datagram.port);
        } catch (_) {
          // ignore malformed pings
        }
      });

      final store = ModuleStore.forTesting();
      final module = _module(
        id: 'hub',
        ipAddress: '127.0.0.1',
        apiTls: false,
      );
      await store.replaceAll([module]);
      // Point the heartbeat at the test server's ephemeral port.
      store.byId('hub')!.heartbeatPort = server.port;

      final monitor = SoleuxHeartbeatMonitor(
        interval: const Duration(milliseconds: 200),
        acceptWindow: const Duration(milliseconds: 500),
      );
      final service =
          ModuleHeartbeatService.forTesting(store: store, monitor: monitor);
      service.start();

      try {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (store.byId('hub')!.apiTls != true) {
          if (DateTime.now().isAfter(deadline)) {
            fail('API_TLS was not refreshed from the pong within 5 s');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(store.byId('hub')!.deviceId, 'modbus_hub-123');
        expect(store.byId('hub')!.lastSeenAt, isNotNull);
        // The valid pong is recovery: the module flips online with the
        // same policy the 5008 API check applies.
        expect(store.byId('hub')!.status, ConnectionStatus.online);
      } finally {
        service.stop();
        server.close();
      }
    });
  });
}

/// A minimal pong body with the additive fields under test.
SoleuxPong _pong({
  bool? apiTls,
  int? apiPort,
  int? apiVersion,
  String? deviceId,
}) =>
    SoleuxPong(
      nonce: 'n',
      tcpPort: 5008,
      apiPort: apiPort,
      apiVersion: apiVersion,
      apiTls: apiTls,
      deviceId: deviceId,
    );

