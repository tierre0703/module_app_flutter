// lib/models/models.dart
//
// Plain Dart data classes used by the static UI prototype. There is no
// backend, database, or network layer behind these models - screens create
// and mutate local copies in-memory only (see lib/data/mock_data.dart).
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

/// Seven modern preset colors offered for a scenario's background. Selecting
/// one makes the scenario's Home quick-access card render with that color.
const List<Color> kScenarioBackgroundPresets = [
  Color(0xFF3949AB), // Indigo
  Color(0xFF0288D1), // Sky blue
  Color(0xFF00897B), // Teal
  Color(0xFF43A047), // Green
  Color(0xFFEF6C00), // Amber
  Color(0xFFE91E63), // Pink
  Color(0xFF7B1FA2), // Purple
];

/// The five dedicated hardware module types described in the brief
/// (section 2.3 "Extended Control Types").
enum ModuleType { relay, blind, dimmerDc, dimmerAc, temperature }

extension ModuleTypeX on ModuleType {
  String get label {
    switch (this) {
      case ModuleType.relay:
        return 'Standard Relay';
      case ModuleType.blind:
        return 'Blind Motor Control';
      case ModuleType.dimmerDc:
        return 'Lighting Dimmer (DC)';
      case ModuleType.dimmerAc:
        return 'Lighting Dimmer (AC)';
      case ModuleType.temperature:
        return 'Temperature Module';
    }
  }

  IconData get icon {
    switch (this) {
      case ModuleType.relay:
        return Icons.electrical_services;
      case ModuleType.blind:
        return Icons.blinds;
      case ModuleType.dimmerDc:
        return Icons.tune;
      case ModuleType.dimmerAc:
        return Icons.tune;
      case ModuleType.temperature:
        return Icons.thermostat;
    }
  }
}

/// Connection / availability indicator shown throughout the app: green
/// (online), amber (suspect - heartbeat failing but not yet offline) or red
/// (offline).
enum ConnectionStatus { online, suspect, offline }

/// Input field behaviour - the Control API `set_input_configuration` `mode`
/// (momentary | maintained | pulse), see
/// doc/Soleux_Control_API_Command_Specification_v0.3.md §3.3.
enum InputMode { momentary, maintained, pulse }

extension InputModeX on InputMode {
  String get label {
    switch (this) {
      case InputMode.momentary:
        return 'Momentary';
      case InputMode.maintained:
        return 'Maintained';
      case InputMode.pulse:
        return 'Pulse';
    }
  }

  String get description {
    switch (this) {
      case InputMode.momentary:
        return 'The action is executed only while the button is pressed.';
      case InputMode.maintained:
        return 'The state stays ON until the button is pressed again.';
      case InputMode.pulse:
        return 'A press pulses the input for a fixed duration, then releases it.';
    }
  }
}

/// Scenario kinds - brief section 2.4.
enum ScenarioType { tapToRun, manualSlider }

/// Smart automation trigger kinds - brief section 2.4.
enum AutomationTriggerType { time, deviceState }

/// A room / zone used to group modules and scenarios (brief section 2.5).
class Room {
  Room({required this.id, required this.name});

  final String id;
  String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory Room.fromJson(Map<String, Object?> json) =>
      Room(id: json['id'] as String, name: json['name'] as String? ?? '');
}

/// Where an output settles after the module powers up / restarts
/// (Control API `set_output_configuration` `initial_state`).
enum OutputInitialState {
  on,
  off,
  lastState;

  /// Parses any device-reported representation (`off`/`on`/`restore`, legacy
  /// ints or an absent field) into [OutputInitialState]; anything that is not
  /// an explicit `on`/`off` degrades to the default [OutputInitialState.lastState].
  static OutputInitialState fromWire(Object? raw) =>
      switch (raw?.toString().toLowerCase()) {
        'on' => OutputInitialState.on,
        'off' => OutputInitialState.off,
        _ => OutputInitialState.lastState,
      };
}

extension OutputInitialStateX on OutputInitialState {
  /// Wire value for `set_output_configuration` `initial_state`. Null means
  /// the parameter is omitted, which leaves the module in [lastState] - i.e.
  /// it restores the state it had before the restart.
  String? get wireValue => switch (this) {
        OutputInitialState.on => 'on',
        OutputInitialState.off => 'off',
        OutputInitialState.lastState => null,
      };
}

/// A single output/channel on a module (relay output, dimmer channel or
/// blind direction pair).
class ChannelOutput {
  ChannelOutput({
    required this.id,
    required this.name,
    required this.icon,
    this.isOn = false,
    this.brightness = 0,
    this.enabled = true,
    this.stepSize = 1,
    this.initialState = OutputInitialState.lastState,
  });

