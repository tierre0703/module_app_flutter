// lib/screens/hub_control_screen.dart
//
// Control screen for Modbus HUB modules (Hub mini, Hub v1.0). Displays a
// dashboard with normal outputs and Modbus power outputs, allows ON/OFF,
// pulse, and restart operations. Uses the Hub-specific JSON API (protocol 1)
// over TCP port 5008, as documented in doc/Modbus_Hub_Control_API.md.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../core/logger/app_logger.dart';
import '../core/soleux/soleux_device_event.dart';
import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/module_status/hub_api_protocol.dart';
import '../services/module_status/module_tcp_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/system_log_screen.dart';
import 'channel_editor_screen.dart';

class HubControlScreen extends StatefulWidget {
  const HubControlScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<HubControlScreen> createState() => _HubControlScreenState();
}

class _HubControlScreenState extends State<HubControlScreen> {
  HubJsonProtocol? _hubClient;
  HubDashboardData? _dashboard;
  HubDeviceInfo? _deviceInfo;
  bool _offline = false;
  bool _editDialogOpen = false;
  StreamSubscription<SoleuxDeviceEvent>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _connectAndRefresh();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _hubClient?.dispose();
    _hubClient = null;
    super.dispose();
  }

  /// Applies an async Hub device event to the live dashboard data, then syncs
  /// to the shared store so all screens reflect the change in real-time.
  ///
  /// Handles `output_state_changed`, `input_state_changed`, and `system_status`
  /// broadcasts pushed by the Hub (doc/Modbus_Hub_Control_API.md §"Asynchronous
  /// TCP events").
  void _onHubEvent(SoleuxDeviceEvent event) {
    final dash = _dashboard;
    if (dash == null) return;

    // Log every incoming Hub broadcast event for monitoring/diagnostics.
    AppLogger.log(
        'Hub broadcast: ${event.rawEvent}',
        tag: 'hub_control_screen');

    var changed = false;
    switch (event.type) {
      case SoleuxDeviceEventType.outputStateChanged: {
        // Hub async events use zero-based bank channels per spec §"Channel
        // and state rules". Map onto the dashboard's normal-output list.
        final channel = event.channel;
        final state = event.state;
        if (channel != null && state != null &&
            channel >= 0 && channel < dash.outputs.length) {
          dash.outputs[channel].state = state;
          changed = true;
        }
        break;
      }
      case SoleuxDeviceEventType.systemStatus: {
        // Periodic ~5-second system snapshot with CPU temp, internal temp,
        // memory/CPU usage, and LAN IP.
        final system = event.system;
        if (system != null) {
          final cpuTemp = system['cpu_temp_c'];
          if (cpuTemp is num) {
            dash.cpuTemp = cpuTemp.toDouble();
          }
          final internalTemp = system['internal_temp_c'];
          if (internalTemp is num) {
            dash.internalTemp = internalTemp.toDouble();
          }
          changed = true;
        }
        break;
      }
      default:
        // input_state_changed and other events are logged but do not affect
        // the dashboard output display (inputs are not rendered here).
        break;
    }

    if (changed) {
      _syncToStore();
      if (mounted) setState(() {});
    }
  }

  Future<void> _connectAndRefresh() async {
    final module = widget.module;
    final host = module.host;
    final port = module.controlApiPort;

    final connection = ModuleTcpConnection(
      host: host,
      port: port,
      timeout: const Duration(seconds: 5),
    );
    _hubClient = HubJsonProtocol(connection);

    connection.dataStream.listen((chunk) {
      _hubClient!.feed(chunk);
    });

    // Subscribe to Hub async device events for real-time state updates.
    _eventSubscription?.cancel();
    _eventSubscription = _hubClient!.deviceEventStream.listen(_onHubEvent);

    try {
      await connection.connect();
      if (!connection.isConnected) {
        _offline = true;
        setState(() {});
        return;
      }
      _offline = false;

      final hello = await _hubClient!.hello();
      if (!hello.ok) {
        _offline = true;
        if (mounted) setState(() {});
        return;
      }

      final infoResp = await _hubClient!.getDeviceInfo();
      if (infoResp.ok && infoResp.result != null) {
        _deviceInfo = HubDeviceInfo.fromResult(infoResp.result!);
        final hubName = _deviceInfo!.name;
        if (hubName != null && hubName.isNotEmpty) {
          ModuleStore.shared.update(module.id, (m) {
            m.name = hubName;
          });
        }
      }

      await _fetchDashboard();

      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: connect/refresh failed: $e\n$st');
      _offline = true;
      if (mounted) setState(() {});
    }
  }

  Future<void> _fetchDashboard() async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    try {
      final response = await client.getDashboard();
      if (response.ok && response.result != null) {
        _dashboard = HubDashboardData.fromResult(response.result!);
        _syncToStore();
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: get_dashboard failed: $e\n$st');
    }
  }

  void _syncToStore() {
    final dash = _dashboard;
    if (dash == null) return;
    ModuleStore.shared.update(widget.module.id, (m) {
      m.status = ConnectionStatus.online;
      m.lastSeenAt = DateTime.now();
      while (m.channels.length < dash.outputs.length) {
        m.channels.add(ChannelOutput(
          id: '${m.id}h${m.channels.length}',
          name: 'Output ${m.channels.length + 1}',
          icon: Icons.electrical_services,
        ));
      }
      if (m.channels.length > dash.outputs.length) {
        m.channels.removeRange(dash.outputs.length, m.channels.length);
      }
      for (int i = 0; i < dash.outputs.length && i < m.channels.length; i++) {
        final state = dash.outputs[i];
        m.channels[i].name = state.name.isNotEmpty
            ? state.name
            : m.channels[i].name;
        m.channels[i].isOn = state.state;
      }
      if (dash.cpuTemp != null) m.internalTempC = dash.cpuTemp!;
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {});
    try {
      if (_hubClient == null || !_hubClient!.isConnected) {
        await _connectAndRefresh();
      } else {
        await _fetchDashboard();
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _editChannel(int index) async {
    final module = ModuleStore.shared.byId(widget.module.id) ?? widget.module;
    if (index < 0 || index >= module.channels.length) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => ChannelEditorScreen(
              channel: module.channels[index],
              module: module,
              index: index)),
    );
    if (saved == true) {
      await ModuleStore.shared.update(widget.module.id, (_) {});
    }
    if (mounted) setState(() {});
  }

  Future<void> _editModuleInfo() async {
    if (_editDialogOpen) return;
    _editDialogOpen = true;
    try {
      final module = ModuleStore.shared.byId(widget.module.id) ?? widget.module;
      final saved = await showEditModuleInfoDialog(context, module);
      if (saved && mounted) setState(() {});
    } finally {
      _editDialogOpen = false;
    }
  }

  Future<void> _toggleOutput(int index, bool next) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    final dash = _dashboard;
    final name = dash != null && index < dash.outputs.length
        ? dash.outputs[index].name
        : 'Output $channel';
    EventLogStore.shared.recordModuleAction(
      moduleName: widget.module.name,
      outputName: name,
      on: next,
    );
    try {
      final response = await client.setOutput(channel, next);
      if (response.ok) {
        _showToast('$name turned ${next ? "ON" : "OFF"}');
        await _fetchDashboard();
        if (mounted) setState(() {});
      } else {
        _showToast('$name: command failed');
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: set_output failed: $e\n$st');
      _showToast('$name: command failed');
    }
  }

  Future<void> _pulseOutput(int index) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    final dash = _dashboard;
    final name = dash != null && index < dash.outputs.length
        ? dash.outputs[index].name
        : 'Output $channel';
    try {
      await client.pulseOutput(channel);
      _showToast('$name: pulse sent');
      await Future.delayed(const Duration(seconds: 1500));
      await _fetchDashboard();
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: pulse_output failed: $e\n$st');
      _showToast('$name: pulse failed');
    }
  }

  Future<void> _toggleModbusOutput(int index, bool next) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    final dash = _dashboard;
    final name = dash != null && index < dash.modbusOutputs.length
        ? dash.modbusOutputs[index].name
        : 'Modbus Output $channel';
    try {
      final response = await client.setModbusOutput(channel, next);
      if (response.ok) {
        _showToast('$name turned ${next ? "ON" : "OFF"}');
        await _fetchDashboard();
        if (mounted) setState(() {});
      } else {
        _showToast('$name: command failed');
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: set_modbus_output failed: $e\n$st');
      _showToast('$name: command failed');
    }
  }

  Future<void> _restartModbusOutput(int index) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    final dash = _dashboard;
    final name = dash != null && index < dash.modbusOutputs.length
        ? dash.modbusOutputs[index].name
        : 'Modbus Output $channel';
    try {
      await client.restartModbusOutput(channel);
      _showToast('$name: restart sent');
      await Future.delayed(const Duration(seconds: 2000));
      await _fetchDashboard();
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: restart_modbus_output failed: $e\n$st');
      _showToast('$name: restart failed');
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    final module =
        ModuleStore.shared.byId(widget.module.id) ?? widget.module;
    final dash = _dashboard;
    final di = _deviceInfo;

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

            if (di != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Device Info',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      if (di.model != null)
                        _infoRow('Model', di.model!, onSurface),
                      if (di.appFirmware != null)
                        _infoRow(
                            'Firmware', di.appFirmware!, onSurface),
                      if (di.serial != null)
                        _infoRow('Serial', di.serial!, onSurface),
                      if (di.mac != null)
                        _infoRow('MAC', di.mac!, onSurface),
                    ],
                  ),
                ),
              ),
            ],

            if (dash != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('System Status',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      if (dash.internalTemp != null)
                        _infoRow(
                            'Internal Temp',
                            '${dash.internalTemp!.toStringAsFixed(1)} °C',
                            onSurface),
                      if (dash.cpuTemp != null)
                        _infoRow(
                            'CPU Temp',
                            '${dash.cpuTemp!.toStringAsFixed(1)} °C',
                            onSurface),
                      if (dash.cpuUsage != null)
                        _infoRow(
                            'CPU Usage',
                            '${dash.cpuUsage!.toStringAsFixed(1)}%',
                            onSurface),
                      if (dash.memoryUsage != null)
                        _infoRow(
                            'Memory',
                            '${dash.memoryUsage!.toStringAsFixed(1)}%',
                            onSurface),
                    ],
                  ),
                ),
              ),
            ],

            if (dash != null && dash.outputs.isNotEmpty) ...[
              const SizedBox(height: 24),
              SectionHeader(
                  'Outputs (${dash.outputs.length})'),
              for (int i = 0; i < dash.outputs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: _HubOutputRow(
                    index: i,
                    output: dash.outputs[i],
                    onToggle: () => _toggleOutput(
                        i, !dash.outputs[i].state),
                    onPulse: () => _pulseOutput(i),
                    onEdit: () => _editChannel(i),
                    l10n: l10n,
                    onSurface: onSurface,
                  ),
                ),
            ],

            if (dash != null && dash.modbusOutputs.isNotEmpty) ...[
              const SizedBox(height: 24),
              SectionHeader(
                  'Modbus Power Outputs (${dash.modbusOutputs.length})'),
              for (int i = 0; i < dash.modbusOutputs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: _HubModbusOutputRow(
                    index: i,
                    output: dash.modbusOutputs[i],
                    onToggle: () => _toggleModbusOutput(
                        i, !dash.modbusOutputs[i].state),
                    onRestart: () => _restartModbusOutput(i),
                    onEdit: () => _editChannel(i),
                    l10n: l10n,
                    onSurface: onSurface,
                  ),
                ),
            ],

            if (dash == null && !_offline) ...[
              const SizedBox(height: 24),
              Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.6)),
                      const SizedBox(height: 12),
                      Text('Loading...'),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, Color onSurface) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: onSurface.withValues(alpha: 0.55))),
          Expanded(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 12))),
        ]),
      );
}

