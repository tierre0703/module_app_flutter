// lib/widgets/action_picker.dart
//
// Shared "Add Action" bottom sheet used by both the Scenario editor and the
// Automation editor, so a scenario/automation can control "one or more
// outputs, regardless of whether they belong to relay modules (ON/OFF) or
// dimmer modules (intensity control)" (brief section 2.4). It can also drive
// a module's virtual input (ON / OFF / Pulse), e.g. to trigger a physical
// input's associated output from a scenario.
//
// Layout: module first, then the target section (Output / Input toggle plus
// the output or input the action drives below it).
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';

/// Shows a bottom sheet that lets the user pick a module and either an
/// output (relay ON/OFF or dimmer brightness) or an input (ON / OFF / Pulse),
/// returning the resulting [ScenarioAction], or null if the user cancelled.
///
/// When an [initial] action is provided the sheet pre-populates its fields
/// and behaves as an "edit" instead of "add".
Future<ScenarioAction?> showAddActionSheet(
  BuildContext context,
  List<DeviceModule> modules, {
  ScenarioAction? initial,
}) {
  final List<DeviceModule> outputModules =
      modules.where((m) => m.channels.isNotEmpty).toList();
  // A disabled input is not an eligible target anywhere in the app, so only
  // enabled inputs are offered here.
  final List<DeviceModule> inputModules =
      modules.where((m) => _enabledInputs(m.inputs).isNotEmpty).toList();
  final List<DeviceModule> allModules = modules
      .where((m) =>
          m.channels.isNotEmpty || _enabledInputs(m.inputs).isNotEmpty)
      .toList();

  bool isInputTarget = initial?.isInputAction ?? false;
  DeviceModule? module;
  ChannelOutput? channel;
  PhysicalInput? input;
  bool turnOn = initial?.turnOn ?? true;
  int brightness = initial?.brightnessPct ?? 100;
  InputActionState inputState = initial?.inputState ?? InputActionState.on;

  if (initial != null) {
    module = _matchModule(allModules, initial.moduleName) ??
        (allModules.isNotEmpty ? allModules.first : null);
    if (isInputTarget) {
      input = _matchInput(module?.inputs, initial.inputName);
      if (module != null &&
          _enabledInputs(module.inputs).isEmpty &&
          inputModules.isNotEmpty) {
        module = inputModules.first;
        input = _enabledInputs(module.inputs).first;
      }
      // Dimmer inputs only support Pulse.
      if (module?.type == ModuleType.dimmerDc ||
          module?.type == ModuleType.dimmerAc) {
        inputState = InputActionState.pulse;
      }
    } else {
      channel = _matchChannel(module?.channels, initial.channelName);
      if (module != null &&
          module.channels.isEmpty &&
          outputModules.isNotEmpty) {
        module = outputModules.first;
        channel = module.channels.first;
      }
    }
  } else {
    if (outputModules.isNotEmpty) {
      module = outputModules.first;
      channel = module.channels.first;
    } else if (inputModules.isNotEmpty) {
      isInputTarget = true;
      module = inputModules.first;
      input = _enabledInputs(module.inputs).first;
    }
  }

  final bool isEditing = initial != null;

  return showModalBottomSheet<ScenarioAction>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final bool isDimmerModule = module?.type == ModuleType.dimmerDc ||
              module?.type == ModuleType.dimmerAc;

          void switchTarget(bool toInput) {
            setSheetState(() {
              isInputTarget = toInput;
              // Keep the current module when it supports the new target,
              // otherwise fall back to the first module that does.
              if (toInput) {
                channel = null;
                input = _enabledInputs(module?.inputs).isNotEmpty
                    ? _enabledInputs(module!.inputs).first
                    : null;
                if (input == null && inputModules.isNotEmpty) {
                  module = inputModules.first;
                  input = _enabledInputs(module!.inputs).first;
                }
                // Dimmer inputs only support Pulse.
                if (module?.type == ModuleType.dimmerDc ||
                    module?.type == ModuleType.dimmerAc) {
                  inputState = InputActionState.pulse;
                }
              } else {
                input = null;
                channel = module?.channels.isNotEmpty == true
                    ? module!.channels.first
                    : null;
                if (channel == null && outputModules.isNotEmpty) {
                  module = outputModules.first;
                  channel = module!.channels.first;
                }
              }
            });
          }

          final bool isDimmer = isDimmerModule && !isInputTarget;
          final l10n = AppLocalizations.of(context);

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 20,
                bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      isEditing
                          ? l10n.actionPickerEditTitle
                          : l10n.actionPickerAddTitle,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  if (allModules.isEmpty)
                    Text(l10n.actionPickerNoTargets)
                  else ...[
                    DropdownButtonFormField<DeviceModule>(
                      initialValue: module,
                      decoration: InputDecoration(
                          labelText: l10n.actionPickerModuleLabel),
                      items: [
                        for (final m in allModules)
                          DropdownMenuItem(value: m, child: Text(m.name)),
                      ],
                      onChanged: (m) => setSheetState(() {
                        module = m;
                        if (isInputTarget) {
                          input = _enabledInputs(m?.inputs).isNotEmpty
                              ? _enabledInputs(m!.inputs).first
                              : null;
                          // Dimmer inputs only support Pulse.
                          if (m?.type == ModuleType.dimmerDc ||
                              m?.type == ModuleType.dimmerAc) {
                            inputState = InputActionState.pulse;
                          }
                        } else {
                          channel = m?.channels.isNotEmpty == true
                              ? m!.channels.first
                              : null;
                        }
                      }),
                    ),
                    const SizedBox(height: 20),
                    Text(l10n.actionPickerTargetLabel,
                        style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(l10n.actionPickerOutputTarget),
                          icon: const Icon(Icons.output_outlined),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(l10n.actionPickerInputTarget),
                          icon: const Icon(Icons.touch_app_outlined),
                        ),
                      ],
                      selected: {isInputTarget},
                      onSelectionChanged: (s) => switchTarget(s.first),
                    ),
                    const SizedBox(height: 12),
                    if (isInputTarget)
                      if (_enabledInputs(module?.inputs).isEmpty)
                        Text(l10n.actionPickerNoInputs)
                      else
                        DropdownButtonFormField<PhysicalInput>(
                          initialValue: input,
                          decoration: InputDecoration(
                              labelText: l10n.actionPickerInputLabel),
                          items: [
                            for (final i in _enabledInputs(module?.inputs))
                              DropdownMenuItem(value: i, child: Text(i.name)),
                          ],
                          onChanged: (i) => setSheetState(() => input = i),
                        )
                    else if (module?.channels.isEmpty ?? true)
                      Text(l10n.actionPickerNoOutputs)
                    else
                      DropdownButtonFormField<ChannelOutput>(
                        initialValue: channel,
                        decoration: InputDecoration(
                            labelText: l10n.actionPickerOutputLabel),
                        items: [
                          for (final c
                              in module?.channels ?? const <ChannelOutput>[])
                            DropdownMenuItem(value: c, child: Text(c.name)),
                        ],
                        onChanged: (c) => setSheetState(() => channel = c),
                      ),
                    const SizedBox(height: 16),
                    if (isInputTarget) ...[
                      Text(l10n.actionPickerState,
                          style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<InputActionState>(
                        segments: isDimmerModule
                            ? [
                                ButtonSegment(
                                    value: InputActionState.pulse,
                                    label: Text(l10n.pulse)),
                              ]
                            : [
                                ButtonSegment(
                                    value: InputActionState.on,
                                    label: Text(l10n.on)),
                                ButtonSegment(
                                    value: InputActionState.off,
                                    label: Text(l10n.off)),
                                ButtonSegment(
                                    value: InputActionState.pulse,
                                    label: Text(l10n.pulse)),
                              ],
                        selected: {inputState},
                        onSelectionChanged: (s) =>
                            setSheetState(() => inputState = s.first),
                      ),
                    ] else if (isDimmer) ...[
                      Text(l10n.actionPickerBrightness(brightness),
                          style: Theme.of(context).textTheme.bodyLarge),
                      Slider(
                        value: brightness.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: channel?.brightnessSliderDivisions ?? 100,
                        label: '$brightness%',
                        onChanged: (v) => setSheetState(() => brightness =
                            channel?.snapBrightness(v.round()) ?? v.round()),
                      ),
                    ] else ...[
                      Text(l10n.actionPickerState,
                          style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(value: true, label: Text(l10n.on)),
                          ButtonSegment(value: false, label: Text(l10n.off)),
                        ],
                        selected: {turnOn},
                        onSelectionChanged: (s) =>
                            setSheetState(() => turnOn = s.first),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: module == null ||
                              (isInputTarget ? input == null : channel == null)
                          ? null
                          : () => Navigator.pop(
                                context,
                                ScenarioAction(
                                  moduleName: module!.name,
                                  channelName: channel?.name ?? '',
                                  icon: isInputTarget
                                      ? Icons.touch_app_outlined
                                      : channel!.icon,
                                  isDimmerAction: isDimmer,
                                  turnOn: turnOn,
                                  brightnessPct: brightness,
                                  isInputAction: isInputTarget,
                                  inputName: input?.name ?? '',
                                  inputState: inputState,
                                ),
                              ),
                      child: Text(isEditing
                          ? l10n.actionPickerSave
                          : l10n.actionPickerAdd),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Only the inputs the user left enabled can be targeted by a scenario or
/// automation; a disabled input is ignored by the whole app.
List<PhysicalInput> _enabledInputs(List<PhysicalInput>? inputs) => [
      for (final i in inputs ?? const <PhysicalInput>[])
        if (i.enabled) i,
    ];

DeviceModule? _matchModule(List<DeviceModule> modules, String name) {
  for (final m in modules) {
    if (m.name == name) return m;
  }
  return null;
}

ChannelOutput? _matchChannel(List<ChannelOutput>? channels, String name) {
  for (final c in channels ?? const <ChannelOutput>[]) {
    if (c.name == name) return c;
  }
  return null;
}

PhysicalInput? _matchInput(List<PhysicalInput>? inputs, String name) {
  for (final i in inputs ?? const <PhysicalInput>[]) {
    if (i.name == name) return i;
  }
  return null;
}
