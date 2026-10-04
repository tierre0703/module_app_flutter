// End-to-end test: a protocol-2 broadcast (input_state_changed /
// output_state_changed) must flow from the live Control API socket through
// ModuleStatusService into the app-wide ModuleStore and render on the real
// relay control screen - without any get_device_state polling.
//
// This mirrors production exactly: the fake device serves the Control API
// port (legacy + 3), ModuleStatusService wires the broadcast stream into the
// shared store, and RelayControlScreen rebuilds via ListenableBuilder on that
// store.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/screens/dimmer_ac_screen.dart';
import 'package:soleux_device_manager/screens/relay_control_screen.dart';
import 'package:soleux_device_manager/services/module_status/module_status_service.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/widgets/common_widgets.dart';

/// Fake Control API device: answers `hello` / `get_relay_configuration` /
/// `get_device_state`, and pushes unsolicited protocol-2 broadcasts over the
/// same socket.
class _FakeDevice {
  final ServerSocket server;
  final String device;
  final List<_FakeSocket> _sockets = [];

  _FakeDevice._(this.server, this.device);

  static Future<_FakeDevice> start({String device = 'relay_module'}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeDevice._(server, device);
    server.listen((socket) => fake._accept(socket));
    return fake;
  }

  int get port => server.port;

  void broadcast(String line) {
    for (final entry in List.of(_sockets)) {
      if (!entry.destroyed) entry.socket.write('$line\r\n');
    }
  }

  void _accept(Socket socket) {
    final entry = _FakeSocket(socket);
    _sockets.add(entry);
    socket.done.then((_) => entry.destroyed = true);
    final buffer = StringBuffer();
    socket.listen((bytes) {
      buffer.write(utf8.decode(bytes));
      var text = buffer.toString();
      var idx = text.indexOf('\n');
      while (idx >= 0) {
        final line = text.substring(0, idx).replaceAll(RegExp(r'\r$'), '');
        _reply(line, socket);
        text = text.substring(idx + 1);
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
        'device': device,
        'name': 'Rack',
        'input_count': 2,
        'virtual_input_count': 0,
        'output_count': 2,
      };
    } else if (action == 'get_relay_configuration') {
      final dimmer = device == 'dimmer';
      result = {
        'input_count': 2,
        'virtual_input_count': 0,
        'output_count': 2,
        'outputs': [
          for (var ch = 0; ch < 2; ch++)
            {
              'channel': ch,
              'output_name': 'Output ${ch + 1}',
              'output_state': false,
              'output_on_delay': 0,
              'output_off_delay': 0,
              'output_on_run_time': 0,
              'output_off_run_time': 0,
              'start_delay': 0,
              'initial_state': 0,
              'turn_off_disable': false,
              'restart_disable': false,
              if (dimmer) 'pwm': 0,
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
    } else {
      result = {};
    }
    socket.write('${jsonEncode({
          'protocol': 2,
          'id': id,
          'ok': true,
          'result': result,
        })}\r\n');
  }
}

class _FakeSocket {
  final Socket socket;
  bool destroyed = false;

  _FakeSocket(this.socket);
}

/// Drains the on-open refresh the module screen fires from `initState`
/// (hello -> relay configuration -> device state). Each request needs real I/O
/// to receive its response (runAsync) and a pump to run the FakeAsync
/// continuation, so a few alternating cycles settle the whole chain.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
      'protocol-2 broadcasts render on the relay screen without polling',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = (await tester.runAsync(_FakeDevice.start))!;
    final module = DeviceModule(
      id: 'm-relay',
      name: 'Relay Rack',
      type: ModuleType.relay,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 24,
      tcpPort: fake.port, // controlApiPort = tcpPort = fake.port
    );

    final store = ModuleStore.shared;
    await tester.runAsync(() => store.replaceAll([module]));
    // Use the shared service (the one the screen refreshes on open) so its
    // socket is already live before the widget is pumped.
    final service = ModuleStatusService.shared;
    final refreshed = await tester.runAsync(() => service.refreshOne(module));
    expect(refreshed, isTrue,
        reason: 'Control API hello + configuration fetch must succeed');
    // Let the debounced store commit run so the config lands in the store.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RelayControlScreen(module: module),
    ));
    await tester.pump();
    await _settle(tester);

    // Both outputs start OFF, both inputs OFF.
    expect(find.byWidgetPredicate((w) => w is FilledButton && w.enabled),
        findsNothing,
        reason: 'no output is ON before the broadcast');
    expect(find.text('ON'), findsNothing,
        reason: 'no input is lit before the broadcast');

    // Device pushes protocol-2 broadcasts over the same Control API socket.
    await tester.runAsync(() async {
      fake.broadcast('{"protocol":2,"id":null,"ok":true,'
          '"event":"output_state_changed",'
          '"result":{"channel":1,"state":true,"revision":1789531200123}}');
      fake.broadcast('{"protocol":2,"id":null,"ok":true,'
          '"event":"input_state_changed",'
          '"result":{"channel":0,"state":true,"revision":1789531200000}}');
      // Let the commit debounce (150 ms) run.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // Output 1 is now ON (FilledButton) and input 0 shows the ON badge.
    // The output button label ("ON") plus the input badge make two "ON" texts.
    expect(find.byWidgetPredicate((w) => w is FilledButton && w.enabled),
        findsOneWidget,
        reason: 'output_state_changed must flip the relay output to ON');
    expect(find.text('ON'), findsNWidgets(2),
        reason: 'output ON button label + lit input indicator badge');

    // Tear the shared service's keep-alive/socket timers down so none stay
    // pending after the test.
    ModuleStatusService.shared.dispose();
    await tester.runAsync(fake.server.close);
  });

  testWidgets(
      'dimmer output_state_changed reflects the logical ON state on screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake =
        (await tester.runAsync(() => _FakeDevice.start(device: 'dimmer')))!;
    final module = DeviceModule(
      id: 'm-dimmer',
      name: 'Lobby Dimmer',
      type: ModuleType.dimmerAc,
      ipAddress: '127.0.0.1',
      status: ConnectionStatus.offline,
      roomName: 'Room',
      internalTempC: 24,
      tcpPort: fake.port,
    );

    final store = ModuleStore.shared;
    await tester.runAsync(() => store.replaceAll([module]));
    // Use the shared service (the one the screen refreshes on open) so its
    // socket is already live before the widget is pumped.
    final service = ModuleStatusService.shared;
    expect(await tester.runAsync(() => service.refreshOne(module)), isTrue);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DimmerAcScreen(module: module),
    ));
    await tester.pump();
    await _settle(tester);

    List<IconAvatar> avatars() =>
        tester.widgetList<IconAvatar>(find.byType(IconAvatar)).toList();
    expect(avatars().first.filled, isFalse, reason: 'dimmer starts OFF');

    // Device confirms the output turned on: the logical state must surface in
    // the UI even though the retained brightness level (0%) has not changed.
    await tester.runAsync(() async {
      fake.broadcast('{"protocol":2,"id":null,"ok":true,'
          '"event":"output_state_changed",'
          '"result":{"channel":0,"state":true,"revision":1789531200123}}');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(avatars().first.filled, isTrue,
        reason: 'dimmer output_state_changed must fill the channel icon');
    expect(avatars().length, greaterThan(1),
        reason: 'sanity: more than one channel avatar exists');

    // Tear the shared service's keep-alive/socket timers down so none stay
    // pending after the test.
    ModuleStatusService.shared.dispose();
    await tester.runAsync(fake.server.close);
  });
}
