// lib/services/module_status/soleux_json_service.dart
//
// Persistent Control API / JSON command service for Soleux devices, implemented
// against the transport/JSON split described in
// doc/Soleux_Control_API_Command_Specification_v0.2.md §"Transport and message
// envelope".
//
//   - one persistent, auto-reconnecting socket per device (reused via
//     [ModuleTcpConnection]);
//   - a buffered CR/LF line reader (never assume one read == one message);
//   - JSON responses matched by `id`, never by arrival order; a unique `id`
//     guards every outstanding request;
//   - the Control API framing (a plain JSON object per line, no `J:` prefix,
//     with the outer `protocol` field) is the default. [SoleuxJsonFraming.legacyJ]
//     is DEPRECATED (legacy pre-Control-API devices) and no longer used by a
//     production path; retained for the staged removal of the legacy stack;
//   - unsolicited JSON device events (`event` + `data`, or the protocol-2
//     broadcast `event` + `result` with `id:null`, doc/...Specification_v0.6.md
//     §"Device events" / Soleux-Mobile-TCP-Protocol.md) are routed to
//     [deviceEventStream] as parsed [SoleuxDeviceEvent]s;
//   - non-JSON lines (legacy welcome status dump, unsolicited `OUT:`/`IN:`
//     state, `OVERRIDE:`, `GETENERGY:`, `OK`, ...) are routed to [eventStream]
//     as parsed [SoleuxLegacyEvent]s. This is DEPRECATED legacy handling and is
//     retained for the staged removal of the legacy stack.
//
// Command framing lives here; rendering onto a [DeviceModule] is the job of the
// Soleux JSON fetcher (soleux_json_fetcher.dart).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/soleux/soleux_device_event.dart';
import '../../core/soleux/soleux_json_protocol.dart';
import 'module_tcp_service.dart';
import 'soleux_control_api_service.dart';

export '../../core/soleux/soleux_json_protocol.dart' show SoleuxJsonFraming;

/// One in-flight JSON request waiting for its response.
class _JsonPending {
  final Completer<SoleuxJsonResponse> completer;
  final Timer timer;

  _JsonPending({required this.completer, required this.timer});
}

/// Kind of a parsed non-JSON (legacy) line.
///
/// DEPRECATED — legacy protocol handling; retained for the staged removal of
/// the legacy stack (current modules push JSON Control API device events).
@Deprecated('The legacy non-JSON line protocol is no longer supported; the '
    'Control API (TCP 5008) is the only protocol. Retained for staged removal.')
enum SoleuxLegacyEventType {
  output,
  input,
  overrideOn,
  overrideOff,
  energy,
  ok,
  error,
  other
}

/// A parsed non-JSON (legacy) line emitted by the device.
///
/// DEPRECATED — legacy protocol handling; retained for the staged removal.
@Deprecated('The legacy non-JSON line protocol is no longer supported; the '
    'Control API (TCP 5008) is the only protocol. Retained for staged removal.')
class SoleuxLegacyEvent {
  final String raw;
  final SoleuxLegacyEventType type;

  /// Channel for `OUT:<ch>:<ON|OFF>` / `IN:<ch>:<ON|OFF>`.
  final int? channel;

  /// ON/OFF state for output/input events.
  final bool? state;

  /// Scalar key/value pairs parsed from `KEY:value` lines.
  final Map<String, String> kv;

  const SoleuxLegacyEvent({
    required this.raw,
    required this.type,
    this.channel,
    this.state,
    this.kv = const {},
  });

  /// Parses one legacy line.
  static SoleuxLegacyEvent parse(String line) {
    final trimmed = line.trim();
    final field = RegExp(r'^(OUT|IN):(\d+):(ON|OFF)$').firstMatch(trimmed);
    if (field != null) {
      final isOut = field.group(1) == 'OUT';
      return SoleuxLegacyEvent(
        raw: trimmed,
        type:
            isOut ? SoleuxLegacyEventType.output : SoleuxLegacyEventType.input,
        channel: int.parse(field.group(2)!),
        state: field.group(3) == 'ON',
      );
    }
    if (trimmed == 'OVERRIDE:ON') {
      return SoleuxLegacyEvent(
          raw: trimmed, type: SoleuxLegacyEventType.overrideOn);
    }
    if (trimmed == 'OVERRIDE:OFF') {
      return SoleuxLegacyEvent(
          raw: trimmed, type: SoleuxLegacyEventType.overrideOff);
    }
    if (trimmed.startsWith('GETENERGY:')) {
      return SoleuxLegacyEvent(
        raw: trimmed,
        type: SoleuxLegacyEventType.energy,
        kv: {'value': trimmed.substring('GETENERGY:'.length)},
      );
    }
    if (trimmed == 'OK') {
      return SoleuxLegacyEvent(raw: trimmed, type: SoleuxLegacyEventType.ok);
    }
    if (trimmed == 'ERROR' ||
        trimmed.startsWith('Error') ||
        trimmed.startsWith('ERROR:')) {
      return SoleuxLegacyEvent(raw: trimmed, type: SoleuxLegacyEventType.error);
    }
    // Generic `KEY:value` scalar (SYSTEMP, VER, ...).
    final scalar =
        RegExp(r'^([A-Za-z_][A-Za-z0-9_]*):(.*)$').firstMatch(trimmed);
    if (scalar != null) {
      return SoleuxLegacyEvent(
        raw: trimmed,
        type: SoleuxLegacyEventType.other,
        kv: {scalar.group(1)!: scalar.group(2)!.trim()},
      );
    }
    return SoleuxLegacyEvent(raw: trimmed, type: SoleuxLegacyEventType.other);
  }
}

