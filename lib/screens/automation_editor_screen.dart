// lib/screens/automation_editor_screen.dart
//
// Brief section 2.4 "Smart Automations": build an IF...THEN... rule -
// trigger by time of day or by another device's state - with one or more
// resulting actions.
//
// Both the watched target and every THEN action are wired by *index* (fleet
// position + channel/input position), not by name, so renaming a module or an
// output never orphans the rule.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/action_picker.dart';
import '../widgets/common_widgets.dart';

/// Only the inputs the user left enabled can be watched by an automation.
List<PhysicalInput> _enabledInputs(List<PhysicalInput>? inputs) => [
      for (final i in inputs ?? const <PhysicalInput>[])
        if (i.enabled) i,
    ];

class AutomationEditorScreen extends StatefulWidget {
  const AutomationEditorScreen({super.key, this.automation});

  /// Null when creating a brand new automation.
  final Automation? automation;

  @override
  State<AutomationEditorScreen> createState() => _AutomationEditorScreenState();
}

class _AutomationEditorScreenState extends State<AutomationEditorScreen> {
  late final bool _isNew = widget.automation == null;
  late final TextEditingController _nameController =
      TextEditingController(text: widget.automation?.name ?? '');
  late AutomationTriggerType _triggerType =
      widget.automation?.triggerType ?? AutomationTriggerType.time;
  late TimeOfDay _time = TimeOfDay(
    hour: widget.automation?.effectiveScheduleHour ?? 20,
    minute: widget.automation?.effectiveScheduleMinute ?? 0,
  );
  late bool _deviceTurnsOn = widget.automation?.watchState ?? true;
  late final List<ScenarioAction> _actions =
      List.of(widget.automation?.actions ?? const []);
  List<DeviceModule> _modules = const [];

  /// Watched module/input/output wired by **index** (see [Automation]); the
  /// names are kept for the saved trigger summary and as a legacy fallback.
  late int _watchModuleIndex = widget.automation?.watchModuleIndex ?? -1;
  late bool _deviceIsInput = widget.automation?.watchIsInput ?? false;
  late int _watchInputIndex = widget.automation?.watchInputIndex ?? -1;
  late int _watchChannelIndex = widget.automation?.watchChannelIndex ?? -1;
  late String _deviceModuleName = widget.automation?.watchModuleName ?? '';
  late String _deviceInputName = widget.automation?.watchInputName ?? '';
  late String _deviceChannelName = widget.automation?.watchChannelName ?? '';
  // Hub-specific trigger fields
  late bool _watchIsHubModbus = false;

  /// Modules that expose at least one channel output or enabled input, i.e.
  /// everything the device-state trigger can watch. Disabled inputs are not
  /// offered as watch targets.
  List<DeviceModule> get _modulesWithTargets => [
        for (final m in _modules)
          if (m.channels.isNotEmpty || _enabledInputs(m.inputs).isNotEmpty) m
      ];

  /// The watched module: resolved by fleet index when wired, otherwise (legacy)
  /// by the saved module name.
  DeviceModule? get _selectedModule {
    final byIndex = moduleAtIndex(_modules, _watchModuleIndex);
    if (byIndex != null) return byIndex;
    if (_deviceModuleName.isEmpty) return null;
    for (final m in _modulesWithTargets) {
      if (m.name == _deviceModuleName) return m;
    }
    return null;
  }

  /// Indices (within the module's channel/input list) the trigger can watch.
  List<int> get _outputIndices => [
        for (var i = 0; i < (_selectedModule?.channels.length ?? 0); i++) i,
      ];

  /// Indices of the module's *enabled* inputs (a disabled input is never a
  /// watch target).
  List<int> get _inputIndices => [
        for (var i = 0; i < (_selectedModule?.inputs.length ?? 0); i++)
          if (_selectedModule!.inputs[i].enabled) i,
      ];

  /// The module name shown for the saved trigger summary.
  String get _watchTargetName {
    final m = _selectedModule;
    if (m != null) {
      if (m.type == ModuleType.hub && _watchIsHubModbus) {
        return 'Modbus ${_channelNameAt(m, _watchChannelIndex)}';
      }
      return _deviceIsInput
          ? _inputNameAt(m, _watchInputIndex)
          : _channelNameAt(m, _watchChannelIndex);
    }
    if (m.type == ModuleType.hub && _watchIsHubModbus) {
      return 'Modbus ${_channelNameAt(m, _watchChannelIndex)}';
    }
    return _deviceIsInput ? _deviceInputName : _deviceChannelName;
  }

  String _channelNameAt(DeviceModule m, int index) =>
      (index >= 0 && index < m.channels.length) ? m.channels[index].name : '';

  String _inputNameAt(DeviceModule m, int index) =>
      (index >= 0 && index < m.inputs.length) ? m.inputs[index].name : '';

