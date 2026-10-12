// lib/services/module_status/module_api_health_service.dart
//
// Single source of truth for a module's online / unknown / offline status.
//
// Reachability is decided *only* by the module's 5008 Control API port
// ([DeviceModule.controlApiPort]); the legacy UDP heartbeat port (5007) no
// longer participates in the online/offline decision.
//
// Status model (mirrors the brief for the new check):
//   - a module is seeded [ConnectionStatus.offline] and stays offline until the
//     5008 API answers for the first time;
//   - while the 5008 API answers (a `hello` round-trip succeeds) the module is
//     [ConnectionStatus.online] and `lastSeenAt` is refreshed;
//   - when the 5008 API stops answering (the socket is dead / nothing answers
//     within the timeout) a module that was online *and is still reachable on
//     the network* becomes [ConnectionStatus.unknown] - "was online, API is
//     broken";
//   - when the module is not reachable at all (the TCP socket cannot be opened)
//     it is [ConnectionStatus.offline]. A module that was never online therefore
//     goes straight to offline, never through unknown.
//
// The service shares the persistent Control API socket owned by
// [ModuleStatusService] (so a broken API session is also what the probe sees)
// and only opens a throw-away socket to tell "device gone" apart from "device
// up, API broken" when the shared unit is no longer connected.
//
// Each module is checked independently and concurrently on a periodic cadence,
// so a slow or unreachable module never delays the rest of the fleet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/soleux/soleux_json_protocol.dart';
import '../../models/models.dart';
import '../module_store.dart';
import '../module_host_resolver.dart';
import 'module_status_service.dart';
import 'soleux_control_api_service.dart';

/// Periodic 5008-API reachability monitor that owns [ConnectionStatus].
class ModuleApiHealthService {
  static ModuleApiHealthService? _shared;
  static ModuleApiHealthService get shared =>
      _shared ??= ModuleApiHealthService(
          store: ModuleStore.shared,
          statusService: () => ModuleStatusService.shared);

  /// Creates an isolated service for tests.
  @visibleForTesting
  static ModuleApiHealthService forTesting({
    required ModuleStore store,
    ModuleStatusService? statusService,
  }) =>
      ModuleApiHealthService(
        store: store,
        statusService: statusService == null ? null : () => statusService,
      );

  final ModuleStore store;

  /// Resolves the owning status service (which holds the persistent Control API
  /// sockets). Null keeps the service socket-only, used by tests.
  final ModuleStatusService? Function()? _statusService;

  /// How often every module's 5008 API is re-checked.
  final Duration interval;

  /// How long a single API check (socket connect + `hello`) may take.
  final Duration timeout;

  bool _running = false;
  Timer? _timer;
  Timer? _commitDebounce;
  bool _checking = false;

  ModuleApiHealthService({
    required this.store,
    ModuleStatusService? Function()? statusService,
    this.interval = defaultInterval,
    this.timeout = defaultTimeout,
  }) : _statusService = statusService;

  /// Production cadence for the 5008 API check.
  static const Duration defaultInterval = Duration(seconds: 15);

  /// Per-module timeout for one API check: a socket that is dead (connection
  /// refused / no route) fails immediately, while a half-open socket is caught
  /// by this window.
  static const Duration defaultTimeout = Duration(seconds: 3);

  /// Per-module timeout for the `hello` round-trip that confirms the API works.
  static const Duration _helloTimeout = Duration(seconds: 2);

  bool get running => _running;

