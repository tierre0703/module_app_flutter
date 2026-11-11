// lib/screens/hub_control_screen.dart
//
// Control screen for Modbus HUB modules (Hub mini, Hub v1.0). Displays a
// dashboard with normal outputs and Modbus power outputs, allows ON/OFF,
// pulse, and restart operations. Uses the Hub-specific JSON API (protocol 1)
// over TCP port 5008, as documented in doc/Modbus_Hub_Control_API.md.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../core/config/env.dart';
import '../core/logger/app_logger.dart';
import '../core/soleux/soleux_device_event.dart';
import '../core/soleux/soleux_tls.dart';
import '../models/models.dart';
import '../services/event_log_store.dart';
import '../services/hub_credential_store.dart';
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
  StreamSubscription<String>? _dataSubscription;

  /// True when the Hub demanded a login (`authentication_required` - the TLS
  /// login contract, doc/Soleux_Mobile_Control_API_TLS_Integration.md
  /// §"Login and commands"): control commands are not sent until the user
  /// signs in, so an unauthenticated session is never polled.
  bool _needsLogin = false;

  /// The last hub login failure shown in the login card/dialog. Never
  /// contains credentials.
  String? _loginError;

  /// True while [_connectAndRefresh] is in flight, so a concurrent refresh
  /// does not stack a second client/connection on top of the first (the
  /// TLS handshake makes the connect window long enough to hit this).
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _connectAndRefresh();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _dataSubscription = null;
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
  ///
  /// The Hub broadcast includes an `output_type` field in the payload:
  ///   `"modbus_power"` — targets the modbus power output list
  ///   `"local"` — targets the normal output list
  ///   absent — treated as a normal output (backward compatibility)
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
        // and state rules". The `output_type` field distinguishes modbus
        // power outputs from regular local outputs.
        final channel = event.channel;
        final state = event.state;
        if (channel == null || state == null) break;

        final outputType = event.data['output_type'] as String?;
        if (outputType == 'modbus_power') {
          if (channel >= 0 && channel < dash.modbusOutputs.length) {
            dash.modbusOutputs[channel].state = state;
            changed = true;
          }
        } else {
          // "local" or absent — treat as a normal output.
          if (channel >= 0 && channel < dash.outputs.length) {
            dash.outputs[channel].state = state;
            changed = true;
          }
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
    if (_connecting) return;
    _connecting = true;
    final module = widget.module;
    final host = module.host;
    final port = module.controlApiPort;

    // Tear down any previous client/connection before wiring the new one, so
    // two live connections never share this state (the previous call's
    // listeners are cancelled with their subscriptions below).
    _dataSubscription?.cancel();
    _dataSubscription = null;
    _hubClient?.dispose();
    _hubClient = null;

    final connection = ModuleTcpConnection(
      host: host,
      port: port,
      tls: moduleTlsOptions(module, forced: Env.config.apiTlsEnabled),
      timeout: const Duration(seconds: 5),
    );
    final hubClient = HubJsonProtocol(connection);
    _hubClient = hubClient;

    // The chunk pump captures the LOCAL client: stream events are delivered
    // in delayed microtasks, so dereferencing the field here raced with
    // dispose()/re-connect nulling it (the `!` on a nulled field crashed).
    // Feeding a disposed client's parser is harmless - its pending
    // completers are gone and the connection under it is closed.
    _dataSubscription = connection.dataStream.listen(hubClient.feed);

    // Subscribe to Hub async device events for real-time state updates.
    _eventSubscription?.cancel();
    _eventSubscription = hubClient.deviceEventStream.listen(_onHubEvent);

    try {
      await connection.connect();
      if (!mounted) return;
      if (!connection.isConnected) {
        _offline = true;
        setState(() {});
        return;
      }
      _offline = false;

      // TLS Hub login (doc §"Login and commands"): the first request on a
      // fresh TLS session must be `authenticate`. Without stored (or newly
      // entered) credentials the screen shows the login card and does not
      // poll control commands on the unauthenticated session.
      if (connection.usesTls &&
          !await _loginWithStoredCredentials(hubClient)) {
        _needsLogin = true;
        if (mounted) setState(() {});
        return;
      }
      _needsLogin = false;

      await _loadHubData(hubClient, module);

      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('HubControlScreen: connect/refresh failed: $e\n$st');
      _offline = true;
      if (mounted) setState(() {});
    } finally {
      _connecting = false;
    }
  }

  /// Authenticates [hubClient] with the stored Hub admin credentials.
  /// Returns true when the session is authenticated; false when no
  /// credentials are saved or the Hub rejected them (never retried in a
  /// loop - the Hub locks accounts after repeated failures). Credential
  /// values never reach the logs.
  Future<bool> _loginWithStoredCredentials(HubJsonProtocol hubClient) async {
    final module =
        ModuleStore.shared.byId(widget.module.id) ?? widget.module;
    final credentials = await HubCredentialStore.shared.load(module.id);
    if (credentials == null) return false;
    try {
      final response = await hubClient.authenticate(
          credentials.username, credentials.password);
      if (response.ok) {
        _loginError = null;
        return true;
      }
      _loginError =
          'The Hub rejected the saved credentials (${response.error ?? 'login failed'}). Sign in again.';
      return false;
    } catch (e, st) {
      debugPrint('HubControlScreen: stored-credential login failed: $e\n$st');
      _loginError = 'Login failed: could not reach the Hub login.';
      return false;
    }
  }

  /// The shared hello / device-info / tag-catalogue / dashboard pass run
  /// after a successful (stored or interactive) hub login.
  Future<void> _loadHubData(
      HubJsonProtocol hubClient, DeviceModule module) async {
    final hello = await hubClient.hello();
    if (!hello.ok) {
      if (hubClient.authenticationRequired) {
        _needsLogin = true;
      } else {
        _offline = true;
      }
      if (mounted) setState(() {});
      return;
    }

    final infoResp = await hubClient.getDeviceInfo();
    if (infoResp.ok && infoResp.result != null) {
      _deviceInfo = HubDeviceInfo.fromResult(infoResp.result!);
      final hubName = _deviceInfo!.name;
      if (hubName != null && hubName.isNotEmpty) {
        ModuleStore.shared.update(module.id, (m) {
          m.name = hubName;
        });
      }
    }

    await _fetchVirtualTags();

    await _fetchDashboard();

    if (mounted) setState(() {});
  }

  /// Fetches the `vio` virtual-tag group from the read-only hub tag catalogue
  /// (`get_tag_groups` + `get_tag_group group:'vio'`), caches it on the
  /// module's persisted hub information ([DeviceModule.virtualTags], doc
  /// §"Tag catalogue"), and keeps it current across screen refreshes.
  ///
  /// Never fails the connect/refresh pass: unsupported (`unknown action`) or
  /// erroring catalogue fetches leave the previously cached tags untouched.
  Future<void> _fetchVirtualTags() async {
    final client = _hubClient;
    if (client == null || !client.isConnected) return;
    try {
      final groupsResp = await client.getTagGroups();
      if (!groupsResp.ok || groupsResp.result == null) return;
      final groups = HubTagGroupsData.fromResult(groupsResp.result!);
      if (groups.byGroup('vio') == null) return;
      final groupResp = await client.getTagGroup('vio');
      if (!groupResp.ok || groupResp.result == null) return;
      final group = HubTagGroupData.fromResult(groupResp.result!);
      if (group.tags.isEmpty) return;
      ModuleStore.shared.update(widget.module.id, (m) {
        m.virtualTags = [
          for (final record in group.tags) record.toVirtualTag(),
        ];
      });
    } catch (e, st) {
      debugPrint('HubControlScreen: vio tag fetch failed: $e\n$st');
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
      } else if (_noteAuthRequired(response)) {
        return;
      }
    } catch (e, st) {
      debugPrint('HubControlScreen: get_dashboard failed: $e\n$st');
    }
  }

  /// Reacts to a mid-session `authentication_required` (the Hub drops the
  /// login when the TLS session is replaced): flips the screen to the login
  /// card instead of retrying commands on the unauthenticated session.
  /// Returns true when the response was an auth-required rejection.
  bool _noteAuthRequired(HubCommandResponse response) {
    if (response.ok || response.error != 'authentication_required') {
      return false;
    }
    if (!_needsLogin) {
      _needsLogin = true;
      if (mounted) setState(() {});
    }
    return true;
  }

  /// Interactive hub login (the TLS login contract's manual path): collects
  /// the Hub's web administrator credentials, authenticates the live
  /// session inside the dialog and stores them in the OS secure credential
  /// store when "remember" is checked. A failed login stays in the dialog
  /// (the Hub locks accounts after repeated failures, so nothing
  /// auto-retries). Credential values never reach the logs.
  ///
  /// The dialog is a self-owned [StatefulWidget] ([_HubLoginDialog]) so its
  /// text controllers live exactly as long as the dialog's widget subtree -
  /// disposing them right after [showDialog] completes raced with the exit
  /// animation and crashed the element tree
  /// (`_dependents.isEmpty is not true`).
  Future<void> _showHubLoginDialog() async {
    final client = _hubClient;
    if (client == null || !client.isConnected) {
      _showToast('Connect to the Hub first');
      unawaited(_refresh());
      return;
    }
    final signedIn = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HubLoginDialog(
        client: client,
        moduleId: widget.module.id,
        initialError: _loginError,
      ),
    );
    if (signedIn != true || !mounted) return;

    // Interactive login succeeded: drop the login state and load the hub
    // data on the now-authenticated session.
    _needsLogin = false;
    _loginError = null;
    final module =
        ModuleStore.shared.byId(widget.module.id) ?? widget.module;
    await _loadHubData(client, module);
    if (mounted) setState(() {});
  }

  void _syncToStore() {
    final dash = _dashboard;
    if (dash == null) return;
    final totalChannels = dash.outputs.length + dash.modbusOutputs.length;
    ModuleStore.shared.update(widget.module.id, (m) {
      m.status = ConnectionStatus.online;
      m.lastSeenAt = DateTime.now();
      while (m.channels.length < totalChannels) {
        final isModbus = m.channels.length >= dash.outputs.length;
        m.channels.add(ChannelOutput(
          id: '${m.id}h${m.channels.length}',
          name: isModbus ? 'Modbus Output ${m.channels.length - dash.outputs.length + 1}' : 'Output ${m.channels.length + 1}',
          icon: Icons.electrical_services,
          isModbusPower: isModbus,
        ));
      }
      if (m.channels.length > totalChannels) {
        m.channels.removeRange(totalChannels, m.channels.length);
      }
      for (int i = 0; i < dash.outputs.length && i < m.channels.length; i++) {
        final state = dash.outputs[i];
        m.channels[i].name = state.name.isNotEmpty
            ? state.name
            : m.channels[i].name;
        m.channels[i].isOn = state.state;
        m.channels[i].isModbusPower = false;
      }
      for (int i = 0; i < dash.modbusOutputs.length && i + dash.outputs.length < m.channels.length; i++) {
        final state = dash.modbusOutputs[i];
        final ci = dash.outputs.length + i;
        m.channels[ci].name = state.name.isNotEmpty
            ? state.name
            : 'Modbus Output ${i + 1}';
        m.channels[ci].isOn = state.state;
        m.channels[ci].isModbusPower = true;
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
      if (_noteAuthRequired(response)) return;
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
      await Future.delayed(const Duration(milliseconds: 1500));
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
      if (_noteAuthRequired(response)) return;
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
      await Future.delayed(const Duration(milliseconds: 2000));
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
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            // Action buttons row.
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: l10n.relayRefreshTooltip,
                    onPressed: _refresh),
                IconButton(
                    icon: const Icon(Icons.receipt_long_outlined),
                    tooltip: l10n.systemLogTooltip,
                    onPressed: () => showSystemLogScreen(
                        context, module)),
                IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _editModuleInfo),
              ],
            ),
            const SizedBox(height: 8),
            ModuleStatusHeader(module: module),

            // Hub login required (TLS login contract): control commands are
            // withheld until the user signs in - the unauthenticated
            // session is never polled (doc §"Connection sequence").
            if (_needsLogin) ...[
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Hub sign-in required',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer)),
                      const SizedBox(height: 4),
                      Text(
                        _loginError ??
                            'Sign in with the Hub administrator account to '
                                'send commands (stored in the OS secure '
                                'credential store).',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _showHubLoginDialog,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ],

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

            if (module.virtualTags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.hubVirtualTagsTitle,
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      for (final tag in module.virtualTags)
                        _infoRow(
                            (tag.name == null || tag.name!.isEmpty)
                                ? tag.tagName
                                : tag.name!,
                            tag.value, onSurface),
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
                        onPressed: turnOffDisabled ? null : onPulse,
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

/// The interactive Hub sign-in dialog (TLS login contract, doc/
/// Soleux_Mobile_Control_API_TLS_Integration.md §"Login and commands").
///
/// Owns its text controllers so they live exactly as long as the dialog's
/// widget subtree: the route stays mounted through the exit animation, and
/// disposing controllers when [State.dispose] runs (after the animation) is
/// what keeps the element tree consistent. Authenticates against the live
/// session and pops `true` only on success; a rejected login stays in the
/// dialog without auto-retry (the Hub locks accounts after repeated
/// failures).
class _HubLoginDialog extends StatefulWidget {
  const _HubLoginDialog({
    required this.client,
    required this.moduleId,
    this.initialError,
  });

  final HubJsonProtocol client;
  final String moduleId;

  /// The stored-credential rejection message shown until the first
  /// interactive attempt (never contains credentials).
  final String? initialError;

  @override
  State<_HubLoginDialog> createState() => _HubLoginDialogState();
}

class _HubLoginDialogState extends State<_HubLoginDialog> {
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _remember = true;
  bool _signingIn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error =
          'Enter the Hub administrator username and password.');
      return;
    }
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      final response = await widget.client.authenticate(username, password);
      if (response.ok) {
        if (_remember) {
          await HubCredentialStore.shared.save(
            widget.moduleId,
            HubCredentials(username: username, password: password),
          );
        }
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _error =
            'The Hub rejected the credentials (${response.error ?? 'login failed'}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _error = 'Login failed: could not reach the Hub login.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // scrollable: the keyboard's view insets shrink the dialog's max height;
    // without scrolling the content (error + 2 fields + remember checkbox)
    // overflows the bottom by tens of pixels when the keyboard is up.
    return AlertDialog(
      title: const Text('Hub sign-in'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: 'Username'),
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _signIn(),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _remember,
            onChanged: (value) => setState(() => _remember = value ?? true),
            title: const Text('Remember on this device'),
            subtitle: const Text('Stored in the OS secure credential store'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              _signingIn ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _signingIn ? null : _signIn,
          child: _signingIn
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign in'),
        ),
      ],
    );
  }
}