  /// True when the selected module exposes at least one output (or enabled
  /// input when an input trigger is chosen), i.e. there is a target to watch.
  bool get _hasWatchTarget {
    final m = _selectedModule;
    if (m == null) return false;
    return _outputIndices.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    ModuleStore.shared.init().then((_) {
      if (!mounted) return;
      setState(() {
        _modules = ModuleStore.shared.modules;
        _adoptSavedTriggerTarget();
      });
    });
  }

  /// Restores the module-scoped trigger target when editing a saved
  /// automation: by fleet index first, then (legacy) by the saved names.
  void _adoptSavedTriggerTarget() {
    if (moduleAtIndex(_modules, _watchModuleIndex) == null) {
      // Legacy: find the module that owns the saved output/input name.
      final wanted = _deviceIsInput ? _deviceInputName : _deviceChannelName;
      if (wanted.isNotEmpty) {
        for (final m in _modulesWithTargets) {
          final names = _deviceIsInput
              ? [for (final i in m.inputs) i.name]
              : [for (final c in m.channels) c.name];
          if (names.contains(wanted)) {
            _watchModuleIndex = moduleIndexOf(_modules, m);
            _deviceModuleName = m.name;
            break;
          }
        }
      }
    }
    if (moduleAtIndex(_modules, _watchModuleIndex) == null &&
        _modulesWithTargets.isNotEmpty) {
      _watchModuleIndex = moduleIndexOf(_modules, _modulesWithTargets.first);
      _deviceModuleName = _modulesWithTargets.first.name;
    }
    _ensureValidWatchTarget();
  }

  /// Drops a target that no longer exists on the selected module and falls back
  /// to the module's first output/input of the selected kind.
  void _ensureValidWatchTarget() {
    final m = _selectedModule;
    if (m == null) {
      _watchInputIndex = -1;
      _watchChannelIndex = -1;
      return;
    }
    if (m.type == ModuleType.hub) {
      final isModbus = _watchIsHubModbus;
      if (!_outputIndices.contains(_watchChannelIndex)) {
        _watchChannelIndex =
            _outputIndices.isNotEmpty ? _outputIndices.first : -1;
      }
      _deviceChannelName = _channelNameAt(m, _watchChannelIndex);
    } else if (_deviceIsInput) {
      if (!_inputIndices.contains(_watchInputIndex)) {
        _watchInputIndex = _inputIndices.isNotEmpty ? _inputIndices.first : -1;
      }
      _deviceInputName = _inputNameAt(m, _watchInputIndex);
    } else {
      if (!_outputIndices.contains(_watchChannelIndex)) {
        _watchChannelIndex =
            _outputIndices.isNotEmpty ? _outputIndices.first : -1;
      }
      _deviceChannelName = _channelNameAt(m, _watchChannelIndex);
    }
  }

