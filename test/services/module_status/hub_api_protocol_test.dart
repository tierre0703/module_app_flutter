// Integration tests for HubJsonProtocol command dispatch: protocol-1
// request/response id matching over a real loopback socket against a fake
// Modbus Hub. The caller owns the wiring (connection.dataStream -> feed()),
// exactly as the hub control screen and ModuleStatusService.sendHubOutputCommand
// do; without it every command would time out.
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/module_status/hub_api_protocol.dart';
import 'package:soleux_device_manager/services/module_status/module_tcp_service.dart';

/// A fake Modbus Hub: greets like the real device (`Soleux JSON API Ready`),
/// accepts protocol-1 JSON lines and echoes an `ok` result for the actions it
/// knows.
class _FakeHub {
  final ServerSocket server;
  final List<String> received = [];

  _FakeHub._(this.server);

  static Future<_FakeHub> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hub = _FakeHub._(server);
    server.listen((socket) {
      // The Hub greets before any JSON exchange.
      socket.write('Soleux JSON API Ready\r\n');
      hub._handle(socket);
    });
    return hub;
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
        buffer.clear();
        buffer.write(text.substring(idx + 1));
        text = buffer.toString();
        idx = text.indexOf('\n');
        if (line.isEmpty) continue;
        received.add(line);
        _reply(line, socket);
      }
    }, onDone: () => socket.destroy());
  }

  void _reply(String line, Socket socket) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final id = request['id'];
    final action = request['action'];
    final params = request['params'] as Map<String, dynamic>;
    final result = switch (action) {
      'hello' => {
          'protocol': 1,
          'device': 'modbus_hub',
          'actions': [
            'hello',
            'get_device_info',
            'get_dashboard',
            'set_output',
            'get_tag',
            'set_tag',
            'get_tag_groups',
            'get_tag_group',
            'get_tag_details',
          ],
        },
      'set_output' || 'set_modbus_output' => {
          'channel': params['channel'],
          'state': params['state'],
        },
      'get_tag_groups' => {
          'groups': [
            {
              'group': 'vio',
              'name': 'Virtual Tags',
              'kind': 'builtin',
              'tag_count': 2,
            },
            {
              'group': 'therm1',
              'name': 'Thermometers',
              'kind': 'device',
              'tag_count': 1,
            },
          ],
        },
      'get_tag_group' when params['group'] == 'vio' => {
          'group': 'vio',
          'name': 'Virtual Tags',
          'kind': 'builtin',
          'tags': [
            {
              'tag': 'tag_1',
              'tag_name': 'tag_1',
              'group': 'vio',
              'category': 'virtual',
              'name': 'Tag 1',
              'value': '100',
              'parameters': {},
            },
            {
              'tag': 'Var_2',
              'tag_name': 'Var_2',
              'group': 'vio',
              'category': 'virtual',
              'name': '',
              'value': 'on',
              'parameters': {},
            },
          ],
        },
      'get_tag_group' => {
          'group': params['group'],
          'tags': [],
        },
      'get_tag_details' => {
          'tag': 'temperature',
          'tag_name': 'therm1.temperature',
          'group': 'therm1',
          'value': '23.4',
          'parameters': {'address': 1},
        },
      _ => {},
    };
    socket.write('${jsonEncode({'protocol': 1, 'id': id, 'ok': true, 'result': result})}\r\n');
  }
}

/// Opens a protocol-1 session against the fake hub the way production
/// callers do: manually pumping the connection's data stream into feed().
Future<(HubJsonProtocol, StreamSubscription<String>, ModuleTcpConnection)>
    _openSession(_FakeHub hub) async {
  final connection = ModuleTcpConnection(
    host: InternetAddress.loopbackIPv4.address,
    port: hub.port,
    timeout: const Duration(seconds: 5),
  );
  final protocol = HubJsonProtocol(connection);
  final pump = connection.dataStream.listen(protocol.feed);
  await connection.connect();
  return (protocol, pump, connection);
}

