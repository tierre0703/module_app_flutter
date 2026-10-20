// lib/screens/temperature_module_screen.dart
//
// Brief section 2.3 "Temperature Module": displays the current temperature
// and lets the user configure high/low alert thresholds. Per the brief's
// explicit note, advanced thermostat functionality is not exposed in this
// phase (Level 1) - shown here as a disabled row for transparency.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class TemperatureModuleScreen extends StatefulWidget {
  const TemperatureModuleScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<TemperatureModuleScreen> createState() =>
      _TemperatureModuleScreenState();
}

class _TemperatureModuleScreenState extends State<TemperatureModuleScreen> {
  bool _alertsEnabled = true;

  bool _editDialogOpen = false;

  Future<void> _editModuleInfo() async {
    if (_editDialogOpen) return;
    _editDialogOpen = true;
    try {
      final saved = await showEditModuleInfoDialog(context, widget.module);
      if (saved && mounted) setState(() {});
    } finally {
      _editDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live temperature arrives as `system_status` broadcasts (every ~5 s while
    // a client is connected) and flows into the store via ModuleStatusService;
    // rebuild when it does instead of polling get_device_state every second.
    return ListenableBuilder(
      listenable: ModuleStore.shared,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final module = ModuleStore.shared.byId(widget.module.id) ?? widget.module;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    final bool alert = module.isOverTemperature;
    final String statusLabel = !alert
        ? l10n.tempStatusNormal
        : (module.internalTempC > module.tempMaxC
            ? l10n.tempStatusAboveMax
            : l10n.tempStatusBelowMin);

    return Scaffold(
      appBar: AppBar(
        title: Text(module.name),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            // Action buttons row.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _editModuleInfo),
              ],
            ),
            const SizedBox(height: 8),
            ModuleStatusHeader(module: module),
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Text(
                    l10n.tempValueCelsius(
                        module.internalTempC.toStringAsFixed(1)),
                    style: TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                      color: alert ? AppColors.offlineAlert : onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusLabel,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color:
                            alert ? AppColors.offlineAlert : AppColors.online),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.tempThresholdsHeader),
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    _ThresholdSlider(
                      label: l10n.tempMinimum,
                      value: module.tempMinC,
                      onChanged: (v) => setState(() => module.tempMinC = v),
                    ),
                    _ThresholdSlider(
                      label: l10n.tempMaximum,
                      value: module.tempMaxC,
                      onChanged: (v) => setState(() => module.tempMaxC = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.tempFunctionsHeader),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text(l10n.tempFuncHighLow),
                    subtitle: Text(l10n.tempFuncHighLowDesc),
                    value: _alertsEnabled,
                    onChanged: (v) => setState(() => _alertsEnabled = v),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: Text(l10n.tempFuncDisplay),
                    subtitle: Text(l10n.tempFuncDisplayDesc),
                    trailing: const Icon(Icons.check_circle_outline),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: Text(l10n.tempFuncThermostat),
                    subtitle: Text(l10n.tempFuncThermostatDesc),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: onSurface.withValues(alpha: 0.25)),
                      ),
                      child: Text(l10n.comingSoon,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                    enabled: false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThresholdSlider extends StatelessWidget {
  const _ThresholdSlider(
      {required this.label, required this.value, required this.onChanged});

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final String celsius = value.toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(l10n.tempValueCelsius(celsius)),
          ],
        ),
        Slider(
          value: value.clamp(0, 100),
          min: 0,
          max: 100,
          divisions: 100,
          label: l10n.tempValueCelsius(celsius),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