/// Persistent JSON protocol command service for one Soleux device.
///
/// This is the TCP implementation of the transport-neutral [SoleuxControlApiService]
/// surface: commands are one JSON object per line over an auto-reconnecting
/// socket, matched by `id`; the HTTP/HTTPS counterpart is [SoleuxHttpService]
/// (soleux_http_service.dart).
class SoleuxJsonService extends SoleuxControlApiService {
  final ModuleTcpConnection _connection;

  /// Wire framing selected at construction ([SoleuxJsonFraming.controlApi] is
  /// the default).
  @override
  final SoleuxJsonFraming framing;

  final StreamController<SoleuxLegacyEvent> _events =
      StreamController<SoleuxLegacyEvent>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _jsonEvents =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<SoleuxDeviceEvent> _deviceEvents =
      StreamController<SoleuxDeviceEvent>.broadcast(sync: true);
  final SoleuxLineSplitter _splitter = SoleuxLineSplitter();
  final Map<int, _JsonPending> _pending = {};

  StreamSubscription<String>? _dataSubscription;
  int _nextId = 1;

  /// Application-level keep-alive that periodically sends a `hello` request on
  /// the live socket so proxies/gateways/NAT do not idle-timeout the persistent
  /// connection and half-open sockets are detected quickly.
  ///
  /// Per the protocol-2 broadcast contract (Soleux-Mobile-TCP-Protocol.md) the
  /// device's unsolicited broadcasts (`input_state_changed`,
  /// `output_state_changed`, `system_status`) do **not** reset the 30-second
  /// receive-idle timeout, so the app must keep sending periodic requests
  /// (every 15-20 s). Live state is driven entirely by those broadcasts, so a
  /// light `hello` is enough to keep the session alive.
  Timer? _keepAliveTimer;
  static const Duration _keepAliveInterval = Duration(seconds: 15);

  /// Parsed legacy/event lines from the device.
  Stream<SoleuxLegacyEvent> get eventStream => _events.stream;

  /// Unsolicited (no pending request) JSON lines, e.g. pushed configuration
  /// updates, decoded as raw maps.
  Stream<Map<String, dynamic>> get jsonEventStream => _jsonEvents.stream;

  /// Unsolicited Control API device events
  /// (doc/...Specification_v0.6.md §"Device events" / the protocol-2 broadcast
  /// contract): parsed JSON envelopes carrying `event` + `data`/`result`
  /// (e.g. `output_state_changed`, `system_status`).
  Stream<SoleuxDeviceEvent> get deviceEventStream => _deviceEvents.stream;

  /// Connection up/down transitions, forwarded from [ModuleTcpConnection].
  @override
  Stream<bool> get connectionStateStream => _connection.connectionStateStream;

  /// The underlying transport (exposes `port`/`key` for callers that probe
  /// different endpoints).
  ModuleTcpConnection get connection => _connection;

  /// Stable endpoint key (`host:port`) used to detect when an existing unit
  /// must be replaced (see [SoleuxControlApiService.transportKey]).
  @override
  String get transportKey => _connection.key;

  @override
  bool get isConnected => _connection.isConnected;

  SoleuxJsonService({
    required ModuleTcpConnection connection,
    this.framing = SoleuxJsonFraming.controlApi,
  }) : _connection = connection {
    _dataSubscription = _connection.dataStream.listen(_handleData);
  }

  /// Opens the persistent connection and starts the keep-alive timer.
  @override
  Future<void> connect() async {
    await _connection.connect();
    _startKeepAlive();
  }

  /// Closes the live socket, stops auto-reconnect and the keep-alive timer.
  @override
  Future<void> disconnect() async {
    _stopKeepAlive();
    await _connection.disconnect();
  }

  /// Starts the keep-alive heartbeat once a live socket exists. Restarting is
  /// idempotent: the previous timer (if any) is replaced.
  void _startKeepAlive() {
    _stopKeepAlive();
    if (!_connection.isConnected) return;
    _keepAliveTimer =
        Timer.periodic(_keepAliveInterval, (_) => unawaited(_sendKeepAlive()));
  }

