// lib/widgets/common_widgets.dart
//
// Small reusable UI building blocks shared by several screens, kept in one
// file to avoid duplicating the same layout code across the prototype.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';

/// Small green/amber/red dot used everywhere a module's connectivity status is
/// shown (online = green, suspect = amber, offline = red).
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 10});

  final ConnectionStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConnectionStatus.online => AppColors.online,
      ConnectionStatus.suspect => AppColors.suspect,
      ConnectionStatus.offline => AppColors.offlineAlert,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// A full width, high-visibility banner used for the offline-module alert
/// and the temperature-threshold alert (brief section I, points 2 and 3
/// call for the *same* prominent red banner treatment for both).
class AlertBanner extends StatelessWidget {
  const AlertBanner({
    super.key,
    required this.message,
    required this.onTap,
    this.icon = Icons.warning_amber_rounded,
  });

  final String message;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.offlineAlert,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// A left-aligned section title with optional trailing action, used to
/// break every screen into clearly labelled groups.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Circular icon avatar used for channel/scenario icons, with a subtle
/// outlined high-contrast style consistent across the app.
class IconAvatar extends StatelessWidget {
  const IconAvatar(
      {super.key, required this.icon, this.size = 44, this.filled = false});

  final IconData icon;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color fg = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? fg : Colors.transparent,
        border: Border.all(color: fg.withValues(alpha: filled ? 0 : 0.25)),
      ),
      child: Icon(icon,
          color: filled ? Theme.of(context).colorScheme.surface : fg,
          size: size * 0.5),
    );
  }
}

/// Placeholder shown when a list has no items yet.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final Color fg =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(icon, size: 40, color: fg),
          const SizedBox(height: 12),
          Text(message,
              style: TextStyle(color: fg), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// A round chip-like tag used to show a room name on scenario/module cards.
class RoomTag extends StatelessWidget {
  const RoomTag({super.key, required this.label, this.fg});

  final String label;

  /// Overrides the theme foreground (e.g. for colored scenario cards).
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final Color base = fg ?? Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: base.withValues(alpha: 0.12),
        border: Border.all(color: base.withValues(alpha: 0.25)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: base.withValues(alpha: 0.75))),
    );
  }
}

/// Confirmation dialog helper (used for destructive actions like removing a
/// module or deleting a room).
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = true,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.offlineAlert,
                  foregroundColor: Colors.white)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Simple text-input dialog helper (used for renaming modules/rooms).
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String hint = '',
  String confirmLabel = 'Save',
}) async {
  final controller = TextEditingController(text: initialValue);
  final String? result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.pop(context);
            },
            child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context, controller.text.trim());
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return (result == null || result.isEmpty) ? null : result;
}

/// Dialog editing a module's identity (name, IP address, TCP port) in place.
/// Returns true when the user saved; the passed [module] is updated directly.
Future<bool> showEditModuleInfoDialog(
    BuildContext context, DeviceModule module) async {
  final result = await showDialog<ModuleInfoResult>(
    context: context,
    builder: (_) => _ModuleInfoDialog(module: module),
  );

  if (result?.saved == true) {
    if (result!.name.isNotEmpty) module.name = result.name;
    if (result.ip.isNotEmpty) module.ipAddress = result.ip;
    if (result.type != null) module.type = result.type!;
    if (result.connectionType != null) {
      module.connectionType = result.connectionType;
    }
    final port = result.port;
    if (port != null) module.tcpPort = port;
    final tempThreshold = result.tempThreshold;
    if (tempThreshold != null && tempThreshold > 0) {
      module.tempMaxC = tempThreshold.clamp(0, 100);
    }
  }
  return result?.saved == true;
}

/// Result payload collected once the dialog is fully closed, so the
/// controllers only live (and are disposed) inside the dialog's own State.
class ModuleInfoResult {
  const ModuleInfoResult({
    required this.saved,
    required this.name,
    required this.ip,
    this.type,
    this.connectionType,
    this.port,
    this.tempThreshold,
  });

  final bool saved;
  final String name;
  final String ip;
  final ModuleType? type;
  final String? connectionType;
  final int? port;
  final double? tempThreshold;
}

class _ModuleInfoDialog extends StatefulWidget {
  const _ModuleInfoDialog({required this.module});

  final DeviceModule module;

  @override
  State<_ModuleInfoDialog> createState() => _ModuleInfoDialogState();
}

