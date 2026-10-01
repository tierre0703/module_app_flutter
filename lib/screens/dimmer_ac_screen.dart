// lib/screens/dimmer_ac_screen.dart
//
// Brief section 2.3 "Lighting Dimming Modules (AC)": intensity control for
// the 4 outputs of 220V AC lighting.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/dimmer_controls_section.dart';
import '../widgets/system_log_screen.dart';
import 'channel_editor_screen.dart';
import 'input_editor_screen.dart';

class DimmerAcScreen extends StatefulWidget {
  const DimmerAcScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<DimmerAcScreen> createState() => _DimmerAcScreenState();
}

class _DimmerAcScreenState extends State<DimmerAcScreen> {
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
    final module = widget.module;
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
              icon: const Icon(Icons.edit_outlined), onPressed: _editModuleInfo)
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: ModuleStore.shared,
          builder: (context, _) {
            final live =
                ModuleStore.shared.byId(widget.module.id) ?? widget.module;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.outerPadding),
              children: [
                ModuleStatusHeader(module: live),
                const SizedBox(height: 8),
                Text(
                  l10n.dimmerAcSubtitle,
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 16),
                DimmerControlsSection(
                  module: live,
                  onEditChannel: (index) =>
                      _editChannel(live.channels[index], index),
                ),
                if (live.inputs.any((i) => i.enabled)) ...[
                  const SizedBox(height: 24),
                  SectionHeader(l10n.moduleInputs(live.inputs.length)),
                  for (int i = 0; i < live.inputs.length; i++)
                    if (live.inputs[i].enabled)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppSpacing.betweenCards),
                        child: InputFieldCard(
                          input: live.inputs[i],
                          onHoldChanged: (held) => _holdInput(module, i, held),
                          onReleased: _refresh,
                          onEdit: () => _editInput(live.inputs[i], i),
                        ),
                      ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
