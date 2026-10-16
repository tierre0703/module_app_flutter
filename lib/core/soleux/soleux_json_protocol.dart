// lib/core/soleux/soleux_json_protocol.dart
//
// Codec for the Soleux Control API / JSON protocol described in
// doc/Soleux_Control_API_Command_Specification_v0.3.md §"Transport and message
// envelope".
//
// Wire contract (Control API, the default framing):
//   - request and response are each one CRLF- or LF-terminated UTF-8 JSON
//     object per line (no prefix), on the legacy TCP port + 3 (5008 default);
//   - a request carries the outer `protocol` (2 for the current Relay subset,
//     the value 3 remains the target catalogue) plus a unique `id`; the device
//     echoes the `id` in the response, so clients match by `id`, never by
//     arrival order;
//   - a successful response has `"ok":true` and a `result` object;
//   - a failed response has `"ok":false` and an `error` object with a stable
//     `code`;
//   - unknown response properties must be ignored (forward compatibility).
//
// Legacy framing (J: prefix) is kept for older PDU / Soleux devices that
// predate the Control API, but is DEPRECATED: current modules speak only the
// Control API. Per the spec the `J:` prefix is NOT accepted on the Control API
// or on the legacy Relay port; it is only used when talking to a device that
// was verified to answer the legacy JSON protocol.
//
// This file is deliberately networking-free: a pure codec that any transport
// (persistent socket, tests, mock) can use. Only JSON line framing lives here.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The prefix legacy JSON protocol lines start with on the wire. Only used for
/// pre-Control-API devices; the Control API itself must not send it.
///
/// DEPRECATED: current modules speak only the Control API; retained for the
/// staged removal of the legacy `J:` framing.
const String kSoleuxJsonPrefix = 'J:';

/// Framing used on the wire for JSON protocol requests.
enum SoleuxJsonFraming {
  /// The Control API transport: one plain JSON object per line (no `J:`
  /// prefix), carrying the outer `protocol` field. Used on the Control API
  /// port (legacy TCP port + 3) and by the HTTP/HTTPS transport, which sends
  /// the same envelope as a `POST /api/v1/command` body.
  controlApi,

  /// Legacy pre-Control-API framing: `J:`-prefixed JSON lines on the legacy
  /// TCP port.
  ///
  /// DEPRECATED: current modules speak only the Control API. Retained for the
  /// staged removal of the legacy framing.
  @Deprecated('The legacy `J:` framing is no longer supported; the Control API '
      '(TCP 5008) is the only protocol. Retained for the staged removal.')
  legacyJ,
}

/// Negotiated Control API protocol version.
///
/// The Relay Module currently implements the protocol 2 command subset; the
/// version 3 catalogue in the specification remains the target contract.
abstract final class SoleuxProtocolVersion {
  SoleuxProtocolVersion._();

  /// Version implemented by the current Relay Module firmware.
  static const int implemented = 2;

  /// Version targeted by the full command catalogue.
  static const int target = 3;

  /// Protocol version the app advertises in every request.
  static const int defaultRequest = implemented;
}

/// JSON actions common to all supported families
/// (doc/Soleux-Mobile-TCP-Protocol.md, "Common JSON actions").
abstract final class SoleuxJsonActions {
  SoleuxJsonActions._();

  static const String hello = 'hello';
  static const String getRelayConfiguration = 'get_relay_configuration';
  static const String getPageConfiguration = 'get_page_configuration';
  static const String setPageConfiguration = 'set_page_configuration';
  static const String mutatePageRow = 'mutate_page_row';
  static const String executePageAction = 'execute_page_action';

  // Relay Module / PDU (current generation).
  static const String setInputConfiguration = 'set_input_configuration';
  static const String setOutputConfiguration = 'set_output_configuration';
  static const String setMapping = 'set_mapping';
  static const String writeHardware = 'write_hardware';
  static const String settingsBackupDownloadBegin =
      'settings_backup_download_begin';
  static const String transferUploadBegin = 'transfer_upload_begin';
  static const String transferUploadChunk = 'transfer_upload_chunk';
  static const String transferUploadFinish = 'transfer_upload_finish';
  static const String transferDownloadChunk = 'transfer_download_chunk';
  static const String transferDownloadFinish = 'transfer_download_finish';
  static const String transferCommit = 'transfer_commit';

  // AC/DC Dimmer.
  static const String setDimmerFrequency = 'set_dimmer_frequency';

  // PDU Energy Meter.
  static const String getEnergyHistory = 'get_energy_history';