  final String id;
  String name;
  IconData icon;

  /// Relay / blind ON state.
  bool isOn;

  /// Dimmer brightness percentage, 0-100 (0 = OFF, 100 = fully ON).
  int brightness;

  /// Brightness step size (0-100) this output's dimmer slider moves in;
  /// pulled from the device's `output_off_delay` (default 1).
  int stepSize;

  /// Whether the output is shown / controllable on the module screen.
  bool enabled;

  /// State the output settles in after the module starts (`initial_state`).
  OutputInitialState initialState;

  /// [stepSize] clamped to a usable slider range.
  int get effectiveStepSize =>
      stepSize < 1 ? 1 : (stepSize > 100 ? 100 : stepSize);

  /// Number of discrete brightness stops a 0-100 slider needs to move in
  /// [effectiveStepSize] increments.
  int get brightnessSliderDivisions =>
      (100 ~/ effectiveStepSize).clamp(1, 100).toInt();

  /// Rounds a raw brightness percentage to the nearest [effectiveStepSize]
  /// multiple, clamped to 0-100.
  int snapBrightness(int value) =>
      ((value / effectiveStepSize).round() * effectiveStepSize)
          .clamp(0, 100)
          .toInt();

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'icon': iconToJson(icon),
        'isOn': isOn,
        'brightness': brightness,
        'stepSize': stepSize,
        'enabled': enabled,
        'initialState': initialState.name,
      };

  factory ChannelOutput.fromJson(Map<String, Object?> json) => ChannelOutput(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: iconFromJson(json['icon']),
        isOn: json['isOn'] as bool? ?? false,
        brightness: json['brightness'] as int? ?? 0,
        stepSize: (json['stepSize'] as num?)?.toInt() ?? 1,
        enabled: json['enabled'] as bool? ?? true,
        initialState: OutputInitialState.fromWire(json['initialState']),
      );
}

/// Const icons that can be persisted to JSON and rebuilt at runtime.
///
/// [IconData] must only be constructed from const glyph arguments for the
/// release build's icon tree-shaker to work; a runtime `IconData(...)` call
/// fails AOT compilation. Persisted JSON therefore references entries of this
/// registry (by name) instead of raw glyph codepoints. Keep in sync with
/// `kChannelIconChoices` in lib/data/mock_data.dart plus module default icons.
const Map<String, IconData> kPersistableIcons = {
  'lightbulb': Icons.lightbulb,
  'lightbulb_outline': Icons.lightbulb_outline,
  'light': Icons.light,
  'nightlight_round': Icons.nightlight_round,
  'wb_incandescent': Icons.wb_incandescent,
  'wb_sunny_outlined': Icons.wb_sunny_outlined,
  'tv': Icons.tv,
  'kitchen': Icons.kitchen,
  'water_drop': Icons.water_drop,
  'water': Icons.water,
  'ac_unit': Icons.ac_unit,
  'blinds': Icons.blinds,
  'deck': Icons.deck,
  'anchor': Icons.anchor,
  'directions_boat': Icons.directions_boat,
  'power': Icons.power,
  'electrical_services': Icons.electrical_services,
  'outdoor_grill': Icons.outdoor_grill,
  'garage': Icons.garage,
  'emoji_objects': Icons.emoji_objects,
  'tune': Icons.tune,
  'thermostat': Icons.thermostat,
  'touch_app': Icons.touch_app_outlined,
};

Map<int, IconData>? _iconByCodePoint;

Map<int, IconData> get _iconByCodePointMap => _iconByCodePoint ??= {
      for (final icon in kPersistableIcons.values) icon.codePoint: icon,
    };

/// Encodes an [IconData] for JSON storage (stable name + glyph codepoint).
Map<String, Object?> iconToJson(IconData icon) {
  String? name;
  for (final entry in kPersistableIcons.entries) {
    if (entry.value.codePoint == icon.codePoint &&
        entry.value.fontFamily == icon.fontFamily) {
      name = entry.key;
      break;
    }
  }
  return {
    'name': name,
    'fontFamily': icon.fontFamily,
    'codePoint': icon.codePoint
  };
}

/// Rebuilds an [IconData] from the JSON produced by [iconToJson].
///
/// Looks icons up from const [kPersistableIcons] so no runtime
/// `IconData(...)` constructor is emitted (required by the icon tree-shaker).
IconData iconFromJson(Object? json) {
  if (json is! Map) return Icons.power;
  final byName = kPersistableIcons[json['name'] as String?];
  if (byName != null) return byName;
  final codePoint = (json['codePoint'] as num?)?.toInt();
  if (codePoint != null) return _iconByCodePointMap[codePoint] ?? Icons.power;
  return Icons.power;
}

