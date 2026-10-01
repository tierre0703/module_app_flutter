// lib/screens/blind_control_screen.dart
//
// Brief section 2.3 "Blind Motor Control Modules (DC)": directional UP/DOWN
// buttons with toggle-stop behaviour - a first press starts the motor in
// that direction, a second press of the *same* button stops it.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/system_log_screen.dart';
import 'input_editor_screen.dart';

enum _Motion { idle, up, down }

class BlindControlScreen extends StatefulWidget {
  const BlindControlScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<BlindControlScreen> createState() => _BlindControlScreenState();
}

class _BlindControlScreenState extends State<BlindControlScreen> {
  final Map<String, _Motion> _motion = {};

  @override
  void initState() {
    super.initState();
    // Pull a fresh status dump (output/input states + names) when the screen
    // opens, so device-side changes made outside the app show immediately.
    _refresh();
  }

  _Motion _motionOf(ChannelOutput channel) =>
      _motion[channel.id] ?? _Motion.idle;

  /// Pressing the active direction's button again stops the motor;
  /// pressing the other direction switches directly to it.
  void _press(ChannelOutput channel, _Motion direction) {
    setState(() {
      _motion[channel.id] =
          _motionOf(channel) == direction ? _Motion.idle : direction;
    });
  }

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

  Future<void> _refresh() async {
    if (!mounted) return;
    await ModuleStatusService.shared
        .refreshOne(ModuleStore.shared.byId(widget.module.id) ?? widget.module)
        .then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _editInput(PhysicalInput input, int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => InputEditorScreen(
              input: input, module: widget.module, index: index)),
    );
    setState(() {});
  }

  Future<void> _holdInput(DeviceModule module, int index, bool held) =>
      ModuleStatusService.shared.setVirtualInputState(module.id, index, held);

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the app-wide store changes: live output/input state
    // arrives as device broadcasts (`output_state_changed`/`input_state_changed`)
    // and flows into the module via ModuleStatusService - no get_device_state
    // polling needed.
    return ListenableBuilder(
      listenable: ModuleStore.shared,
      builder: (context, _) {
        final module =
            ModuleStore.shared.byId(widget.module.id) ?? widget.module;
        final l10n = AppLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(module.name),
            actions: [
              IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: l10n.refreshTooltip,
                  onPressed: _refresh),
              IconButton(
                  icon: const Icon(Icons.receipt_long_outlined),
                  tooltip: l10n.systemLogTooltip,
                  onPressed: () => showSystemLogScreen(context, module)),
              IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _editModuleInfo)
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.outerPadding),
              children: [
                ModuleStatusHeader(module: module),
                const SizedBox(height: 24),
                SectionHeader(l10n.blindHeader),
                for (final channel in module.channels)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                    child: _BlindCard(
                      channel: channel,
                      motion: _motionOf(channel),
                      onUp: () => _press(channel, _Motion.up),
                      onDown: () => _press(channel, _Motion.down),
                    ),
                  ),
                if (module.inputs.any((i) => i.enabled)) ...[
                  const SizedBox(height: 24),
                  SectionHeader(l10n.moduleInputs(module.inputs.length)),
                  for (int i = 0; i < module.inputs.length; i++)
                    if (module.inputs[i].enabled)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppSpacing.betweenCards),
                        child: InputFieldCard(
                          input: module.inputs[i],
                          onHoldChanged: (held) => _holdInput(module, i, held),
                          onReleased: _refresh,
                          onEdit: () => _editInput(module.inputs[i], i),
                        ),
                      ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BlindCard extends StatelessWidget {
  const _BlindCard(
      {required this.channel,
      required this.motion,
      required this.onUp,
      required this.onDown});

  final ChannelOutput channel;
  final _Motion motion;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    final String status = switch (motion) {
      _Motion.up => l10n.blindMovingUp,
      _Motion.down => l10n.blindMovingDown,
      _Motion.idle => l10n.blindStopped,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconAvatar(icon: channel.icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(channel.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                Text(
                  status,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: motion == _Motion.idle
                        ? onSurface.withValues(alpha: 0.55)
                        : onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _DirectionButton(
                    active: motion == _Motion.up,
                    icon: Icons.keyboard_arrow_up,
                    idleLabel: l10n.blindUp,
                    onPressed: onUp,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DirectionButton(
                    active: motion == _Motion.down,
                    icon: Icons.keyboard_arrow_down,
                    idleLabel: l10n.blindDown,
                    onPressed: onDown,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A large directional button whose label/icon flips to "STOP" while its
/// direction is active, making the toggle-stop interaction unambiguous.
class _DirectionButton extends StatelessWidget {
  const _DirectionButton({
    required this.active,
    required this.icon,
    required this.idleLabel,
    required this.onPressed,
  });

  final bool active;
  final IconData icon;
  final String idleLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(active ? Icons.stop_circle_outlined : icon),
        const SizedBox(width: 8),
        Text(active ? l10n.blindStop : idleLabel,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
    return SizedBox(
      height: 56,
      child: active
          ? FilledButton(onPressed: onPressed, child: content)
          : OutlinedButton(onPressed: onPressed, child: content),
    );
  }
}