void main() {
  test('set_output completes when the data stream is wired to feed()',
      () async {
    final hub = await _FakeHub.start();
    final (protocol, pump, connection) = await _openSession(hub);
    try {
      final hello = await protocol.hello();
      expect(hello.ok, isTrue);

      final resp = await protocol.setOutput(1, true);
      expect(resp.ok, isTrue);
    } finally {
      await pump.cancel();
      // dispose() closes the underlying connection too - do not call
      // connection.dispose() again (it would close the controller twice).
      protocol.dispose();
      hub.server.close();
    }
  });

  test('set_modbus_output reaches the device with its own channel', () async {
    final hub = await _FakeHub.start();
    final (protocol, pump, connection) = await _openSession(hub);
    try {
      final resp = await protocol.setModbusOutput(2, false);
      expect(resp.ok, isTrue);

      final req = jsonDecode(hub.received.last) as Map<String, dynamic>;
      expect(req['action'], 'set_modbus_output');
      expect(req['params']['channel'], 2);
      expect(req['params']['state'], isFalse);
    } finally {
      await pump.cancel();
      protocol.dispose();
      hub.server.close();
    }
  });

  test('tag catalogue commands reach the device and parse result models',
      () async {
    final hub = await _FakeHub.start();
    final (protocol, pump, connection) = await _openSession(hub);
    try {
      final groupsResp = await protocol.getTagGroups();
      expect(groupsResp.ok, isTrue);
      final params = jsonDecode(hub.received.last) as Map<String, dynamic>;
      expect(params['action'], 'get_tag_groups');
      expect(params['protocol'], 1);

      final groups = HubTagGroupsData.fromResult(groupsResp.result!);
      expect(groups.groups.length, 2);
      expect(groups.byGroup('vio')!.tagCount, 2);
      expect(groups.byGroup('VIO')!.group, 'vio');
      expect(groups.byGroup('missing'), isNull);

      final groupResp = await protocol.getTagGroup('vio');
      expect(groupResp.ok, isTrue);
      final req = jsonDecode(hub.received.last) as Map<String, dynamic>;
      expect(req['action'], 'get_tag_group');
      expect(req['params']['group'], 'vio');

      final group = HubTagGroupData.fromResult(groupResp.result!);
      expect(group.group, 'vio');
      expect(group.tags.length, 2);
      expect(group.tags[0].tag, 'tag_1');
      expect(group.tags[0].value, '100');
      expect(group.tags[1].value, 'on');

      final cached = group.tags.map((r) => r.toVirtualTag()).toList();
      expect(cached.first, isA<HubVirtualTag>());
      expect(cached.first.tag, 'tag_1');
      expect(cached.first.tagName, 'tag_1');
      expect(cached.first.name, 'Tag 1');
      expect(cached.first.value, '100');
      // Empty reported labels degrade to null (UI falls back to the tag name).
      expect(cached[1].name, isNull);
      expect(cached[1].value, 'on');

      final detailsResp = await protocol.getTagDetails('therm1.temperature');
      expect(detailsResp.ok, isTrue);
      final last = jsonDecode(hub.received.last) as Map<String, dynamic>;
      expect(last['action'], 'get_tag_details');
      expect(last['params']['tag_name'], 'therm1.temperature');
      final record =
          HubTagRecord.fromJson(Map<String, dynamic>.from(detailsResp.result!));
      expect(record.tagName, 'therm1.temperature');
      expect(record.value, '23.4');
    } finally {
      await pump.cancel();
      protocol.dispose();
      hub.server.close();
    }
  });

  test('HubVirtualTag persists through the DeviceModule JSON round-trip', () {
    final module = DeviceModule(
      id: 'hub-1',
      name: 'Plant Hub',
      type: ModuleType.hub,
      ipAddress: '192.168.1.50',
      status: ConnectionStatus.online,
      roomName: 'Plant',
      internalTempC: 0,
      virtualTags: const [
        HubVirtualTag(
            tag: 'tag_1', tagName: 'tag_1', name: 'Tag 1', value: '100'),
        HubVirtualTag(tag: 'Var_2', tagName: 'Var_2', value: 'on'),
      ],
    );
    final restored = DeviceModule.fromJson(module.toJson());
    expect(restored.virtualTags.length, 2);
    expect(restored.virtualTags[0].tag, 'tag_1');
    expect(restored.virtualTags[0].name, 'Tag 1');
    expect(restored.virtualTags[0].value, '100');
    expect(restored.virtualTags[1].name, isNull);
    expect(restored.virtualTags[1].value, 'on');
  });
}
