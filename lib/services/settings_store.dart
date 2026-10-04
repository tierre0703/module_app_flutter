// lib/services/settings_store.dart
//
// App-wide persistence for user preferences via shared_preferences:
//   - Notifications: toggles for offline / output-left-on / temperature /
//     automation-triggered alerts.
//   - Language: the active Locale (en / ro).
//   - Appearance: the active ThemeMode (light / dark / system) and the
//     Home theme palette (HomeThemeId).
//   - Command protocol: whether Control API commands use the persistent TCP
//     session (the Control API port, 5008 by default) or the stateless
//     HTTP/HTTPS POST /api/v1/command endpoint
//     (doc/Soleux_Control_API_Command_Specification_v0.2.md §"Transport
//     mapping").
//
// The theme / locale / palette values are also mirrored onto the global
// ValueNotifiers (themeModeNotifier, appLocaleNotifier, homeThemeIdNotifier)
// so MaterialApp and every screen rebuild immediately. Notification toggles
// and the command protocol are exposed here as a ChangeNotifier so the
// Settings screens can bind to them instead of local widget state.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../theme/theme_palettes.dart';

/// How the app talks to the Soleux Control API on the wire
/// (doc/Soleux_Control_API_Command_Specification_v0.2.md §"Transport mapping").
enum CommandTransportMode {
  /// Persistent JSON TCP session on the Control API port (5008 by default).
  /// Receives pushed state changes on the same socket.
  tcp,

  /// Stateless `POST /api/v1/command` over HTTP port 80.
  http,

  /// Stateless `POST /api/v1/command` over HTTPS port 443 (SSL enabled).
  https,
}

extension CommandTransportModeX on CommandTransportMode {
  /// Short stable identifier for logs and diagnostics.
  String get label => switch (this) {
        CommandTransportMode.tcp => 'tcp',
        CommandTransportMode.http => 'http',
        CommandTransportMode.https => 'https',
      };

  /// Human-readable summary of the endpoint the mode drives.
  String get description => switch (this) {
        CommandTransportMode.tcp => 'TCP port 5008',
        CommandTransportMode.http => 'HTTP port 80',
        CommandTransportMode.https => 'HTTPS port 443',
      };
}

