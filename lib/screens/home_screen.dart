// lib/screens/home_screen.dart
//
// Brief section I "Home Section":
//  1. Quick access to scenarios flagged "Show in Home", reorderable by drag
//     and drop.
//  2. A prominent red banner when a module is offline, tapping it opens the
//     Notification History page.
//  3. Real-time internal temperature monitoring per module with a similar
//     alert banner when thresholds are exceeded.
// Rooms (brief 2.5) are also surfaced here for quick access to their
// scenario groups.
//
// Visual language: styled entirely through the app theme
// (lib/theme/app_theme.dart) via Theme.of(context). Cards use the themed
// glass Card look and accents come from the active SmartHome palette, so this
// screen matches every other screen in the app. Offline/temperature semantics
// stay green/red for consistency.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/module_status/module_status_service.dart';
import '../services/scenario_runner.dart';
import '../services/module_store.dart';
import '../services/room_store.dart';
import '../services/scenario_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'configuration_screen.dart' show openModuleDetail;
import 'manual_dimming_slider_screen.dart';
import 'scenario_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The fleet is read from the app-wide [ModuleStore] so live status
  /// (online/offline, temperature) refreshed on open is reflected here.
  List<DeviceModule> get _modules => ModuleStore.shared.modules;

  /// Auto-dismiss timer for the alert banners: each newly-appearing alert
  /// (offline / over-temperature) is shown for about 5 seconds, then fades
  /// out of the screen.
  Timer? _bannerTimer;

  /// Whether the alert banners are currently visible.
  bool _bannerVisible = true;

  /// Whether an alert condition was present on the previous build, used to
  /// detect the leading edge of a new alert episode so the banner re-shows.
  bool _lastAlertsActive = false;

  @override
  void initState() {
    super.initState();
    debugPrint('HomeScreen initState: refreshing all modules...');
    // Re-probe every module whenever Home is opened so the online/offline
    // count reflects live status instead of a stale/persisted snapshot. The
    // store commits + notifies as results arrive, rebuilding this count.
    ModuleStatusService.shared.refreshAll().ignore();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  /// Detects the leading edge of an alert episode (no alert -> alert) and, on
  /// that transition, shows the banner and schedules its auto-dismiss after
  /// ~5 seconds. Called from build so it stays in sync with store updates.
  void _syncAlertBanner(bool hasAlerts) {
    final leadingEdge = hasAlerts && !_lastAlertsActive;
    _lastAlertsActive = hasAlerts;
    if (!leadingEdge) return;
    _bannerVisible = true;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _bannerVisible = false);
    });
  }

  /// Rooms order is shared with the Rooms screen via [RoomStore.shared].
  List<Room> get _rooms => RoomStore.shared.rooms;

  /// Home quick-access rooms: the "General" catch-all pinned first, then the
  /// persisted rooms in stored order. "General" holds every scenario that has
  /// no specific room assigned.
  List<Room> get _homeRooms => [
        Room(id: 'room-general', name: 'General'),
        ..._rooms,
      ];

  /// Single source of truth for scenarios lives in [ScenarioStore.shared];
  /// the Home quick-access list below is a filtered *view* over this same
  /// list of object references, so slider edits made from a Home card stay
  /// consistent with the room bottom sheet within this screen's lifetime.
  List<Scenario> get _allScenarios => ScenarioStore.shared.scenarios;

  /// Scenarios flagged "Show in Home", in global persisted order.
  List<Scenario> get _homeScenarios =>
      _allScenarios.where((s) => s.showInHome).toList();

  int get _onlineCount => _onlineModules.length;

  List<DeviceModule> get _onlineModules =>
      _modules.where((m) => m.status == ConnectionStatus.online).toList();

  List<DeviceModule> get _overTempModules =>
      _modules.where((m) => m.isOverTemperature).toList();

  /// Translates a reorder within the Home (show-in-home) filtered subset into
  /// a move in the global persisted scenario list.
  ///
  /// `newIndex` follows [ReorderableListView.onReorderItem] semantics: it is
  /// the slot (after the dragged item is removed) where it should land.
  void _onReorderHomeScenarios(int oldIndex, int newIndex) {
    final home = _homeScenarios;
    if (oldIndex >= home.length) return;
    final dragged = home[oldIndex];
    final remaining = [...home]..removeAt(oldIndex);
    final all = ScenarioStore.shared.scenarios;
    int target = all.length;
    if (newIndex < remaining.length) {
      target = all.indexOf(remaining[newIndex]);
      if (target < 0) target = all.length;
    }
    ScenarioStore.shared.move(dragged.id, target);
  }

  Future<void> _runScenario(Scenario scenario) async {
    if (scenario.type == ScenarioType.manualSlider) {
      EventLogStore.shared.recordScenario(scenarioName: scenario.name);
      Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => ManualDimmingSliderScreen(scenario: scenario)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              AppLocalizations.of(context).homeRunningScenario(scenario.name))),
    );
    final result = await ScenarioRunner.shared.run(scenario);
    await EventLogStore.shared.recordScenarioResult(result);
  }

  void _showRoomScenarios(Room room) {
    final scenarios =
        _allScenarios.where((s) => s.roomName == room.name).toList();
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _Greeting(room.name,
                        subtitle: l10n.homeScenariosCount(scenarios.length)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                    tooltip: l10n.close,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (scenarios.isEmpty)
                EmptyState(
                    icon: Icons.auto_awesome_outlined,
                    message: l10n.homeNoScenariosInRoom)
              else
                for (final s in scenarios)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: IconAvatar(icon: s.icon),
                    title: Text(s.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      s.type == ScenarioType.manualSlider
                          ? l10n.homeManualDimmingSlider
                          : l10n.homeActionsCount(s.actions.length),
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.6),
                          fontSize: 13),
                    ),
                    trailing: Icon(Icons.chevron_right,
                        color: cs.onSurface.withValues(alpha: 0.6)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _runScenario(s);
                    },
                  ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offlineModules =
        _modules.where((m) => m.status == ConnectionStatus.offline).toList();
    final overTemp = _overTempModules;
    _syncAlertBanner(offlineModules.isNotEmpty || overTemp.isNotEmpty);
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(
          [ModuleStore.shared, RoomStore.shared, ScenarioStore.shared]),
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header / deck title.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: _Greeting(
                        l10n.homeTitle,
                        subtitle: l10n.homeModulesOnline(
                            _onlineCount, _modules.length),
                      ),
                    ),
                    _StatusPill(officers: _onlineCount, total: _modules.length),
                    const SizedBox(width: 10),
                    Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(100),
                        onTap: () => Navigator.of(context)
                            .restorablePushNamed('/system-status'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          child: Icon(Icons.notifications_none,
                              color: cs.primary, size: 20),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: _bannerVisible &&
                              (offlineModules.isNotEmpty || overTemp.isNotEmpty)
                          ? Padding(
                              key: const ValueKey('alerts'),
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (offlineModules.isNotEmpty) ...[
                                    _AlertBanner(
                                      icon: Icons.wifi_off_rounded,
                                      message: offlineModules.length == 1
                                          ? l10n.homeModuleOffline(
                                              offlineModules.first.name)
                                          : l10n.homeModulesOffline(
                                              offlineModules.length),
                                      onTap: () => Navigator.of(context)
                                          .restorablePushNamed(
                                              '/system-status'),
                                    ),
                                    const SizedBox(
                                        height: AppSpacing.betweenCards),
                                  ],
                                  if (overTemp.isNotEmpty) ...[
                                    _AlertBanner(
                                      icon: Icons.thermostat,
                                      message: l10n.homeTempOutOfRange(
                                          overTemp.first.name,
                                          overTemp.first.internalTempC
                                              .toStringAsFixed(1)),
                                      onTap: () => Navigator.of(context)
                                          .restorablePushNamed(
                                              '/system-status'),
                                    ),
                                    const SizedBox(
                                        height: AppSpacing.betweenCards),
                                  ],
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 12),
                    _SectionLabel(l10n.homeSectionRooms),
                    const SizedBox(height: 10),
                    if (_homeRooms.isEmpty)
                      EmptyState(
                        icon: Icons.meeting_room_outlined,
                        message: l10n.roomsEmpty,
                      )
                    else
                      SizedBox(
                        height: 56,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _homeRooms.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final room = _homeRooms[index];
                            return _RoomChip(
                                room: room,
                                onTap: () => _showRoomScenarios(room));
                          },
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                            child:
                                _SectionLabel(l10n.homeSectionQuickScenarios)),
                        Text(
                          l10n.homeHoldDragReorder,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_homeScenarios.isEmpty)
                      EmptyState(
                        icon: Icons.auto_awesome_outlined,
                        message: l10n.homePinToHomeHint,
                      )
                    else
                      ReorderableListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        onReorderItem: _onReorderHomeScenarios,
                        children: [
                          for (int i = 0; i < _homeScenarios.length; i++)
                            Padding(
                              key: ValueKey(_homeScenarios[i].id),
                              padding: const EdgeInsets.only(
                                  bottom: AppSpacing.betweenCards),
                              child: _QuickScenarioCard(
                                index: i,
                                scenario: _homeScenarios[i],
                                onRun: () => _runScenario(_homeScenarios[i]),
                                onSliderChanged: (value) => setState(() {
                                  _homeScenarios[i].sliderValue = value;
                                  ScenarioStore.shared.commit();
                                }),
                                onOpenSlider: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            ManualDimmingSliderScreen(
                                                scenario: _homeScenarios[i])),
                                  );
                                  await ScenarioStore.shared.commit();
                                },
                                onEdit: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ScenarioEditorScreen(
                                          scenario: _homeScenarios[i]),
                                    ),
                                  );
                                  await ScenarioStore.shared.commit();
                                },
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 24),
                    _SectionLabel(l10n.homeSectionTempMonitoring),
                    const SizedBox(height: 10),
                    if (_onlineModules.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            l10n.homeTempEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.6)),
                          ),
                        ),
                      )
                    else
                      for (final module in _onlineModules)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppSpacing.betweenCards),
                          child: _TemperatureRow(
                              module: module,
                              onTap: () => openModuleDetail(context, module)),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase, wide-tracked section label (replaces AuroraSectionLabel).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
        color: cs.onSurface.withValues(alpha: 0.65),
      ),
    );
  }
}

