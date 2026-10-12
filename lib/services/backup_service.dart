// lib/services/backup_service.dart
//
// Local backup & restore for the device-manager configuration. A backup is a
// single versioned JSON file (named
// `soleux_backup_<location>_v<version>_<timestamp>.json`, see
// [BackupService.fileNameFor]) that snapshots every piece of user
// configuration:
//
//   - settings            (theme / locale / palette / notification toggles /
//                          temperature threshold / command transport / custom
//                          scenario colors - see SettingsStore)
//   - location            (the active location id + name)
//   - rooms               (order preserving)
//   - scenarios           (tap-to-run + manual slider + their actions)
//   - modules             (device list incl. channels, inputs and identity)
//   - automations         (IF...THEN... rules)
//
// The file carries a semantic schema version (see [BackupVersion]). Restore
// offers two modes:
//
//   - [BackupRestoreMode.freshLoad] applies the backup verbatim; and
//   - [BackupRestoreMode.migrate] first walks the backup through the
//     [_migrations] chain (one transformation per source major version) so an
//     older backup is upgraded to the current format before being applied.
//
// Backups produced by a newer major version than this build (major bump = a
// breaking format change) are rejected with [BackupFromFutureException].
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import '../theme/theme_palettes.dart';
import 'automation_store.dart';
import 'custom_color_store.dart';
import 'module_store.dart';
import 'room_store.dart';
import 'scenario_store.dart';
import 'settings_store.dart';

/// Semantic version of the backup file format. Bump [major] for any change
/// that makes older backups structurally incompatible (and add a migration in
/// [BackupService._migrations]); bump [minor] for backwards-compatible
/// additions.
class BackupVersion {
  const BackupVersion({required this.major, required this.minor});

  final int major;
  final int minor;

  /// Compares this version with [other]; primary on [major], secondary on
  /// [minor].
  int compareTo(BackupVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    return minor.compareTo(other.minor);
  }

  Map<String, dynamic> toJson() => {'major': major, 'minor': minor};