class _ModuleInfoDialogState extends State<_ModuleInfoDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _ipController;
  late final TextEditingController _portController;
  late final TextEditingController _tempController;
  late ModuleType _type;
  late String? _connectionType;

  @override
  void initState() {
    super.initState();
    final m = widget.module;
    _nameController = TextEditingController(text: m.name);
    _ipController = TextEditingController(text: m.ipAddress);
    _type = m.type;
    // The retired pre-migration default 5005 is presented as the current
    // 5008 command HostPort.
    final port = m.tcpPort == 5005 ? '5008' : m.tcpPort.toString();
    _portController = TextEditingController(text: port);
    _tempController =
        TextEditingController(text: m.tempMaxC.toStringAsFixed(0));
    _connectionType =
        const {'local_network', 'remote', 'cloud'}.contains(m.connectionType)
            ? m.connectionType
            : 'local_network';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _tempController.dispose();
    super.dispose();
  }

  void _submit(bool saved) {
    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      saved
          ? ModuleInfoResult(
              saved: true,
              name: _nameController.text.trim(),
              ip: _ipController.text.trim(),
              type: _type,
              connectionType: _connectionType,
              port: int.tryParse(_portController.text.trim()),
              tempThreshold: double.tryParse(_tempController.text.trim()),
            )
          : const ModuleInfoResult(saved: false, name: '', ip: ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.moduleInfoTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).moduleName,
                  prefixIcon: const Icon(Icons.edit_outlined)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ModuleType>(
              initialValue: _type,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).addModuleType,
                  prefixIcon: const Icon(Icons.category_outlined)),
              items: [
                for (final type in ModuleType.values)
                  DropdownMenuItem(
                    value: type,
                    child: Text(
                      type.label,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _type = value ?? _type),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _connectionType,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).connectionType,
                  prefixIcon: const Icon(Icons.public_outlined)),
              items: [
                DropdownMenuItem(
                  value: 'local_network',
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      AppLocalizations.of(context).connectionLocalNetwork,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'remote',
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      AppLocalizations.of(context).connectionRemote,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'cloud',
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      AppLocalizations.of(context).connectionCloud,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => _connectionType = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipController,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).ipAddress,
                  prefixIcon: const Icon(Icons.lan_outlined)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).tcpPort,
                  prefixIcon: const Icon(Icons.router_outlined)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tempController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).tempThresholdLabel,
                  prefixIcon: const Icon(Icons.thermostat_outlined)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => _submit(false),
            child: Text(AppLocalizations.of(context).cancel)),
        FilledButton(
          onPressed: () => _submit(true),
          child: Text(AppLocalizations.of(context).save),
        ),
      ],
    );
  }
}

/// Compact status header (online/offline + IP/room + internal temperature)
/// reused at the top of every module detail / control screen.
class ModuleStatusHeader extends StatelessWidget {
  const ModuleStatusHeader({super.key, required this.module});