/// Hero greeting line used as the Home screen's deck title (replaces
/// AuroraGreeting).
class _Greeting extends StatelessWidget {
  const _Greeting(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            color: cs.onSurface.withValues(alpha: 0.92),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: TextStyle(
                fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ],
    );
  }
}

/// Compact online/offline summary pill shown in the Home header.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.officers, required this.total});

  final int officers;
  final int total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool allOk = officers == total;
    return Card(
      color: cs.primary.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(100),
        side: BorderSide(
          color: allOk
              ? cs.primary.withValues(alpha: 0.4)
              : cs.error.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlowDot(color: allOk ? AppColors.online : AppColors.offlineAlert),
            const SizedBox(width: 8),
            Text(
              '$officers/$total',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: allOk ? cs.primary : cs.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small glowing status dot (green = all online, red = some offline).
class _GlowDot extends StatelessWidget {
  const _GlowDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    const double size = 8;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: 6,
              spreadRadius: 1)
        ],
      ),
    );
  }
}

/// Red alert banner (offline / over-temperature) that opens Notification
/// History on tap -- the same prominent treatment for both alerts.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner(
      {required this.icon, required this.message, required this.onTap});

  final IconData icon;
  final String message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.error.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.error.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: cs.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                      color: cs.error,
                      fontWeight: FontWeight.w700,
                      fontSize: 14),
                ),
              ),
              Icon(Icons.chevron_right, color: cs.error),
            ],
          ),
        ),
      ),
    );
  }
}