/// A single normal-output row matching the relay screen's _OutputRow style.
/// ON/OFF button, Pulse button and edit button are all in the same row.
class _HubOutputRow extends StatelessWidget {
  const _HubOutputRow({
    required this.index,
    required this.output,
    required this.onToggle,
    required this.onPulse,
    required this.onEdit,
    required this.l10n,
    required this.onSurface,
  });

  final int index;
  final HubOutputState output;
  final VoidCallback onToggle;
  final VoidCallback onPulse;
  final VoidCallback onEdit;
  final AppLocalizations l10n;
  final Color onSurface;

  @override
  Widget build(BuildContext context) {
    final state = output.state;
    final turnOffDisabled = output.turnOffDisable;
    final pulseDisabled = turnOffDisabled || output.restartDisable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconAvatar(
                icon: Icons.electrical_services,
                filled: state),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(output.name.isNotEmpty
                          ? output.name
                          : 'Output ${index + 1}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('Channel ${output.channel}',
                      style: TextStyle(
                          fontSize: 12,
                          color: onSurface.withValues(alpha: 0.5))),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 88,
                        height: 48,
                        child: state
                            ? FilledButton(
                                onPressed: turnOffDisabled
                                    ? null
                                    : onToggle,
                                child: Text(l10n.on))
                            : OutlinedButton(
                                onPressed: onToggle,
                                child: Text(l10n.off)),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: pulseDisabled ? null : onPulse,
                        child: const Text('Pulse'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: onEdit),
          ],
        ),
      ),
    );
  }
}

