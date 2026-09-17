// lib/screens/manual_dimming_slider_screen.dart
//
// Brief section 2.4 "Dedicated Manual Control": a special scenario type
// that controls a single dimmer output and can be opened directly from
// Home for quick intensity adjustment.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';

class ManualDimmingSliderScreen extends StatefulWidget {
  const ManualDimmingSliderScreen({super.key, required this.scenario});

  final Scenario scenario;

  @override
  State<ManualDimmingSliderScreen> createState() =>
      _ManualDimmingSliderScreenState();
}

class _ManualDimmingSliderScreenState extends State<ManualDimmingSliderScreen> {
  /// Value while the user is dragging. Null reverts the display to the target
  /// channel's live PWM so the screen stays synced with the module.
  int? _dragValue;

  (DeviceModule, int)? get _targetRef => dimmerTargetRef(
      ModuleStore.shared.modules, widget.scenario.sliderTargetName);

  ChannelOutput? get _target => _targetRef?.$1.channels[_targetRef!.$2];

  int get _value {
    if (_dragValue != null) return _dragValue!;
    final channel = _target;
    if (channel != null) return channel.brightness.clamp(0, 100);
    return widget.scenario.sliderValue.clamp(0, 100);
  }

  Future<void> _update(int value) async {
    final snapped = _target?.snapBrightness(value) ?? value;
    final v = snapped.clamp(0, 100).toInt();
    setState(() {
      _dragValue = v;
      widget.scenario.sliderValue = v;
    });
    final ref = _targetRef;
    if (ref != null) {
      await ModuleStatusService.shared.setDimmerLevel(ref.$1.id, ref.$2, v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: ModuleStore.shared,
      builder: (context, _) {
        final target = _target;
        final visible = _dragValue ?? _value;
        return Scaffold(
          appBar: AppBar(title: Text(widget.scenario.name)),
          body: Padding(
            padding: const EdgeInsets.all(AppSpacing.outerPadding),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const Spacer(),
                  Icon(
                    Icons.lightbulb,
                    size: 96,
                    color: visible == 0
                        ? onSurface.withValues(alpha: 0.2)
                        : onSurface,
                  ),
                  const SizedBox(height: 16),
                  Text('$visible%',
                      style: const TextStyle(
                          fontSize: 64, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    widget.scenario.sliderTargetName.isEmpty
                        ? l10n.manualDimDefaultLabel
                        : widget.scenario.sliderTargetName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: onSurface.withValues(alpha: 0.55)),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      const Icon(Icons.brightness_low),
                      Expanded(
                        child: Slider(
                          value: visible.toDouble(),
                          min: 0,
                          max: 100,
                          divisions: target?.brightnessSliderDivisions ?? 100,
                          label: '$visible%',
                          onChanged: (v) => _update(v.round()),
                          onChangeEnd: (_) =>
                              setState(() => _dragValue = null),
                        ),
                      ),
                      const Icon(Icons.brightness_high),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                          child: OutlinedButton(
                              onPressed: () => _update(0),
                              child: Text(l10n.off))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: FilledButton(
                              onPressed: () => _update(100),
                              child: Text(l10n.on))),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
