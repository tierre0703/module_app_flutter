// lib/services/module_status/soleux_control_api_service.dart
//
// Transport-neutral command surface for the Soleux Control API
// (doc/Soleux_Control_API_Command_Specification_v0.3.md §"Transport and message
// envelope"): the action + params envelope and the common `ok`/`error` result
// are identical on every transport, so a single interface describes both the
// persistent TCP socket client ([SoleuxJsonService]) and the stateless
// HTTP/HTTPS client ([SoleuxHttpService]).
//
// Implementations override only the abstract transport members (connectivity,
// [framing] and the raw [request] round-trip); every documented catalogue
// action below is a concrete method on this base, so live control code never
// depends on the wire details (TCP JSON line vs HTTP POST).
//
// When a catalogue action is not yet implemented the device returns the common
// `unsupported_command`/`unknown_action` error (spec "Common error catalogue");
// clients must rely on that and must not assume every catalogued action is
// available. Only the modern Control-API framings (TCP plain-JSON envelope and
// HTTP/HTTPS) are part of this contract.
import '../../core/soleux/soleux_json_protocol.dart';

/// A live Soleux Control API command client over one transport.
///
/// Implementations:
///   - [SoleuxJsonService] - persistent TCP socket on the Control API port
///     (5008 by default) or the legacy `J:` framing;
///   - [SoleuxHttpService]  - stateless `POST /api/v1/command` on HTTP 80 /
///     HTTPS 443.
abstract class SoleuxControlApiService {
  /// True while the underlying transport is live. For the stateless HTTP
  /// transport this is the result of the latest reachability probe.
  bool get isConnected;

  /// Connection up/down transitions. The HTTP transport emits the result of
  /// each reachability probe.
  Stream<bool> get connectionStateStream;

  /// The wire framing in use. The HTTP transport always uses the Control API
  /// envelope ([SoleuxJsonFraming.controlApi]); a TCP unit may use the legacy
  /// `J:` framing for pre-Control-API devices.
  SoleuxJsonFraming get framing;

  /// Opens the transport. On TCP this opens/keeps the persistent socket; on
  /// HTTP/HTTPS it performs a `hello` reachability probe.
  Future<void> connect();

  /// Closes the transport (drops the TCP socket / resets HTTP reachability).
  /// The unit stays reusable via [connect].
  Future<void> disconnect();

  /// Releases the transport's resources permanently.
  void dispose();

