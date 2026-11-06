// Integration tests for HubJsonProtocol command dispatch: protocol-1
// request/response id matching over a real loopback socket against a fake
// Modbus Hub. The caller owns the wiring (connection.dataStream -> feed()),
// exactly as the hub control screen and ModuleStatusService.sendHubOutputCommand
// do; without it every command would time out.
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
      'hello' => {'protocol': 1, 'device': 'modbus_hub', 'actions': []},
      'set_output' || 'set_modbus_output' => {
          'channel': params['channel'],
          'state': params['state'],
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
}
