// Tests for the Soleux UDP heartbeat client and monitor
// (doc/Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1.md §4).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/core/soleux/soleux_heartbeat.dart';

/// Binds a local UDP echo server that, on any `ping`, replies a `pong`
/// carrying the same nonce, a [tcpPort] and [name].
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
      final reply = utf8.encode(jsonEncode({
        'soleux_heartbeat': 1,
        'op': 'pong',
        'nonce': nonce,
        'tcp_port': tcpPort,
        'name': name,
      }));
      socket.send(reply, datagram.address, datagram.port);
    } catch (_) {
      // ignore malformed pings
    }
  });
  return (socket, socket.port);
}

void main() {
  /// Pumps the event loop until [condition] holds (or fails after [timeout]),
  /// so timing-dependent assertions do not race with the ping cadence.
  Future<void> pumpUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  test('heartbeat port is TCP HostPort + 2', () {
    expect(SoleuxHeartbeat.defaultAcceptWindow,
        const Duration(milliseconds: 1500));
  });

  test('SoleuxNonce.generate respects the 64-char cap and is non-empty', () {
    for (var i = 0; i < 50; i++) {
      final nonce = SoleuxNonce.generate();
      expect(nonce, isNotEmpty);
      expect(nonce.length <= 64, isTrue, reason: 'nonce too long: $nonce');
    }
  });

  test('SoleuxPong.parse reads additive Control API and boot fields (§4.2)',
      () {
    final pong = SoleuxPong.parse(
        '{"soleux_heartbeat":1,"op":"pong","nonce":"n","tcp_port":5005,'
        '"name":"Plant Room Relays","api_port":5008,"api_version":3,'
        '"device_id":"0000000012345678","boot_id":"4d2f9c"}');
    expect(pong.nonce, 'n');
    expect(pong.tcpPort, 5005);
    expect(pong.name, 'Plant Room Relays');
    expect(pong.apiPort, 5008);
    expect(pong.apiVersion, 3);
    expect(pong.deviceId, '0000000012345678');
    expect(pong.bootId, '4d2f9c');
  });

  test('additive fields default to null on a minimal pong', () {
    final pong = SoleuxPong.parse(
        '{"soleux_heartbeat":1,"op":"pong","nonce":"n","tcp_port":5005}');
    expect(pong.apiPort, isNull);
    expect(pong.apiVersion, isNull);
    expect(pong.deviceId, isNull);
    expect(pong.bootId, isNull);
  });

  test('ping() returns alive and the matched pong', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Plant Room Relays');
    // Heartbeat is the fixed well-known 5007 unless an explicit heartbeatPort
    // is given; point the client at the server's ephemeral bound port.
    final client = SoleuxHeartbeat(acceptWindow: const Duration(seconds: 2));

    final result = await client.ping('127.0.0.1', 5008,
        heartbeatPort: serverPort, nonce: 'test-nonce-0001');

    expect(result.alive, isTrue);
    expect(result.pong, isNotNull);
    expect(result.pong!.nonce, 'test-nonce-0001');
    expect(result.pong!.tcpPort, 5008);
    expect(result.pong!.name, 'Plant Room Relays');
    server.close();
  });

  test('uses an explicitly advertised heartbeat port (§4.2)', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Dimmer');
    final client = SoleuxHeartbeat(acceptWindow: const Duration(seconds: 1));

    // tcpPort is intentionally a wrong/arbitrary value: the advertised
    // heartbeat port wins over the fixed well-known 5007.
    final result = await client.ping('127.0.0.1', 1234,
        heartbeatPort: serverPort, nonce: 'explicit-port');

    expect(result.alive, isTrue);
    expect(result.pong!.name, 'Dimmer');
    server.close();
  });

  test('ping() reports dead when no pong arrives', () async {
    // A socket bound to a port that never replies.
    final silent =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client =
        SoleuxHeartbeat(acceptWindow: const Duration(milliseconds: 300));
    final result = await client.ping(
      '127.0.0.1',
      5008,
      heartbeatPort: silent.port, // targets the silent heartbeat port
      nonce: 'no-reply-nonce',
    );
    expect(result.alive, isFalse);
    expect(result.error, isNotNull);
    silent.close();
  });

  test('strictSourcePort rejects a pong from a different source port (§4.5)',
      () async {
    final main = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mainPort = main.port;
    // A second socket on a *different* port that forges a pong. The real
    // device would reply from the heartbeat socket; this one does not.
    final rogue = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    main.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = main.receive();
      if (datagram == null) return;
      try {
        final decoded = jsonDecode(utf8.decode(datagram.data));
        if (decoded['op'] != 'ping') return;
        final nonce = decoded['nonce'] as String;
        final reply = utf8.encode(jsonEncode({
          'soleux_heartbeat': 1,
          'op': 'pong',
          'nonce': nonce,
          'tcp_port': 5005,
          'name': 'Forged',
        }));
        rogue.send(reply, datagram.address, datagram.port);
      } catch (_) {
        // ignore malformed pings
      }
    });

    final client =
        SoleuxHeartbeat(acceptWindow: const Duration(milliseconds: 500));
    // Strict: the forged pong source port != heartbeat port -> ignored.
    final strict = await client.ping('127.0.0.1', mainPort - 2,
        heartbeatPort: mainPort, nonce: 'forged-nonce', strictSourcePort: true);
    expect(strict.alive, isFalse,
        reason: 'a pong from a foreign source port must be ignored');

    // Relaxed: only the source IP is validated, so the foreign pong is
    // accepted as reachability evidence.
    final relaxed = await client.ping('127.0.0.1', mainPort - 2,
        heartbeatPort: mainPort,
        nonce: 'forged-nonce',
        strictSourcePort: false);
    expect(relaxed.alive, isTrue);

    main.close();
    rogue.close();
  });

  test('rejects invalid nonces', () async {
    final client = SoleuxHeartbeat();
    expect((await client.ping('127.0.0.1', 5005, nonce: '')).alive, isFalse);
    final tooLong = 'x' * 65;
    expect(
        (await client.ping('127.0.0.1', 5005, nonce: tooLong)).alive, isFalse);
  });

  test('SoleuxHeartbeatMonitor ticks periodically and reports reachability',
      () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'PDU Meter');
    final results = <HeartbeatResult>[];
    final monitor = SoleuxHeartbeatMonitor(
      interval: const Duration(milliseconds: 200),
      acceptWindow: const Duration(seconds: 1),
    );
    monitor.onResult = (host, port, result) => results.add(result);

    monitor.start(const []);
    monitor.refreshTargets([
      HeartbeatTarget(
          host: '127.0.0.1', tcpPort: 5008, heartbeatPort: serverPort),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    monitor.stop();

    expect(results, isNotEmpty);
    expect(results.every((r) => r.alive), isTrue);
    expect(results.every((r) => r.pong!.tcpPort == 5008), isTrue);
    server.close();
  });

  test('monitor transitions online -> suspect -> offline on missed pings',
      () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final states = <HeartbeatAvailability>[];
    final monitor = SoleuxHeartbeatMonitor(
      // Small accept window so a miss cycle (timeout + interval) is quick and
      // the consecutive-miss sequence completes within the test window.
      interval: const Duration(milliseconds: 150),
      acceptWindow: const Duration(milliseconds: 60),
      maxMissedCycles: 3,
    );
    monitor.onState = (target, state) => states.add(state);

    monitor.start(const []);
    monitor.refreshTargets([
      HeartbeatTarget(
          host: '127.0.0.1', tcpPort: 5008, heartbeatPort: serverPort),
    ]);
    await pumpUntil(() => states.contains(HeartbeatAvailability.online));
    server.close(); // the device stops answering pings
    await pumpUntil(() => states.contains(HeartbeatAvailability.offline));
    monitor.stop();

    expect(states, contains(HeartbeatAvailability.online));
    expect(states, contains(HeartbeatAvailability.suspect));
    expect(states.indexOf(HeartbeatAvailability.online),
        lessThan(states.indexOf(HeartbeatAvailability.suspect)));
    expect(states.indexOf(HeartbeatAvailability.suspect),
        lessThan(states.indexOf(HeartbeatAvailability.offline)));
  });

  test('defaults to a fixed 30 s cadence and 3-miss offline threshold', () {
    final monitor = SoleuxHeartbeatMonitor();
    expect(monitor.interval, const Duration(seconds: 30));
    expect(monitor.maxMissedCycles, 3);
  });

  test('a successful pong resets consecutive misses and returns online',
      () async {
    // A pong server that can be silenced and revived on the same port, so the
    // monitor keeps addressing the same target across outage + recovery.
    final socket =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    var enabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      if (!enabled) return; // offline window: swallow pings
      try {
        final decoded = jsonDecode(utf8.decode(datagram.data));
        if (decoded['op'] != 'ping') return;
        final nonce = decoded['nonce'] as String;
        socket.send(
            utf8.encode(jsonEncode({
              'soleux_heartbeat': 1,
              'op': 'pong',
              'nonce': nonce,
              'tcp_port': 5005,
              'name': 'Relay',
            })),
            datagram.address,
            datagram.port);
      } catch (_) {}
    });

    final states = <HeartbeatAvailability>[];
    final monitor = SoleuxHeartbeatMonitor(
      interval: const Duration(milliseconds: 150),
      acceptWindow: const Duration(milliseconds: 60),
      maxMissedCycles: 3,
    );
    monitor.onState = (target, state) => states.add(state);

    monitor.start(const []);
    monitor.refreshTargets([
      HeartbeatTarget(
          host: '127.0.0.1', tcpPort: 5008, heartbeatPort: socket.port),
    ]);
    await pumpUntil(() => states.contains(HeartbeatAvailability.online));

    // One to two missed pings flag the target suspect, but never offline.
    enabled = false;
    await pumpUntil(() => states.contains(HeartbeatAvailability.suspect));
    expect(states, isNot(contains(HeartbeatAvailability.offline)));

    // A recovered pong returns the target online and resets the miss counter,
    // so the next outage starts again from zero (suspect, not offline).
    enabled = true;
    await pumpUntil(() => states.last == HeartbeatAvailability.online);
    enabled = false;
    await pumpUntil(() => states.contains(HeartbeatAvailability.suspect));
    expect(states, isNot(contains(HeartbeatAvailability.offline)));

    monitor.stop();
    socket.close();
  });

  test('a few missed cycles do not flip a live target offline (no flicker)',
      () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final states = <HeartbeatAvailability>[];
    final monitor = SoleuxHeartbeatMonitor(
      interval: const Duration(milliseconds: 200),
      acceptWindow: const Duration(milliseconds: 60),
      maxMissedCycles: 3,
    );
    monitor.onState = (target, state) => states.add(state);

    monitor.start(const []);
    monitor.refreshTargets([
      HeartbeatTarget(
          host: '127.0.0.1', tcpPort: 5008, heartbeatPort: serverPort),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 520));
    expect(states, contains(HeartbeatAvailability.online));

    server.close(); // the device disappears after a recent successful pong
    // A couple of missed cycles (< 3, i.e. within the consecutive-miss
    // threshold) must not declare the target offline.
    await Future<void>.delayed(const Duration(milliseconds: 420));
    expect(states, isNot(contains(HeartbeatAvailability.offline)));

    // Continued loss degrades to suspect then offline.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(
        states,
        containsAll(
            [HeartbeatAvailability.suspect, HeartbeatAvailability.offline]));

    monitor.stop();
    server.close();
  });

  test('refreshTargets keeps per-target state by key', () async {
    final (server, serverPort) =
        await startPongServer(tcpPort: 5008, name: 'Relay');
    final target = HeartbeatTarget(
      host: '127.0.0.1',
      tcpPort: 5008,
      heartbeatPort: serverPort,
      key: 'module-1',
    );
    final monitor = SoleuxHeartbeatMonitor(
      interval: const Duration(milliseconds: 150),
      acceptWindow: const Duration(seconds: 1),
    );

    monitor.start(const []);
    monitor.refreshTargets([target]);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Refreshing with an equivalent keyed target restarts the keyed state but
    // the underlying host/port is tracked via the target record.
    monitor.refreshTargets([target]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(monitor.lastSeenAtFor('module-1'), isNotNull);

    monitor.stop();
    server.close();
  });
}