  /// Starts the periodic API check. Idempotent. The first pass runs
  /// immediately so a freshly launched app converges on real status quickly.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    store.addListener(_onStoreChanged);
    unawaited(checkAll());
    _timer = Timer.periodic(interval, (_) => unawaited(checkAll()));
  }

  /// Stops the periodic check (used when the app backgrounds, where the native
  /// background worker takes over). Idempotent.
  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _commitDebounce?.cancel();
    _commitDebounce = null;
    store.removeListener(_onStoreChanged);
  }

  /// Runs one immediate pass without toggling the lifecycle state (used after
  /// a network change).
  Future<void> refreshNow() => checkAll();

  void _onStoreChanged() {
    if (!_running || _checking) return;
    // A module was added, removed or re-addressed: re-check now so its status
    // catches up immediately instead of waiting for the next periodic pass.
    unawaited(_initialiseNewModules().then((_) => kick()));
  }

  /// Seeds every module that has no status baseline yet to offline, so a
  /// module that has never answered the 5008 API never shows as online.
  Future<void> _initialiseNewModules() async {
    await store.init();
    var changed = false;
    for (final module in store.modules) {
      if (_seen.contains(module.id)) continue;
      _seen.add(module.id);
      if (module.status != ConnectionStatus.offline) {
        module.status = ConnectionStatus.offline;
        changed = true;
      }
    }
    if (changed) await store.commit();
  }

  /// Ids the service has already produced a verdict for in this process.
  final Set<String> _seen = <String>{};

  /// Checks every module's 5008 API concurrently and commits once.
  Future<void> checkAll() async {
    if (_checking) return;
    _checking = true;
    try {
      await store.init();
      await _initialiseNewModules();
      final modules = store.modules;
      await Future.wait(modules.map(checkOne));
      await store.commit();
    } catch (e, st) {
      debugPrint('ModuleApiHealthService: check pass failed: $e\n$st');
    } finally {
      _checking = false;
    }
  }

  /// Checks one module's 5008 API and updates its [ConnectionStatus].
  ///
  /// Returns the module's status after the check.
  Future<ConnectionStatus> checkOne(DeviceModule module) async {
    final live = store.byId(module.id) ?? module;
    final previous = live.status;

    // true = API answered, false = socket opened but the API did not answer,
    // null = the socket itself could not be opened (module unreachable).
    final bool? api = await _apiAnswers(live);

    final ConnectionStatus next;
    if (api == true) {
      // Recovery always wins: as soon as the 5008 API answers, the module is
      // online again - from unknown and from offline alike.
      next = ConnectionStatus.online;
      live.lastSeenAt = DateTime.now();
    } else if (api == false) {
      // The socket opened: the device is on the network, so a module that is
      // not answering the API is `unknown`. A module that never answered is
      // still `offline` until it is confirmed.
      next = previous == ConnectionStatus.offline
          ? ConnectionStatus.offline
          : ConnectionStatus.unknown;
    } else {
      // Socket dead / unreachable - the module is gone.
      next = ConnectionStatus.offline;
      final reachable = await _socketReachable(live);
      if (reachable && previous != ConnectionStatus.offline) {
        // It is back on the network but the API session could not be opened:
        // report the degraded state rather than offline.
        return _apply(live, ConnectionStatus.unknown, previous, commit: false);
      }
    }

    return _apply(live, next, previous);
  }

  ConnectionStatus _apply(
      DeviceModule live, ConnectionStatus next, ConnectionStatus previous,
      {bool commit = true}) {
    if (live.status != next) {
      live.status = next;
      if (commit) {
        _scheduleCommit();
      }
      debugPrint('ModuleApiHealthService: ${live.name} (${live.id}) '
          '${previous.name} -> ${next.name}');
    }
    return next;
  }

  /// Checks the module's 5008 Control API.
  ///
  /// Prefers the persistent unit already owned by [ModuleStatusService] (so a
  /// broken session is detected exactly where the probe sees it). When there is
  /// no live unit, a throw-away socket performs the same hello round-trip.
  ///
  /// Returns true (API answered), false (socket open, no API answer) or null
  /// (socket could not be opened).
  Future<bool?> _apiAnswers(DeviceModule module) async {
    final unit = _statusService?.call()?.jsonCommandServiceFor(module.id);
    if (unit != null && unit.isConnected) {
      // The persistent session is live; a failed hello means the API is
      // broken while the socket still exists.
      return _helloOk(unit);
    }
    return _transientHello(module);
  }

  Future<bool> _helloOk(SoleuxControlApiService unit) async {
    try {
      final hello = await unit.hello(timeout: _helloTimeout);
      return hello.ok;
    } catch (e, st) {
      debugPrint('ModuleApiHealthService: API hello failed: $e\n$st');
      return false;
    }
  }

  /// Opens a short-lived Control API socket and sends `hello`.
  ///
  /// [module.ipAddress] may be a literal IPv4/IPv6 address *or* a domain name
  /// (remote mode). A domain can resolve to several addresses (e.g. IPv6 +
  /// IPv4), so every resolved address is tried in turn until one socket opens;
  /// the first that opens is the one `hello` is sent on.
  ///
  /// Returns true when the module answered `ok` (API alive), false when the
  /// socket opened but nothing valid came back in time (socket alive, API
  /// broken), and **null** when no socket could be opened at all (module
  /// unreachable - the caller reports offline).
  Future<bool?> _transientHello(DeviceModule module) async {
    final port = module.controlApiPort;
    final Socket? socket = await _openSocket(module.host, port);
    if (socket == null) return null;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final id = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
      socket.write(SoleuxJsonRequest(
        id: id,
        action: SoleuxControlApiActions.hello,
        protocol: SoleuxProtocolVersion.defaultRequest,
      ).encode());

      final hello = await _firstJsonResponse(socket, id);
      return hello?.ok ?? false;
    } catch (e, st) {
      debugPrint('ModuleApiHealthService: API hello on ${module.ipAddress}:'
          '$port failed: $e\n$st');
      return false;
    } finally {
      try {
        socket.destroy();
      } catch (e, st) {
        debugPrint('ModuleApiHealthService: socket destroy failed: $e\n$st');
      }
    }
  }

  /// Stops the periodic poll and runs one pass immediately, so the next check
  /// is not blocked behind a slow periodic tick.
  Future<void> kick() => checkAll();

  /// Opens a TCP socket to [host]:[port]. [host] is normally a module's cached
  /// endpoint ([DeviceModule.host]), i.e. an IP literal; a hostname is still
  /// accepted (resolved IPv4-first, each address tried) as a fallback when no
  /// cached IP exists. Returns null when no address could be reached.
  Future<Socket?> _openSocket(String host, int port) => connectModuleSocket(
        host,
        port,
        timeout: timeout,
        debugTag: 'ModuleApiHealthService',
      );

  /// True when a TCP socket to the module's 5008 API port can be opened at all.
  /// Used to tell "device is gone" apart from "device is up but the API is
  /// broken".
  Future<bool> _socketReachable(DeviceModule module) async {
    final socket = await _openSocket(module.host, module.controlApiPort);
    if (socket == null) return false;
    try {
      return true;
    } finally {
      try {
        socket.destroy();
      } catch (_) {
        // Nothing to do: the check is best-effort.
      }
    }
  }

  /// Waits for the JSON response with [id]. The line splitter tolerates a
  /// response split across TCP chunks; a partial frame simply times out.
  ///
  /// The raw received bytes are logged (and returned via [onRaw]) so a
  /// device/proxy that answers something other than the expected JSON envelope
  /// is visible in the debug log instead of silently timing out.
  Future<SoleuxJsonResponseLike?> _firstJsonResponse(
    Socket socket,
    int id, {
    void Function(String raw)? onRaw,
  }) async {
    final completer = Completer<SoleuxJsonResponseLike?>();
    final buffer = StringBuffer();
    final seen = StringBuffer();
    var completed = false;
    late StreamSubscription<List<int>> subscription;
    final timer = Timer(_helloTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    subscription = socket.listen(
      (bytes) {
        // Decode per chunk and split on \n: a response may arrive split across
        // TCP segments, so bytes are accumulated before decoding.
        buffer.write(utf8.decode(bytes, allowMalformed: true));
        var text = buffer.toString();
        var index = text.indexOf('\n');
        while (index >= 0) {
          final line = text.substring(0, index).trim();
          text = text.substring(index + 1);
          index = text.indexOf('\n');
          if (line.isEmpty) continue;
          seen.write('$line | ');
          final decoded = _decodeResponse(line, id);
          if (decoded != null) {
            completed = true;
            if (!completer.isCompleted) completer.complete(decoded);
          }
        }
        buffer
          ..clear()
          ..write(text);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: false,
    );

    try {
      final response = await completer.future;
      onRaw?.call(seen.toString());
      if (!completed) {
        // Nothing matched the request id: the module answered, but not with a
        // usable Control API response.
        debugPrint('ModuleApiHealthService: no $id response from the module '
            '(received: ${seen.isEmpty ? 'nothing' : seen.toString()})');
      }
      return response;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  /// Decodes one wire line into the minimal response shape, or null when it is
  /// not a JSON response / does not match [id].
  SoleuxJsonResponseLike? _decodeResponse(String line, int id) {
    final response = SoleuxJsonResponse.maybeParse(line);
    if (response == null || response.id != id) return null;
    return SoleuxJsonResponseLike(id: response.id, ok: response.ok);
  }

  void _scheduleCommit() {
    _commitDebounce?.cancel();
    _commitDebounce =
        Timer(const Duration(milliseconds: 200), () => store.commit().ignore());
  }
}

/// Minimal decoded `hello`/response shape used by the health check.
class SoleuxJsonResponseLike {
  final int id;
  final bool ok;

  const SoleuxJsonResponseLike({required this.id, required this.ok});
}