/// A touch-sized glass chip for each room's quick access (>=48dp tall).
class _RoomChip extends StatelessWidget {
  const _RoomChip({required this.room, required this.onTap});

  final Room room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.meeting_room_outlined, color: cs.primary, size: 20),
              const SizedBox(width: 10),
              Text(
                room.name,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  color: cs.onSurface.withValues(alpha: 0.6), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickScenarioCard extends StatefulWidget {
  const _QuickScenarioCard({
    required this.index,
    required this.scenario,
    required this.onRun,
    required this.onSliderChanged,
    required this.onOpenSlider,
    required this.onEdit,
  });

  final int index;
  final Scenario scenario;
  final VoidCallback onRun;
  final ValueChanged<int> onSliderChanged;
  final VoidCallback onOpenSlider;
  final VoidCallback onEdit;

  @override
  State<_QuickScenarioCard> createState() => _QuickScenarioCardState();
}

class _QuickScenarioCardState extends State<_QuickScenarioCard> {
  /// Value while the user is dragging the slider. Null reverts the display to
  /// the module's live PWM so the card stays synced with the device.
  int? _dragValue;

  Scenario get scenario => widget.scenario;

  ChannelOutput? get sliderChannel => dimmerTargetChannel(
      ModuleStore.shared.modules, scenario.sliderTargetName);

  /// The slider's displayed value: the in-progress drag value, else the target
  /// channel's live PWM (the module is the source of truth), falling back to
  /// the stored default when no dimmer output is resolved.
  int get _displayValue {
    if (_dragValue != null) return _dragValue!;
    final channel = sliderChannel;
    if (channel != null) return channel.brightness.clamp(0, 100);
    return scenario.sliderValue.clamp(0, 100);
  }

  Future<void> _onSliderChanged(int value) async {
    final snapped = sliderChannel?.snapBrightness(value) ?? value;
    final v = snapped.clamp(0, 100);
    setState(() => _dragValue = v);
    widget.onSliderChanged(v);
    final ref = dimmerTargetRef(
        ModuleStore.shared.modules, scenario.sliderTargetName);
    if (ref != null) {
      await ModuleStatusService.shared.setDimmerLevel(ref.$1.id, ref.$2, v);
    }
  }

  void _onSliderEnd(double value) {
    setState(() => _dragValue = null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final scenario = this.scenario;
    final isSlider = scenario.type == ScenarioType.manualSlider;
    final sliderChannel = this.sliderChannel;
    final sliderValue = _displayValue;

    // A scenario can carry a custom background color: then the whole card is
    // painted with it and the foreground flips to black/white for contrast.
    final Color? bg = scenario.backgroundColor;
    final bool hasBg = bg != null;
    final Color fg = hasBg
        ? (ThemeData.estimateBrightnessForColor(bg) == Brightness.light
            ? Colors.black87
            : Colors.white)
        : cs.onSurface;
    final Color accent = hasBg ? fg : cs.primary;

    return Card(
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onEdit,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.drag_indicator,
                          color: fg.withValues(alpha: 0.6), size: 22),
                    ),
                  ),
                  _ScenarioAvatar(
                      icon: scenario.icon, tint: isSlider ? accent : fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          scenario.name,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: fg),
                        ),
                        const SizedBox(height: 4),
                        _RoomTag(label: scenario.roomName, fg: fg),
                        const SizedBox(height: 4),
                        Text(
                          isSlider
                              ? l10n.homeManualDimming
                              : l10n.homeActionsCount(scenario.actions.length),
                          style: TextStyle(
                              fontSize: 12, color: fg.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isSlider)
                    _IconActionButton(
                      icon: const Icon(Icons.open_in_full, size: 20),
                      onTap: widget.onOpenSlider,
                      outlined: true,
                      fg: fg,
                      accent: accent,
                    )
                  else
                    _RunButton(onTap: widget.onRun),
                ],
              ),
              if (isSlider) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: Row(
                    children: [
                      Icon(Icons.brightness_low,
                          size: 18, color: fg.withValues(alpha: 0.6)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: accent,
                            inactiveTrackColor: fg.withValues(alpha: 0.14),
                            thumbColor: accent,
                            overlayColor: accent.withValues(alpha: 0.15),
                            valueIndicatorColor: accent,
                            valueIndicatorTextStyle: TextStyle(
                                color: hasBg ? bg : cs.onPrimary,
                                fontWeight: FontWeight.w700),
                          ),
                          child: Slider(
                            value: sliderValue.toDouble(),
                            min: 0,
                            max: 100,
                            divisions:
                                sliderChannel?.brightnessSliderDivisions ?? 100,
                            label: '$sliderValue%',
                            onChanged: (v) => _onSliderChanged(
                                sliderChannel?.snapBrightness(v.round()) ??
                                    v.round()),
                            onChangeEnd: _onSliderEnd,
                          ),
                        ),
                      ),
                      Icon(Icons.brightness_high,
                          size: 18, color: fg.withValues(alpha: 0.6)),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '$sliderValue%',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Scenario icon avatar; slider icons get a mint halo echoing the reference's
