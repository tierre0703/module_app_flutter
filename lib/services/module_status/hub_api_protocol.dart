// lib/services/module_status/hub_api_protocol.dart
//
// Modbus Hub JSON API protocol handler, implementing the command set described
// in doc/Modbus_Hub_Control_API.md. The Hub uses protocol 1 over raw TCP on
// port 5008, with a plain-text greeting line before the first JSON message.
//
// Unlike the standard Soleux Control API devices (relay, dimmer, PDU), the Hub
// has its own command catalogue:
//   - identity: `hello`, `get_device_info`
//   - dashboard and output control: `get_dashboard`, `set_output`,
//     `pulse_output`, `set_modbus_output`, `restart_modbus_output`
//   - tags: `get_tag`, `set_tag`
//   - system and logs: `get_system`, `clear_system_logs`
//   - settings: `get_settings`, `save_settings`, `settings_action`
//   - security: `get_security`, `save_security`, `security_action`
//   - users: `get_users`, `save_user`, `get_user_permissions`,
//     `save_user_permissions`
//   - I/O configuration: `get_io_configuration`, `save_io_channel`,
//     `rewrite_io_hardware`
//   - backup/transfer: settings_backup_download_begin, transfer_download_chunk,
//     transfer_download_finish, transfer_upload_begin, transfer_upload_chunk,
//     transfer_upload_finish, transfer_commit
library;

import 'dart:async';
import 'dart:convert';

import 'module_tcp_service.dart';

/// Response from a Hub command, wrapping the raw `id`, `ok`, result and error.
class HubCommandResponse {
  final int id;
  final bool ok;
  final Map<String, dynamic>? result;
  final String? error;

  const HubCommandResponse({
    required this.id,
    required this.ok,
    this.result,
    this.error,
  });

  factory HubCommandResponse.fromJson(Map<String, dynamic> json) {
    final err = json['error'];
    return HubCommandResponse(
      id: json['id'] is num ? (json['id'] as num).toInt() : 0,
      ok: json['ok'] is bool ? json['ok'] : false,
      result: json['result'] is Map
          ? Map<String, dynamic>.from(json['result'])
          : null,
      error: err is String ? err : null,
    );
  }
}

/// Hub dashboard data parsed from `get_dashboard`.
class HubDashboardData {
  final int outputCount;
  final int modbusPowerOutputCount;
  final String? date;
  final String? time;
  final double? internalTemp;
  final double? cpuTemp;
  final double? memoryUsage;
  final double? cpuUsage;
  final List<HubOutputState> outputs;
  final List<HubOutputState> modbusOutputs;

  const HubDashboardData({
    required this.outputCount,
    required this.modbusPowerOutputCount,
    this.date,
    this.time,
    this.internalTemp,
    this.cpuTemp,
    this.memoryUsage,
    this.cpuUsage,
    this.outputs = const [],
    this.modbusOutputs = const [],
  });

  factory HubDashboardData.fromResult(Map<String, dynamic> result) {
    final settings = result['settings'] is Map
        ? Map<String, dynamic>.from(result['settings'])
        : <String, dynamic>{};
    final status = result['status'] is Map
        ? Map<String, dynamic>.from(result['status'])
        : <String, dynamic>{};
    return HubDashboardData(
      outputCount: (settings['output_count'] as num?)?.toInt() ?? 0,
      modbusPowerOutputCount:
          (settings['modbus_power_output_count'] as num?)?.toInt() ?? 0,
      date: status['date'] as String?,
      time: status['time'] as String?,
      internalTemp: (status['internal_temp'] as num?)?.toDouble(),
      cpuTemp: (status['cpu_temp'] as num?)?.toDouble(),
      memoryUsage: (status['memory_usage'] as num?)?.toDouble(),
      cpuUsage: (status['cpu_usage'] as num?)?.toDouble(),
      outputs: [
        for (final o in result['outputs'] is List
            ? result['outputs'] as List
            : const [])
          if (o is Map) HubOutputState.fromJson(Map<String, dynamic>.from(o)),
      ],
      modbusOutputs: [
        for (final o in result['modbus_outputs'] is List
            ? result['modbus_outputs'] as List
            : const [])
          if (o is Map) HubOutputState.fromJson(Map<String, dynamic>.from(o)),
      ],
    );
  }
}

