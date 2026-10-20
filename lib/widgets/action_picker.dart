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
//
// The returned [ScenarioAction] references the module and output/input by
// index (fleet position + channel/input position) so a rename never orphans
// the action; the picked display names are stored alongside for the UI.
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
      .where(
          (m) => m.channels.isNotEmpty || _enabledInputs(m.inputs).isNotEmpty)
      .toList();
  // A module's position is its index in the full fleet, not in the filtered
  // [allModules] list: `indexOf` on the sublist would break whenever a module
  // without channels/inputs sits before it.
  int fleetIndex(DeviceModule m) => moduleIndexOf(modules, m);

  bool isInputTarget = initial?.isInputAction ?? false;
  DeviceModule? module;
  int moduleIndex = -1;
  int channelIndex = -1;
  int inputIndex = -1;
  bool turnOn = initial?.turnOn ?? true;
  int brightness = initial?.brightnessPct ?? 100;
  InputActionState inputState = initial?.inputState ?? InputActionState.on;
  HubOutputBank hubOutputBank = initial?.hubOutputBank ?? HubOutputBank.normal;
  bool hubActionPulse = initial?.hubActionPulse ?? false;

  /// Keeps the index pair in sync with the currently selected module/channel.
  void selectModule(DeviceModule? m) {
    module = m;
    moduleIndex = m == null ? -1 : fleetIndex(m);
  }

  if (initial != null) {
    // The stored fleet index is the source of truth; the saved name is only a
    // legacy fallback for actions created before index wiring existed.
    selectModule(_resolveModule(allModules, modules, initial));
    if (isInputTarget) {
      if (module != null) inputIndex = _resolveInputIndex(module!, initial);
      if (module != null &&
          inputIndex < 0 &&
          _enabledInputs(module!.inputs).isEmpty &&
          inputModules.isNotEmpty) {
        selectModule(inputModules.first);
        inputIndex = _resolveInputIndex(module!, initial);
      }
      // Dimmer inputs only support Pulse.
      if (module?.type == ModuleType.dimmerDc ||
          module?.type == ModuleType.dimmerAc) {
        inputState = InputActionState.pulse;
      }
    } else if (initial?.isHubAction ?? false) {
      // Hub target — channelIndex references the Hub's normal-output list but
      // the output bank decides which physical list to target.
      if (module != null) channelIndex = _resolveChannelIndex(module!, initial);
      if (module != null &&
          channelIndex < 0 &&
          module!.channels.isEmpty &&
          outputModules.isNotEmpty) {
        selectModule(outputModules.first);
        channelIndex = _resolveChannelIndex(module!, initial);
      }
      hubOutputBank = initial!.hubOutputBank;
      hubActionPulse = initial!.hubActionPulse;
    } else {
      if (module != null) channelIndex = _resolveChannelIndex(module!, initial);
      if (module != null &&
          channelIndex < 0 &&
          module!.channels.isEmpty &&
          outputModules.isNotEmpty) {
        selectModule(outputModules.first);
        channelIndex = _resolveChannelIndex(module!, initial);
      }
    }
  } else {
    if (outputModules.isNotEmpty) {
      selectModule(outputModules.first);
      channelIndex = 0;
    } else if (inputModules.isNotEmpty) {
      isInputTarget = true;
      selectModule(inputModules.first);
      inputIndex = 0;
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
          final bool isHubModule = module?.type == ModuleType.hub;

          void switchTarget(bool toInput) {
            setSheetState(() {
              isInputTarget = toInput;
              // Keep the current module when it supports the new target,
              // otherwise fall back to the first module that does.
              if (toInput) {
                channelIndex = -1;
                inputIndex = _firstEnabledInputIndex(module);
                if (inputIndex < 0 && inputModules.isNotEmpty) {
                  selectModule(inputModules.first);
                  inputIndex = _firstEnabledInputIndex(module);
                }
                // Dimmer inputs only support Pulse.
                if (module?.type == ModuleType.dimmerDc ||
                    module?.type == ModuleType.dimmerAc) {
                  inputState = InputActionState.pulse;
                }
              } else {
                inputIndex = -1;
                channelIndex = (module?.channels.isNotEmpty ?? false) ? 0 : -1;
                if (channelIndex < 0 && outputModules.isNotEmpty) {
                  selectModule(outputModules.first);
                  channelIndex = 0;
                }
              }
            });
          }

          final bool isDimmer = isDimmerModule && !isInputTarget;
          // The dimmer output the sheet currently points at (by index), used
          // for the slider's step size.
          ChannelOutput? sliderChannel() {
            final m = module;
            if (m == null ||
                channelIndex < 0 ||
                channelIndex >= m.channels.length) {
              return null;
            }
            return m.channels[channelIndex];
          }

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
                        selectModule(m);
                        if (isInputTarget) {
                          inputIndex = _firstEnabledInputIndex(m);
                          // Dimmer inputs only support Pulse.
                          if (m?.type == ModuleType.dimmerDc ||
                              m?.type == ModuleType.dimmerAc) {
                            inputState = InputActionState.pulse;
                          }
                        } else {
                          channelIndex =
                              (m?.channels.isNotEmpty ?? false) ? 0 : -1;
                        }
                      }),
                    ),
                    const SizedBox(height: 20),
                    Text(l10n.actionPickerTargetLabel,
                        style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 8),
                    if (isHubModule) ...[
                      // Hub modules: choose between normal Output and
                      // Modbus Power output bank instead of Output vs Input.
                      SegmentedButton<HubOutputBank>(
                        segments: [
                          ButtonSegment(
                            value: HubOutputBank.normal,
                            label: Text('Output'),
                            icon: const Icon(Icons.output_outlined),
                          ),
                          ButtonSegment(
                            value: HubOutputBank.modbusPower,
                            label: Text('Modbus'),
                            icon: const Icon(Icons.electrical_services),
                          ),
                        ],
                        selected: {hubOutputBank},
                        onSelectionChanged: (s) => setSheetState(()
                            => hubOutputBank = s.first),
                      ),
                      const SizedBox(height: 12),
                      if (module?.channels.isEmpty ?? true)
                        Text(l10n.actionPickerNoOutputs)
                      else
                        DropdownButtonFormField<int>(
                          initialValue:
                              channelIndex >= 0 ? channelIndex : null,
                          decoration: InputDecoration(
                              labelText: l10n.actionPickerOutputLabel),
                          items: [
                            for (var c = 0;
                                c < (module?.channels.length ?? 0);
                                c++)
                              DropdownMenuItem(
                                  value: c,
                                  child: Text(module!.channels[c].name)),
                          ],
                          onChanged: (c) => setSheetState(
                              () => channelIndex = c ?? channelIndex),
                        ),
                    ] else ...[
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
                          DropdownButtonFormField<int>(
                            initialValue:
                                inputIndex >= 0 ? inputIndex : null,
                            decoration: InputDecoration(
                                labelText: l10n.actionPickerInputLabel),
                            items: [
                              for (final i in _enabledInputs(module?.inputs))
                                DropdownMenuItem(
                                    value: module!.inputs.indexOf(i),
                                    child: Text(i.name)),
                            ],
                            onChanged: (i) => setSheetState(
                                () => inputIndex = i ?? inputIndex),
                          )
                      else if (module?.channels.isEmpty ?? true)
                        Text(l10n.actionPickerNoOutputs)
                      else
                        DropdownButtonFormField<int>(
                          initialValue:
                              channelIndex >= 0 ? channelIndex : null,
                          decoration: InputDecoration(
                              labelText: l10n.actionPickerOutputLabel),
                          items: [
                            for (var c = 0;
                                c < (module?.channels.length ?? 0);
                                c++)
                              DropdownMenuItem(
                                  value: c,
                                  child: Text(module!.channels[c].name)),
                          ],
                          onChanged: (c) => setSheetState(
                              () => channelIndex = c ?? channelIndex),
                        ),
                    ],
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
                    ] else if (isHubModule) ...[
                      Text(l10n.actionPickerState,
                          style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                              value: 'on', label: Text(l10n.on)),
                          ButtonSegment(
                              value: 'off', label: Text(l10n.off)),
                          ButtonSegment(
                              value: 'pulse', label: Text('Pulse')),
                        ],
                        selected: {hubActionPulse ? 'pulse' : turnOn ? 'on' : 'off'},
                        onSelectionChanged: (s) => setSheetState(() {
                          final v = s.first;
                          if (v == 'pulse') {
                            hubActionPulse = true;
                          } else {
                            hubActionPulse = false;
                            turnOn = v == 'on';
                          }
                        }),
                      ),
                    ] else if (isDimmer) ...[
                      Text(l10n.actionPickerBrightness(brightness),
                          style: Theme.of(context).textTheme.bodyLarge),
                      Slider(
                        value: brightness.toDouble(),
                        min: 0,
                        max: 100,
                        divisions:
                            sliderChannel()?.brightnessSliderDivisions ?? 100,
                        label: '$brightness%',
                        onChanged: (v) => setSheetState(() => brightness =
                            sliderChannel()?.snapBrightness(v.round()) ??
                                v.round()),
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
                              (isInputTarget
                                  ? inputIndex < 0 ||
                                      inputIndex >= module!.inputs.length
                                  : channelIndex < 0 ||
                                      channelIndex >= module!.channels.length)
                          ? null
                          : () => Navigator.pop(
                                context,
                                ScenarioAction(
                                  moduleName: module!.name,
                                  moduleIndex: moduleIndex,
                                  channelName: module!.channels[channelIndex].name,
                                  channelIndex: channelIndex,
                                  icon: module!.channels[channelIndex].icon,
                                  isDimmerAction: false,
                                  turnOn: turnOn,
                                  brightnessPct: brightness,
                                  isInputAction: false,
                                  inputName: '',
                                  inputIndex: -1,
                                  inputState: InputActionState.on,
                                  isHubAction: isHubModule,
                                  hubOutputBank: hubOutputBank,
                                  hubActionPulse: hubActionPulse,
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

/// The target module for an edited action: the stored fleet index when it
/// still resolves, otherwise (legacy) the saved module name.
DeviceModule? _resolveModule(List<DeviceModule> allModules,
    List<DeviceModule> fleet, ScenarioAction initial) {
  final byIndex = moduleAtIndex(fleet, initial.moduleIndex);
  if (byIndex != null && allModules.contains(byIndex)) return byIndex;
  return _matchModule(allModules, initial.moduleName) ??
      (allModules.isNotEmpty ? allModules.first : null);
}

/// Index of the first enabled input on [m], or -1 when it has none.
int _firstEnabledInputIndex(DeviceModule? m) {
  if (m == null) return -1;
  for (var i = 0; i < m.inputs.length; i++) {
    if (m.inputs[i].enabled) return i;
  }
  return -1;
}

/// Resolves the output index an action points at: the stored [channelIndex]
/// when valid, otherwise a legacy match on the saved channel name.
int _resolveChannelIndex(DeviceModule module, ScenarioAction initial) {
  if (initial.channelIndex >= 0 &&
      initial.channelIndex < module.channels.length) {
    return initial.channelIndex;
  }
  return module.channels.indexWhere((c) => c.name == initial.channelName);
}

/// Resolves the input index an action points at: the stored [inputIndex] when
/// valid, otherwise a legacy match on the saved input name.
int _resolveInputIndex(DeviceModule module, ScenarioAction initial) {
  if (initial.inputIndex >= 0 && initial.inputIndex < module.inputs.length) {
    return initial.inputIndex;
  }
  return module.inputs.indexWhere((i) => i.name == initial.inputName);
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
