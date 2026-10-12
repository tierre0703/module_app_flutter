// Tests for the app-wide backup/restore service: versioned JSON export to
// local storage, verbatim + migration-based restore, and rejection of backups
// from a newer app build.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/services/automation_store.dart';
import 'package:soleux_device_manager/services/backup_service.dart';
import 'package:soleux_device_manager/services/custom_color_store.dart';
import 'package:soleux_device_manager/services/module_store.dart';
import 'package:soleux_device_manager/services/room_store.dart';
import 'package:soleux_device_manager/services/scenario_store.dart';
import 'package:soleux_device_manager/services/settings_store.dart';
import 'package:soleux_device_manager/theme/app_theme.dart';
import 'package:soleux_device_manager/theme/theme_palettes.dart';

Future<Directory> tempDir() async {
  final dir = await Directory.systemTemp.createTemp('backup_service_test');
  return dir;
}

Room _room(String id, String name) => Room(id: id, name: name);

Scenario _scenario(String id, String name) => Scenario(
      id: id,
      name: name,
      icon: Icons.power,
      type: ScenarioType.tapToRun,
      actions: [
        ScenarioAction(
          moduleName: 'Relay 1',
          channelName: 'Lamp',
          icon: Icons.lightbulb,
          isDimmerAction: false,
        ),
      ],
    );

DeviceModule _module(String id) => DeviceModule(
      id: id,
      name: 'Relay $id',
      type: ModuleType.relay,
      ipAddress: '192.168.1.$id',
      status: ConnectionStatus.offline,
      roomName: 'Living',
      internalTempC: 30,
      channels: [
        ChannelOutput(id: '${id}c1', name: 'Lamp', icon: Icons.lightbulb),
      ],
    );

Automation _automation(String id) => Automation(
      id: id,
      name: 'Turn on at 8:00',
      triggerType: AutomationTriggerType.time,
      triggerSummary: 'Daily at 08:00',
      scheduleHour: 8,
      scheduleMinute: 0,
      actions: [
        ScenarioAction(
          moduleName: 'Relay 1',
          channelName: 'Lamp',
          icon: Icons.lightbulb,
          isDimmerAction: false,
          turnOn: true,
        ),
      ],
    );

