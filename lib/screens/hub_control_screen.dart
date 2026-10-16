// lib/screens/hub_control_screen.dart
//
// Control screen for Modbus HUB modules (Hub mini, Hub v1.0). Displays a
// dashboard with normal outputs and Modbus power outputs, allows ON/OFF,
// pulse, and restart operations. Uses the Hub-specific JSON API (protocol 1)
// over TCP port 5008, as documented in doc/Modbus_Hub_Control_API.md.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/module_status/hub_api_protocol.dart';
import '../services/module_status/module_tcp_service.dart';
import '../services/module_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

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
  bool _busy = false;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _connectAndRefresh();
  }

  @override
  void dispose() {
    _hubClient?.dispose();
    _hubClient = null;
    super.dispose();
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
      final responses = _hubClient!.feed(chunk);
      for (final response in responses) {
        if (response != null) {
          _handleResponse(response);
        }
      }
    });

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
        if (_deviceInfo!.name != null && _deviceInfo!.name!.isNotEmpty) {
          ModuleStore.shared.update(module.id, (m) {
            m.name = _deviceInfo!.name!;
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

  void _handleResponse(HubCommandResponse response) {
    // Completers resolved in HubJsonProtocol.feed
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    _busy = true;
    setState(() {});
    try {
      if (_hubClient == null || !_hubClient!.isConnected) {
        await _connectAndRefresh();
      } else {
        await _fetchDashboard();
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleOutput(int index, bool next) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    final dash = _dashboard;
    EventLogStore.shared.recordModuleAction(
      moduleName: widget.module.name,
      outputName: dash != null && index < dash.outputs.length
          ? dash.outputs[index].name
          : 'Output $channel',
      on: next,
    );
    try {
      final response = await client.setOutput(channel, next);
      if (response.ok) {
        await _fetchDashboard();
        if (mounted) setState(() {});
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: set_output failed: $e\n$st');
    }
  }

  Future<void> _pulseOutput(int index) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    try {
      await client.pulseOutput(channel);
      await Future.delayed(const Duration(seconds: 1500));
      await _fetchDashboard();
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: pulse_output failed: $e\n$st');
    }
  }

  Future<void> _restartModbusOutput(int index) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    try {
      await client.restartModbusOutput(channel);
      await Future.delayed(const Duration(seconds: 2000));
      await _fetchDashboard();
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: restart_modbus_output failed: $e\n$st');
    }
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
              icon: Icon(_busy ? Icons.sync : Icons.refresh),
              tooltip: l10n.relayRefreshTooltip,
              onPressed: _busy ? null : _refresh),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            if (_offline)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    StatusDot(
                        status: ConnectionStatus.offline, size: 14),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            '${module.name} is offline - check connection')),
                  ]),
                ),
              )
            else
              ModuleStatusHeader(module: module),

            if (di != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Device Info',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      if (di!.model != null)
                        _infoRow('Model', di!.model!, onSurface),
                      if (di!.appFirmware != null)
                        _infoRow('Firmware', di!.appFirmware!, onSurface),
                      if (di!.serial != null)
                        _infoRow('Serial', di!.serial!, onSurface),
                      if (di!.mac != null)
                        _infoRow('MAC', di!.mac!, onSurface),
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
                      const Text('System Status',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      if (dash!.internalTemp != null)
                        _infoRow(
                            'Internal Temp',
                            '${dash!.internalTemp!.toStringAsFixed(1)} °C',
                            onSurface),
                      if (dash!.cpuTemp != null)
                        _infoRow(
                            'CPU Temp',
                            '${dash!.cpuTemp!.toStringAsFixed(1)} °C',
                            onSurface),
                      if (dash!.cpuUsage != null)
                        _infoRow(
                            'CPU Usage',
                            '${dash!.cpuUsage!.toStringAsFixed(1)}%',
                            onSurface),
                      if (dash!.memoryUsage != null)
                        _infoRow(
                            'Memory',
                            '${dash!.memoryUsage!.toStringAsFixed(1)}%',
                            onSurface),
                    ],
                  ),
                ),
              ),
            ],

            if (dash != null && dash!.outputs.isNotEmpty) ...[
              const SizedBox(height: 24),
              SectionHeader(
                  'Outputs (${dash!.outputs.length})'),
              for (int i = 0; i < dash!.outputs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: _buildOutputRow(
                    i,
                    dash!.outputs[i],
                    onSurface,
                    l10n,
                  ),
                ),
            ],

            if (dash != null && dash!.modbusOutputs.isNotEmpty) ...[
              const SizedBox(height: 24),
              SectionHeader(
                  'Modbus Power Outputs (${dash!.modbusOutputs.length})'),
              for (int i = 0; i < dash!.modbusOutputs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: _buildModbusRow(
                    i,
                    dash!.modbusOutputs[i],
                    onSurface,
                    l10n,
                  ),
                ),
            ],

            if (dash == null && !_offline) ...[
              const SizedBox(height: 24),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.6)),
                      const SizedBox(height: 12),
                      const Text('Loading...'),
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

  Widget _buildOutputRow(
    int index,
    HubOutputState output,
    Color onSurface,
    AppLocalizations l10n,
  ) {
    final bool state = output.state;
    final bool turnOffDisabled = output.turnOffDisable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    ],
                  ),
                ),
                SizedBox(
                  width: 88,
                  height: 48,
                  child: state
                      ? FilledButton(
                          onPressed: turnOffDisabled
                              ? null
                              : () => _toggleOutput(index, false),
                          child: Text(l10n.on))
                      : OutlinedButton(
                          onPressed: () => _toggleOutput(index, true),
                          child: Text(l10n.off)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () => _pulseOutput(index),
                  child: const Text('Pulse'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModbusRow(
    int index,
    HubOutputState output,
    Color onSurface,
    AppLocalizations l10n,
  ) {
    final bool state = output.state;
    final bool turnOffDisabled = output.turnOffDisable;
    final bool restartDisabled = output.restartDisable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    ],
                  ),
                ),
                SizedBox(
                  width: 88,
                  height: 48,
                  child: state
                      ? FilledButton(
                          onPressed: turnOffDisabled
                              ? null
                              : () => _toggleOutput(index, false),
                          child: Text(l10n.on))
                      : OutlinedButton(
                          onPressed: () => _toggleOutput(index, true),
                          child: Text(l10n.off)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: restartDisabled
                      ? null
                      : () => _restartModbusOutput(index),
                  child: const Text('Restart'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}