  /// Sends a JSON request envelope and waits for the matching response.
  ///
  /// On TCP the response is matched by `id` (never by arrival order); on HTTP
  /// the response body is the common envelope parsed by
  /// [SoleuxJsonResponse.parseFromBody].
  Future<SoleuxJsonResponse> request(
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 5),
  });

  // ---------------------------------------------------------------------------
  // Convenience wrappers over the documented common actions. Every action's
  // params/result contract is identical on TCP and HTTP/HTTPS.
  // ---------------------------------------------------------------------------

  /// `hello` - identifies protocol, device, name and channel counts.
  Future<SoleuxJsonResponse> hello({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxJsonActions.hello, const {}, timeout: timeout);

  /// `get_relay_configuration` - full I/O + settings + mapping dump.
  Future<SoleuxJsonResponse> getRelayConfiguration({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxJsonActions.getRelayConfiguration, const {},
          timeout: timeout);

  /// `get_page_configuration` - reads a device-driven configuration page.
  ///
  /// [logPage]/[logPageSize] are the `system` page's `system_logs` pagination;
  /// [logFrom]/[logTo] (device format `YYYY-MM-DD HH:MM:SS`) and [logTag]
  /// optionally filter the returned log rows.
  Future<SoleuxJsonResponse> getPageConfiguration(
    String page, {
    int? logPage,
    int? logPageSize,
    String? logFrom,
    String? logTo,
    String? logTag,
  }) =>
      request(SoleuxJsonActions.getPageConfiguration, {
        'page': page,
        if (logPage != null) 'log_page': logPage,
        if (logPageSize != null) 'log_page_size': logPageSize,
        if (logFrom != null) 'log_from': logFrom,
        if (logTo != null) 'log_to': logTo,
        if (logTag != null) 'log_tag': logTag,
      });

  /// `set_page_configuration` - saves one page section.
  Future<SoleuxJsonResponse> setPageConfiguration(
    String page,
    String section,
    Map<String, dynamic> values,
  ) =>
      request(SoleuxJsonActions.setPageConfiguration,
          {'page': page, 'section': section, 'values': values});

  /// `mutate_page_row` - add/update/delete a schedule, watchdog or ACL row.
  Future<SoleuxJsonResponse> mutatePageRow(
    String page,
    String section,
    String operation,
    Map<String, dynamic> values, {
    int? id,
  }) =>
      request(SoleuxJsonActions.mutatePageRow, {
        'page': page,
        'section': section,
        'operation': operation,
        if (id != null) 'id': id,
        'values': values,
      });

  /// `execute_page_action` - a page operation such as reboot or time sync.
  Future<SoleuxJsonResponse> executePageAction(
    String pageAction,
    Map<String, dynamic> actionData,
  ) =>
      request(SoleuxJsonActions.executePageAction,
          {'page_action': pageAction, ...actionData});

  /// `set_output_configuration` - one output's name/delays/runtime and (for
  /// dimmers) PWM.
  Future<SoleuxJsonResponse> setOutputConfiguration(
    int channel,
    Map<String, dynamic> values,
  ) =>
      request(SoleuxJsonActions.setOutputConfiguration,
          {'channel': channel, ...values});

  /// `set_input_configuration` - one physical input's configuration.
  Future<SoleuxJsonResponse> setInputConfiguration(
    int channel,
    Map<String, dynamic> values,
  ) =>
      request(SoleuxJsonActions.setInputConfiguration,
          {'channel': channel, ...values});

  /// `set_virtual_input_state` - set and retain a virtual input's state
  /// (Control API spec §3.4).
  Future<SoleuxJsonResponse> setVirtualInputState(
    int channel,
    bool state, {
    String? source,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setVirtualInputState,
          {
            'channel': channel,
            'state': state,
            if (source != null) 'source': source,
          },
          timeout: timeout);

  /// `set_mapping` - input->output mapping (code 0..5).
  Future<SoleuxJsonResponse> setMapping(int input, int output, int code) =>
      request(SoleuxJsonActions.setMapping,
          {'input': input, 'output': output, 'code': code});

  /// `get_energy_history` (PDU Energy Meter). The date range must not exceed
  /// 365 days.
  Future<SoleuxJsonResponse> getEnergyHistory(
    SoleuxEnergyParameter parameter,
    String startDate,
    String endDate,
  ) =>
      request(SoleuxJsonActions.getEnergyHistory, {
        'parameter': parameter.index,
        'start_date': startDate,
        'end_date': endDate,
      });

  // ---------------------------------------------------------------------------
  // Control API catalogue commands (doc/...Specification_v0.3.md). These replace
  // the legacy AT+ control operations: set_output_state / toggle_output /
  // restart_output replace ON/OFF/TOGGLE/RESTART and masked AT operations,
  // set_dimmer_level replaces the dimmer brightness command, and ping replaces
  // `AT\r`. Dimmer level read-back goes through get_device_state (set_pwm /
  // actual_pwm) and dimmer on/off through set_output_state, replacing the
  // retired get_dimmer_state/get_dimmer_levels/dimmer_on/dimmer_off commands.
  // set_dimmer_level, set_multiple_dimmer_levels, toggle_dimmer,
  // get_dimmer_frequency and set_dimmer_frequency remain on the Control API
  // port (5008 by default). Unimplemented catalogue actions
  // return the common `unsupported_command` error, which the caller can use to
  // fall back to the implemented subset.
  // ---------------------------------------------------------------------------

  /// `ping` - reachability + round-trip estimate (§1.2). Result carries
  /// `server_time` and `uptime_ms`.
  Future<SoleuxJsonResponse> ping({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.ping, const {}, timeout: timeout);

  /// `get_capabilities` - supported commands, events and limits (§1.4).
  Future<SoleuxJsonResponse> capabilities({
    bool includeSchemas = false,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.getCapabilities,
          {'include_schemas': includeSchemas},
          timeout: timeout);

  /// `set_output_state` - set one output on/off (spec §4.3). Replaces
  /// `AT+ON`/`AT+OFF`.
  Future<SoleuxJsonResponse> setOutputState(
    int channel,
    bool state, {
    int? transitionMs,
    String? source,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setOutputState,
          {
            'channel': channel,
            'state': state,
            if (transitionMs != null) 'transition_ms': transitionMs,
            if (source != null) 'source': source,
          },
          timeout: timeout);

  /// `toggle_output` - invert one output state (spec §4.4). Replaces
  /// `AT+TOGGLE`.
  Future<SoleuxJsonResponse> toggleOutput(
    int channel, {
    int? transitionMs,
    String? source,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.toggleOutput,
          {
            'channel': channel,
            if (transitionMs != null) 'transition_ms': transitionMs,
            if (source != null) 'source': source,
          },
          timeout: timeout);

  /// `restart_output` - cycle one output off and back on (spec §4.5).
  /// Replaces `AT+RESTART`.
  Future<SoleuxJsonResponse> restartOutput(
    int channel, {
    int? offTimeMs,
    String? restoreMode,
    String? source,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.restartOutput,
          {
            'channel': channel,
            if (offTimeMs != null) 'off_time_ms': offTimeMs,
            if (restoreMode != null) 'restore_mode': restoreMode,
            if (source != null) 'source': source,
          },
          timeout: timeout);

  /// `get_outputs` - read all output states (spec §4.1).
  Future<SoleuxJsonResponse> getOutputs({
    bool includeConfiguration = true,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.getOutputs,
          {'include_configuration': includeConfiguration},
          timeout: timeout);

  /// `get_inputs` - read all physical and virtual inputs (spec §3.1).
  Future<SoleuxJsonResponse> getInputs({
    bool includeConfiguration = true,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.getInputs,
          {'include_configuration': includeConfiguration},
          timeout: timeout);

  /// Reads one dimmer channel's state via `get_device_state`, returning the
  /// matching `outputs` entry (with `set_pwm`/`actual_pwm`) so callers can build
  /// a [DimmerStateSnapshot]. Returns a response whose `result` is the flat
  /// per-channel map (channel/state/set_pwm/actual_pwm) or null when the channel
  /// is absent from the snapshot.
  Future<SoleuxJsonResponse> getDimmerState(
    int channel, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await getDeviceState(timeout: timeout);
    if (!response.ok || response.result == null) return response;
    final outputs = response.result!['outputs'];
    Map<String, dynamic>? entry;
    if (outputs is List) {
      for (final output in outputs) {
        if (output is Map && output['channel'] == channel) {
          entry = Map<String, dynamic>.from(output);
          break;
        }
      }
    }
    return SoleuxJsonResponse(
      id: response.id,
      ok: response.ok,
      protocol: response.protocol,
      result: entry,
      error: response.error,
    );
  }

  /// Reads every dimmer channel's state via `get_device_state`, returning the
  /// `outputs` list (with `set_pwm`/`actual_pwm`) as `{outputs: [...]}`.
  Future<SoleuxJsonResponse> getDimmerLevels({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await getDeviceState(timeout: timeout);
    if (!response.ok || response.result == null) return response;
    final outputs = response.result!['outputs'];
    return SoleuxJsonResponse(
      id: response.id,
      ok: response.ok,
      protocol: response.protocol,
      result: {'outputs': outputs is List ? outputs : const []},
      error: response.error,
    );
  }

  /// `get_device_state` - complete synchronization snapshot (spec §2.3).
  Future<SoleuxJsonResponse> getDeviceState({
    List<String> include = const ['inputs', 'outputs', 'sensors'],
    bool includeConfiguration = false,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.getDeviceState,
          {
            'include': include,
            'include_configuration': includeConfiguration,
          },
          timeout: timeout);

  /// `set_dimmer_level` - set one dimmer brightness level (spec §6.3).
  /// Replaces the legacy dimmer brightness AT command. The target device
  /// expects the brightness under the `value` key and enforces an integer
  /// (0-100); the spec table lists it as `0.0-100.0 percent` but the firmware
  /// rejects fractional values.
  Future<SoleuxJsonResponse> setDimmerLevel(
    int channel,
    int level, {
    int? transitionMs,
    bool? turnOn,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setDimmerLevel,
          {
            'channel': channel,
            'value': level,
            if (transitionMs != null) 'transition_ms': transitionMs,
            if (turnOn != null) 'turn_on': turnOn,
          },
          timeout: timeout);

  /// `set_multiple_dimmer_levels` - set several brightness levels together
  /// (spec §6.4). [targets] holds `{channel, level, transition_ms?}` maps.
  /// Levels are coerced to integers on the wire, matching the device's integer
  /// `level` rule for [setDimmerLevel].
  Future<SoleuxJsonResponse> setMultipleDimmerLevels(
    List<Map<String, dynamic>> targets, {
    String? execution,
    int? intervalMs,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setMultipleDimmerLevels,
          {
            'outputs': [
              for (final target in targets)
                {
                  'channel': target['channel'],
                  'level': (target['level'] as num?)?.round() ?? 0,
                  if (target.containsKey('transition_ms'))
                    'transition_ms': target['transition_ms'],
                },
            ],
            if (execution != null) 'execution': execution,
            if (intervalMs != null) 'interval_ms': intervalMs,
          },
          timeout: timeout);

  /// Turns one dimmer channel on via `set_output_state` (`state: true`),
  /// replacing the retired `dimmer_on` command.
  Future<SoleuxJsonResponse> dimmerOn(
    int channel, {
    int? transitionMs,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      setOutputState(channel, true,
          transitionMs: transitionMs, timeout: timeout);

  /// Turns one dimmer channel off via `set_output_state` (`state: false`),
  /// replacing the retired `dimmer_off` command.
  Future<SoleuxJsonResponse> dimmerOff(
    int channel, {
    int? transitionMs,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      setOutputState(channel, false,
          transitionMs: transitionMs, timeout: timeout);

  /// `toggle_dimmer` - toggle one dimmer while retaining its target level
  /// (spec §6.7). Result carries the resulting `dimmer` state.
  Future<SoleuxJsonResponse> toggleDimmer(
    int channel, {
    int? transitionMs,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.toggleDimmer,
          {
            'channel': channel,
            if (transitionMs != null) 'transition_ms': transitionMs,
          },
          timeout: timeout);

  /// `get_dimmer_frequency` - read configured dimmer PWM/drive frequency
  /// (spec §6.8). Result carries `frequency_hz`, `allowed_hz` and
  /// `apply_required`.
  Future<SoleuxJsonResponse> getDimmerFrequency({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.getDimmerFrequency, const {},
          timeout: timeout);

  /// `set_dimmer_frequency` - change dimmer PWM/drive frequency (spec §6.9).
  /// `frequency_hz` must be one of `allowed_hz` reported by
  /// [getDimmerFrequency]; [applyNow] applies immediately when true (default).
  Future<SoleuxJsonResponse> setDimmerFrequency(
    int frequencyHz, {
    bool? applyNow,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setDimmerFrequency,
          {
            'frequency_hz': frequencyHz,
            if (applyNow != null) 'apply_now': applyNow,
          },
          timeout: timeout);

  /// `set_multiple_outputs` - set several outputs deterministically
  /// (spec §4.6). `targets` holds `{channel, state, transition_ms?}` maps.
  Future<SoleuxJsonResponse> setMultipleOutputs(
    List<Map<String, dynamic>> targets, {
    String? execution,
    int? intervalMs,
    bool stopOnError = false,
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(
          SoleuxControlApiActions.setMultipleOutputs,
          {
            'outputs': targets,
            if (execution != null) 'execution': execution,
            if (intervalMs != null) 'interval_ms': intervalMs,
            'stop_on_error': stopOnError,
          },
          timeout: timeout);

  /// `get_mappings` - read the input-output mapping matrix (spec §5.1).
  Future<SoleuxJsonResponse> getMappings({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(SoleuxControlApiActions.getMappings, const {}, timeout: timeout);

  /// Stable endpoint key (`host:port` for TCP, `scheme://host[:port]/path` for
  /// HTTP/HTTPS) used by the status service to detect when the transport (or
  /// target endpoint) of an existing unit must be replaced.
  String get transportKey;
}