/// An input field shown on a module screen: pressing-and-holding its action
/// button drives the associated virtual input (`set_virtual_input_state`), and
/// its configuration (name / behaviour / enabled) is pushed with
/// `set_input_configuration`.
class PhysicalInput {
  PhysicalInput({
    required this.id,
    required this.name,
    this.mode = InputMode.momentary,
    this.enabled = true,
    this.state = false,
  });

  final String id;
  String name;
  InputMode mode;

  /// When false the input is hidden from its module screen.
  bool enabled;

  /// Live input state (`input_state_changed` device event / `IN:<ch>:<ON|OFF>`),
  /// shown as an indicator on the module screen.
  bool state;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'mode': mode.name,
        'enabled': enabled,
        'state': state,
      };

  factory PhysicalInput.fromJson(Map<String, Object?> json) => PhysicalInput(
        id: json['id'] as String,
        name: (json['name'] ?? json['label']) as String? ?? 'Switch',
        mode: _inputModeFromJson(json['mode']),
        enabled: json['enabled'] as bool? ?? true,
        state: json['state'] as bool? ?? false,
      );

  /// Maps a persisted `mode` value to [InputMode], tolerating the legacy
  /// `toggle` / `associated` values so old saved data still loads.
  static InputMode _inputModeFromJson(Object? raw) => switch (raw) {
        'momentary' => InputMode.momentary,
        'maintained' => InputMode.maintained,
        'pulse' => InputMode.pulse,
        'toggle' || 'associated' => InputMode.maintained,
        _ => InputMode.momentary,
      };
}

/// Network/LAN+Wi-Fi info reported by `get_device_state` `result.network`.
class DeviceNetworkInfo {
  const DeviceNetworkInfo({
    this.lanIp = '',
    this.lanGateway = '',
    this.lanSubnet = '',
    this.wifiSsid = '',
    this.wifiIp = '',
    this.wifiSubnet = '',
    this.wifiGateway = '',
  });

  final String lanIp;
  final String lanGateway;
  final String lanSubnet;
  final String wifiSsid;
  final String wifiIp;
  final String wifiSubnet;
  final String wifiGateway;

