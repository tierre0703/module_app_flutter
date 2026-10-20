// lib/screens/add_module_screen.dart
//
// Brief section 2.1 "Simplified Addition": modules broadcast a self
// discovery message that the app can pick up (see ModuleDiscovery, which
// implements the Soleux UDP discovery protocol in
// doc/Soleux-Network-Discovery-and-DCP.md §1), and are otherwise
// identified / added manually by IP address or, in remote mode, by hostname.
// Selecting or submitting a module simply returns it to the Configuration
// screen via `Navigator.pop`.
//
// The discovered list supports batch addition: a long press enters selection
// mode (cards become checkable), the "Add selected" action stays disabled
// until at least one module is selected, and submitting pops every checked
// module as a `List<DeviceModule>`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../core/discovery/module_discovery.dart';
import '../models/models.dart';
import '../services/module_host_resolver.dart';
import '../services/module_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class AddModuleScreen extends StatefulWidget {
  const AddModuleScreen({super.key});

  @override
  State<AddModuleScreen> createState() => _AddModuleScreenState();
}

class _AddModuleScreenState extends State<AddModuleScreen> {
  bool _scanning = true;
  late List<DeviceModule> _discovered;

  /// Ids of the discovered modules checked while selection mode is active.
  /// Non-empty implies selection mode; long press starts it, and the
  /// "Add selected" action is only enabled while it holds at least one id.
  final Set<String> _selected = <String>{};

  final ModuleDiscovery _discovery = ModuleDiscovery();

  /// True while a manually entered hostname is being resolved (remote mode).
  bool _resolvingAddress = false;

  final _nameController = TextEditingController();
  final _ipController = TextEditingController();
  final _tcpPortController = TextEditingController(text: '5008');
  late final TextEditingController _tempThresholdController;
  ModuleType _manualType = ModuleType.relay;
  String _connectionType = 'local_network';

  @override
  void initState() {
    super.initState();
    _discovered = [];
    _tempThresholdController = TextEditingController(
        text: SettingsStore.shared.defaultTemperatureThreshold
            .toInt()
            .toString());
    _scan();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _tcpPortController.dispose();
    _tempThresholdController.dispose();
    super.dispose();
  }

  List<ChannelOutput> _defaultChannelsFor(
      ModuleType type, AppLocalizations l10n) {
    switch (type) {
      case ModuleType.relay:
        return List.generate(
            8,
            (i) => ChannelOutput(
                id: 'new-r$i',
                name: l10n.addModuleOutput(i + 1),
                icon: Icons.power));
      case ModuleType.blind:
        return List.generate(
            2,
            (i) => ChannelOutput(
                id: 'new-b$i',
                name: l10n.addModuleBlind(i + 1),
                icon: Icons.blinds));
      case ModuleType.dimmerDc:
      case ModuleType.dimmerAc:
        return List.generate(
            4,
            (i) => ChannelOutput(
                id: 'new-d$i',
                name: l10n.addModuleChannel(i + 1),
                icon: Icons.tune));
      case ModuleType.temperature:
        return [];
      case ModuleType.hub:
        return List.generate(
            11,
            (i) => ChannelOutput(
                id: 'new-h$i',
                name: i < 8 ? l10n.addModuleOutput(i + 1) : 'Modbus Output ${i - 7}',
                icon: Icons.electrical_services,
                isModbusPower: i >= 8));
    }
  }