/// A raw legacy (pre-schema / v0) backup document using the old key names.
Map<String, dynamic> legacyV0Json() => {
      'version': '0.9',
      'exportedAt': '2026-01-01T00:00:00.000',
      'settings': {
        'theme': 'dark',
        'locale': 'ro',
        'commandMode': 'http',
        'moduleStatus': true,
        'temperature': false,
        'defaultTemperatureThreshold': 70,
        'outputOnThresholdHours': 10,
      },
      'location': {'id': 'loc-1', 'name': 'Casa'},
      'rooms': [
        {'id': 'r1', 'name': 'Living room'},
      ],
      'scenarios': <Object?>[],
      'modules': <Object?>[],
      'automations': <Object?>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BackupService.backup', () {
    test('writes a versioned JSON snapshot with every section', () async {
      final dir = await tempDir();
      addTearDown(() => dir.delete(recursive: true));

      await RoomStore.shared.replaceAll([_room('r1', 'Living')]);
      await ScenarioStore.shared.replaceAll([_scenario('s1', 'Movie night')]);
      await ModuleStore.shared.replaceAll([_module('1')]);
      await AutomationStore.shared.replaceAll([_automation('a1')]);
      await SettingsStore.shared.init();
      await SettingsStore.shared.setLocation(id: 'loc-9', name: 'My Home');

      final file = await BackupService.shared.backup(directory: dir);
      expect(file.existsSync(), isTrue);
      // Name carries the location slug, the format version and a timestamp.
      final name = file.uri.pathSegments.last;
      expect(BackupService.isBackupFileName(name), isTrue);
      expect(name, startsWith('${BackupService.filePrefix}_My_Home_'));
      expect(name, contains('_v${BackupService.currentVersion}_'));

      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(((json['schema'] as Map)['major'] as num).toInt(),
          BackupService.currentVersion.major);
      expect(((json['schema'] as Map)['minor'] as num).toInt(),
          BackupService.currentVersion.minor);
      expect(json['exportedAt'], isNotNull);
      expect(json['settings'], isA<Map>());
      expect((json['location'] as Map)['name'], 'My Home');
      expect(json['rooms'], hasLength(1));
      expect(json['scenarios'], hasLength(1));
      expect(json['modules'], hasLength(1));
      expect(json['automations'], hasLength(1));
    });

    test('readBackup returns null when no file exists', () async {
      final dir = await tempDir();
      addTearDown(() => dir.delete(recursive: true));
      expect(await BackupService.shared.readBackup(directory: dir), isNull);
    });

    test('each backup gets a unique, meaningful file name', () async {
      final dir = await tempDir();
      addTearDown(() => dir.delete(recursive: true));
      await SettingsStore.shared.init();
      await SettingsStore.shared.setLocation(id: 'loc-9', name: 'Casa Verde');

      final first = await BackupService.shared.backup(directory: dir);
      final second = await BackupService.shared.backup(directory: dir);

      expect(first.path, isNot(second.path),
          reason: 'a timestamped name must not overwrite the previous backup');
      final name = first.uri.pathSegments.last;
      expect(name, startsWith('${BackupService.filePrefix}_Casa_Verde_v'));
      expect(name, endsWith('.json'));
    });

    test('readBackup picks the newest timestamped backup in the directory',
        () async {
      final dir = await tempDir();
      addTearDown(() => dir.delete(recursive: true));
      await SettingsStore.shared.init();

      final older = File('${dir.path}${Platform.pathSeparator}'
          '${BackupService.filePrefix}_Home_v1.0_20260101-101010.json');
      final newer = File('${dir.path}${Platform.pathSeparator}'
          '${BackupService.filePrefix}_Home_v1.1_20260202-202020.json');
      await older.writeAsString('{}');
      await newer.writeAsString('{}');
      // Force distinct modification times regardless of file-system clock
      // resolution.
      await older.setLastModified(DateTime(2026, 1, 1, 10, 10, 10));
      await newer.setLastModified(DateTime(2026, 2, 2, 20, 20, 20));

      expect(await BackupService.latestBackupFile(dir), newer);

      // A legacy fixed-name backup is still recognised.
      final legacy = File('${dir.path}${Platform.pathSeparator}'
          '${BackupService.legacyFileName}');
      await legacy.writeAsString('{}');
      expect(BackupService.isBackupFileName(BackupService.legacyFileName),
          isTrue);
      expect(BackupService.isBackupFileName('notes.txt'), isFalse);
    });
  });

  group('BackupService.restore', () {
    test('fresh load round-trips every store', () async {
      final dir = await tempDir();
      addTearDown(() => dir.delete(recursive: true));

      // 1. Seed every store with a known state and export it.
      await RoomStore.shared.replaceAll([_room('r1', 'Living')]);
      await ScenarioStore.shared.replaceAll([_scenario('s1', 'Movie night')]);
      await ModuleStore.shared.replaceAll([_module('1')]);
      await AutomationStore.shared.replaceAll([_automation('a1')]);
      await CustomColorStore.shared
          .replaceAll([const Color(0xFF123456), const Color(0xFF654321)]);
      await SettingsStore.shared.setThemeMode(ThemeMode.dark);
      await SettingsStore.shared.setLocale(const Locale('ro'));
      await SettingsStore.shared.setHomeTheme(HomeThemeId.noir);
      await SettingsStore.shared
          .setCommandTransport(CommandTransportMode.https);
      await SettingsStore.shared.setDefaultTemperatureThreshold(55);
      await SettingsStore.shared.setOutputOnThresholdHours(8);
      await SettingsStore.shared.setLocation(id: 'loc-9', name: 'My Home');
      await BackupService.shared.backup(directory: dir);

      // 2. Wipe the device back to defaults.
      await RoomStore.shared.replaceAll(const []);
      await ScenarioStore.shared.replaceAll(const []);
      await ModuleStore.shared.replaceAll(const []);
      await AutomationStore.shared.replaceAll(const []);
      await CustomColorStore.shared.replaceAll(const []);
      await SettingsStore.shared.setThemeMode(ThemeMode.light);
      await SettingsStore.shared.setLocale(const Locale('en'));
      await SettingsStore.shared.setHomeTheme(HomeThemeId.mintFrost);
      await SettingsStore.shared.setCommandTransport(CommandTransportMode.tcp);
      await SettingsStore.shared.setDefaultTemperatureThreshold(65);
      await SettingsStore.shared.setOutputOnThresholdHours(12);
      await SettingsStore.shared.setLocation(id: 'single-location', name: '');

      // 3. Restore from the local file.
      final doc = await BackupService.shared.readBackup(directory: dir);
      expect(doc, isNotNull);
      await BackupService.shared
          .restore(doc!, mode: BackupRestoreMode.freshLoad);

      expect(RoomStore.shared.rooms, hasLength(1));
      expect(RoomStore.shared.rooms.single.name, 'Living');
      expect(ScenarioStore.shared.scenarios.single.name, 'Movie night');
      expect(ModuleStore.shared.modules.single.name, 'Relay 1');
      expect(ModuleStore.shared.modules.single.channels.single.name, 'Lamp');
      expect(AutomationStore.shared.automations.single.name, 'Turn on at 8:00');
      expect(CustomColorStore.shared.colors,
          [const Color(0xFF123456), const Color(0xFF654321)]);
      expect(themeModeNotifier.value, ThemeMode.dark);
      expect(appLocaleNotifier.value.languageCode, 'ro');
      expect(homeThemeIdNotifier.value, HomeThemeId.noir);
      expect(SettingsStore.shared.commandTransport, CommandTransportMode.https);
      expect(SettingsStore.shared.defaultTemperatureThreshold, 55);
      expect(SettingsStore.shared.outputOnThresholdHours, 8);
      expect(SettingsStore.shared.locationName, 'My Home');
      expect(SettingsStore.shared.locationId, 'loc-9');
    });

    test('migrate upgrades a legacy v0 document before applying', () async {
      final doc = BackupDocument.fromJson(legacyV0Json());
      expect(doc.schema.major, 0);

      await BackupService.shared.restore(doc, mode: BackupRestoreMode.migrate);

      // Legacy keys were renamed by the v0 -> v1 migration.
      expect(themeModeNotifier.value, ThemeMode.dark);
      expect(appLocaleNotifier.value.languageCode, 'ro');
      expect(SettingsStore.shared.commandTransport, CommandTransportMode.http);
      expect(SettingsStore.shared.moduleStatus, isTrue);
      expect(SettingsStore.shared.temperature, isFalse);
      expect(SettingsStore.shared.defaultTemperatureThreshold, 70);
      expect(SettingsStore.shared.outputOnThresholdHours, 10);
      expect(SettingsStore.shared.locationId, 'loc-1');
      expect(SettingsStore.shared.locationName, 'Casa');
      expect(RoomStore.shared.rooms.single.name, 'Living room');
    });

    test('fresh load applies an older backup without migrating', () async {
      final doc = BackupDocument.fromJson(legacyV0Json());

      await SettingsStore.shared.setThemeMode(ThemeMode.light);
      await BackupService.shared
          .restore(doc, mode: BackupRestoreMode.freshLoad);

      // 'theme' was never renamed (no migration ran), so the old key is
      // ignored and the previous theme is kept.
      expect(themeModeNotifier.value, ThemeMode.light);
      // Keys that already used current names still apply.
      expect(appLocaleNotifier.value.languageCode, 'ro');
      expect(SettingsStore.shared.moduleStatus, isTrue);
    });

    test('rejects backups from a newer major version', () async {
      final doc = BackupDocument(
        schema: const BackupVersion(major: 9, minor: 0),
        exportedAt: DateTime.now(),
        settings: const BackupSettings(),
        location: const BackupLocation(id: 'x', name: 'x'),
        rooms: const [],
        scenarios: const [],
        modules: const [],
        automations: const [],
      );

      await expectLater(
        BackupService.shared.restore(doc, mode: BackupRestoreMode.freshLoad),
        throwsA(isA<BackupFromFutureException>()),
      );
    });
  });
}