  // Modbus Hub (doc/Modbus_Hub_Control_API.md).
  static const String getDashboard = 'get_dashboard';
  static const String setOutput = 'set_output';
  static const String pulseOutput = 'pulse_output';
  static const String setModbusOutput = 'set_modbus_output';
  static const String restartModbusOutput = 'restart_modbus_output';
  static const String getTag = 'get_tag';
  static const String setTag = 'set_tag';
  static const String getSystem = 'get_system';
  static const String clearSystemLogs = 'clear_system_logs';
  static const String getSettings = 'get_settings';
  static const String saveSettings = 'save_settings';
  static const String settingsAction = 'settings_action';
  static const String getSecurity = 'get_security';
  static const String saveSecurity = 'save_security';
  static const String securityAction = 'security_action';
  static const String getUsers = 'get_users';
  static const String saveUser = 'save_user';
  static const String getUserPermissions = 'get_user_permissions';
  static const String saveUserPermissions = 'save_user_permissions';
  static const String getIoConfiguration = 'get_io_configuration';
  static const String saveIoChannel = 'save_io_channel';
  static const String rewriteIoHardware = 'rewrite_io_hardware';

  /// Row operations for [SoleuxJsonActions.mutatePageRow].
  static const String opAdd = 'add';
  static const String opUpdate = 'update';
  static const String opDelete = 'delete';
}

/// Control API catalogue actions
/// (doc/Soleux_Control_API_Command_Specification_v0.3.md, "Command catalogue").
///
/// Clients must use `hello` and `get_capabilities` data and must not assume
/// every catalogued action is available on a given firmware yet; unimplemented
/// actions return the common `unsupported_command` error, at which point the
/// app falls back to the implemented protocol 2 subset or the legacy AT path.
abstract final class SoleuxControlApiActions {
  SoleuxControlApiActions._();

  // Session and protocol (§1).
  static const String hello = 'hello';
  static const String ping = 'ping';
  static const String authenticate = 'authenticate';
  static const String getCapabilities = 'get_capabilities';
  static const String batchExecute = 'batch_execute';

  // Device information and health (§2).
  static const String getDeviceInfo = 'get_device_info';
  static const String getDeviceHealth = 'get_device_health';
  static const String getDeviceState = 'get_device_state';
  static const String getTemperature = 'get_temperature';
  static const String getTime = 'get_time';
  static const String rebootDevice = 'reboot_device';

  // Inputs and virtual inputs (§3).
  static const String getInputs = 'get_inputs';
  static const String getInput = 'get_input';
  static const String setVirtualInputState = 'set_virtual_input_state';
  static const String triggerVirtualInput = 'trigger_virtual_input';

  // Outputs (§4). These replace ON, OFF, TOGGLE, RESTART and masked AT
  // operations (spec §4 header).
  static const String getOutputs = 'get_outputs';
  static const String getOutput = 'get_output';
  static const String setOutputState = 'set_output_state';
  static const String toggleOutput = 'toggle_output';
  static const String restartOutput = 'restart_output';
  static const String setMultipleOutputs = 'set_multiple_outputs';
  static const String toggleMultipleOutputs = 'toggle_multiple_outputs';
  static const String restartMultipleOutputs = 'restart_multiple_outputs';

  // Input-output mappings (§5).
  static const String getMappings = 'get_mappings';
  static const String getInputMapping = 'get_input_mapping';
  static const String clearMapping = 'clear_mapping';
  static const String applyHardwareConfiguration =
      'apply_hardware_configuration';

  // Dimmer control (§6). Level read-back and on/off now go through
  // `get_device_state` (set_pwm/actual_pwm) and `set_output_state`.
  static const String setDimmerLevel = 'set_dimmer_level';
  static const String setMultipleDimmerLevels = 'set_multiple_dimmer_levels';
  static const String toggleDimmer = 'toggle_dimmer';
  static const String getDimmerFrequency = 'get_dimmer_frequency';
  static const String setDimmerFrequency = 'set_dimmer_frequency';

  // PDU energy and override (§7).
  static const String getEnergySummary = 'get_energy_summary';
  static const String getPowerLimits = 'get_power_limits';
  static const String getOverrideState = 'get_override_state';

  // Configuration, network and security (§10).
  static const String getConfiguration = 'get_configuration';
  static const String setConfiguration = 'set_configuration';
  static const String scanWifi = 'scan_wifi';
  static const String testNetwork = 'test_network';
  static const String testMqtt = 'test_mqtt';
  static const String getAccessRules = 'get_access_rules';
  static const String addAccessRule = 'add_access_rule';
  static const String updateAccessRule = 'update_access_rule';
  static const String deleteAccessRule = 'delete_access_rule';