  /// Sends the UDP discovery broadcast and awaits PDU identity responses.
  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _discovered = [];
      // A rescan replaces the list, so any previous selection is stale.
      _selected.clear();
    });
    List<DeviceModule> found;
    try {
      await ModuleStore.shared.init();
      final existing = ModuleStore.shared.modules;
      final results = await _discovery.discover();
      found = [
        for (final d in results)
          if (!_alreadyAdded(_toDeviceModule(d), existing)) _toDeviceModule(d),
      ];
    } catch (e, st) {
      debugPrint('AddModuleScreen: discovery scan failed: $e\n$st');
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _discovered = found;
    });
  }

  /// True when [candidate] matches an already-added module in the fleet, so
  /// rediscovered devices are not offered for duplicate addition. Matches on
  /// stable identity first (id / MAC / serial), then on the endpoint the user
  /// may have added manually (IP + TCP port).
  bool _alreadyAdded(DeviceModule candidate, List<DeviceModule> existing) {
    for (final m in existing) {
      if (m.id == candidate.id) return true;
      if (m.mac != null && candidate.mac != null && m.mac == candidate.mac) {
        return true;
      }
      if (m.serial != null &&
          candidate.serial != null &&
          m.serial == candidate.serial) {
        return true;
      }
      if (m.ipAddress == candidate.ipAddress &&
          m.tcpPort == candidate.tcpPort) {
        return true;
      }
    }
    return false;
  }

  void _refreshDiscovery() {
    _scan();
  }

  /// Parses the temperature threshold field, falling back to the app-wide
  /// default configured on Settings -> Notifications.
  double _temperatureThreshold() {
    final parsed = double.tryParse(_tempThresholdController.text.trim());
    if (parsed == null || parsed <= 0) {
      return SettingsStore.shared.defaultTemperatureThreshold;
    }
    return parsed.clamp(0, 100);
  }

  /// Builds a [DeviceModule] from a UDP discovery reply. The family GUID maps
  /// to a device family (relay module / dimmer / PDU ...), which picks the
  /// default module type, channel shape and label; the returned HostPort and
  /// firmware version are carried over for the status service. Advertised
  /// additive endpoints (MAC, Control API port, heartbeat port, API version
  /// and capabilities) are carried over so monitoring uses what the device
  /// actually advertised (spec §3 endpoint selection).
  DeviceModule _toDeviceModule(DiscoveredModule discovered) {
    final family = discovered.family;
    final type = family?.defaultModuleType ?? ModuleType.relay;
    return DeviceModule(
      id: 'discovered-${discovered.serial.isNotEmpty ? discovered.serial : discovered.guid}',
      name: discovered.name.isNotEmpty
          ? discovered.name
          : (family?.label ??
              AppLocalizations.of(context).addModuleUnnamedRelay),
      type: type,
      ipAddress: discovered.ip,
      tcpPort: discovered.tcpPort,
      firmware: discovered.version.isEmpty ? null : discovered.version,
      serial: discovered.serial.isEmpty ? null : discovered.serial,
      mac: discovered.mac,
      apiPort: discovered.apiPort,
      apiVersion: discovered.apiVersion,
      heartbeatPort: discovered.advertisedHeartbeatPort,
      caps: discovered.caps,
      // Answering a discovery broadcast does not prove the module is still
      // reachable: seed it offline (unverified) and let the heartbeat monitor
      // confirm it online on the first successful pong.
      status: ConnectionStatus.offline,
      roomName: AppLocalizations.of(context).unassigned,
      internalTempC: 25,
      tempMaxC: SettingsStore.shared.defaultTemperatureThreshold,
      channels: _defaultChannelsFor(type, AppLocalizations.of(context)),
    );
  }

  void _addDiscovered(DeviceModule module) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(<DeviceModule>[module]);
  }

  /// True while the list accepts checkbox taps (selection mode). Selection
  /// mode is entered by a long press and only stays on while at least one
  /// module is checked.
  bool get _selectionMode => _selected.isNotEmpty;

  void _toggleSelection(DeviceModule module) {
    setState(() {
      if (!_selected.remove(module.id)) {
        _selected.add(module.id);
      }
    });
  }

  /// Long press: enter selection mode straight away and check [module], so the
  /// user immediately sees the selectable list and the enabled batch action.
  void _startSelection(DeviceModule module) {
    if (!_selectionMode) {
      HapticFeedback.mediumImpact();
    }
    setState(() => _selected.add(module.id));
  }

  void _clearSelection() {
    setState(_selected.clear);
  }

  /// Returns every checked discovered module to the Configuration screen for
  /// batch upsert. Only reachable while [_selectionMode] holds modules.
  void _addSelected() {
    if (!_selectionMode) return;
    FocusScope.of(context).unfocus();
    final List<DeviceModule> picked = [
      for (final module in _discovered)
        if (_selected.contains(module.id)) module,
    ];
    if (picked.isEmpty) return;
    Navigator.of(context).pop(picked);
  }

  void _addManual() {
    FocusScope.of(context).unfocus();
    if (_ipController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).addModuleEnterIp)),
      );
      return;
    }
    _addManualAsync();
  }

  /// Adds the manually entered module. In remote mode the address may be a
  /// hostname: it is resolved to an IPv4 address once, here, and cached on the
  /// module ([DeviceModule.resolvedIp]) so no lookup happens per connection.
  Future<void> _addManualAsync() async {
    final l10n = AppLocalizations.of(context);
    final entered = _ipController.text.trim();
    final isRemote = _connectionType == 'remote';

    String? resolvedIp;
    final needsLookup = isRemote && !isLiteralIpAddress(entered);
    if (needsLookup) {
      setState(() => _resolvingAddress = true);
      resolvedIp =
          await resolveModuleAddress(entered, debugTag: 'AddModuleScreen');
      if (!mounted) return;
      setState(() => _resolvingAddress = false);
      if (resolvedIp == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.addModuleResolveFailed(entered))),
        );
        return;
      }
    }

    if (!mounted) return;
    final module = DeviceModule(
      id: 'manual-${DateTime.now().millisecondsSinceEpoch}',
      name: _nameController.text.trim().isEmpty
          ? _manualType.label
          : _nameController.text.trim(),
      type: _manualType,
      connectionType: _connectionType,
      ipAddress: entered,
      resolvedIp: resolvedIp,
      tcpPort: int.tryParse(_tcpPortController.text.trim()) ?? 5008,
      // A manually entered address has not been verified reachable yet: seed
      // it offline and let the API health check confirm it online. Seeding
      // online here would show a module as reachable even when it is not.
      status: ConnectionStatus.offline,
      roomName: l10n.unassigned,
      internalTempC: 25,
      tempMaxC: _temperatureThreshold(),
      channels: _defaultChannelsFor(_manualType, l10n),
    );
    Navigator.of(context).pop(<DeviceModule>[module]);
  }

  /// Card for one discovered module. Idle it offers a single "Add" button;
  /// while selection mode is on the same card becomes a checkbox row, so the
  /// user can build up a batch of modules to add at once.
  Widget _buildDiscoveredCard(
      DeviceModule module, AppLocalizations l10n, Color onSurface) {
    final bool selected = _selected.contains(module.id);
    final Widget icon = IconAvatar(icon: module.type.icon);
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(module.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(
            (module.firmware != null && module.firmware!.isNotEmpty)
                ? l10n.addModuleFamilyMeta(module.type.label, module.firmware!)
                : l10n.configModuleSummary(module.type.label, module.ipAddress),
            style: TextStyle(
                fontSize: 12, color: onSurface.withValues(alpha: 0.55))),
        const SizedBox(height: 2),
        Text(
          module.ipAddress,
          style:
              TextStyle(fontSize: 11, color: onSurface.withValues(alpha: 0.45)),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.betweenCards),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onLongPress: () => _startSelection(module),
          onTap: _selectionMode ? () => _toggleSelection(module) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (_selectionMode) ...[
                  Checkbox(
                    value: selected,
                    onChanged: (_) => _toggleSelection(module),
                  ),
                  const SizedBox(width: 4),
                ],
                icon,
                const SizedBox(width: 12),
                Expanded(child: details),
                if (!_selectionMode)
                  FilledButton(
                      onPressed: () => _addDiscovered(module),
                      child: Text(l10n.addModuleButton)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addModuleTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            SectionHeader(
              l10n.addModuleDiscovered,
              // Batch actions live in the header while selecting: "add" is
              // only shown (and only enabled) in selection mode, so the user
              // must pick modules before adding them all at once; the clear
              // icon leaves selection mode.
              trailing: _selectionMode
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip:
                              l10n.addModuleAddSelectedCount(_selected.length),
                          onPressed: _addSelected,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                        IconButton(
                          tooltip: l10n.addModuleDeselectAll,
                          onPressed: _clearSelection,
                          icon: const Icon(Icons.clear_all),
                        ),
                      ],
                    )
                  : IconButton(
                      tooltip: l10n.addModuleRefreshTooltip,
                      onPressed: _scanning ? null : _refreshDiscovery,
                      icon: Icon(
                        _scanning ? Icons.sync : Icons.refresh,
                      ),
                    ),
            ),
            if (_selectionMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l10n.addModuleSelectedCount(_selected.length),
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurface.withValues(alpha: 0.6),
                  ),
                ),
              )
            else if (!_scanning && _discovered.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l10n.addModuleSelectHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            if (_scanning)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.6)),
                      const SizedBox(height: 12),
                      Text(l10n.addModuleListening),
                    ],
                  ),
                ),
              )
            else if (_discovered.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    EmptyState(
                        icon: Icons.wifi_find_outlined,
                        message: l10n.addModuleNoneFound),
                    const SizedBox(height: 8),
                    Text(
                      l10n.addModuleDcpHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final module in _discovered)
                _buildDiscoveredCard(module, l10n, onSurface),
            const SizedBox(height: 24),
            SectionHeader(l10n.addModuleManualSection),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                  labelText: l10n.addModuleNameOptional,
                  prefixIcon: const Icon(Icons.edit_outlined)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _connectionType,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: l10n.connectionType,
                  prefixIcon: const Icon(Icons.public_outlined)),
              items: [
                DropdownMenuItem(
                  value: 'local_network',
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      l10n.connectionLocalNetwork,
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
                      l10n.connectionRemote,
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
                      l10n.connectionCloud,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _connectionType = value ?? _connectionType),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipController,
              decoration: InputDecoration(
                  labelText: _connectionType == 'remote'
                      ? l10n.addModuleAddressOrHostname
                      : l10n.ipAddress,
                  hintText: _connectionType == 'remote'
                      ? 'module.example.com'
                      : '192.168.1.120',
                  helperText: _connectionType == 'remote'
                      ? l10n.addModuleHostnameHelp
                      : null,
                  prefixIcon: Icon(_connectionType == 'remote'
                      ? Icons.dns_outlined
                      : Icons.lan_outlined)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tcpPortController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: l10n.tcpPort,
                  hintText: '5008',
                  prefixIcon: const Icon(Icons.router_outlined)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ModuleType>(
              initialValue: _manualType,
              decoration: InputDecoration(
                  labelText: l10n.addModuleType,
                  prefixIcon: const Icon(Icons.category_outlined)),
              items: [
                for (final type in ModuleType.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: (value) =>
                  setState(() => _manualType = value ?? _manualType),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tempThresholdController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: l10n.tempThresholdLabel,
                  helperText: l10n.addModuleTempThresholdDefault(
                      SettingsStore.shared.defaultTemperatureThreshold.toInt()),
                  prefixIcon: const Icon(Icons.thermostat_outlined)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: _resolvingAddress ? null : _addManual,
                icon: _resolvingAddress
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2))
                    : const Icon(Icons.add),
                label: Text(_resolvingAddress
                    ? l10n.addModuleResolvingAddress
                    : l10n.addModuleAddAction)),
          ],
        ),
      ),
    );
  }
}