/// primary-glow wash.
class _ScenarioAvatar extends StatelessWidget {
  const _ScenarioAvatar({required this.icon, required this.tint});

  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tint.withValues(alpha: 0.12),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(color: tint.withValues(alpha: 0.18), blurRadius: 12)
        ],
      ),
      child: Icon(icon, color: tint, size: 22),
    );
  }
}

/// Inline room tag, restyled to match the glass chips.
class _RoomTag extends StatelessWidget {
  const _RoomTag({required this.label, this.fg});

  final String label;

  /// Overrides the theme foreground (e.g. for colored scenario cards).
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color c = fg ?? cs.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: c.withValues(alpha: 0.85)),
      ),
    );
  }
}

/// Primary-accent "run / play" button.
class _RunButton extends StatelessWidget {
  const _RunButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: Ink(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [cs.primary, cs.primary]),
        ),
        width: 52,
        height: 52,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(Icons.play_arrow_rounded, color: cs.onPrimary, size: 30),
        ),
      ),
    );
  }
}

/// Secondary outlined icon action (e.g. open slider in full screen).
class _IconActionButton extends StatelessWidget {
  const _IconActionButton(
      {required this.icon,
      required this.onTap,
      required this.outlined,
      this.fg,
      this.accent});

  final Widget icon;
  final VoidCallback onTap;
  final bool outlined;