  factory DeviceNetworkInfo.fromJson(Map<String, dynamic> json) =>
      DeviceNetworkInfo(
        lanIp: json['lan_ip'] as String? ?? '',
        lanGateway: json['lan_gateway'] as String? ?? '',
        lanSubnet: json['lan_subnet'] as String? ?? '',
        wifiSsid: json['wifi_ssid'] as String? ?? '',
        wifiIp: json['wifi_ip'] as String? ?? '',
        wifiSubnet: json['wifi_subnet'] as String? ?? '',
        wifiGateway: json['wifi_gateway'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {
        'lan_ip': lanIp,
        'lan_gateway': lanGateway,
        'lan_subnet': lanSubnet,
        'wifi_ssid': wifiSsid,
        'wifi_ip': wifiIp,
        'wifi_subnet': wifiSubnet,
        'wifi_gateway': wifiGateway,
      };
}

/// Full system snapshot reported by `get_device_state` `result.system`
/// (+ `result.network`), held on [DeviceModule.systemInfo] so screens can show
/// CPU/memory/temperature/uptime and network details from the live device.
class DeviceSystemInfo {
  const DeviceSystemInfo({
    this.cpuUsagePercent,
    this.uptime,
    this.memoryUsagePercent,
    this.cpuTempC,
    this.internalTempC,
    this.externalTempC,
    this.time,
    this.network,
  });

  /// CPU load, percent (0-100).
  final double? cpuUsagePercent;

  /// Human-readable uptime string, e.g. `75294 seconds`.
  final String? uptime;

  /// Memory load, percent (may be reported as a string, e.g. `19.35`).
  final double? memoryUsagePercent;

  /// Processor temperature (°C).
  final double? cpuTempC;

  /// Internal (enclosure) temperature (°C).
  final double? internalTempC;

  /// External/sensor temperature (°C), when the device exposes one.
  final double? externalTempC;

  /// Device clock time, e.g. `2026/09/09 15:44:42`.
  final String? time;

  /// LAN/Wi-Fi addressing info.
  final DeviceNetworkInfo? network;

  /// Builds the snapshot from the top-level `get_device_state` result: reads
  /// `result.system` for the system fields and `result.network` for addressing.
  factory DeviceSystemInfo.fromJson(Map<String, dynamic> result) {
    final system = result['system'] is Map
        ? Map<String, dynamic>.from(result['system'] as Map)
        : const <String, dynamic>{};
    final network = result['network'] is Map
        ? Map<String, dynamic>.from(result['network'] as Map)
        : null;
    return DeviceSystemInfo(
      cpuUsagePercent: _tempFrom(system['cpu_usage_percent']),
      uptime: system['uptime'] as String?,
      memoryUsagePercent: _tempFrom(system['memory_usage_percent']),
      cpuTempC: _tempFrom(system['cpu_temp_c']),
      internalTempC: _tempFrom(system['internal_temp_c']),
      externalTempC: _tempFrom(system['external_temp_c']),
      time: system['time'] as String?,
      network: network == null ? null : DeviceNetworkInfo.fromJson(network),
    );
  }

  Map<String, Object?> toJson() => {
        'system': {
          if (cpuUsagePercent != null) 'cpu_usage_percent': cpuUsagePercent,
          if (uptime != null) 'uptime': uptime,
          if (memoryUsagePercent != null)
            'memory_usage_percent': memoryUsagePercent,
          if (cpuTempC != null) 'cpu_temp_c': cpuTempC,
          if (internalTempC != null) 'internal_temp_c': internalTempC,
          if (externalTempC != null) 'external_temp_c': externalTempC,
          if (time != null) 'time': time,
        },
        if (network != null) 'network': network!.toJson(),
      };
}

/// Parses a temperature/percentage that the device may report as a number or a
/// numeric string, e.g. `3.8.7`-style invalid values degrade to null.
double? _tempFrom(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// A hardware module added to the system (brief section 2.1).
class DeviceModule {
  DeviceModule({
    required this.id,
    required this.name,
    required this.type,
    required this.ipAddress,
    required this.status,
    required this.roomName,
    required this.internalTempC,
    int tcpPort = 5005,
    this.tempMinC = 0,
    this.tempMaxC = 60,
    this.firmware,
    this.serial,
    this.mac,
    this.connectionType = 'local_network',
    this.apiPort,
    this.apiHttpPort,
    this.apiVersion,
    this.heartbeatPort,
    this.caps = const [],
    this.lastSeenAt,
    List<ChannelOutput>? channels,
    List<PhysicalInput>? inputs,
  })  : _tcpPort = tcpPort,
        channels = channels ?? <ChannelOutput>[],
        inputs = inputs ?? <PhysicalInput>[];

  final String id;
  String name;
  final ModuleType type;
  String ipAddress;

  /// Firmware/build reported by the module (e.g. `AT+VER` → `VER:`).
  String? firmware;

  /// Device serial number (identifies an individual physical device).
  String? serial;

  /// Ethernet MAC address (authoritative when reported by DCP).
  String? mac;

  /// How the client reaches this module: `local_network`, `remote`, or
  /// `cloud`. Null until set from the edit-module-info dialog.
  String? connectionType;

  /// Control API v3 TCP port when advertised by discovery (normally 5008).
  int? apiPort;

  /// Optional override of the Control API HTTP/HTTPS endpoint port
  /// (`POST /api/v1/command`). Defaults to 80 over HTTP and 443 over HTTPS per
  /// the Control API spec §"Transport mapping"; set it for development,
  /// testing or non-standard deployments.
  int? apiHttpPort;

  /// Highest advertised/negotiated Control API version (current 3).
  int? apiVersion;

  /// Advertised UDP heartbeat port (normally 5007). Null means the monitor
  /// derives it from [tcpPort] (`tcpPort + 2`).
  int? heartbeatPort;

  /// Advertised compact capability identifiers (`control_api_v3`, etc.).
  final List<String> caps;

  /// Last time the module answered a heartbeat pong (spec §4.2 `last_seen_at`).
  DateTime? lastSeenAt;

  /// UDP port heartbeat pings are directed at: advertised when present,
  /// otherwise the derived legacy `tcpPort + 2` (spec §3 endpoint selection).
  int get effectiveHeartbeatPort => heartbeatPort ?? tcpPort + 2;

  /// TCP port the module listens on (default 5005). Backed by a nullable
  /// field so legacy persisted JSON (or any null) degrades to the default.
  int? _tcpPort;
  int get tcpPort => _tcpPort ?? 5005;
  set tcpPort(int value) => _tcpPort = value;

  /// Control API TCP port used by the JSON Control API transport
  /// (doc/Soleux_Control_API_Command_Specification_v0.3.md §"Transport
  /// mapping"): the advertised [apiPort] when present, otherwise the legacy
  /// TCP port + 3 (`5005 -> 5008`). Per the discovery/heartbeat spec, when
  /// `API_PORT` is absent a client may probe `PORT + 3` but must complete the
  /// Control API `hello` exchange before treating the device as Control API.
  int get controlApiPort => apiPort ?? tcpPort + 3;

  /// Whether the module advertised the Control API transport (via discovery
  /// `API_PORT`/`API_VER`/`CAPS` or a heartbeat identity). Used to pick the
  /// Control API port and framing before a hello has been completed.
  bool get isControlApiAdvertised =>
      apiPort != null || apiVersion != null || caps.contains('control_api_v3');

  ConnectionStatus status;
  String roomName;

  /// Internal module temperature, monitored for every module type
  /// (brief section I, point 3).
  double internalTempC;
  double tempMinC;
  double tempMaxC;

  /// Full live `get_device_state` system/network snapshot, when the last
  /// refresh reported one. Used by module screens to show CPU/memory/temperature
  /// and network details.
  DeviceSystemInfo? systemInfo;

  final List<ChannelOutput> channels;
  final List<PhysicalInput> inputs;

  bool get isOverTemperature =>
      internalTempC > tempMaxC || internalTempC < tempMinC;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'ipAddress': ipAddress,
        'tcpPort': tcpPort,
        'status': status.name,
        'roomName': roomName,
        'internalTempC': internalTempC,
        'tempMinC': tempMinC,
        'tempMaxC': tempMaxC,
        'firmware': firmware,
        'serial': serial,
        'mac': mac,
        'connectionType': connectionType,
        'apiPort': apiPort,
        'apiHttpPort': apiHttpPort,
        'apiVersion': apiVersion,
        'heartbeatPort': heartbeatPort,
        'caps': caps,
        'lastSeenAt': lastSeenAt?.toIso8601String(),
        if (systemInfo != null) 'systemInfo': systemInfo!.toJson(),
        'channels': channels.map((c) => c.toJson()).toList(),
        'inputs': inputs.map((i) => i.toJson()).toList(),
      };

  factory DeviceModule.fromJson(Map<String, Object?> json) => DeviceModule(
        id: json['id'] as String,
        name: json['name'] as String,
        type: ModuleType.values.byName(json['type'] as String),
        ipAddress: json['ipAddress'] as String,
        tcpPort: (json['tcpPort'] as num?)?.toInt() ?? 5005,
        status: ConnectionStatus.values.byName(json['status'] as String),
        roomName: json['roomName'] as String? ?? 'Unassigned',
        internalTempC: (json['internalTempC'] as num?)?.toDouble() ?? 0,
        tempMinC: (json['tempMinC'] as num?)?.toDouble() ?? 0,
        tempMaxC: (json['tempMaxC'] as num?)?.toDouble() ?? 60,
        firmware: json['firmware'] as String?,
        serial: json['serial'] as String?,
        mac: json['mac'] as String?,
        connectionType: json['connectionType'] as String? ?? 'local_network',
        apiPort: (json['apiPort'] as num?)?.toInt(),
        apiHttpPort: (json['apiHttpPort'] as num?)?.toInt(),
        apiVersion: (json['apiVersion'] as num?)?.toInt(),
        heartbeatPort: (json['heartbeatPort'] as num?)?.toInt(),
        caps: [
          for (final c in json['caps'] as List? ?? const []) c as String,
        ],
        lastSeenAt: json['lastSeenAt'] == null
            ? null
            : DateTime.tryParse(json['lastSeenAt'] as String),
        channels: [
          for (final c in json['channels'] as List? ?? const [])
            ChannelOutput.fromJson((c as Map).cast<String, Object?>()),
        ],
        inputs: [
          for (final i in json['inputs'] as List? ?? const [])
            PhysicalInput.fromJson((i as Map).cast<String, Object?>()),
        ],
      )..systemInfo = json['systemInfo'] is Map
          ? DeviceSystemInfo.fromJson(
              (json['systemInfo'] as Map).cast<String, dynamic>())
          : null;
}

/// Desired state of an input action in a scenario: drive the virtual input
/// `true` (ON), `false` (OFF) or pulse it (`true`, then `false` after a short
/// delay).
enum InputActionState { on, off, pulse }

extension InputActionStateX on InputActionState {
  String get label => switch (this) {
        InputActionState.on => 'ON',
        InputActionState.off => 'OFF',
        InputActionState.pulse => 'Pulse',
      };
}

/// Resolves the [ChannelOutput] a manual-dimmer scenario's [Scenario.sliderTargetName]
/// points at. Target names use the `"<channel> - <module>"` format produced by
/// the scenario editor; returns null when no dimmer output matches.
ChannelOutput? dimmerTargetChannel(
    List<DeviceModule> modules, String targetName) {
  final ref = dimmerTargetRef(modules, targetName);
  if (ref == null) return null;
  return ref.$1.channels[ref.$2];
}

/// Resolves the owning module and zero-based channel index a manual-dimmer
/// scenario's [Scenario.sliderTargetName] points at, so `set_dimmer_level` can
/// be issued on the right output.
(DeviceModule, int)? dimmerTargetRef(
    List<DeviceModule> modules, String targetName) {
  for (final module in modules) {
    if (module.type != ModuleType.dimmerDc &&
        module.type != ModuleType.dimmerAc) {
      continue;
    }
    for (var i = 0; i < module.channels.length; i++) {
      final channel = module.channels[i];
      if ('${channel.name} - ${module.name}' == targetName) {
        return (module, i);
      }
    }
  }
  return null;
}

/// A single command executed by a scenario or automation.
class ScenarioAction {
  ScenarioAction({
    required this.moduleName,
    required this.channelName,
    required this.icon,
    required this.isDimmerAction,
    this.turnOn = true,
    this.brightnessPct = 100,
    this.isInputAction = false,
    this.inputName = '',
    this.inputState = InputActionState.on,
  });

  final String moduleName;
  final String channelName;
  final IconData icon;
  final bool isDimmerAction;
  final bool turnOn;
  final int brightnessPct;

  /// True when this action drives a virtual input instead of an output
  /// channel. When set, [channelName] is unused and [inputName]/[inputState]
  /// describe the target.
  final bool isInputAction;
  final String inputName;
  final InputActionState inputState;

  String get summary => isInputAction
      ? '$inputName -> ${inputState.label}'
      : isDimmerAction
          ? '$channelName -> $brightnessPct%'
          : '$channelName -> ${turnOn ? 'ON' : 'OFF'}';

  Map<String, Object?> toJson() => {
        'moduleName': moduleName,
        'channelName': channelName,
        'icon': iconToJson(icon),
        'isDimmerAction': isDimmerAction,
        'turnOn': turnOn,
        'brightnessPct': brightnessPct,
        'isInputAction': isInputAction,
        'inputName': inputName,
        if (isInputAction) 'inputState': inputState.name,
      };

  factory ScenarioAction.fromJson(Map<String, Object?> json) => ScenarioAction(
        moduleName: json['moduleName'] as String,
        channelName: json['channelName'] as String,
        icon: iconFromJson(json['icon']),
        isDimmerAction: json['isDimmerAction'] as bool? ?? false,
        turnOn: json['turnOn'] as bool? ?? true,
        brightnessPct: json['brightnessPct'] as int? ?? 100,
        isInputAction: json['isInputAction'] as bool? ?? false,
        inputName: json['inputName'] as String? ?? '',
        inputState: switch (json['inputState'] as String?) {
          'on' => InputActionState.on,
          'off' => InputActionState.off,
          'pulse' => InputActionState.pulse,
          _ => InputActionState.on,
        },
      );
}

/// A tap-to-run scenario or manual dimming slider (brief section 2.4).
class Scenario {
  Scenario({
    required this.id,
    required this.name,
    required this.icon,
    required this.type,
    this.roomName = 'General',
    this.showInHome = false,
    this.backgroundColor,
    List<ScenarioAction>? actions,
    this.sliderTargetName = '',
    this.sliderValue = 0,
  }) : actions = actions ?? <ScenarioAction>[];

  final String id;
  String name;
  IconData icon;
  ScenarioType type;
  String roomName;
  bool showInHome;

  /// Background color applied to the scenario's Home quick-access card.
  /// Null keeps the default themed surface.
  Color? backgroundColor;

  final List<ScenarioAction> actions;

  // Only used when [type] == ScenarioType.manualSlider.
  String sliderTargetName;
  int sliderValue;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'icon': iconToJson(icon),
        'type': type.name,
        'roomName': roomName,
        'showInHome': showInHome,
        'backgroundColor': backgroundColor?.toARGB32(),
        'actions': actions.map((a) => a.toJson()).toList(),
        'sliderTargetName': sliderTargetName,
        'sliderValue': sliderValue,
      };

  factory Scenario.fromJson(Map<String, Object?> json) => Scenario(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: iconFromJson(json['icon']),
        type: ScenarioType.values.byName(json['type'] as String),
        roomName: switch (json['roomName']) {
          null || 'No room' => 'General',
          final value => value as String,
        },
        showInHome: json['showInHome'] as bool? ?? false,
        backgroundColor: json['backgroundColor'] == null
            ? null
            : Color(json['backgroundColor'] as int),
        actions: [
          for (final a in json['actions'] as List? ?? const [])
            ScenarioAction.fromJson((a as Map).cast<String, Object?>()),
        ],
        sliderTargetName: json['sliderTargetName'] as String? ?? '',
        sliderValue: json['sliderValue'] as int? ?? 0,
      );
}

/// An IF...THEN... smart automation (brief section 2.4).
class Automation {
  Automation({
    required this.id,
    required this.name,
    required this.triggerType,
    required this.triggerSummary,
    this.enabled = true,
    this.scheduleHour,
    this.scheduleMinute,
    this.watchModuleName,
    this.watchIsInput = false,
    this.watchInputName,
    this.watchChannelName,
    this.watchState = true,
    List<ScenarioAction>? actions,
  }) : actions = actions ?? <ScenarioAction>[];