  final DeviceModule module;

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    final tempAlert = module.isOverTemperature;
    final (label, color) = switch (module.status) {
      ConnectionStatus.online => (l10n.online, AppColors.online),
      ConnectionStatus.suspect => (l10n.suspect, AppColors.suspect),
      ConnectionStatus.offline => (l10n.offline, AppColors.offlineAlert),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            StatusDot(status: module.status, size: 14),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontWeight: FontWeight.w800, color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${module.ipAddress} · ${module.roomName}',
                    style: TextStyle(
                        fontSize: 12, color: onSurface.withValues(alpha: 0.55)),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(Icons.thermostat,
                    size: 20,
                    color: tempAlert
                        ? AppColors.offlineAlert
                        : onSurface.withValues(alpha: 0.6)),
                Text(
                  '${module.internalTempC.toStringAsFixed(1)}°C',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tempAlert ? AppColors.offlineAlert : onSurface),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single dimmer channel: name/icon, brightness readout, quick 0%/100%
/// shortcuts and a slider - shared by the DC and AC dimmer screens (brief
/// section 2.3).
///
/// In addition to the drag-based [onChanged]/[onChangeEnd] pair, the card can
/// be wired to the Control API: tapping the icon toggles the output
/// ([onToggle] -> `toggle_dimmer`), the low shortcut fires [onTurnOff]
/// (`set_output_state` `state: false`) and the high shortcut fires [onTurnOn]
/// (`set_output_state` `state: true`). When a shortcut callback is omitted it
/// falls back to the escalated [onChanged] + [onChangeEnd] pair so the card
/// still works without a Control API unit.
class DimmerChannelCard extends StatelessWidget {
  const DimmerChannelCard({
    super.key,
    required this.channel,
    required this.onChanged,
    required this.onEdit,
    this.onChangeEnd,
    this.onToggle,
    this.onTurnOn,
    this.onTurnOff,
  });

  final ChannelOutput channel;
  final ValueChanged<int> onChanged;
  final VoidCallback onEdit;

  /// Invoked once when a drag gesture ends, carrying the settled brightness.
  final ValueChanged<int>? onChangeEnd;

  /// Tapping the channel icon. Used to `toggle_dimmer` (Control API §4.4).
  final VoidCallback? onToggle;

  /// Turning the output on (`set_output_state` `state: true`). Invoked by the
  /// full-brightness shortcut when provided.
  final VoidCallback? onTurnOn;

  /// Turning the output off (`set_output_state` `state: false`). Invoked by the
  /// low shortcut when provided.
  final VoidCallback? onTurnOff;

  @override
  Widget build(BuildContext context) {
    // The logical output state comes from the device broadcast
    // (`output_state_changed`), which may differ from the retained brightness
    // (a dimmer can be OFF while remembering its level). The filled icon
    // therefore follows [ChannelOutput.isOn]; the slider/readout keep showing
    // the brightness.
    final bool isOn = channel.isOn;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: onToggle,
                  child: IconAvatar(icon: channel.icon, filled: isOn),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(channel.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                Text('${channel.brightness}%',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
                IconButton(
                    icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
              ],
            ),
            Row(
              children: [
                IconButton(
                  tooltip: AppLocalizations.of(context).cwTurnOff,
                  icon: const Icon(Icons.brightness_low),
                  onPressed: () {
                    if (onTurnOff != null) {
                      onTurnOff!();
                    } else {
                      onChanged(0);
                      onChangeEnd?.call(0);
                    }
                  },
                ),
                Expanded(
                  child: Slider(
                    value: channel.brightness.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: channel.brightnessSliderDivisions,
                    label: '${channel.brightness}%',
                    onChanged: (v) =>
                        onChanged(channel.snapBrightness(v.round())),
                    onChangeEnd: (v) =>
                        onChangeEnd?.call(channel.snapBrightness(v.round())),
                  ),
                ),
                IconButton(
                  tooltip: AppLocalizations.of(context).cwTurnOn,
                  icon: const Icon(Icons.brightness_high),
                  onPressed: () {
                    if (onTurnOn != null) {
                      onTurnOn!();
                    } else {
                      onChanged(100);
                      onChangeEnd?.call(100);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single input field on a module screen. Tapping the card opens the input
/// configuration page ([onEdit]); the action button drives the associated
/// virtual input (`set_virtual_input_state`): each press sends `true`, waits
/// 100 ms, then sends `false`.
///
/// A press is ignored while a previous press's `false` command is still
/// awaiting its response, so rapid repeats never pile up on the transport.
/// After the `false` response arrives, [onReleased] fires so the caller can
/// re-fetch module info and refresh the input/output state shown on screen.
class InputFieldCard extends StatefulWidget {
  const InputFieldCard({
    super.key,
    required this.input,
    required this.onHoldChanged,
    required this.onEdit,
    this.onReleased,
  });

  final PhysicalInput input;
  final Future<void> Function(bool) onHoldChanged;
  final VoidCallback onEdit;
  final VoidCallback? onReleased;

  @override
  State<InputFieldCard> createState() => _InputFieldCardState();
}

class _InputFieldCardState extends State<InputFieldCard> {
  static const int _pressDelayMs = 100;

  bool _busy = false;

  /// Fires a single press action: drives the virtual input `true`, waits
  /// [_pressDelayMs], then drives it `false`. The button stays locked
  /// ([_busy]) until the `false` command's response arrives, so the next
  /// press is ignored while one is still in flight.
  Future<void> _fire() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onHoldChanged(true);
    await Future<void>.delayed(const Duration(milliseconds: _pressDelayMs));
    await widget.onHoldChanged(false);
    setState(() => _busy = false);
    widget.onReleased?.call();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: widget.onEdit,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.toggle_on_outlined,
                        size: 28,
                        color: widget.input.state
                            ? scheme.primary
                            : onSurface.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                Flexible(
                                  child: Text(widget.input.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16),
                                      overflow: TextOverflow.ellipsis),
                                ),
                                if (widget.input.state) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6),
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: Text(
                                      'ON',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: scheme.onPrimary),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.input.mode.label,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: onSurface.withValues(alpha: 0.55)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _fire(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _busy ? scheme.primary : scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.play_arrow,
                  size: 28,
                  color: _busy ? scheme.onPrimary : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats a [DateTime] as a short relative-ish timestamp for log lists.
String formatLogTimestamp(DateTime time, AppLocalizations l10n) {
  final Duration diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return l10n.cwJustNow;
  if (diff.inMinutes < 60) return l10n.cwMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.cwHoursAgo(diff.inHours);
  if (diff.inDays < 30) return l10n.cwDaysAgo(diff.inDays);
  return '${time.day}/${time.month}/${time.year}';
}
