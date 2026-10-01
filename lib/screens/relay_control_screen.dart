// lib/screens/relay_control_screen.dart
//
// Brief section 2.3 "Standard Relay Modules": ON/OFF control for every
// output, plus (brief section 2.2) naming/icon customization and physical
// switch input configuration.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/system_log_screen.dart';
import 'channel_editor_screen.dart';
import 'input_editor_screen.dart';

class RelayControlScreen extends StatefulWidget {
  const RelayControlScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<RelayControlScreen> createState() => _RelayControlScreenState();
}

class _RelayControlScreenState extends State<RelayControlScreen> {
  @override
  void initState() {
    super.initState();
    // Pull a fresh status dump (output/input states + names) when the screen
    // opens, so device-side changes made outside the app show immediately.
    _refresh();
  }

  Future<void> _editChannel(ChannelOutput channel, int index) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => ChannelEditorScreen(
              channel: channel, module: widget.module, index: index)),
    );
    if (saved == true) {
      // Persist the renamed output so the user-defined name survives restarts.
      await ModuleStore.shared.update(widget.module.id, (_) {});
    }
    setState(() {});
  }

  Future<void> _editInput(PhysicalInput input, int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => InputEditorScreen(
              input: input, module: widget.module, index: index)),
    );
    setState(() {});
  }

  /// Drives the input's virtual input: sending `true` on touch start and
  /// `false` on touch end (set_virtual_input_state). Results in no state
  /// change when the module is offline.
  Future<void> _holdInput(DeviceModule module, int index, bool held) =>
      ModuleStatusService.shared.setVirtualInputState(module.id, index, held);

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

  /// Sends the ON/OFF relay command to the module through whichever transport
  /// is active (Soleux JSON unit or legacy AT+ unit), then re-asks for the
  /// actual output states. The parsed response flows through the service into
  /// the store, which rebuilds this screen to reflect the module-reported
  /// state.
  Future<void> _toggleOutput(DeviceModule module, int index, bool next) async {
    EventLogStore.shared.recordModuleAction(
      moduleName: module.name,
      outputName: module.channels[index].name,
      on: next,
    );
    final service = ModuleStatusService.shared;
    try {
      final ok = next
          ? await service.turnOnOutput(module.id, index)
          : await service.turnOffOutput(module.id, index);
      if (!ok) {
        // No live unit for this module - fall back to a local toggle.
        setState(() => module.channels[index].isOn = next);
      }
    } catch (e, st) {
      debugPrint('RelayControlScreen: toggle output failed: $e\n$st');
      // Command failed or module offline - keep the UI showing reality.
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

  @override
  Widget build(BuildContext context) {
    // Present the live instance from the app-wide store (status refreshed on
    // open) while keeping the tapped module (which owns the editor callbacks).
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
                  tooltip: l10n.relayRefreshTooltip,
                  onPressed: _refresh),
              IconButton(
                  icon: const Icon(Icons.receipt_long_outlined),
                  tooltip: l10n.systemLogTooltip,
                  onPressed: () => showSystemLogScreen(context, module)),
              IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _editModuleInfo),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.outerPadding),
              children: [
                ModuleStatusHeader(module: module),
                const SizedBox(height: 24),
                SectionHeader(l10n.relayOutputsHeader(module.channels.length)),
                for (int i = 0; i < module.channels.length; i++)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                    child: _OutputRow(
                      channel: module.channels[i],
                      index: i,
                      onToggle: () =>
                          _toggleOutput(module, i, !module.channels[i].isOn),
                      onEdit: () => _editChannel(module.channels[i], i),
                    ),
                  ),
                if (module.inputs.isNotEmpty) ...[
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

class _OutputRow extends StatelessWidget {
  const _OutputRow(
      {required this.channel,
      required this.index,
      required this.onToggle,
      required this.onEdit});

  final ChannelOutput channel;
  final int index;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconAvatar(icon: channel.icon, filled: channel.isOn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(channel.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(l10n.relayOutput(index + 1),
                      style: TextStyle(
                          fontSize: 12,
                          color: onSurface.withValues(alpha: 0.5))),
                ],
              ),
            ),
            SizedBox(
              width: 88,
              height: 48,
              child: channel.isOn
                  ? FilledButton(onPressed: onToggle, child: Text(l10n.on))
                  : OutlinedButton(onPressed: onToggle, child: Text(l10n.off)),
            ),
            IconButton(
                icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
          ],
        ),
      ),
    );
  }
}
