// lib/services/module_status/module_command_service.dart
//
// Per-module command + status service, mirroring the reference
// `at_command_service.dart` (AtCommandService) built on top of the connection
// layer (ModuleTcpConnection, mirror of `tcp_service.dart`).
//
// Exactly like the AT service, a single subscription to the connection's
// [ModuleTcpConnection.dataStream] does two jobs at once:
//
//   1. Continuous status ingestion - the module's welcome status dump and any
//      unsolicited push broadcasts are parsed into module state (temperature,
//      firmware, output/input pin states) and published on [moduleStream].
//   2. Request/response framing - commands issued through the service are
//      matched to their `\r\nOK` / `\r\nERROR` terminator via a one-at-a-time
//      pending slot ([_PendingCommand]).
//
// State is applied to the bound [module] through the module type's
// [ModuleStatusFetcher] (same reconciliation as before), so dimmer /
// temperature / blind support keeps working without transport changes.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import 'module_status_fetcher.dart';
import 'module_tcp_service.dart';
import 'pdu_protocol.dart';

/// A single in-flight command waiting for its `\r\nOK`/`\r\nERROR` terminator.
class _PendingCommand {
  final Completer<String> completer;
  final Timer timer;
  final StringBuffer buffer;

  _PendingCommand({required this.completer, required this.timer})
      : buffer = StringBuffer();
}

class ModuleCommandService {
  final ModuleTcpConnection _connection;
  final ModuleStatusFetcher _fetcher;

  final StreamController<DeviceModule> _moduleController =
      StreamController<DeviceModule>.broadcast();
  StreamSubscription<String>? _dataSubscription;

  /// The module being refreshed. Rebound via [attach] whenever the store hands
  /// us a fresh instance so mutations land on the object every screen watches.
  DeviceModule _module;
  _PendingCommand? _pending;

  // Continuous status accumulation of the whole live session.
  final Map<String, String> _kv = {};
  final Map<int, bool> _outputs = {};
  final Map<int, bool> _inputs = {};
  final Map<int, String> _outputNames = {};
  final Map<int, String> _inputNames = {};

  /// The current live module instance.
  DeviceModule get module => _module;

  /// Emits the module every time new status data has been parsed from the wire.
  Stream<DeviceModule> get moduleStream => _moduleController.stream;

  /// Connection up/down transitions, forwarded from [ModuleTcpConnection].
  Stream<bool> get connectionStateStream => _connection.connectionStateStream;

  /// The underlying TCP connection, exposed so the status service can detect
  /// a changed endpoint (host/port) and recreate the unit instead of keeping a
  /// stale socket bound to the old port.
  ModuleTcpConnection get connection => _connection;

  bool get isConnected => _connection.isConnected;

  ModuleCommandService({
    required ModuleTcpConnection connection,
    required ModuleStatusFetcher fetcher,
    required DeviceModule module,
  })  : _connection = connection,
        _fetcher = fetcher,
        _module = module {
    _dataSubscription = _connection.dataStream.listen(_handleData);
  }

  /// Re-targets this service at a (possibly new) store instance of the module.
  /// The accumulated device state persists across instances.
  void attach(DeviceModule module) {
    _module = module;
  }

  /// Opens the connection, delegating to the underlying transport.
  Future<void> connect() => _connection.connect();

  /// Closes the live socket and stops the transport's auto-reconnect. The
  /// service itself is kept intact so it can be resumed later with [connect].
  /// Used by the lifecycle scheduler when the app goes to the background.
  Future<void> disconnect() => _connection.disconnect();

  /// Feeds every decoded chunk to both the status parser and the pending
  /// command state machine.
  void _handleData(String data) {
    var changed = false;
    for (final token in data.split('\r\n')) {
      if (_consumeLine(token)) changed = true;
    }
    if (changed) {
      _applyParsed();
    }

    if (_pending != null) {
      _pending!.buffer.write(data);
      final raw = _pending!.buffer.toString().trimRight();
      if (raw.endsWith('\r\nOK') || raw.endsWith('\r\nERROR')) {
        _pending!.timer.cancel();
        _pending!.completer.complete(raw);
        _pending = null;
      }
    }
  }