  final String id;
  String name;
  bool enabled;
  AutomationTriggerType triggerType;
  String triggerSummary;
  final List<ScenarioAction> actions;

  /// Hour of the daily time trigger (0-23). Only meaningful when
  /// [triggerType] == AutomationTriggerType.time; null falls back to 20:00.
  int? scheduleHour;

  /// Minute of the daily time trigger (0-59). Only meaningful when
  /// [triggerType] == AutomationTriggerType.time.
  int? scheduleMinute;

  /// Name of the module the device-state trigger watches. Only meaningful when
  /// [triggerType] == AutomationTriggerType.deviceState; null means "any
  /// module" (legacy automations saved before module selection existed).
  String? watchModuleName;

  /// Whether the device-state trigger watches a [PhysicalInput] (true) or a
  /// [ChannelOutput] (false).
  bool watchIsInput;

  /// [PhysicalInput] name watched by an input-based device-state trigger. Only
  /// meaningful when [triggerType] == AutomationTriggerType.deviceState and
  /// [watchIsInput] is true; use [watchChannelName] for output triggers.
  String? watchInputName;

  /// Output name watched by a device-state trigger. Only meaningful when
  /// [triggerType] == AutomationTriggerType.deviceState and [watchIsInput] is
  /// false.
  String? watchChannelName;