  /// Sends a non-fatal `hello` keep-alive while the socket is live. Live state
  /// flows in through the device's broadcast events, so a bare `hello` (the
  /// documented keep-alive request, Soleux-Mobile-TCP-Protocol.md) is enough
  /// to stop the 30-second receive-idle timeout from closing the session.
  Future<void> _sendKeepAlive() async {
    if (!_connection.isConnected) return;
    try {
      await hello(timeout: const Duration(seconds: 5));
    } catch (_) {
      // Keep-alive failures are non-fatal; the socket layer handles reconnect.
    }
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// Feeds a chunk of wire data as if it had just arrived on the socket.
  /// Exposed for tests so routing/splitting logic can be exercised without
  /// real sockets.
  @visibleForTesting
  void feed(String chunk) => _handleData(chunk);

  /// Feeds decoded chunks through the buffered line splitter and routes each
  /// complete line:
  ///   - Control API device events (JSON with an `event` field and no command
  ///     `id`; `data`- or `result`-payload, see [SoleuxDeviceEvent]) surface on
  ///     [deviceEventStream];
  ///   - `J:` / plain JSON responses match pending requests by `id`;
  ///   - everything else becomes a legacy event.
  void _handleData(String chunk) {
    for (final line in _splitter.add(chunk)) {
      final deviceEvent = SoleuxDeviceEvent.maybeParse(line);
      if (deviceEvent != null) {
        _deviceEvents.add(deviceEvent);
        continue;
      }
      final response = SoleuxJsonResponse.maybeParse(line);
      if (response == null) {
        _events.add(SoleuxLegacyEvent.parse(line));
        continue;
      }
      final pending = _pending.remove(response.id);
      if (pending != null) {
        pending.timer.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.complete(response);
        }
      } else {
        // Unsolicited / unmatched JSON line - surface it as an event.
        _jsonEvents.add(response.result ?? {});
      }
    }
  }

  /// Allocates the next unique request id.
  int get _nextRequestId => _nextId++;

  /// Sends a JSON request and waits for its matching response.
  @override
  Future<SoleuxJsonResponse> request(
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_connection.isConnected) {
      throw Exception('Soleux JSON service not connected');
    }
    final id = _nextRequestId;
    if (_pending.containsKey(id)) {
      throw StateError('Duplicate request id: $id');
    }
    final completer = Completer<SoleuxJsonResponse>();
    final timer = Timer(timeout, () {
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(
            TimeoutException('Soleux JSON request $action (id $id) timed out'));
      }
    });
    _pending[id] = _JsonPending(completer: completer, timer: timer);
    _connection.write(SoleuxJsonRequest(
      id: id,
      action: action,
      params: params,
      protocol: SoleuxProtocolVersion.defaultRequest,
      legacyJPrefix: framing == SoleuxJsonFraming.legacyJ,
    ).encode());
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // Convenience wrappers over the documented common actions.
  // ---------------------------------------------------------------------------
  //
  // The `hello`, `get_relay_configuration`, `set_output_state`, ... wrappers
  // are defined once on [SoleuxControlApiService] so the TCP socket client and
  // the HTTP/HTTPS client share exactly the same command contract. Only the
  // TCP-specific raw [legacy] line helper lives here.

  /// Sends a raw legacy `AT+...` line and returns the accumulated response text
  /// up to (and including) the `OK`/`ERROR` terminator, or everything received
  /// before [timeout] elapses.
  ///
  /// DEPRECATED — legacy path only (pre-Control-API devices / the AT-only legacy
  /// port). Current modules use the Control API catalogue commands
  /// ([setOutputState], [toggleOutput], [setDimmerLevel], ...). Retained for the
  /// staged removal of the legacy stack.
  ///
  /// Requests are CRLF-terminated per the legacy protocol
  /// (doc/Soleux-Mobile-TCP-Protocol.md §"Transport").
  @Deprecated('The legacy AT protocol is no longer supported; the Control API '
      '(TCP 5008) is the only protocol. Retained for the staged removal.')
  Future<String> legacy(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    final subscription = _events.stream.listen((event) {
      buffer.writeln(event.raw);
      if (event.type == SoleuxLegacyEventType.ok ||
          event.type == SoleuxLegacyEventType.error) {
        if (!completer.isCompleted) completer.complete(buffer.toString());
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(buffer.toString());
    });
    final wire = command.contains('\n') ? command : '$command\r\n';
    _connection.write(wire);
    final raw = await completer.future;
    timer.cancel();
    await subscription.cancel();
    return raw.trimRight();
  }

  @override
  void dispose() {
    _stopKeepAlive();
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer
            .completeError(StateError('Soleux JSON service disposed'));
      }
    }
    _pending.clear();
    _dataSubscription?.cancel();
    _events.close();
    _jsonEvents.close();
    _deviceEvents.close();
    _connection.dispose();
  }

  /// Debug-friendly state for logging.
  @override
  String toString() =>
      'SoleuxJsonService(${_connection.key}, connected: $isConnected, '
      'outstanding: ${_pending.length})';
}
