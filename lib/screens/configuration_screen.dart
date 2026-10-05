// lib/screens/configuration_screen.dart
//
// Brief section 2.1 "Adding and Managing Modules": the device list shows
// every added module with an online/offline indicator, and lets the user
// add new ones (via the self-discovery / manual-IP flow on AddModuleScreen).
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/module_status/module_status_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'add_module_screen.dart';
import 'blind_control_screen.dart';
import 'dimmer_ac_screen.dart';
import 'dimmer_dc_screen.dart';
import 'relay_control_screen.dart';
import 'temperature_module_screen.dart';

/// Pushes the correct dedicated control screen for [module]'s type (brief
/// section 2.3 "Extended Control Types"). Shared by the Configuration list
/// and the Home temperature cards so both link to the same detail UI.
void openModuleDetail(BuildContext context, DeviceModule module) {
  final Widget screen = switch (module.type) {
    ModuleType.relay => RelayControlScreen(module: module),
    ModuleType.blind => BlindControlScreen(module: module),
    ModuleType.dimmerDc => DimmerDcScreen(module: module),
    ModuleType.dimmerAc => DimmerAcScreen(module: module),
    ModuleType.temperature => TemperatureModuleScreen(module: module),
  };
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
}

class ConfigurationScreen extends StatefulWidget {
  const ConfigurationScreen({super.key});

  @override
  State<ConfigurationScreen> createState() => _ConfigurationScreenState();
}

class _ConfigurationScreenState extends State<ConfigurationScreen> {
  ModuleStore get _store => ModuleStore.shared;

  @override
  void initState() {
    super.initState();
    _store.init();
  }

  Future<void> _addModule() async {
    final DeviceModule? added = await Navigator.of(context).push<DeviceModule>(
      MaterialPageRoute(builder: (_) => const AddModuleScreen()),
    );
    if (added != null) {
      await _store.upsert(added);
      // Probe the new module now so its real status is reflected in the list
      // and on the Home screen immediately. Every addition starts unverified
      // (offline) until the probe/heartbeat confirms it reachable.
      await ModuleStatusService.shared.refreshOne(added);
    }
  }

  Future<void> _renameModule(DeviceModule module) async {
    final String? newName = await showTextInputDialog(
      context,
      title: AppLocalizations.of(context).configRenameDialog,
      initialValue: module.name,
    );
    if (newName == null) return;
    await _store.update(module.id, (m) => m.name = newName);
    // Re-fetch the module's live status after editing it.
    await ModuleStatusService.shared.refreshOne(module);
  }

  Future<void> _removeModule(DeviceModule module) async {
    final bool confirmed = await showConfirmDialog(
      context,
      title: AppLocalizations.of(context).configRemoveDialog,
      message: AppLocalizations.of(context).configRemoveMsg(module.name),
      confirmLabel: AppLocalizations.of(context).remove,
    );
    if (!confirmed) return;
    await _store.remove(module.id);
    // Drop the module's persistent connection so it stops reconnecting and the
    // fleet/status counts update to exactly the remaining modules.
    ModuleStatusService.shared.removeModule(module.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.configTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: l10n.configAddTooltip,
            onPressed: _addModule,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final modules = _store.modules;
            if (!_store.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            if (modules.isEmpty) {
              return const Center(child: Text('No modules added yet'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.outerPadding),
              itemCount: modules.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.betweenCards),
              itemBuilder: (context, index) {
                final module = modules[index];
                return _ModuleCard(
                  module: module,
                  onTap: () => openModuleDetail(context, module),
                  onRename: () => _renameModule(module),
                  onRemove: () => _removeModule(module),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _addModule,
        icon: const Icon(Icons.add),
        label: Text(l10n.configAddTooltip, style: AppTheme.fabLabelStyle),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.onTap,
    required this.onRename,
    required this.onRemove,
  });

  final DeviceModule module;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    final status = module.status;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconAvatar(icon: module.type.icon),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          shape: BoxShape.circle),
                      child: StatusDot(status: status),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(module.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(
                        l10n.configModuleSummary(
                            module.type.label, module.ipAddress),
                        style: TextStyle(
                            fontSize: 12,
                            color: onSurface.withValues(alpha: 0.55))),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        RoomTag(label: module.roomName),
                        const SizedBox(width: 8),
                        Text(
                          switch (status) {
                            ConnectionStatus.online => l10n.online,
                            ConnectionStatus.suspect => l10n.suspect,
                            ConnectionStatus.offline => l10n.offline,
                          },
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: switch (status) {
                              ConnectionStatus.online => AppColors.online,
                              ConnectionStatus.suspect => AppColors.suspect,
                              ConnectionStatus.offline =>
                                AppColors.offlineAlert,
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'rename') onRename();
                  if (value == 'remove') onRemove();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                      value: 'rename', child: Text(l10n.configRenameDialog)),
                  PopupMenuItem(value: 'remove', child: Text(l10n.remove)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