/// A single Modbus output row matching the relay screen's _OutputRow style.
class _HubModbusOutputRow extends StatelessWidget {
  const _HubModbusOutputRow({
    required this.index,
    required this.output,
    required this.onToggle,
    required this.onRestart,
    required this.onEdit,
    required this.l10n,
    required this.onSurface,
  });

  final int index;
  final HubOutputState output;
  final VoidCallback onToggle;
  final VoidCallback onRestart;
  final VoidCallback onEdit;
  final AppLocalizations l10n;
  final Color onSurface;

  @override
  Widget build(BuildContext context) {
    final state = output.state;
    final turnOffDisabled = output.turnOffDisable;
    final restartDisabled = output.restartDisable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconAvatar(
                icon: Icons.electrical_services,
                filled: state),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(output.name.isNotEmpty
                          ? output.name
                          : 'Modbus Output ${index + 1}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('Channel ${output.channel}',
                      style: TextStyle(
                          fontSize: 12,
                          color: onSurface.withValues(alpha: 0.5))),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 88,
                        height: 48,
                        child: state
                            ? FilledButton(
                                onPressed: turnOffDisabled
                                    ? null
                                    : onToggle,
                                child: Text(l10n.on))
                            : OutlinedButton(
                                onPressed: onToggle,
                                child: Text(l10n.off)),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: restartDisabled
                            ? null
                            : onRestart,
                        child: const Text('Restart'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: onEdit),
          ],
        ),
      ),
    );
  }
}