  // Schedules and automations (§8).
  static const String getSchedules = 'get_schedules';
  static const String getSchedule = 'get_schedule';
  static const String createSchedule = 'create_schedule';
  static const String updateSchedule = 'update_schedule';
  static const String deleteSchedule = 'delete_schedule';
  static const String enableSchedule = 'enable_schedule';
  static const String executeSchedule = 'execute_schedule';
  static const String getAutomations = 'get_automations';
  static const String createAutomation = 'create_automation';
  static const String updateAutomation = 'update_automation';
  static const String deleteAutomation = 'delete_automation';
  static const String enableAutomation = 'enable_automation';

  // Dimmer scenarios and sequences (§9).
  static const String getScenarios = 'get_scenarios';
  static const String createScenario = 'create_scenario';
  static const String updateScenario = 'update_scenario';
  static const String deleteScenario = 'delete_scenario';
  static const String executeScenario = 'execute_scenario';
  static const String getSequences = 'get_sequences';
  static const String createSequence = 'create_sequence';
  static const String updateSequence = 'update_sequence';
  static const String deleteSequence = 'delete_sequence';
  static const String startSequence = 'start_sequence';
  static const String stopSequence = 'stop_sequence';

  // Backup, restore and firmware transfer (§11).
  static const String uploadBegin = 'upload_begin';
  static const String uploadChunk = 'upload_chunk';
  static const String uploadFinish = 'upload_finish';
  static const String uploadCommit = 'upload_commit';
  static const String downloadBegin = 'download_begin';
  static const String downloadChunk = 'download_chunk';
  static const String downloadFinish = 'download_finish';
}

/// Common config pages (doc/Soleux-Mobile-TCP-Protocol.md, JSON section).
abstract final class SoleuxJsonPages {
  SoleuxJsonPages._();

  static const String automation = 'automation';
  static const String schedule = 'schedule';
  static const String settings = 'settings';
  static const String security = 'security';
  static const String system = 'system';
}

/// Energy-history parameters (PDU Energy Meter).
enum SoleuxEnergyParameter {
  voltage,
  current,
  power,
  powerFactor,
  apparentPower,
  energy
}

extension SoleuxEnergyParameterX on SoleuxEnergyParameter {
  /// The device-side parameter index (`0=voltage ... 5=energy`).
  int get index => switch (this) {
        SoleuxEnergyParameter.voltage => 0,
        SoleuxEnergyParameter.current => 1,
        SoleuxEnergyParameter.power => 2,
        SoleuxEnergyParameter.powerFactor => 3,
        SoleuxEnergyParameter.apparentPower => 4,
        SoleuxEnergyParameter.energy => 5,
      };

  /// Display unit reported by the device (V, A, W, '', VA, kWh).
  String get unit => switch (this) {
        SoleuxEnergyParameter.voltage => 'V',
        SoleuxEnergyParameter.current => 'A',
        SoleuxEnergyParameter.power => 'W',
        SoleuxEnergyParameter.powerFactor => '',
        SoleuxEnergyParameter.apparentPower => 'VA',
        SoleuxEnergyParameter.energy => 'kWh',
      };
}

/// A single outbound Control API / JSON protocol request.
class SoleuxJsonRequest {
  final int id;
  final String action;
  final Map<String, dynamic> params;

  /// Protocol version advertised in the envelope (`2` for the current Relay
  /// subset; `3` is the target catalogue). See [SoleuxProtocolVersion].
  final int protocol;

  /// When true the request is framed as a legacy `J:` line for older Soleux
  /// devices that answer the legacy JSON protocol (pre-Control-API). The
  /// Control API framing (plain JSON object, no prefix) is the default and must
  /// be used on the Control API transport.
  final bool legacyJPrefix;

  const SoleuxJsonRequest({
    required this.id,
    required this.action,
    this.params = const {},
    this.protocol = SoleuxProtocolVersion.defaultRequest,
    this.legacyJPrefix = false,
  });

  /// The protocol envelope as a JSON map. Shared by the newline-delimited TCP
  /// encoding ([encode]) and the HTTP/HTTPS `POST /api/v1/command` transport,
  /// which sends the same object as its request body
  /// (doc/...Specification_v0.2.md §"Request envelope").
  Map<String, dynamic> toMap() => {
        'protocol': protocol,
        'id': id,
        'action': action,
        'params': params,
      };

