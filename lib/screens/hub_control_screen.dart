// lib/screens/hub_control_screen.dart
//
// Control screen for Modbus HUB modules (Hub mini, Hub v1.0). Displays a
// dashboard with normal outputs and Modbus power outputs, allows ON/OFF,
// pulse, and restart operations. Uses the Hub-specific JSON API (protocol 1)
// over TCP port 5008, as documented in doc/Modbus_Hub_Control_API.md.
//
// ModuleStatusHeader is imported from common_widgets.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../../models/models.dart';
import '../../services/event_log_store.dart';
import '../../services/module_host_resolver.dart';
import '../../services/module_status/module_status_service.dart';
import '../../services/module_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common_widgets.dart';
import 'module_tcp_service.dart';
import 'hub_api_protocol.dart' show HubJsonProtocol, HubDashboardData, HubDeviceInfo, HubOutputState, HubCommandResponse;

class HubControlScreen extends StatefulWidget {
  const HubControlScreen({super.key, required this.module});

  final DeviceModule module;

  @override
  State<HubControlScreen> createState() => _HubControlScreenState();
}

class _HubControlScreenState extends State<HubControlScreen> {
  /// The persistent Hub JSON protocol client.
  HubJsonProtocol? _hubClient;

  /// Cached dashboard data, set after a successful get_dashboard.
  HubDashboardData? _dashboard;

  /// Cached device info.
  HubDeviceInfo? _deviceInfo;

  /// True while a command is in-flight.
  bool _busy = false;

  /// True when the module is unreachable on the last probe.
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

  /// Connects to the Hub and fetches the dashboard.
  Future<void> _connectAndRefresh() async {
    final module = widget.module;
    final host = module.host;
    final port = module.controlApiPort;

    // Create the TCP connection and protocol handler.
    final connection = ModuleTcpConnection(
      host: host,
      port: port,
      timeout: const Duration(seconds: 5),
    );
    _hubClient = HubJsonProtocol(connection);

    // Wire the data stream to parse Hub responses.
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

      // Step 1: hello — the Hub sends "Soleux JSON API Ready" on connect,
      // which HubJsonProtocol.feed discards automatically.
      final hello = await _hubClient!.hello();
      if (!hello.ok) {
        _offline = true;
        if (mounted) setState(() {});
        return;
      }

      // Step 2: get_device_info
      final infoResp = await _hubClient!.getDeviceInfo();
      if (infoResp.ok && infoResp.result != null) {
        _deviceInfo = HubDeviceInfo.fromResult(infoResp.result!);
        // Sync the module's name and serial from the Hub.
        if (_deviceInfo!.name != null && _deviceInfo!.name!.isNotEmpty) {
          ModuleStore.shared.update(module.id, (m) {
            m.name = _deviceInfo!.name!;
          });
        }
      }

      // Step 3: get_dashboard
      await _fetchDashboard();

      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: connect/refresh failed: $e\n$st');
      _offline = true;
      if (mounted) setState(() {});
    }
  }

  /// Fetches the dashboard data.
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

  /// Syncs dashboard data into the ModuleStore so the module card reflects
  /// live status.
  void _syncToStore() {
    final dash = _dashboard;
    if (dash == null) return;
    ModuleStore.shared.update(widget.module.id, (m) {
      m.status = ConnectionStatus.online;
      m.lastSeenAt = DateTime.now();
      // Map dashboard outputs to channels.
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

  /// Handles a parsed Hub command response.
  void _handleResponse(HubCommandResponse response) {
    // Command completers are resolved in HubJsonProtocol.feed - nothing
    // additional needed here for basic command/response matching.
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    _busy = true;
    setState(() {});
    try {
      // If the client disconnected, reconnect.
      if (_hubClient == null || !_hubClient.isConnected) {
        await _connectAndRefresh();
      } else {
        await _fetchDashboard();
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  /// Toggles a normal output.
  Future<void> _toggleOutput(int index, bool next) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1; // Hub channels are one-based.
    EventLogStore.shared.recordModuleAction(
      moduleName: widget.module.name,
      outputName: _dashboard != null &&
              index < _dashboard!.outputs.length
          ? _dashboard!.outputs[index].name
          : 'Output ${channel}',
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

  /// Pulses a normal output.
  Future<void> _pulseOutput(int index) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    try {
      await client.pulseOutput(channel);
      // Wait a moment then refresh.
      await Future.delayed(const Duration(seconds: 1500));
      await _fetchDashboard();
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: pulse_output failed: $e\n$st');
    }
  }

  /// Toggles a Modbus power output.
  Future<void> _toggleModbusOutput(int index, bool next) async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    final channel = index + 1;
    try {
      final response = await client.setModbusOutput(channel, next);
      if (response.ok) {
        await _fetchDashboard();
        if (mounted) setState(() {});
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: set_modbus_output failed: $e\n$st');
    }
  }

  /// Restarts a Modbus power output.
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
            // Status header
            if (_offline)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Container(
                      width: 12,
                      height: 12,
                      child: SizedBox.shrinkWrap(
                          child: const ColoredBox(
                              color: Color(0xFFD32F2F))),
                      decoration: const BoxDecoration(borderRadius: 6),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(l10n.configModuleOffline(module.name))),
                  ]),
                ),
              )
            else
              ModuleStatusHeader(module: module),

            // Device info
            if (_deviceInfo != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Device Info',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      if (_deviceInfo!.model != null)
                        _infoRow('Model', _deviceInfo!.model!, onSurface),
                      if (_deviceInfo!.appFirmware != null)
                        _infoRow(
                            'Firmware', _deviceInfo!.appFirmware!, onSurface),
                      if (_deviceInfo!.serial != null)
                        _infoRow(
                            'Serial', _deviceInfo!.serial!, onSurface),
                      if (_deviceInfo!.mac != null)
                        _infoRow('MAC', _deviceInfo!.mac!, onSurface),
                    ],
                  ),
                ),
              ),
            ],

            // Temperature / CPU / memory status
            if (dash != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('System Status',
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

            // Normal outputs
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
                    isModbus: false,
                  ),
                ),
            ],

            // Modbus power outputs
            if (dash != null && dash!.modbusOutputs.isNotEmpty) ...[
              const SizedBox(height: 24),
              SectionHeader(
                  'Modbus Power Outputs (${dash!.modbusOutputs.length})'),
              for (int i = 0; i < dash!.modbusOutputs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppSpacing.betweenCards),
                  child: _buildOutputRow(
                    i,
                    dash!.modbusOutputs[i],
                    onSurface,
                    l10n,
                    isModbus: true,
                  ),
                ),
            ],

            // Empty state when no outputs
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
                      Text(l10n.configLoading),
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
                  style: TextStyle(fontSize: 12))),
        ]),
      );

  Widget _buildOutputRow(
    int index,
    HubOutputState output,
    Color onSurface,
    AppLocalizations l10n,
    {bool isModbus = false},
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
                              : '${isModbus ? "Modbus " : ""}Output ${index + 1}',
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
            // Action buttons row
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isModbus) ...[
                  OutlinedButton(
                    onPressed: () => _pulseOutput(index),
                    child: Text('Pulse'),
                  ),
                ],
                if (isModbus) ...[
                  OutlinedButton(
                    onPressed: restartDisabled
                        ? null
                        : () => _restartModbusOutput(index),
                    child: Text('Restart'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}