class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  /// App-wide shared instance used by the launch path and Settings screens.
  static SettingsStore shared = SettingsStore._();

  /// Creates an isolated store for tests (backed by the same persistence).
  @visibleForTesting
  static SettingsStore forTesting() => SettingsStore._();

  SharedPreferences? _prefs;
  bool _loaded = false;

  // Notification preferences (ChangeNotifier-exposed so the notifications
  // screen rebuilds when they change).
  bool _moduleStatus = true;
  bool _outputLeftOn = true;
  bool _temperature = true;
  bool _automationTriggered = false;
  bool _firmwareUpdate = false;

  /// Which Control API command transport the app uses (TCP 5008 by default).
  CommandTransportMode _commandTransport = CommandTransportMode.tcp;

  /// Active location this build manages. The app is single-location for now
  /// (see the Settings "Location" section), but the id/name are persisted so
  /// the backup/restore flow can round-trip them and a future multi-location
  /// build can migrate.
  String _locationId = 'single-location';
  String _locationName = '';

  /// Default temperature alert threshold (°C) applied to newly added
  /// modules. Configured on the Settings -> Notifications screen.
  double _defaultTempThreshold = 65;

  /// Number of hours an output must remain ON before the "Output left ON too
  /// long" alert fires. Configured on the Settings -> Notifications screen.
  int _outputOnThresholdHours = 12;

  /// True once [init] has completed (successfully or not).
  bool get loaded => _loaded;

  bool get moduleStatus => _moduleStatus;
  bool get outputLeftOn => _outputLeftOn;
  bool get temperature => _temperature;
  bool get automationTriggered => _automationTriggered;
  bool get firmwareUpdate => _firmwareUpdate;

  /// The Control API command transport in use (TCP 5008 default; HTTP/HTTPS
  /// POST /api/v1/command selectable in Settings).
  CommandTransportMode get commandTransport => _commandTransport;

  /// Persistent id of the active location.
  String get locationId => _locationId;

  /// Display name of the active location. Empty means the build default is
  /// shown (see the Settings "Location" row).
  String get locationName => _locationName;

  /// The default temperature alert threshold (°C) for new modules.
  double get defaultTemperatureThreshold => _defaultTempThreshold;

  /// Number of hours an output must stay ON before the "Output left ON too
  /// long" alert fires.
  int get outputOnThresholdHours => _outputOnThresholdHours;

  static const String _kKeyThemeMode = 'settings_theme_mode';
  static const String _kKeyLocale = 'settings_locale';
  static const String _kKeyHomeTheme = 'settings_home_theme';
  static const String _kKeyModuleStatus = 'settings_notify_module_status';
  static const String _kKeyOutputLeftOn = 'settings_notify_output_left_on';
  static const String _kKeyTemperature = 'settings_notify_temperature';
  static const String _kKeyAutomation = 'settings_notify_automation';
  static const String _kKeyDefaultTempThreshold =
      'settings_default_temp_threshold';
  static const String _kKeyOutputOnThresholdHours =
      'settings_output_on_threshold_hours';
  static const String _kKeyCommandTransport = 'settings_command_transport';
  static const String _kKeyFirmwareUpdate = 'settings_notify_firmware_update';
  static const String _kKeyLocationId = 'settings_location_id';
  static const String _kKeyLocationName = 'settings_location_name';

  /// Loads all saved preferences once and applies them to the global
  /// notifiers. Safe to call repeatedly.
  Future<void> init() async {
    if (_loaded) return;
    try {
      _prefs = await SharedPreferences.getInstance();

      themeModeNotifier.value =
          ThemeMode.values.asNameMap()[_prefs!.getString(_kKeyThemeMode)] ??
              themeModeNotifier.value;

      final code = _prefs!.getString(_kKeyLocale);
      if (code != null && code.isNotEmpty) {
        appLocaleNotifier.value = Locale(code);
      }

      homeThemeIdNotifier.value =
          HomeThemeId.values.asNameMap()[_prefs!.getString(_kKeyHomeTheme)] ??
              homeThemeIdNotifier.value;

      _moduleStatus = _prefs!.getBool(_kKeyModuleStatus) ?? true;
      _outputLeftOn = _prefs!.getBool(_kKeyOutputLeftOn) ?? true;
      _temperature = _prefs!.getBool(_kKeyTemperature) ?? true;
      _automationTriggered = _prefs!.getBool(_kKeyAutomation) ?? false;
      _firmwareUpdate = _prefs!.getBool(_kKeyFirmwareUpdate) ?? false;
      _defaultTempThreshold =
          _prefs!.getDouble(_kKeyDefaultTempThreshold) ?? 65;
      _outputOnThresholdHours =
          _prefs!.getInt(_kKeyOutputOnThresholdHours) ?? 12;
      _commandTransport = CommandTransportMode.values
              .asNameMap()[_prefs!.getString(_kKeyCommandTransport)] ??
          CommandTransportMode.tcp;
      _locationId = _prefs!.getString(_kKeyLocationId) ?? 'single-location';
      _locationName = _prefs!.getString(_kKeyLocationName) ?? '';
    } catch (e, st) {
      debugPrint('SettingsStore: loading preferences failed: $e\n$st');
      // Keep defaults if preferences are unavailable.
    }
    _loaded = true;
    notifyListeners();
  }

  // ---- Appearance ---------------------------------------------------------

  /// Sets the active [ThemeMode] and persists it.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeModeNotifier.value = mode;
    await _prefs?.setString(_kKeyThemeMode, mode.name);
  }

  /// Sets the active [Locale] and persists it.
  Future<void> setLocale(Locale locale) async {
    appLocaleNotifier.value = locale;
    await _prefs?.setString(_kKeyLocale, locale.languageCode);
  }

  /// Sets the active Home [HomeThemeId] palette and persists it.
  Future<void> setHomeTheme(HomeThemeId id) async {
    homeThemeIdNotifier.value = id;
    await _prefs?.setString(_kKeyHomeTheme, id.name);
  }

  // ---- Notifications ------------------------------------------------------

  /// Sets whether offline / temperature alerts are enabled and persists it.
  Future<void> setModuleStatus(bool value) {
    _moduleStatus = value;
    return _persistAndNotify();
  }

  Future<void> setOutputLeftOn(bool value) {
    _outputLeftOn = value;
    return _persistAndNotify();
  }

  Future<void> setTemperature(bool value) {
    _temperature = value;
    return _persistAndNotify();
  }

  Future<void> setAutomationTriggered(bool value) {
    _automationTriggered = value;
    return _persistAndNotify();
  }

  Future<void> setFirmwareUpdate(bool value) {
    _firmwareUpdate = value;
    return _persistAndNotify();
  }

  /// Sets the default temperature alert threshold (°C) for new modules,
  /// clamped to a sensible 0-100 range, and persists it.
  Future<void> setDefaultTemperatureThreshold(double value) {
    _defaultTempThreshold = value.clamp(0, 100).toDouble();
    return _persistAndNotify();
  }

  /// Sets the number of hours an output must stay ON before the "Output
  /// left ON too long" alert fires, clamped to 1-168 (one week), and
  /// persists it.
  Future<void> setOutputOnThresholdHours(int value) {
    _outputOnThresholdHours = value.clamp(1, 168);
    return _persistAndNotify();
  }

  // ---- Command protocol ---------------------------------------------------

  /// Sets the Control API command transport (TCP 5008, HTTP 80 or HTTPS 443)
  /// and persists it. Newly-created module sessions honour the selection.
  Future<void> setCommandTransport(CommandTransportMode mode) {
    _commandTransport = mode;
    return _persistAndNotify();
  }

  // ---- Location -----------------------------------------------------------

  /// Records the active location and persists it. Used by the backup/restore
  /// flow and the Settings "Location" row.
  Future<void> setLocation({required String id, required String name}) {
    _locationId = id;
    _locationName = name;
    return _persistAndNotify();
  }

  Future<void> _persistAndNotify() async {
    await _prefs?.setBool(_kKeyModuleStatus, _moduleStatus);
    await _prefs?.setBool(_kKeyOutputLeftOn, _outputLeftOn);
    await _prefs?.setBool(_kKeyTemperature, _temperature);
    await _prefs?.setBool(_kKeyAutomation, _automationTriggered);
    await _prefs?.setBool(_kKeyFirmwareUpdate, _firmwareUpdate);
    await _prefs?.setDouble(_kKeyDefaultTempThreshold, _defaultTempThreshold);
    await _prefs?.setInt(_kKeyOutputOnThresholdHours, _outputOnThresholdHours);
    await _prefs?.setString(_kKeyCommandTransport, _commandTransport.name);
    await _prefs?.setString(_kKeyLocationId, _locationId);
    await _prefs?.setString(_kKeyLocationName, _locationName);
    notifyListeners();
  }
}