  /// Resets the watched target to the first output/input of the (newly)
  /// selected kind owned by the current module.
  void _resetWatchTargetToFirst() {
    final m = _selectedModule;
    if (m == null) {
      _watchInputIndex = -1;
      _watchChannelIndex = -1;
      _deviceInputName = '';
      _deviceChannelName = '';
      return;
    }
    if (m.type == ModuleType.hub) {
      _watchIsHubModbus = false;
      _watchInputIndex = -1;
      _deviceInputName = '';
      _watchChannelIndex =
          _outputIndices.isNotEmpty ? _outputIndices.first : -1;
      _deviceChannelName = _channelNameAt(m, _watchChannelIndex);
    } else if (_deviceIsInput) {
      _watchInputIndex = _inputIndices.isNotEmpty ? _inputIndices.first : -1;
      _deviceInputName = _inputNameAt(m, _watchInputIndex);
    } else {
      _watchChannelIndex =
          _outputIndices.isNotEmpty ? _outputIndices.first : -1;
      _deviceChannelName = _channelNameAt(m, _watchChannelIndex);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked =
        await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _addAction() async {
    final action = await showAddActionSheet(context, _modules);
    if (action != null) setState(() => _actions.add(action));
  }

  String get _triggerSummary {
    final l10n = AppLocalizations.of(context);
    if (_triggerType == AutomationTriggerType.time) {
      final hh = _time.hour.toString().padLeft(2, '0');
      final mm = _time.minute.toString().padLeft(2, '0');
      return l10n.automationEveryDayAt('$hh:$mm');
    }
    final module = _selectedModule;
    final device = module == null
        ? _watchTargetName
        : '${module.name} · $_watchTargetName';
    return l10n.automationWhenTurns(
        device, _deviceTurnsOn ? l10n.on : l10n.off);
  }

  void _save() {
    FocusScope.of(context).unfocus();
    final String name = _nameController.text.trim().isEmpty
        ? AppLocalizations.of(context).automationUntitled
        : _nameController.text.trim();
    if (widget.automation != null) {
      final a = widget.automation!;
      a.name = name;
      a.triggerType = _triggerType;
      a.triggerSummary = _triggerSummary;
      a.scheduleHour =
          _triggerType == AutomationTriggerType.time ? _time.hour : null;
      a.scheduleMinute =
          _triggerType == AutomationTriggerType.time ? _time.minute : null;
      final watching = _triggerType == AutomationTriggerType.deviceState;
      a.watchModuleName =
          watching ? (_selectedModule?.name ?? _deviceModuleName) : null;
      a.watchModuleIndex = watching ? _watchModuleIndex : -1;
      a.watchIsInput = watching && _deviceIsInput;
      a.watchInputName = watching && _deviceIsInput ? _deviceInputName : null;
      a.watchInputIndex = watching && _deviceIsInput ? _watchInputIndex : -1;
      a.watchChannelName =
          watching && !_deviceIsInput ? _deviceChannelName : null;
      a.watchChannelIndex =
          watching && !_deviceIsInput ? _watchChannelIndex : -1;
      a.watchState = watching && _deviceTurnsOn;
      // Hub modbus flag not persisted (UI-only reset safeguard); triggers
      // treat _watchIsHubModbus as a derived state from the module type.
      a.actions
        ..clear()
        ..addAll(_actions);
      Navigator.of(context).pop(a);
    } else {
      final a = Automation(
        id: 'automation-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        triggerType: _triggerType,
        triggerSummary: _triggerSummary,
        scheduleHour:
            _triggerType == AutomationTriggerType.time ? _time.hour : null,
        scheduleMinute:
            _triggerType == AutomationTriggerType.time ? _time.minute : null,
        watchModuleName: _triggerType == AutomationTriggerType.deviceState
            ? (_selectedModule?.name ?? _deviceModuleName)
            : null,
        watchModuleIndex: _triggerType == AutomationTriggerType.deviceState
            ? _watchModuleIndex
            : -1,
        watchIsInput:
            _triggerType == AutomationTriggerType.deviceState && _deviceIsInput,
        watchInputName:
            _triggerType == AutomationTriggerType.deviceState && _deviceIsInput
                ? _deviceInputName
                : null,
        watchInputIndex:
            _triggerType == AutomationTriggerType.deviceState && _deviceIsInput
                ? _watchInputIndex
                : -1,
        watchChannelName:
            _triggerType == AutomationTriggerType.deviceState && !_deviceIsInput
                ? _deviceChannelName
                : null,
        watchChannelIndex:
            _triggerType == AutomationTriggerType.deviceState && !_deviceIsInput
                ? _watchChannelIndex
                : -1,
        watchState:
            _triggerType == AutomationTriggerType.deviceState && _deviceTurnsOn,
        actions: _actions,
      );
      Navigator.of(context).pop(a);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(
              _isNew ? l10n.automationNewTitle : l10n.automationEditTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                  labelText: l10n.automationNameLabel,
                  prefixIcon: const Icon(Icons.label_outline)),
            ),
            const SizedBox(height: 20),
            SectionHeader(l10n.automationSectionIf),
            SegmentedButton<AutomationTriggerType>(
              segments: [
                ButtonSegment(
                    value: AutomationTriggerType.time,
                    label: Text(l10n.automationTriggerTime),
                    icon: const Icon(Icons.schedule)),
                ButtonSegment(
                    value: AutomationTriggerType.deviceState,
                    label: Text(l10n.automationTriggerDevice),
                    icon: const Icon(Icons.sensors)),
              ],
              selected: {_triggerType},
              onSelectionChanged: (s) => setState(() => _triggerType = s.first),
            ),
            const SizedBox(height: 16),
            if (_triggerType == AutomationTriggerType.time)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.access_time),
                  title: Text(l10n.automationTriggerTimeLabel),
                  subtitle: Text(_time.format(context)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickTime,
                ),
              )
            else ...[
              DropdownButtonFormField<int>(
                // Watched by fleet index, so a module rename never breaks it.
                key: ValueKey(_watchModuleIndex),
                initialValue: moduleAtIndex(_modules, _watchModuleIndex) != null
                    ? _watchModuleIndex
                    : null,
                decoration: InputDecoration(
                    labelText: l10n.actionPickerModuleLabel,
                    prefixIcon: const Icon(Icons.devices_other)),
                items: [
                  for (final m in _modulesWithTargets)
                    DropdownMenuItem(
                        value: moduleIndexOf(_modules, m), child: Text(m.name)),
                ],
                onChanged: (v) => setState(() {
                  if (v == null) return;
                  _watchModuleIndex = v;
                  _resetWatchTargetToFirst();
                }),
              ),
              const SizedBox(height: 12),
              if (_selectedModule?.type == ModuleType.hub) ...[
                // Hub modules: Output vs Modbus Power instead of Input vs Output.
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                        value: 'output',
                        label: Text('Output'),
                        icon: const Icon(Icons.output_outlined)),
                    ButtonSegment(
                        value: 'modbus',
                        label: Text('Modbus'),
                        icon: const Icon(Icons.electrical_services)),
                  ],
                  selected: {_watchIsHubModbus ? 'modbus' : 'output'},
                  onSelectionChanged: (s) => setState(() {
                    _watchIsHubModbus = s.first == 'modbus';
                    _resetWatchTargetToFirst();
                  }),
                ),
              ] else ...[
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                        value: true,
                        label: Text(l10n.actionPickerInputTarget),
                        icon: const Icon(Icons.touch_app_outlined)),
                    ButtonSegment(
                        value: false,
                        label: Text(l10n.actionPickerOutputTarget),
                        icon: const Icon(Icons.output_outlined)),
                  ],
                  selected: {_deviceIsInput},
                  onSelectionChanged: (s) => setState(() {
                    _deviceIsInput = s.first;
                    _resetWatchTargetToFirst();
                  }),
                ),
              ],
              const SizedBox(height: 12),
              if (!_hasWatchTarget)
                Text(_deviceIsInput
                    ? l10n.actionPickerNoInputs
                    : l10n.actionPickerNoOutputs)
              else
                DropdownButtonFormField<int>(
                  // Watched output/input wired by index; the label is resolved
                  // live so a rename does not orphan the trigger.
                  key: ValueKey(_deviceIsInput
                      ? 'in:$_watchInputIndex'
                      : 'out:$_watchChannelIndex'),
                  initialValue: _deviceIsInput
                      ? (_inputIndices.contains(_watchInputIndex)
                          ? _watchInputIndex
                          : null)
                      : (_outputIndices.contains(_watchChannelIndex)
                          ? _watchChannelIndex
                          : null),
                  decoration: InputDecoration(
                      labelText: _deviceIsInput
                          ? l10n.actionPickerInputLabel
                          : l10n.actionPickerOutputLabel,
                      prefixIcon: Icon(_deviceIsInput
                          ? Icons.touch_app_outlined
                          : Icons.sensors)),
                  items: [
                    for (final i
                        in _deviceIsInput ? _inputIndices : _outputIndices)
                      DropdownMenuItem(
                          value: i,
                          child: Text(_deviceIsInput
                              ? _inputNameAt(_selectedModule!, i)
                              : _channelNameAt(_selectedModule!, i))),
                  ],
                  onChanged: (v) => setState(() {
                    if (v == null) return;
                    final m = _selectedModule;
                    if (m == null) return;
                    if (_deviceIsInput) {
                      _watchInputIndex = v;
                      _deviceInputName = _inputNameAt(m, v);
                    } else {
                      _watchChannelIndex = v;
                      _deviceChannelName = _channelNameAt(m, v);
                    }
                  }),
                ),
              if (_hasWatchTarget) ...[
                const SizedBox(height: 12),
                // Hub modules support ON/OFF/Pulse for IF triggers.
                if (_selectedModule?.type == ModuleType.hub) ...[
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'on', label: Text(l10n.automationTurnsOn)),
                      ButtonSegment(
                          value: 'off', label: Text(l10n.automationTurnsOff)),
                      ButtonSegment(
                          value: 'pulse', label: Text('Pulse')),
                    ],
                    selected: {_deviceTurnsOn ? 'on' : 'off'},
                    onSelectionChanged: (s) => setState(() {
                      final v = s.first;
                      _deviceTurnsOn = v != 'off';
                    }),
                  ),
                ] else ...[
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                          value: true, label: Text(l10n.automationTurnsOn)),
                      ButtonSegment(
                          value: false, label: Text(l10n.automationTurnsOff)),
                    ],
                    selected: {_deviceTurnsOn},
                    onSelectionChanged: (s) =>
                        setState(() => _deviceTurnsOn = s.first),
                  ),
                ],
              ],
            ],
            const SizedBox(height: 24),
            SectionHeader(
              l10n.automationSectionThen,
              trailing: TextButton.icon(
                  onPressed: _addAction,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.add)),
            ),
            if (_actions.isEmpty)
              EmptyState(
                  icon: Icons.flash_on_outlined,
                  message: l10n.automationActionsEmpty)
            else
              for (int i = 0; i < _actions.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: Card(
                    child: ListTile(
                      leading: IconAvatar(icon: _actions[i].icon),
                      title: Text(
                          _actions[i].isInputAction
                              ? _actions[i].inputName
                              : _actions[i].channelName,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(l10n.scenarioActionModuleSummary(
                          _actions[i].moduleName, _actions[i].summary)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _actions.removeAt(i)),
                      ),
                    ),
                  ),
                ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: Text(l10n.automationSave)),
          ],
        ),
      ),
    );
  }
}