  /// Encodes the request as a single CRLF-terminated line. By default it is a
  /// plain JSON object (Control API envelope); with [legacyJPrefix] it is
  /// prefixed with [`kSoleuxJsonPrefix`].
  String encode() {
    final line = jsonEncode(toMap());
    return legacyJPrefix ? '$kSoleuxJsonPrefix$line\r\n' : '$line\r\n';
  }
}

/// The `error` value carried by a failed JSON response.
class SoleuxJsonError {
  final Object? raw;

  const SoleuxJsonError(this.raw);

  /// Error `code` when the device sent an object like
  /// `{"code":"internal_error","message":"..."}`.
  String? get code => raw is Map ? (raw as Map)['code'] as String? : null;

  /// Error `message` when present (string or nested in an object).
  String? get message {
    if (raw is String) return raw as String;
    if (raw is Map) return (raw as Map)['message'] as String?;
    return null;
  }

  String get summary => message ?? code ?? '$raw';
}

/// A decoded `J:` response line.
class SoleuxJsonResponse {
  /// The `id` echoed from the request this response answers.
  final int id;

  /// `true` when the request was accepted (`"ok":true`).
  final bool ok;

  /// The outer `protocol` field, when the firmware sent one (PDU V1.0 omits
  /// it, so this is nullable).
  final int? protocol;

  /// The decoded `result` map of a successful response, or null.
  final Map<String, dynamic>? result;

  /// The `error` value of a failed response, or null.
  final SoleuxJsonError? error;

  const SoleuxJsonResponse({
    required this.id,
    required this.ok,
    this.protocol,
    this.result,
    this.error,
  });

  /// Parses a raw response body (no J: prefix) into a response. Throws a
  /// [FormatException] when the body is not a valid JSON protocol response.
  factory SoleuxJsonResponse.parseFromBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Soleux JSON response is not an object');
    }
    final map = decoded;
    final id = _parseId(map['id']);
    final ok = map['ok'];
    if (ok is! bool) {
      throw const FormatException('Soleux JSON response is missing a bool ok');
    }

    dynamic result;
    try {
      result = map['result'];
    } catch (e, st) {
      debugPrint('SoleuxJsonResponse: reading result field failed: $e\n$st');
      result = null;
    }

    return SoleuxJsonResponse(
      id: id,
      ok: ok,
      protocol:
          map['protocol'] is num ? (map['protocol'] as num).toInt() : null,
      result: result is Map ? Map<String, dynamic>.from(result) : null,
      error: map['error'] == null ? null : SoleuxJsonError(map['error']),
    );
  }

  /// Parses a raw wire line (already trimmed of CR/LF). Returns the response
  /// when the line is a JSON protocol line (either the Control API plain JSON
  /// object framing or a legacy `J:` prefixed line), or null when it is
  /// something else (a legacy `AT+...` event, an `OUT:`/`IN:` status, `OK`,
  /// ...). Tolerates malformed JSON by returning null so one bad frame never
  /// kills the reader.
  static SoleuxJsonResponse? maybeParse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      if (trimmed.startsWith(kSoleuxJsonPrefix)) {
        return SoleuxJsonResponse.parseFromBody(
            trimmed.substring(kSoleuxJsonPrefix.length));
      }
      // Control API transport: a plain JSON object line with no prefix.
      if (trimmed.startsWith('{')) {
        return SoleuxJsonResponse.parseFromBody(trimmed);
      }
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Splits a raw byte/chunk stream into complete, CR/LF-delimited lines.
///
/// The firmware buffers and may flush any number of messages in a single TCP
/// segment (and may split one line across chunks), so framing must be
/// buffered rather than assuming one read == one message.
class SoleuxLineSplitter {
  final StringBuffer _buffer = StringBuffer();

  /// Feeds [chunk] and returns every complete line found (without the
  /// line terminator). A trailing partial line is kept in the buffer.
  List<String> add(String chunk) {
    _buffer.write(chunk);
    final text = _buffer.toString();
    final lines = <String>[];
    var searchFrom = 0;
    while (true) {
      final lf = text.indexOf('\n', searchFrom);
      if (lf < 0) break;
      var end = lf;
      // `\r\n` -> drop the carriage return as part of the terminator.
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

  /// Any partial line currently buffered awaiting its terminator.
  bool get hasPending => _buffer.isNotEmpty;
}

/// Reads the response `id`, which the Control API allows as `integer|string`
/// (spec §"Request envelope"). Numeric strings are accepted so a device that
/// echoes a string id still matches the in-flight integer id.
int _parseId(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) {
    final parsed = int.tryParse(raw);
    if (parsed != null) return parsed;
  }
  throw const FormatException('Soleux JSON response is missing a valid id');
}
