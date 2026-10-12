// lib/screens/automation_editor_screen.dart
//
// Brief section 2.4 "Smart Automations": build an IF...THEN... rule -
// trigger by time of day or by another device's state - with one or more
// resulting actions.
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
  late String _deviceModuleName = widget.automation?.watchModuleName ?? '';
  late bool _deviceIsInput = widget.automation?.watchIsInput ?? false;
  late String _deviceInputName = widget.automation?.watchInputName ?? '';
  late String _deviceChannelName = widget.automation?.watchChannelName ?? '';

  /// Modules that expose at least one channel output or enabled input, i.e.
  /// everything the device-state trigger can watch. Disabled inputs are not
  /// offered as watch targets.
  List<DeviceModule> get _modulesWithTargets => [
        for (final m in _modules)
          if (m.channels.isNotEmpty || _enabledInputs(m.inputs).isNotEmpty) m
      ];

  DeviceModule? get _selectedModule {
    for (final m in _modulesWithTargets) {
      if (m.name == _deviceModuleName) return m;
    }
    return null;
  }

  List<String> _outputNames(DeviceModule? m) =>
      [for (final c in m?.channels ?? const <ChannelOutput>[]) c.name];

  List<String> _inputNames(DeviceModule? m) =>
      [for (final i in _enabledInputs(m?.inputs)) i.name];

  String get _watchTargetName =>
      _deviceIsInput ? _deviceInputName : _deviceChannelName;

  /// True when the selected module exposes at least one output (or input when
  /// an input trigger is chosen), i.e. there is a concrete target to watch.
  bool get _hasWatchTarget {
    final m = _selectedModule;
    if (m == null) return false;
    return _deviceIsInput
        ? _inputNames(m).isNotEmpty
        : _outputNames(m).isNotEmpty;
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

  /// Restores the module-scoped trigger target when editing a saved automation.
  ///
  /// Legacy automations saved only the channel/input name, so the owning module
  /// is derived from it the first time the editor opens.
  void _adoptSavedTriggerTarget() {
    if (_deviceModuleName.isEmpty && _watchTargetName.isNotEmpty) {
      for (final m in _modulesWithTargets) {
        final names = _deviceIsInput ? _inputNames(m) : _outputNames(m);
        if (names.contains(_watchTargetName)) {
          _deviceModuleName = m.name;
          break;
        }
      }
    }
    if (_deviceModuleName.isEmpty && _modulesWithTargets.isNotEmpty) {
      _deviceModuleName = _modulesWithTargets.first.name;
    }
    _ensureValidWatchTarget();
  }

  /// Drops a target that no longer exists on the selected module and falls back
  /// to the module's first output/input of the selected kind.
  void _ensureValidWatchTarget() {
    final m = _selectedModule;
    final names = _deviceIsInput ? _inputNames(m) : _outputNames(m);
    if (!names.contains(_watchTargetName)) {
      if (_deviceIsInput) {
        _deviceInputName = names.isNotEmpty ? names.first : '';
      } else {
        _deviceChannelName = names.isNotEmpty ? names.first : '';
      }
    }
  }

  /// Resets the watched target to the first output/input of the (newly)
  /// selected kind owned by the current module.
  void _resetWatchTargetToFirst() {
    final m = _selectedModule;
    if (m == null) {
      _deviceInputName = '';
      _deviceChannelName = '';
      return;
    }
    if (_deviceIsInput) {
      _deviceInputName = _inputNames(m).isNotEmpty ? _inputNames(m).first : '';
    } else {
      _deviceChannelName =
          _outputNames(m).isNotEmpty ? _outputNames(m).first : '';
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
      a.watchModuleName = _triggerType == AutomationTriggerType.deviceState
          ? _deviceModuleName
          : null;
      a.watchIsInput =
          _triggerType == AutomationTriggerType.deviceState && _deviceIsInput;
      a.watchInputName =
          _triggerType == AutomationTriggerType.deviceState && _deviceIsInput
              ? _deviceInputName
              : null;
      a.watchChannelName =
          _triggerType == AutomationTriggerType.deviceState && !_deviceIsInput
              ? _deviceChannelName
              : null;
      a.watchState =
          _triggerType == AutomationTriggerType.deviceState && _deviceTurnsOn;
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
            ? _deviceModuleName
            : null,
        watchIsInput:
            _triggerType == AutomationTriggerType.deviceState && _deviceIsInput,
        watchInputName:
            _triggerType == AutomationTriggerType.deviceState && _deviceIsInput
                ? _deviceInputName
                : null,
        watchChannelName:
            _triggerType == AutomationTriggerType.deviceState && !_deviceIsInput
                ? _deviceChannelName
                : null,
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
              DropdownButtonFormField<String>(
                initialValue:
                    _deviceModuleName.isEmpty ? null : _deviceModuleName,
                decoration: InputDecoration(
                    labelText: l10n.actionPickerModuleLabel,
                    prefixIcon: const Icon(Icons.devices_other)),
                items: [
                  for (final m in _modulesWithTargets)
                    DropdownMenuItem(value: m.name, child: Text(m.name)),
                ],
                onChanged: (v) => setState(() {
                  if (v == null) return;
                  _deviceModuleName = v;
                  _resetWatchTargetToFirst();
                }),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              if (!_hasWatchTarget)
                Text(_deviceIsInput
                    ? l10n.actionPickerNoInputs
                    : l10n.actionPickerNoOutputs)
              else
                DropdownButtonFormField<String>(
                  initialValue: _watchTargetName,
                  decoration: InputDecoration(
                      labelText: _deviceIsInput
                          ? l10n.actionPickerInputLabel
                          : l10n.actionPickerOutputLabel,
                      prefixIcon: Icon(_deviceIsInput
                          ? Icons.touch_app_outlined
                          : Icons.sensors)),
                  items: [
                    for (final n in _deviceIsInput
                        ? _inputNames(_selectedModule)
                        : _outputNames(_selectedModule))
                      DropdownMenuItem(value: n, child: Text(n)),
                  ],
                  onChanged: (v) => setState(() {
                    if (_deviceIsInput) {
                      _deviceInputName = v ?? _deviceInputName;
                    } else {
                      _deviceChannelName = v ?? _deviceChannelName;
                    }
                  }),
                ),
              if (_hasWatchTarget) ...[
                const SizedBox(height: 12),
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
