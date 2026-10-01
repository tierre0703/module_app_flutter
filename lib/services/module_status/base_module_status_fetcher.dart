// lib/services/module_status/base_module_status_fetcher.dart
//
// Generic status reconciliation shared by every module type.
//
// On top of fetching *online/offline*, a status pass also captures module info
// and the topology reported by the device over PROTOCOLS.md §1:
//   - module identity     (AT+VER  → VER/...) -> [DeviceModule.firmware]
//   - internal temperature (AT+TEMP → SYSTEMP) -> [DeviceModule.internalTempC]
//   - output count         (AT+VER  → RELAY_COUNT)
//   - per-output state     (AT+OUTSTAT → OUT:<pin>:<ON|OFF>)
//   - per-input state      (AT+INSTAT  → IN:<pin>:<ON|OFF>)
//
// Output count is authoritative and comes from the device, and names are too:
// existing channels/inputs adopt the device-reported names (AT+CHNAMES ->
// CHNAME_OUT/CHNAME_IN) on every pass, new channels are appended with the
// device-reported name when available (or a generic default), and channels
// beyond the reported count are dropped - so a rename made outside the app
// shows up on the next refresh. Subclasses only declare their module type and
// the commands that reveal that topology - so dimmer / temperature / blind
// support is added by writing a small subclass, nothing else.
import 'package:flutter/material.dart';

import '../../models/models.dart';
import 'module_status_fetcher.dart';
import 'pdu_protocol.dart';

abstract class BaseModuleStatusFetcher implements ModuleStatusFetcher {
  const BaseModuleStatusFetcher();

  @override
  void apply(DeviceModule module, List<PduResponse> responses) {
    final outputs = <int, bool>{};
    final inputs = <int, bool>{};
    final outputNames = <int, String>{};
    final inputNames = <int, String>{};
    double? temperature;
    String? firmware;
    int? relayCount;

    for (final response in responses) {
      outputs.addAll(response.outputs);
      inputs.addAll(response.inputs);
      outputNames.addAll(response.outputNames);
      inputNames.addAll(response.inputNames);

      final temp = PduResponse.numeric(response.kv['SYSTEMP']);
      if (temp != null) temperature = temp;
      relayCount ??= PduResponse.numeric(response.kv['RELAY_COUNT'])?.toInt();
      firmware ??= response.kv['VER'];
    }

    if (firmware != null) module.firmware = firmware;
    if (temperature != null) module.internalTempC = temperature;

    reconcileOutputs(module, relayCount, outputs, outputNames);
    reconcileInputs(module, inputs, inputNames);

    // Type-specific handling (e.g. brightness for dimmers) hooks here.
    applyExtra(module, responses);
  }

  /// Hook for subclasses that need to interpret responses beyond the generic
  /// scalar/output/input fields shared by PROTOCOLS.md §1 (e.g. dimmer
  /// brightness). No-op by default.
  void applyExtra(DeviceModule module, List<PduResponse> responses) {}

  /// Aligns [module.channels] to the device-reported output count, applying fresh
  /// [outputs] states and the device-reported [outputNames] (the device is the
  /// source of truth for names), and naming any channels appended for the first
  /// time with the device-reported names when available (falling back to a
  /// generic default).
  void reconcileOutputs(
    DeviceModule module,
    int? relayCount,
    Map<int, bool> outputs, [
    Map<int, String> outputNames = const {},
  ]) {
    final targetCount = relayCount ??
        (outputs.isEmpty
            ? module.channels.length
            : (outputs.keys.reduce((a, b) => a > b ? a : b)) + 1);

    while (module.channels.length < targetCount) {
      final index = module.channels.length;
      final deviceName = outputNames[index];
      module.channels.add(ChannelOutput(
        id: '${module.id}c${index + 1}',
        name: (deviceName != null && deviceName.isNotEmpty)
            ? deviceName
            : 'Output ${index + 1}',
        icon: Icons.power,
      ));
    }
    if (module.channels.length > targetCount) {
      module.channels.removeRange(targetCount, module.channels.length);
    }

    for (final entry in outputs.entries) {
      if (entry.key >= 0 && entry.key < module.channels.length) {
        module.channels[entry.key].isOn = entry.value;
      }
    }

    for (final entry in outputNames.entries) {
      if (entry.key >= 0 && entry.key < module.channels.length) {
        // The device is the source of truth for the name; a rename made outside
        // the app shows up on the next refresh.
        if (entry.value.isNotEmpty) {
          module.channels[entry.key].name = entry.value;
        }
      }
    }
  }

  /// Aligns [module.inputs] to the number of inputs the device reports,
  /// appending defaults for new ones (preferring the device-reported names in
  /// [inputNames] when available) and adopting the device-reported names for
  /// existing inputs. Input identities are stable by index.
  void reconcileInputs(
    DeviceModule module,
    Map<int, bool> inputs, [
    Map<int, String> inputNames = const {},
  ]) {
    final targetCount = inputs.isEmpty
        ? module.inputs.length
        : (inputs.keys.reduce((a, b) => a > b ? a : b)) + 1;

    while (module.inputs.length < targetCount) {
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
    if (module.inputs.length > targetCount) {
      module.inputs.removeRange(targetCount, module.inputs.length);
    }

    for (final entry in inputNames.entries) {
      if (entry.key >= 0 && entry.key < module.inputs.length) {
        // The device is the source of truth for the name; a rename made outside
        // the app shows up on the next refresh.
        if (entry.value.isNotEmpty) {
          module.inputs[entry.key].name = entry.value;
        }
      }
    }
  }
}