  /// Interprets a single `KEY:value` scalar, `OUT/IN:<pin>:<ON|OFF>` triplet
  /// or `CHNAME_<OUT|IN>:<pin>:<name>` triplet and folds it into the
  /// accumulated snapshot. Returns true when something was parsed.
  bool _consumeLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;

    final triplet = RegExp(r'^(OUT|IN):(\d+):(ON|OFF)$');
    final chname = RegExp(r'^CHNAME_(OUT|IN):(\d+):(.*)$');
    final scalar = RegExp(r'^([A-Z_]+):(.*)$');

    final t = triplet.firstMatch(trimmed);
    if (t != null) {
      final pin = int.parse(t.group(2)!);
      final on = t.group(3) == 'ON';
      if (t.group(1) == 'OUT') {
        _outputs[pin] = on;
      } else {
        _inputs[pin] = on;
      }
      return true;
    }

    final c = chname.firstMatch(trimmed);
    if (c != null) {
      final pin = int.parse(c.group(2)!);
      final name = c.group(3)!.trim();
      if (name.isNotEmpty) {
        if (c.group(1) == 'OUT') {
          _outputNames[pin] = name;
        } else {
          _inputNames[pin] = name;
        }
      }
      return true;
    }

    final s = scalar.firstMatch(trimmed);
    if (s != null) {
      final key = s.group(1)!;
      final value = s.group(2)!.trim();
      if (value.isNotEmpty) {
        _kv[key] = value;
        return true;
      }
    }
    return false;
  }

  /// Reconciles the accumulated snapshot onto [module] via the fetcher and
  /// publishes it.
  void _applyParsed() {
    final snapshot = PduResponse(
      ok: true,
      kv: Map.of(_kv),
      outputs: Map.of(_outputs),
      inputs: Map.of(_inputs),
      outputNames: Map.of(_outputNames),
      inputNames: Map.of(_inputNames),
    );
    _fetcher.apply(_module, [snapshot]);
    if (!_moduleController.isClosed) {
      _moduleController.add(_module);
    }
  }

  Future<String> _sendAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    debugPrint(
        'Sending command to module ${_module.name} (${_module.id}): $command');
    if (!_connection.isConnected) {
      throw Exception('Not connected');
    }
    if (_pending != null) {
      throw Exception('Command already in progress');
    }

    final completer = Completer<String>();
    final timer = Timer(timeout, () {
      _pending = null;
      if (!completer.isCompleted) {
        completer
            .completeError(TimeoutException('Command timed out: $command'));
      }
    });

    _pending = _PendingCommand(completer: completer, timer: timer);
    _connection.write(command);
    debugPrint('Command sent, waiting for response...');
    return completer.future;
  }

  bool _isOk(String response) => response.endsWith('\r\nOK');

  Future<bool> ping() async => _isOk(await _sendAndWait('AT\r'));

  /// Issues a single command, returning whether it was acknowledged with OK.
  /// Status fields it carries are applied to [module] as a side effect of the
  /// wire bytes flowing through [_handleData].
  Future<bool> command(String command) async =>
      _isOk(await _sendAndWait(command));

  /// Sequentially issues [commands], stopping at the first non-OK. Returns
  /// whether every command was acknowledged.
  Future<bool> run(List<String> commands) async {
    for (final c in commands) {
      final ok = await command(c);
      if (!ok) return false;
    }
    return true;
  }

  Future<bool> turnOnRelay(int pin) async =>
      _isOk(await _sendAndWait('AT+ON:$pin\r'));

  Future<bool> turnOffRelay(int pin) async =>
      _isOk(await _sendAndWait('AT+OFF:$pin\r'));

  Future<bool> toggleRelay(int pin) async =>
      _isOk(await _sendAndWait('AT+TOGGLE:$pin\r'));

  Future<bool> restartRelay(int pin) async =>
      _isOk(await _sendAndWait('AT+RESTART:$pin\r'));

  void dispose() {
    _pending?.timer.cancel();
    _pending = null;
    _dataSubscription?.cancel();
    _moduleController.close();
    _connection.dispose();
  }
}