/// One output row from the Hub dashboard.
class HubOutputState {
  final int id;
  final int channel;
  final String name;
  final bool state;
  final bool turnOffDisable;
  final bool restartDisable;

  const HubOutputState({
    required this.id,
    required this.channel,
    this.name = '',
    this.state = false,
    this.turnOffDisable = false,
    this.restartDisable = false,
  });

  factory HubOutputState.fromJson(Map<String, dynamic> json) => HubOutputState(
        id: (json['id'] as num?)?.toInt() ?? 0,
        channel: (json['channel'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        state: json['state'] is bool ? json['state'] : false,
        turnOffDisable: json['turn_off_disable'] is bool
            ? json['turn_off_disable']
            : false,
        restartDisable: json['restart_disable'] is bool
            ? json['restart_disable']
            : false,
      );
}

/// Hub device info parsed from `get_device_info`.
class HubDeviceInfo {
  final String? name;
  final String? model;
  final String? appFirmware;
  final String? mcuFirmware;
  final String? mcuHardware;
  final String? serial;
  final String? mac;

  const HubDeviceInfo({
    this.name,
    this.model,
    this.appFirmware,
    this.mcuFirmware,
    this.mcuHardware,
    this.serial,
    this.mac,
  });

  factory HubDeviceInfo.fromResult(Map<String, dynamic> result) =>
      HubDeviceInfo(
        name: result['name'] as String?,
        model: result['model'] as String?,
        appFirmware: result['app_firmware'] as String?,
        mcuFirmware: result['mcu_firmware'] as String?,
        mcuHardware: result['mcu_hardware'] as String?,
        serial: result['serial'] as String?,
        mac: result['mac'] as String?,
      );
}

/// Buffer-based line splitter for CR/LF-delimited TCP streams.
class _HubLineSplitter {
  final StringBuffer _buffer = StringBuffer();

  List<String> add(String chunk) {
    _buffer.write(chunk);
    final text = _buffer.toString();
    final lines = <String>[];
    var searchFrom = 0;
    while (true) {
      final lf = text.indexOf('\n', searchFrom);
      if (lf < 0) break;
      var end = lf;
      if (end > 0 && text[end - 1] == '\r') end -= 1;
      lines.add(text.substring(searchFrom, end));
      searchFrom = lf + 1;
    }
    if (searchFrom > 0) {
      _buffer.clear();
      if (searchFrom < text.length) {
        _buffer.write(text.substring(searchFrom));
      }
    }
    return lines;
  }

  bool get hasPending => _buffer.isNotEmpty;
}

/// Protocol 1 socket client for the Modbus Hub JSON API (port 5008).
///
/// Handles the Hub-specific greeting (`Soleux JSON API Ready`), sends
/// protocol-1 requests, and matches responses by `id`.
class HubJsonProtocol {
  final ModuleTcpConnection _connection;

  bool _greetingReceived = false;
  final Map<int, Completer<HubCommandResponse>> _pending = {};
  int _nextId = 1;
  Timer? _timeoutTimer;
  final _HubLineSplitter _splitter = _HubLineSplitter();

  HubJsonProtocol(this._connection);

  /// Connects to the Hub.
  Future<void> connect() => _connection.connect();

  /// Whether the underlying TCP session is live.
  bool get isConnected => _connection.isConnected;

  /// Disconnects from the Hub.
  Future<void> disconnect() => _connection.disconnect();

  /// Disposes of the connection.
  void dispose() {
    _timeoutTimer?.cancel();
    _connection.dispose();
  }

  /// Sends a Hub command (protocol 1) and waits for the matching response.
  Future<HubCommandResponse> sendCommand(
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final id = _nextId++;
    final completer = Completer<HubCommandResponse>();
    _pending[id] = completer;

    final request = jsonEncode({
      'protocol': 1,
      'id': id,
      'action': action,
      'params': params,
    });
    _connection.write('$request\r\n');

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, () {
      _pending.remove(id)?.completeError(
          TimeoutException('Hub command "$action" timed out'));
    });

    try {
      return await completer.future;
    } finally {
      _pending.remove(id);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }
  }

  /// `hello` - identifies the Hub and lists available actions.
  Future<HubCommandResponse> hello(
          {Duration timeout = const Duration(seconds: 5)}) =>
      sendCommand('hello', const {}, timeout: timeout);

  /// `get_device_info` - Hub identity and firmware details.
  Future<HubCommandResponse> getDeviceInfo() =>
      sendCommand('get_device_info', const {});

  /// `get_dashboard` - outputs, modbus outputs, and system status.
  Future<HubCommandResponse> getDashboard() =>
      sendCommand('get_dashboard', const {});

  /// `set_output` - set one normal output state.
  Future<HubCommandResponse> setOutput(int channel, bool state) =>
      sendCommand('set_output', {'channel': channel, 'state': state});

  /// `pulse_output` - pulse one normal output (on, then off after 1 second).
  Future<HubCommandResponse> pulseOutput(int channel) =>
      sendCommand('pulse_output', {'channel': channel});

  /// `set_modbus_output` - set one Modbus power output state.
  Future<HubCommandResponse> setModbusOutput(int channel, bool state) =>
      sendCommand('set_modbus_output', {'channel': channel, 'state': state});

  /// `restart_modbus_output` - cycle one Modbus power output.
  Future<HubCommandResponse> restartModbusOutput(int channel) =>
      sendCommand('restart_modbus_output', {'channel': channel});

  /// `get_tag` - read a virtual tag's value.
  Future<HubCommandResponse> getTag(String tagName) =>
      sendCommand('get_tag', {'tag_name': tagName});

  /// `set_tag` - write a virtual tag's value.
  Future<HubCommandResponse> setTag(String tagName, String value) =>
      sendCommand('set_tag', {'tag_name': tagName, 'value': value});

  /// `get_system` - system info and logs (paginated).
  Future<HubCommandResponse> getSystem({int page = 1, int pageSize = 10}) =>
      sendCommand('get_system', {'page': page, 'page_size': pageSize});

  /// `clear_system_logs` - delete all logs and return refreshed page 1.
  Future<HubCommandResponse> clearSystemLogs({int pageSize = 10}) =>
      sendCommand('clear_system_logs', {'page_size': pageSize});

  /// `get_settings` - current Hub settings.
  Future<HubCommandResponse> getSettings() =>
      sendCommand('get_settings', const {});

  /// `save_settings` - save one settings section.
  Future<HubCommandResponse> saveSettings(
          String section, Map<String, dynamic> values) =>
      sendCommand('save_settings', {'section': section, 'values': values});

  /// `settings_action` - run a time/NTP/reboot/factory-reset operation.
  Future<HubCommandResponse> settingsAction(
          String action, Map<String, dynamic> values) =>
      sendCommand('settings_action', {
        'settings_action': action,
        'values': values,
      });

  /// `get_security` - HTTPS, access filter, and certificate info.
  Future<HubCommandResponse> getSecurity() =>
      sendCommand('get_security', const {});

  /// `save_security` - save one security section.
  Future<HubCommandResponse> saveSecurity(
          String section, Map<String, dynamic> values) =>
      sendCommand('save_security', {'section': section, 'values': values});

  /// `get_io_configuration` - output configuration arrays.
  Future<HubCommandResponse> getIoConfiguration() =>
      sendCommand('get_io_configuration', const {});

  /// Feeds raw data from the TCP socket, parsing lines and completing
  /// pending command responses.
  List<HubCommandResponse?> feed(String chunk) {
    final lines = _splitter.add(chunk);
    final results = <HubCommandResponse?>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!_greetingReceived) {
        if (!trimmed.startsWith('{')) {
          _greetingReceived = true;
          continue;
        }
        _greetingReceived = true;
      }
      final response = _tryParse(trimmed);
      results.add(response);
    }
    return results;
  }

  /// Tries to parse a wire line as a JSON response.
  HubCommandResponse? _tryParse(String line) {
    if (!line.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final rawId = map['id'];
      if (rawId == null) return null;

      final response = HubCommandResponse.fromJson(map);
      final completer = _pending.remove(response.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(response);
      }
      return response;
    } catch (e) {
      return null;
    }
  }
}