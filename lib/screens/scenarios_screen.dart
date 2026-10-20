// lib/screens/scenarios_screen.dart
//
// Brief section 2.4 "Automations and Scenarios (Scenes)": the list of
// tap-to-run scenarios (and the manual dimming slider), with quick access
// to Automations, Rooms and the Event History.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/scenario_runner.dart';
import '../services/scenario_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'manual_dimming_slider_screen.dart';
import 'scenario_editor_screen.dart';

class ScenariosScreen extends StatelessWidget {
  const ScenariosScreen({super.key});

  static final ScenarioStore _store = ScenarioStore.shared;

  Future<void> _runScenario(BuildContext context, Scenario scenario) async {
    if (scenario.type == ScenarioType.manualSlider) {
      EventLogStore.shared.recordScenario(scenarioName: scenario.name);
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ManualDimmingSliderScreen(scenario: scenario)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            AppLocalizations.of(context).homeRunningScenario(scenario.name))));
    final result = await ScenarioRunner.shared.run(scenario);
    await EventLogStore.shared.recordScenarioResult(result);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.failed == 0
            ? '${scenario.name} completed'
            : '${scenario.name}: ${result.failed} action(s) failed')));
  }

  Future<void> _createScenario(BuildContext context) async {
    final Scenario? created = await Navigator.of(context).push<Scenario>(
      MaterialPageRoute(builder: (_) => const ScenarioEditorScreen()),
    );
    if (created != null) await _store.upsert(created);
  }

  Future<void> _editScenario(BuildContext context, Scenario scenario) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ScenarioEditorScreen(scenario: scenario)),
    );
    await _store.commit();
  }

  Future<void> _deleteScenario(BuildContext context, Scenario scenario) async {
    final confirmed = await showConfirmDialog(
      context,
      title: AppLocalizations.of(context).scenariosDeleteDialog,
      message: AppLocalizations.of(context).scenariosDeleteMsg(scenario.name),
      confirmLabel: AppLocalizations.of(context).delete,
    );
    if (confirmed) await _store.remove(scenario.id);
  }

  Future<void> _setShowInHome(Scenario scenario, bool value) async {
    scenario.showInHome = value;
    await _store.commit();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final scenarios = _store.scenarios;
        final l10n = AppLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.scenariosTitle),
            actions: [
              IconButton(
                tooltip: l10n.scenariosRooms,
                icon: const Icon(Icons.meeting_room_outlined),
                onPressed: () =>
                    Navigator.of(context).restorablePushNamed('/rooms'),
              ),
              IconButton(
                tooltip: l10n.scenariosAutomations,
                icon: const Icon(Icons.rule_outlined),
                onPressed: () =>
                    Navigator.of(context).restorablePushNamed('/automations'),
              ),
              // IconButton(
              //   tooltip: l10n.scenariosEventHistory,
              //   icon: const Icon(Icons.history),
              //   onPressed: () =>
              //       Navigator.of(context).restorablePushNamed('/event-history'),
              // ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: scenarios.isEmpty
                ? Center(
                    child: EmptyState(
                      icon: Icons.auto_awesome_outlined,
                      message: l10n.scenariosEmpty,
                    ),
                  )
                : ReorderableListView.builder(
                    padding: EdgeInsets.only(
                      left: AppSpacing.outerPadding,
                      right: AppSpacing.outerPadding,
                      top: AppSpacing.outerPadding,
                      bottom: AppSpacing.outerPadding + 80.0,
                    ),
                    itemCount: scenarios.length,
                    buildDefaultDragHandles: false,
                    onReorderItem: _store.reorder,
                    itemBuilder: (context, index) {
                      final scenario = scenarios[index];
                      return Padding(
                        key: ValueKey(scenario.id),
                        padding: const EdgeInsets.only(
                            bottom: AppSpacing.betweenCards),
                        child: _ScenarioCard(
                          scenario: scenario,
                          index: index,
                          onRun: () => _runScenario(context, scenario),
                          onEdit: () => _editScenario(context, scenario),
                          onDelete: () => _deleteScenario(context, scenario),
                          onShowInHomeChanged: (v) =>
                              _setShowInHome(scenario, v),
                        ),
                      );
                    },
                  ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            heroTag: null,
            onPressed: () => _createScenario(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.scenariosNew, style: AppTheme.fabLabelStyle),
          ),
        );
      },
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.index,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
    required this.onShowInHomeChanged,
  });

  final Scenario scenario;
  final int index;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onShowInHomeChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final bool isSlider = scenario.type == ScenarioType.manualSlider;

    // A scenario can carry a custom background color: then the whole card is
    // painted with it and the foreground flips to black/white for contrast.
    final Color? bg = scenario.backgroundColor;
    final bool hasBg = bg != null;
    final Color fg = hasBg
        ? (ThemeData.estimateBrightnessForColor(bg) == Brightness.light
            ? Colors.black87
            : Colors.white)
        : cs.onSurface;
    final Color fgMuted = fg.withValues(alpha: 0.55);

    return Card(
      color: bg,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child:
                          Icon(Icons.drag_indicator, color: fgMuted, size: 22),
                    ),
                  ),
                  IconAvatar(icon: scenario.icon),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(scenario.name,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                color: fg)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            RoomTag(label: scenario.roomName, fg: fg),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                isSlider
                                    ? l10n.homeManualDimmingSlider
                                    : l10n.homeActionsCount(
                                        scenario.actions.length),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: fgMuted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.outlined(
                      onPressed: onRun,
                      icon: Icon(
                          isSlider ? Icons.open_in_full : Icons.play_arrow)),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
                    ],
                  ),
                ],
              ),
              Divider(height: 20, color: fg.withValues(alpha: 0.15)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.showOnHome,
                      style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
                  Switch(
                      value: scenario.showInHome,
                      onChanged: onShowInHomeChanged),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
