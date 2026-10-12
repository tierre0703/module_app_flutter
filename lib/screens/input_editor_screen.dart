// lib/screens/input_editor_screen.dart
//
// Input configuration page opened when an input field on a module screen is
// tapped. Edits the input's display name, behaviour/mode (momentary |
// maintained | pulse) and whether it is shown on the module screen. Saving the
// changes pushes them to the module with `set_input_configuration`
// (Control API spec §3.3) and persists the local copy.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class InputEditorScreen extends StatefulWidget {
  const InputEditorScreen({
    super.key,
    required this.input,
    required this.module,
    required this.index,
  });

  final PhysicalInput input;
  final DeviceModule module;

  /// Index of the input within [module.inputs]; used as the channel index for
  /// `set_input_configuration`.
  final int index;

  @override
  State<InputEditorScreen> createState() => _InputEditorScreenState();
}

class _InputEditorScreenState extends State<InputEditorScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.input.name);
  late InputMode _mode = widget.input.mode;
  late bool _enabled = widget.input.enabled;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).inputEditorName)),
      );
      return;
    }

    // Apply to the shared module instance, then push the config to the device.
    await ModuleStore.shared.update(widget.module.id, (m) {
      final input = widget.input;
      input.name = name;
      input.mode = _mode;
      input.enabled = _enabled;
    });

    // `set_input_configuration` with channel + name + enabled (+ mode).
    await ModuleStatusService.shared.updateInputConfiguration(
      widget.module.id,
      widget.index,
      name: name,
      enabled: _enabled,
      mode: _mode,
    );

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.input.name)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            Text(
              l10n.inputEditorOnModule(widget.module.name),
              style: TextStyle(color: onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.inputEditorName,
                prefixIcon: const Icon(Icons.edit_outlined),
              ),
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.inputEditorBehavior),
            Card(
              child: RadioGroup<InputMode>(
                groupValue: _mode,
                onChanged: (value) => setState(() => _mode = value ?? _mode),
                child: Column(
                  children: [
                    for (int i = 0; i < InputMode.values.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      RadioListTile<InputMode>(
                        value: InputMode.values[i],
                        title: Text(InputMode.values[i].label,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(InputMode.values[i].description),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.inputEditorBehaviorHint,
                style: TextStyle(
                    fontSize: 12, color: onSurface.withValues(alpha: 0.55)),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: SwitchListTile(
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
                title: Text(l10n.inputEditorEnabled,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(l10n.inputEditorEnabledHint),
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