  /// The state change that fires the rule: true = fires when the watched
  /// target turns ON, false = fires when it turns OFF.
  bool watchState;

  /// Falls back to a sensible default (20:00) for time-triggered rules that
  /// predate structured scheduling data.
  int get effectiveScheduleHour => scheduleHour ?? 20;

  int get effectiveScheduleMinute => scheduleMinute ?? 0;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'triggerType': triggerType.name,
        'triggerSummary': triggerSummary,
        'scheduleHour': scheduleHour,
        'scheduleMinute': scheduleMinute,
        'watchModuleName': watchModuleName,
        'watchIsInput': watchIsInput,
        'watchInputName': watchInputName,
        'watchChannelName': watchChannelName,
        'watchState': watchState,
        'actions': actions.map((a) => a.toJson()).toList(),
      };

  factory Automation.fromJson(Map<String, Object?> json) => Automation(
        id: json['id'] as String,
        name: json['name'] as String,
        enabled: json['enabled'] as bool? ?? true,
        triggerType:
            AutomationTriggerType.values.byName(json['triggerType'] as String),
        triggerSummary: json['triggerSummary'] as String? ?? '',
        scheduleHour: (json['scheduleHour'] as num?)?.toInt(),
        scheduleMinute: (json['scheduleMinute'] as num?)?.toInt(),
        watchModuleName: json['watchModuleName'] as String?,
        watchIsInput: json['watchIsInput'] as bool? ?? false,
        watchInputName: json['watchInputName'] as String?,
        watchChannelName: json['watchChannelName'] as String?,
        watchState: json['watchState'] as bool? ?? true,
        actions: [
          for (final a in json['actions'] as List? ?? const [])
            ScenarioAction.fromJson((a as Map).cast<String, Object?>()),
        ],
      );
}

