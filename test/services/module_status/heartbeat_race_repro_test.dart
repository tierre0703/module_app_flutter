import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_heartbeat.dart';

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
      final nonce =
          (jsonDecode(utf8.decode(datagram.data))['nonce'] as String?)!;
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
    } catch (_) {}
  });
  return (socket, socket.port);
}

void main() {
  test(
      'commit-triggered refreshTargets during ping-await causes duplicate '
      'rapid pings / missed-cycle accumulation', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'R');
    var pingCount = 0;

    final monitor = SoleuxHeartbeatMonitor(
      interval: const Duration(milliseconds: 300),
      acceptWindow: const Duration(milliseconds: 400),
    );

    final states = <HeartbeatAvailability>[];
    monitor.onState = (target, state) => states.add(state);

    // Simulate the service: on every onPong, perform refreshTargets (as the
    // store commit listener does) while the ping for other targets may be
    // in flight.
    monitor.onPong = (target, pong) {
      pingCount++;
      monitor.refreshTargets([target]); // re-triggers _schedule during await
    };

    monitor.start(const []);
    monitor.refreshTargets([
      HeartbeatTarget(
          host: '127.0.0.1', tcpPort: 5008, heartbeatPort: serverPort),
    ]);
    await Future<void>.delayed(const Duration(seconds: 2));
    monitor.stop();
    server.close();

    debugPrint('PING COUNT: $pingCount (expect ~6-7 for fixed 300ms cadence)');
    debugPrint('STATES: $states');
    debugPrint(
        'SPURIOUS OFFLINE: ${states.contains(HeartbeatAvailability.offline)}');
    expect(pingCount, lessThan(15),
        reason: 'commit-triggered refresh during ping-await should NOT '
            'explode ping frequency');
  });
}