  factory BackupVersion.fromJson(Object? json) {
    if (json is! Map) return const BackupVersion(major: 0, minor: 0);
    final map = json.cast<String, dynamic>();
    return BackupVersion(
      major: (map['major'] as num?)?.toInt() ?? 0,
      minor: (map['minor'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() => '$major.$minor';

  @override
  bool operator ==(Object other) =>
      other is BackupVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);
}

/// How a restore should treat the loaded backup.
enum BackupRestoreMode {
  /// Applies the backup verbatim, ignoring any version difference (an older
  /// backup is loaded as-is).
  freshLoad,

  /// Runs the backup's version through the migration chain first, upgrading it
  /// to the current format, then applies it.
  migrate,
}

/// Parsed preferences section of a backup (see `SettingsStore` for field
/// semantics). Absent fields are `null` and are left untouched on restore.
class BackupSettings {
  const BackupSettings({
    this.themeMode,
    this.locale,
    this.homeTheme,
    this.commandTransport,
    this.moduleStatus,
    this.outputLeftOn,
    this.temperature,
    this.automationTriggered,
    this.firmwareUpdate,
    this.defaultTemperatureThreshold,
    this.outputOnThresholdHours,
    this.customColors = const [],
    this.raw = const {},
  });

  final ThemeMode? themeMode;
  final String? locale;
  final HomeThemeId? homeTheme;
  final CommandTransportMode? commandTransport;
  final bool? moduleStatus;
  final bool? outputLeftOn;
  final bool? temperature;
  final bool? automationTriggered;
  final bool? firmwareUpdate;
  final double? defaultTemperatureThreshold;
  final int? outputOnThresholdHours;

  /// Saved custom scenario colors as ARGB ints.
  final List<int> customColors;

  /// Fields from the backup file this build does not recognise. Preserved
  /// verbatim so the migration chain can rename/reshape them and a restore
  /// never silently drops data written by older or newer minor builds.
  final Map<String, dynamic> raw;

  static const Set<String> _knownKeys = {
    'themeMode',
    'locale',
    'homeTheme',
    'commandTransport',
    'moduleStatus',
    'outputLeftOn',
    'temperature',
    'automationTriggered',
    'firmwareUpdate',
    'defaultTemperatureThreshold',
    'outputOnThresholdHours',
    'customColors',
  };

  Map<String, dynamic> toJson() => {
        ...raw,
        if (themeMode != null) 'themeMode': themeMode!.name,
        if (locale != null) 'locale': locale,
        if (homeTheme != null) 'homeTheme': homeTheme!.name,
        if (commandTransport != null)
          'commandTransport': commandTransport!.name,
        if (moduleStatus != null) 'moduleStatus': moduleStatus,
        if (outputLeftOn != null) 'outputLeftOn': outputLeftOn,
        if (temperature != null) 'temperature': temperature,
        if (automationTriggered != null)
          'automationTriggered': automationTriggered,
        if (firmwareUpdate != null) 'firmwareUpdate': firmwareUpdate,
        if (defaultTemperatureThreshold != null)
          'defaultTemperatureThreshold': defaultTemperatureThreshold,
        if (outputOnThresholdHours != null)
          'outputOnThresholdHours': outputOnThresholdHours,
        if (customColors.isNotEmpty) 'customColors': customColors,
      };

  factory BackupSettings.fromJson(Object? json) {
    if (json is! Map) return const BackupSettings();
    final map = json.cast<String, dynamic>();
    final raw = <String, dynamic>{};
    for (final entry in map.entries) {
      if (!_knownKeys.contains(entry.key)) raw[entry.key] = entry.value;
    }
    return BackupSettings(
      themeMode: ThemeMode.values.asNameMap()[map['themeMode'] as String?],
      locale: map['locale'] as String?,
      homeTheme: HomeThemeId.values.asNameMap()[map['homeTheme'] as String?],
      commandTransport: CommandTransportMode.values
          .asNameMap()[map['commandTransport'] as String?],
      moduleStatus: map['moduleStatus'] as bool?,
      outputLeftOn: map['outputLeftOn'] as bool?,
      temperature: map['temperature'] as bool?,
      automationTriggered: map['automationTriggered'] as bool?,
      firmwareUpdate: map['firmwareUpdate'] as bool?,
      defaultTemperatureThreshold:
          (map['defaultTemperatureThreshold'] as num?)?.toDouble(),
      outputOnThresholdHours: (map['outputOnThresholdHours'] as num?)?.toInt(),
      customColors: [
        for (final c in map['customColors'] is List
            ? map['customColors'] as List
            : const <Object?>[])
          (c as num).toInt(),
      ],
      raw: raw,
    );
  }
}

/// Parsed location section of a backup.
class BackupLocation {
  const BackupLocation({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory BackupLocation.fromJson(Object? json) {
    if (json is! Map) {
      return const BackupLocation(id: 'single-location', name: '');
    }
    final map = json.cast<String, dynamic>();
    return BackupLocation(
      id: map['id'] as String? ?? 'single-location',
      name: map['name'] as String? ?? '',
    );
  }
}

/// A full parsed backup document. Holds the raw JSON of every section so it
/// can be re-serialized verbatim through the migration chain.
class BackupDocument {
  const BackupDocument({
    required this.schema,
    required this.exportedAt,
    required this.settings,
    required this.location,
    required this.rooms,
    required this.scenarios,
    required this.modules,
    required this.automations,
  });

  final BackupVersion schema;
  final DateTime? exportedAt;
  final BackupSettings settings;
  final BackupLocation location;
  final List<Room> rooms;
  final List<Scenario> scenarios;
  final List<DeviceModule> modules;
  final List<Automation> automations;

  Map<String, dynamic> toJson() => {
        'schema': schema.toJson(),
        if (exportedAt != null) 'exportedAt': exportedAt!.toIso8601String(),
        'settings': settings.toJson(),
        'location': location.toJson(),
        'rooms': [for (final r in rooms) r.toJson()],
        'scenarios': [for (final s in scenarios) s.toJson()],
        'modules': [for (final m in modules) m.toJson()],
        'automations': [for (final a in automations) a.toJson()],
      };

  factory BackupDocument.fromJson(Map<String, dynamic> json) => BackupDocument(
        schema: BackupVersion.fromJson(json['schema']),
        exportedAt: json['exportedAt'] == null
            ? null
            : DateTime.tryParse(json['exportedAt'] as String),
        settings: BackupSettings.fromJson(json['settings']),
        location: BackupLocation.fromJson(json['location']),
        rooms: [
          for (final r in json['rooms'] as List? ?? const [])
            Room.fromJson((r as Map).cast<String, Object?>()),
        ],
        scenarios: [
          for (final s in json['scenarios'] as List? ?? const [])
            Scenario.fromJson((s as Map).cast<String, Object?>()),
        ],
        modules: [
          for (final m in json['modules'] as List? ?? const [])
            DeviceModule.fromJson((m as Map).cast<String, Object?>()),
        ],
        automations: [
          for (final a in json['automations'] as List? ?? const [])
            Automation.fromJson((a as Map).cast<String, Object?>()),
        ],
      );
}

/// Rewrites a raw backup document one major version forward.
typedef BackupMigration = Map<String, dynamic> Function(
    Map<String, dynamic> doc);

/// A backup created by a newer (structurally incompatible) build.
class BackupFromFutureException implements Exception {
  const BackupFromFutureException(this.backupVersion);

  final BackupVersion backupVersion;

  String get message =>
      'This backup (v$backupVersion) was created by a newer app version and '
      'cannot be restored by this build.';

  @override
  String toString() => message;
}

/// A backup version whose migration chain has no known step to the current
/// version.
class UnsupportedMigrationException implements Exception {
  const UnsupportedMigrationException(this.fromMajor, this.toMajor);

  final int fromMajor;
  final int toMajor;

  String get message =>
      'No migration path from backup v$fromMajor to the current v$toMajor.';

  @override
  String toString() => message;
}

/// App-wide local backup/restore of the device-manager configuration.
class BackupService {
  BackupService._();

  /// App-wide shared instance used by the Account screen.
  static final BackupService shared = BackupService._();

  /// Creates an isolated service for tests.
  @visibleForTesting
  static BackupService forTesting() => BackupService._();

  /// Prefix every backup file name starts with.
  static const String filePrefix = 'soleux_backup';

  /// Legacy, fixed backup file name used by earlier builds. Kept so a backup
  /// written by an older build is still found by [readBackup].
  static const String legacyFileName = 'soleux_backup.json';

  /// Meaningful, unique backup file name:
  /// `soleux_backup_<location>_v<major>.<minor>_<yyyyMMdd-HHmmss>.json`
  ///
  /// The location slug says what the backup is *of*, the version tells which
  /// format it is in (so a restore can be reasoned about before opening it) and
  /// the local timestamp keeps each export distinct and sortable.
  static String fileNameAt(
    DateTime at, {
    String? locationName,
    BackupVersion version = currentVersion,
  }) =>
      '${filePrefix}_${locationSlug(locationName)}_v$version'
      '_${timestampSlug(at)}.json';

  /// Name of the local backup file written into the default directory. There is
  /// no single fixed name any more; this is the name for [DateTime.now] (used
  /// to document the convention and as the FilePicker fallback).
  static String get fileName => fileNameAt(DateTime.now(),
      locationName: SettingsStore.shared.locationName);

  /// Turns a human location name into a file-name-safe slug, falling back to
  /// `location` when nothing usable is available (`Casa Verde` -> `Casa_Verde`).
  static String locationSlug(String? locationName) {
    final slug = (locationName ?? '')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (slug.isEmpty) return 'location';
    // Keep file names comfortably short even for a long location name.
    return slug.length <= 40 ? slug : slug.substring(0, 40);
  }

  /// Local-time `yyyyMMdd-HHmmss` stamp, sortable and unique per second.
  static String timestampSlug(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year.toString().padLeft(4, '0')}${two(at.month)}'
        '${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }

  /// Current backup format version. Bump [major] on breaking structural
  /// changes and register a migration in [_migrations].
  static const BackupVersion currentVersion = BackupVersion(major: 1, minor: 1);

  /// Migration chain keyed by the *source* major version: each step rewrites
  /// a raw document one major version forward. `0 -> 1` upgrades unversioned
  /// backups (created before the `schema` field existed) into the current
  /// shape; every future breaking change adds its own entry.
  static const Map<int, BackupMigration> _migrations = {
    0: _migrateFromV0,
  };

  /// Upgrades an unversioned (pre-schema) backup into format v1.
  static Map<String, dynamic> _migrateFromV0(Map<String, dynamic> doc) {
    // Older exports used a plain `version` string/number instead of a typed
    // `schema` object; drop it so the pipeline stamping rules the version.
    doc.remove('version');
    // Any legacy setting keys are normalised to their v1 names.
    final settings = doc['settings'];
    if (settings is Map) {
      final map = settings.cast<String, dynamic>();
      _renameIfPresent(map, 'theme', 'themeMode');
      _renameIfPresent(map, 'lang', 'locale');
      _renameIfPresent(map, 'commandMode', 'commandTransport');
      _renameIfPresent(map, 'notifyModuleOffline', 'moduleStatus');
      _renameIfPresent(map, 'notifyTemperature', 'temperature');
    }
    return doc;
  }

  static void _renameIfPresent(
      Map<String, dynamic> map, String from, String to) {
    if (map.containsKey(from) && !map.containsKey(to)) {
      map[to] = map.remove(from);
    }
  }

  /// Serialises the current app configuration to a versioned JSON backup file.
  /// Pass [directory] to target a specific folder (tests); otherwise the
  /// platform's external storage is used when available (see
  /// [defaultBackupDirectory]). Returns the written [File].
  ///
  /// The file is named after the current location, format version and timestamp
  /// ([fileNameAt]), so successive backups never overwrite each other. Two
  /// backups taken inside the same second get a `_2`, `_3`, ... suffix instead.
  Future<File> backup({Directory? directory}) async {
    final dir = directory ?? await defaultBackupDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final now = DateTime.now();
    final base =
        fileNameAt(now, locationName: SettingsStore.shared.locationName);
    var file = File('${dir.path}${Platform.pathSeparator}$base');
    var collision = 2;
    while (await file.exists()) {
      file = File('${dir.path}${Platform.pathSeparator}'
          '${base.substring(0, base.length - '.json'.length)}_$collision.json');
      collision++;
    }
    await file.writeAsBytes(await exportBytes());
    return file;
  }

  /// Serialises the current configuration to the versioned backup file's
  /// bytes without writing them. Used by the "Save as" (SAF) flow so the
  /// system dialog can write them to the user-designated external location.
  Future<Uint8List> exportBytes() async {
    final doc = await _snapshot();
    const encoder = JsonEncoder.withIndent('  ');
    return Uint8List.fromList(utf8.encode(encoder.convert(doc.toJson())));
  }

  /// Reads the most recent backup file inside [directory], or null when none
  /// exists / is unreadable.
  ///
  /// Backups are timestamped ([fileNameAt]), so the newest one is picked by
  /// modification time; a legacy fixed-name file ([legacyFileName]) is
  /// recognised too.
  Future<BackupDocument?> readBackup({Directory? directory}) async {
    final dir = directory ?? await defaultBackupDirectory();
    final file = await latestBackupFile(dir);
    if (file == null) return null;
    return readBackupFromFile(file);
  }

  /// The newest backup file in [dir] (by modification time), or null when the
  /// directory holds no backup.
  static Future<File?> latestBackupFile(Directory dir) async {
    if (!await dir.exists()) return null;
    final backups = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!isBackupFileName(entity.uri.pathSegments.last)) continue;
      backups.add(entity);
    }
    if (backups.isEmpty) return null;
    final stats = <(File, DateTime)>[];
    for (final file in backups) {
      try {
        stats.add((file, (await file.stat()).modified));
      } on FileSystemException {
        // Skip files that disappear / are unreadable mid-listing.
      }
    }
    if (stats.isEmpty) return null;
    stats.sort((a, b) => b.$2.compareTo(a.$2));
    return stats.first.$1;
  }

  /// True when [name] follows the backup naming convention (or the legacy
  /// fixed name).
  static bool isBackupFileName(String name) =>
      name == legacyFileName ||
      (name.startsWith('${filePrefix}_') &&
          name.toLowerCase().endsWith('.json'));

  /// Reads the backup at the explicit [file] path (e.g. one picked by the
  /// user), or null when it is missing / unreadable.
  Future<BackupDocument?> readBackupFromFile(File file) async {
    if (!await file.exists()) return null;
    try {
      return parseBackupBytes(await file.readAsBytes());
    } on Exception {
      return null;
    }
  }

  /// Parses [bytes] read from a user-picked backup file, or null when they do
  /// not form a valid backup document.
  static BackupDocument? parseBackupBytes(Uint8List bytes) {
    try {
      return BackupDocument.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Resolves the directory backups are written to when the caller does not
  /// designate one: the platform's external storage (Android) when available,
  /// otherwise the app documents directory.
  Future<Directory> defaultBackupDirectory() async {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    } on UnsupportedError {
      // Not supported on this platform; fall through.
    }
    return getApplicationDocumentsDirectory();
  }

  /// Applies [doc] to the app's stores.
  ///
  /// [mode] controls whether the backup is used verbatim
  /// ([BackupRestoreMode.freshLoad]) or first upgraded through the migration
  /// chain ([BackupRestoreMode.migrate], the default). Backups from a newer
  /// major version always throw [BackupFromFutureException].
  Future<void> restore(
    BackupDocument doc, {
    BackupRestoreMode mode = BackupRestoreMode.migrate,
  }) async {
    final schema = doc.schema;
    if (schema.compareTo(currentVersion) > 0) {
      throw BackupFromFutureException(schema);
    }

    var target = doc;
    if (mode == BackupRestoreMode.migrate &&
        schema.major < currentVersion.major) {
      final migrated = _runMigrations(doc.toJson(), schema, currentVersion);
      target = BackupDocument.fromJson(migrated);
    }
    await _writeAll(target);
  }

  /// Walks [json] through every migration step between [from] and [to].
  Map<String, dynamic> _runMigrations(
    Map<String, dynamic> json,
    BackupVersion from,
    BackupVersion to,
  ) {
    var current = json;
    for (var major = from.major; major < to.major; major++) {
      final migrator = _migrations[major];
      if (migrator == null) {
        throw UnsupportedMigrationException(major, to.major);
      }
      current = migrator(current);
      final schema = (current['schema'] as Map).cast<String, dynamic>();
      schema['major'] = major + 1;
      schema['minor'] = 0;
    }
    return current;
  }

  /// Captures a point-in-time snapshot of every persisted configuration.
  Future<BackupDocument> _snapshot() async {
    final settings = SettingsStore.shared;
    await settings.init();
    await RoomStore.shared.init();
    await ScenarioStore.shared.init();
    await AutomationStore.shared.init();
    await ModuleStore.shared.init();
    await CustomColorStore.shared.init();

    return BackupDocument(
      schema: currentVersion,
      exportedAt: DateTime.now(),
      settings: BackupSettings(
        themeMode: themeModeNotifier.value,
        locale: appLocaleNotifier.value.languageCode,
        homeTheme: homeThemeIdNotifier.value,
        commandTransport: settings.commandTransport,
        moduleStatus: settings.moduleStatus,
        outputLeftOn: settings.outputLeftOn,
        temperature: settings.temperature,
        automationTriggered: settings.automationTriggered,
        firmwareUpdate: settings.firmwareUpdate,
        defaultTemperatureThreshold: settings.defaultTemperatureThreshold,
        outputOnThresholdHours: settings.outputOnThresholdHours,
        customColors: [
          for (final c in CustomColorStore.shared.colors) c.toARGB32(),
        ],
      ),
      location:
          BackupLocation(id: settings.locationId, name: settings.locationName),
      rooms: List.unmodifiable(RoomStore.shared.rooms),
      scenarios: List.unmodifiable(ScenarioStore.shared.scenarios),
      modules: List.unmodifiable(ModuleStore.shared.modules),
      automations: List.unmodifiable(AutomationStore.shared.automations),
    );
  }

  /// Writes a parsed backup into every app store, replacing current data.
  Future<void> _writeAll(BackupDocument doc) async {
    final settings = SettingsStore.shared;
    await settings.init();

    final s = doc.settings;
    if (s.themeMode != null) await settings.setThemeMode(s.themeMode!);
    if (s.locale != null && s.locale!.isNotEmpty) {
      await settings.setLocale(Locale(s.locale!));
    }
    if (s.homeTheme != null) await settings.setHomeTheme(s.homeTheme!);
    if (s.commandTransport != null) {
      await settings.setCommandTransport(s.commandTransport!);
    }
    if (s.moduleStatus != null) await settings.setModuleStatus(s.moduleStatus!);
    if (s.outputLeftOn != null) await settings.setOutputLeftOn(s.outputLeftOn!);
    if (s.temperature != null) await settings.setTemperature(s.temperature!);
    if (s.automationTriggered != null) {
      await settings.setAutomationTriggered(s.automationTriggered!);
    }
    if (s.firmwareUpdate != null) {
      await settings.setFirmwareUpdate(s.firmwareUpdate!);
    }
    if (s.defaultTemperatureThreshold != null) {
      await settings
          .setDefaultTemperatureThreshold(s.defaultTemperatureThreshold!);
    }
    if (s.outputOnThresholdHours != null) {
      await settings.setOutputOnThresholdHours(s.outputOnThresholdHours!);
    }
    await CustomColorStore.shared
        .replaceAll([for (final v in s.customColors) Color(v)]);

    await settings.setLocation(
      id: doc.location.id,
      name: doc.location.name,
    );

    await RoomStore.shared.replaceAll(doc.rooms);
    await ScenarioStore.shared.replaceAll(doc.scenarios);
    await ModuleStore.shared.replaceAll(doc.modules);
    await AutomationStore.shared.replaceAll(doc.automations);
  }
}

/// A backup file chosen via the native picker: its raw bytes (read through the
/// content resolver, so no storage permission is needed) and original name.
class BackupPickedFile {
  const BackupPickedFile({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

/// Opens the native save/open dialogs so the user can designate where a
/// backup is written to or read from (external storage, Downloads, iCloud,
/// ...). On Android and iOS these go through the system document pickers
/// (Storage Access Framework / UIDocumentPicker), which run out-of-process and
/// grant per-file access - no storage permission is required. The static
/// function fields are replaced by widget tests with deterministic data,
/// avoiding the platform channel.
class BackupPathPicker {
  BackupPathPicker._();

  /// Opens the "Save as" dialog, writes [bytes] to the user-designated file
  /// and returns the written file. Returns null when the user cancels.
  static Future<File?> Function(Uint8List bytes) saveBackupFile =
      _saveBackupFile;

  /// Opens the JSON file picker and returns the chosen file's bytes.
  /// Returns null when the user cancels.
  static Future<BackupPickedFile?> Function() pickBackupFile = _pickBackupFile;

  /// Restores the default native pickers (used by tests in tearDown).
  static void resetDefaults() {
    saveBackupFile = _saveBackupFile;
    pickBackupFile = _pickBackupFile;
  }

  static Future<File?> _saveBackupFile(Uint8List bytes) async {
    final path = await FilePicker.platform.saveFile(
      // Pre-fill the dialog with a meaningful, unique name the user can accept
      // or edit (location + format version + timestamp).
      fileName: BackupService.fileNameAt(
        DateTime.now(),
        locationName: SettingsStore.shared.locationName,
      ),
      bytes: bytes,
    );
    return path == null ? null : File(path);
  }

  static Future<BackupPickedFile?> _pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;
    return BackupPickedFile(bytes: bytes, name: file.name);
  }
}
