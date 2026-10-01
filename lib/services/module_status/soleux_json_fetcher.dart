// lib/services/module_status/soleux_json_fetcher.dart
//
// Renders Soleux JSON protocol responses onto a [DeviceModule], counterpart to
// the legacy AT+ fetcher (relay_module_status_fetcher.dart). Implements the
// recommended connection sequence from doc/Soleux-Mobile-TCP-Protocol.md:
//
//   1. `hello`
//   2. `get_relay_configuration`
//   3. build the UI from returned counts, fields, and device identity
//
// Reconciliation treats the device as the source of truth for names: whatever
// the module currently reports for an input/output is adopted on every refresh
// (a rename made outside the app shows up immediately). Only an input/output
// the device reports no name for keeps its local name. Dimmer outputs pick up
// PWM/brightness from the configuration when present.
import 'package:flutter/material.dart';

import '../../core/soleux/soleux_device_family.dart';
import '../../models/models.dart';

/// Parsed `hello` result.
class SoleuxHelloData {
  final int protocol;
  final String device;
  final String name;
  final int inputCount;
  final int virtualInputCount;
  final int outputCount;

  const SoleuxHelloData({
    required this.protocol,
    required this.device,
    this.name = '',
    this.inputCount = 0,
    this.virtualInputCount = 0,
    this.outputCount = 0,
  });

  factory SoleuxHelloData.fromResult(Map<String, dynamic> result) =>
      SoleuxHelloData(
        protocol:
            result['protocol'] is num ? (result['protocol'] as num).toInt() : 0,
        device: result['device'] as String? ?? '',
        name: result['name'] as String? ?? '',
        inputCount: _int(result['input_count']),
        virtualInputCount: _int(result['virtual_input_count']),
        outputCount: _int(result['output_count']),
      );

  /// Device family reported by `device`, when known.
  SoleuxDeviceFamily? get family => SoleuxDeviceFamilies.fromJsonDevice(device);
}

/// One `outputs[]` entry from `get_relay_configuration`.
class SoleuxOutputState {
  final int channel;
  final String name;
  final bool state;
  final int? pwm;

  /// Whether control is permitted (`enabled`). Null when the device does not
  /// report it, in which case the output is treated as enabled.
  final bool? enabled;

  /// Dimmer brightness step size (`output_off_delay`); defaults to 1.
  final int stepSize;

  /// Device `initial_state` (`off`/`on`/`restore`, or a legacy int/absent).
  /// Null when the device does not report it.
  final Object? initialState;

  /// Timed/behavioural fields are surfaced raw for future pages.
  final Map<String, dynamic> raw;

  const SoleuxOutputState({
    required this.channel,
    this.name = '',
    this.state = false,
    this.pwm,
    this.enabled,
    this.stepSize = 1,
    this.initialState,
    this.raw = const {},
  });

  factory SoleuxOutputState.fromJson(Map<String, dynamic> json) {
    final pwmRaw = json['pwm'];
    final enabledRaw = json['output_enabled'] ?? json['enabled'];
    final stepRaw = json['output_off_delay'];
    return SoleuxOutputState(
      channel: _int(json['channel']),
      name: json['output_name'] as String? ?? json['name'] as String? ?? '',
      state: json['output_state'] as bool? ?? false,
      pwm: pwmRaw is num ? pwmRaw.toInt() : null,
      enabled: enabledRaw == null
          ? null
          : enabledRaw is bool
              ? enabledRaw
              : (enabledRaw as num?) != 0,
      stepSize: (stepRaw is num ? stepRaw.toInt() : 1).clamp(1, 100).toInt(),
      initialState: json['initial_state'],
      raw: json,
    );
  }
}

/// One `inputs[]` entry from `get_relay_configuration`.
class SoleuxInputState {
  final int channel;
  final String name;
  final bool state;
  final bool enabled;

  const SoleuxInputState({
    required this.channel,
    this.name = '',
    this.state = false,
    this.enabled = true,
  });

  factory SoleuxInputState.fromJson(Map<String, dynamic> json) {
    final enabledRaw = json['input_enabled'];
    return SoleuxInputState(
      channel: _int(json['channel']),
      name: json['input_name'] as String? ?? json['name'] as String? ?? '',
      state: json['input_state'] as bool? ?? false,
      enabled: enabledRaw is bool ? enabledRaw : (enabledRaw as num? ?? 1) != 0,
    );
  }
}

/// Parsed `get_relay_configuration` result.
class SoleuxRelayConfiguration {
  final int inputCount;
  final int virtualInputCount;
  final int outputCount;
  final List<SoleuxOutputState> outputs;
  final List<SoleuxInputState> inputs;

