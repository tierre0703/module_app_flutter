// lib/screens/channel_editor_screen.dart
//
// Brief section 2.2 "Customization": rename an output, associate a simple
// icon with it and pick the state it settles in after the module restarts
// (ON / OFF / Last State). An output is always shown and controllable - there
// is no enable/disable. Saving applies the change locally and pushes it to the
// module with `set_output_configuration` (Control API spec §4.9).
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../data/mock_data.dart';
import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class ChannelEditorScreen extends StatefulWidget {
  const ChannelEditorScreen({
    super.key,
    required this.channel,
    required this.module,
    required this.index,
  });

  final ChannelOutput channel;
  final DeviceModule module;

  /// Index of the output within [module.channels]; used as the channel index
  /// for `set_output_configuration`.
  final int index;

  @override
  State<ChannelEditorScreen> createState() => _ChannelEditorScreenState();
}

class _ChannelEditorScreenState extends State<ChannelEditorScreen> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.channel.name);
  late IconData _selectedIcon = widget.channel.icon;
  late OutputInitialState _initialState = widget.channel.initialState;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final trimmed = _nameController.text.trim();
    // Apply to the shared channel instance, then push the config to the device.
    widget.channel.name = trimmed.isEmpty ? widget.channel.name : trimmed;
    widget.channel.icon = _selectedIcon;
    widget.channel.initialState = _initialState;

    await ModuleStore.shared.update(widget.module.id, (_) {});
    await ModuleStatusService.shared.updateOutputConfiguration(
      widget.module.id,
      widget.index,
      name: widget.channel.name,
      initialState: widget.channel.initialState,
    );

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.channel.name),
        actions: [
          IconButton(
            tooltip: l10n.save,
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            Text(widget.module.name,
                style: TextStyle(color: onSurface.withValues(alpha: 0.55))),
            const SizedBox(height: 16),
            Center(
                child: IconAvatar(icon: _selectedIcon, size: 72, filled: true)),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                  labelText: l10n.channelNameLabel,
                  prefixIcon: const Icon(Icons.label_outline)),
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.channelChooseIcon),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final icon in kChannelIconChoices)
                  InkWell(
                    borderRadius: BorderRadius.circular(28),
                    onTap: () => setState(() => _selectedIcon = icon),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: icon == _selectedIcon
                            ? onSurface
                            : Colors.transparent,
                        border: Border.all(
                            color: onSurface.withValues(
                                alpha: icon == _selectedIcon ? 0 : 0.25)),
                      ),
                      child: Icon(icon,
                          color: icon == _selectedIcon
                              ? Theme.of(context).colorScheme.surface
                              : onSurface),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.channelEditorInitialState),
            Card(
              child: RadioGroup<OutputInitialState>(
                groupValue: _initialState,
                onChanged: (value) =>
                    setState(() => _initialState = value ?? _initialState),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<OutputInitialState>(
                      value: OutputInitialState.on,
                      title: Text(l10n.on,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(l10n.channelEditorInitialOnHint),
                    ),
                    const Divider(height: 1),
                    RadioListTile<OutputInitialState>(
                      value: OutputInitialState.off,
                      title: Text(l10n.off,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(l10n.channelEditorInitialOffHint),
                    ),
                    const Divider(height: 1),
                    RadioListTile<OutputInitialState>(
                      value: OutputInitialState.lastState,
                      title: Text(l10n.channelEditorInitialLastState,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(l10n.channelEditorInitialLastStateHint),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(onPressed: _save, child: Text(l10n.save)),
          ],
        ),
      ),
    );
  }
}