/// A column definition of the device's system log table
/// (`get_page_configuration` "system" page, `system_logs` section `columns`).
class SystemLogColumn {
  const SystemLogColumn({required this.key, required this.label});

  final String key;

  /// Localized (by the device) column header, e.g. "Date / Time".
  final String label;

  factory SystemLogColumn.fromJson(Map<String, dynamic> json) =>
      SystemLogColumn(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

/// A single row in the device's system log (`get_page_configuration` "system"
/// page, `system_logs` section `rows`).
class SystemLogEntry {
  const SystemLogEntry({
    required this.dateTime,
    required this.tag,
    required this.state,
    required this.note,
  });

  /// Device-formatted timestamp, e.g. `2026/09/17 17:25:26`.
  final String dateTime;

  /// Output/hardware identifier the event belongs to, e.g. `Out-1`.
  final String tag;

  /// Reported status string, e.g. `ON`.
  final String state;

  /// Human-readable event description, e.g. `Duty Set`.
  final String note;

  factory SystemLogEntry.fromJson(Map<String, dynamic> json) => SystemLogEntry(
        dateTime: json['date_time'] as String? ?? '',
        tag: json['tag'] as String? ?? '',
        state: json['state'] as String? ?? '',
        note: json['note'] as String? ?? '',
      );
}

/// One page of the device's system log, parsed from the `system_logs` section
/// of a `get_page_configuration` "system" page response.
class SystemLogPage {
  const SystemLogPage({
    required this.rows,
    required this.columns,
    required this.page,
    required this.pageSize,
    required this.totalPages,
    required this.totalCount,
  });

  final List<SystemLogEntry> rows;
  final List<SystemLogColumn> columns;

  /// Current one-based page number.
  final int page;

  /// Entries per page.
  final int pageSize;

  final int totalPages;

  /// Total entries available on the device.
  final int totalCount;

  /// Whether more pages remain after this one.
  bool get hasMore => page < totalPages;

  /// Parses the `system_logs` section out of a `get_page_configuration`
  /// "system" page result, or null when the section is absent.
  static SystemLogPage? fromResult(Map<String, dynamic>? result) {
    if (result == null) return null;
    final sections = result['sections'];
    if (sections is! List) return null;
    Map<String, dynamic>? logs;
    for (final raw in sections) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      if (map['key'] == 'system_logs') {
        logs = map;
        break;
      }
    }
    if (logs == null) return null;

    final rows = <SystemLogEntry>[];
    final rawRows = logs['rows'];
    if (rawRows is List) {
      for (final raw in rawRows) {
        if (raw is Map) {
          rows.add(SystemLogEntry.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }

    final columns = <SystemLogColumn>[];
    final rawColumns = logs['columns'];
    if (rawColumns is List) {
      for (final raw in rawColumns) {
        if (raw is Map) {
          columns.add(SystemLogColumn.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }

    return SystemLogPage(
      rows: rows,
      columns: columns,
      page: (logs['page'] as num?)?.toInt() ?? 1,
      pageSize: (logs['page_size'] as num?)?.toInt() ?? 10,
      totalPages: (logs['total_pages'] as num?)?.toInt() ?? 1,
      totalCount: (logs['total_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A single row in the 30-day event history (brief section 2.4).
class EventLogEntry {
  EventLogEntry(
      {required this.time, required this.title, required this.subtitle});

  final DateTime time;
  final String title;
  final String subtitle;

  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'title': title,
        'subtitle': subtitle,
      };

  factory EventLogEntry.fromJson(Map<String, Object?> json) => EventLogEntry(
        time: DateTime.parse(json['time'] as String),
        title: json['title'] as String,
        subtitle: json['subtitle'] as String? ?? '',
      );
}

/// The kind of notification history event (feed from ModuleStatusService,
/// firmware updates, etc.).
enum StatusLogType {
  offline,
  restored,
  firmware;

  String label(AppLocalizations l10n) => switch (this) {
        StatusLogType.offline => l10n.statusLogOffline,
        StatusLogType.restored => l10n.statusLogRestored,
        StatusLogType.firmware => l10n.statusLogFirmware,
      };
}

/// A single row in the Notification History (brief section I, point 2).
class StatusLogEntry {
  StatusLogEntry({
    required this.time,
    required this.type,
    required this.deviceName,
    required this.message,
  });

  final DateTime time;
  final StatusLogType type;

  /// Name of the device/module the event belongs to.
  final String deviceName;
  final String message;

  /// True for OFFLINE alerts, false for recovery events.
  bool get isAlert => type == StatusLogType.offline;

  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'type': type.name,
        'deviceName': deviceName,
        'message': message,
      };

  factory StatusLogEntry.fromJson(Map<String, Object?> json) => StatusLogEntry(
        time: DateTime.parse(json['time'] as String),
        type: StatusLogType.values.byName(json['type'] as String),
        deviceName: json['deviceName'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );
}