  const SoleuxRelayConfiguration({
    this.inputCount = 0,
    this.virtualInputCount = 0,
    this.outputCount = 0,
    this.outputs = const [],
    this.inputs = const [],
  });

  factory SoleuxRelayConfiguration.fromResult(Map<String, dynamic> result) =>
      SoleuxRelayConfiguration(
        inputCount: _int(result['input_count']),
        virtualInputCount: _int(result['virtual_input_count']),
        outputCount: _int(result['output_count']),
        outputs: [
          for (final o in result['outputs'] is List
              ? result['outputs'] as List
              : const [])
            if (o is Map)
              SoleuxOutputState.fromJson(Map<String, dynamic>.from(o)),
        ],
        inputs: [
          for (final i
              in result['inputs'] is List ? result['inputs'] as List : const [])
            if (i is Map)
              SoleuxInputState.fromJson(Map<String, dynamic>.from(i)),
        ],
      );
}

int _int(Object? value) => value is num ? value.toInt() : 0;

/// Applies Soleux JSON `hello` + `get_relay_configuration` results onto a
/// module, preserving user-defined names.
class SoleuxJsonFetcher {
  const SoleuxJsonFetcher();

  void apply(DeviceModule module, SoleuxHelloData? hello) {
    if (hello == null) return;
    if (hello.name.isNotEmpty) module.name = hello.name;
  }

  void applyConfiguration(
      DeviceModule module, SoleuxRelayConfiguration config) {
    final targetOutputs = config.outputCount > 0
        ? config.outputCount
        : (config.outputs.isEmpty
            ? module.channels.length
            : (config.outputs
                    .map((o) => o.channel)
                    .fold<int>(0, (a, b) => a > b ? a : b) +
                1));

    final stdoutNames = {
      for (final o in config.outputs) o.channel: o.name,
    };
    final stdoutEnabled = {
      for (final o in config.outputs) o.channel: o.enabled,
    };
    final stdoutInitialState = {
      for (final o in config.outputs) o.channel: o.initialState,
    };
    while (module.channels.length < targetOutputs) {
      final index = module.channels.length;
      final deviceName = stdoutNames[index];
      module.channels.add(ChannelOutput(
        id: '${module.id}c${index + 1}',
        name: (deviceName != null && deviceName.isNotEmpty)
            ? deviceName
            : 'Output ${index + 1}',
        icon: Icons.power,
        enabled: stdoutEnabled[index] ?? true,
        initialState: OutputInitialState.fromWire(stdoutInitialState[index]),
      ));
    }
    if (module.channels.length > targetOutputs) {
      module.channels.removeRange(targetOutputs, module.channels.length);
    }

    for (final output in config.outputs) {
      final index = output.channel;
      if (index < 0 || index >= module.channels.length) continue;
      final channel = module.channels[index];
      channel.isOn = output.state;
      channel.stepSize = output.stepSize;
      // Dimmer outputs expose PWM as a bounded value supplied by firmware
      // metadata; persist it as the channel brightness (0-100%).
      if (output.pwm != null) {
        channel.brightness = output.pwm!.clamp(0, 100);
      }
      // The device is the source of truth for the name; a rename made outside
      // the app shows up on the next refresh.
      if (output.name.isNotEmpty) {
        channel.name = output.name;
      }
    }

    final targetInputs = config.inputs.isEmpty
        ? module.inputs.length
        : (config.inputs
                .map((i) => i.channel)
                .fold<int>(0, (a, b) => a > b ? a : b) +
            1);
    final inputNames = {
      for (final i in config.inputs) i.channel: i.name,
    };
    while (module.inputs.length < targetInputs) {
      final index = module.inputs.length;
      final deviceName = inputNames[index];
      module.inputs.add(PhysicalInput(
        id: '${module.id}i${index + 1}',
        name: (deviceName != null && deviceName.isNotEmpty)
            ? deviceName
            : 'Switch ${index + 1}',
        mode: InputMode.momentary,
      ));
    }
    if (module.inputs.length > targetInputs) {
      module.inputs.removeRange(targetInputs, module.inputs.length);
    }

    for (final input in config.inputs) {
      final index = input.channel;
      if (index < 0 || index >= module.inputs.length) continue;
      final liveInput = module.inputs[index];
      // The device is the source of truth for the name; a rename made outside
      // the app shows up on the next refresh.
      if (input.name.isNotEmpty) {
        liveInput.name = input.name;
      }
    }
  }
}