  /// Overrides the theme foreground/accent (e.g. for colored scenario cards).
  final Color? fg;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color buttonFg = fg ?? cs.onSurface;
    final Color buttonAccent = accent ?? cs.primary;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: Ink(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: outlined ? buttonFg.withValues(alpha: 0.08) : null,
          border: outlined
              ? Border.all(color: buttonFg.withValues(alpha: 0.35))
              : null,
          gradient: outlined
              ? null
              : LinearGradient(colors: [buttonAccent, buttonAccent]),
        ),
        width: 48,
        height: 48,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
              child: outlined
                  ? Icon(Icons.open_in_full, color: buttonFg, size: 20)
                  : icon),
        ),
      ),
    );
  }
}

class _TemperatureRow extends StatelessWidget {
  const _TemperatureRow({required this.module, required this.onTap});

  final DeviceModule module;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final bool alert = module.isOverTemperature;
    final Color valueColor = alert ? cs.error : cs.primary;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: valueColor.withValues(alpha: 0.12),
                  border: Border.all(color: valueColor.withValues(alpha: 0.4)),
                ),
                child: Icon(Icons.thermostat, color: valueColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(module.name,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: cs.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                      l10n.homeTempRange(
                          module.roomName,
                          module.tempMinC.toStringAsFixed(0),
                          module.tempMaxC.toStringAsFixed(0)),
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
              Text(
                '${module.internalTempC.toStringAsFixed(1)}°C',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: valueColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
