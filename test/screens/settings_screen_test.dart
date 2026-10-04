// Renders the real Settings screen to verify the Command protocol section
// (TCP 5008 vs HTTP/HTTPS) builds and localizes correctly, and exercises the
// backup/restore flow that moved here from the Account screen.
//
// The native "Save as"/open dialogs are replaced with deterministic stubs;
// store writes on restore and the save stub still do real disk work, so those
// interactions are given time inside `tester.runAsync`. The full backup write
// path is covered by test/services/backup_service_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';
import 'package:soleux_device_manager/screens/settings_screen.dart';
import 'package:soleux_device_manager/services/backup_service.dart';
import 'package:soleux_device_manager/services/settings_store.dart';

/// Pure-Dart stand-in for the path_provider platform channel, so tests never
/// touch a real plugin.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docPath);

  final String docPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docPath;
}

/// v1 backup fixture written straight to disk by [BackupDocument]'s schema.
Map<String, dynamic> _fixtureJson() => {
      'schema': {'major': 1, 'minor': 0},
      'exportedAt': '2026-09-15T00:00:00.000',
      'settings': {'themeMode': 'dark', 'locale': 'ro'},
      'location': {'id': 'loc-1', 'name': 'Casa'},
      'rooms': [
        {'id': 'r1', 'name': 'Living room'}
      ],
      'scenarios': <Object?>[],
      'modules': <Object?>[],
      'automations': <Object?>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  String backupPath(Directory d) =>
      '${d.path}${Platform.pathSeparator}${BackupService.fileName}';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('settings_screen_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    // Route the native pickers to deterministic test data (the "Save as"
    // dialog writes into the temp dir; the open dialog returns the fixture).
    BackupPathPicker.saveBackupFile = (bytes) async {
      final file = File(backupPath(dir));
      await file.writeAsBytes(bytes);
      return file;
    };
    BackupPathPicker.pickBackupFile = () async {
      final json = const JsonEncoder.withIndent('  ').convert(_fixtureJson());
      return BackupPickedFile(
          bytes: Uint8List.fromList(utf8.encode(json)),
          name: BackupService.fileName);
    };
  });

  tearDown(() async {
    BackupPathPicker.resetDefaults();
    // Windows can briefly hold the file open after a test; retry cleanup.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // Tall viewport so the whole Settings ListView (incl. the below-the-fold
    // Command protocol and backup sections) is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(),
    ));
    await tester.pumpAndSettle();
  }

  /// Alternates fake-clock pumps with real-async windows so multi-hop file IO
  /// chains (e.g. readBackup: exists -> readAsString -> parse) can complete.
  Future<void> pumpRealAsync(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  }

  /// Taps [finder] and lets any real-async work (file IO) make progress.
  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
    await pumpRealAsync(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('Settings screen renders the command protocol picker',
      (tester) async {
    await pumpSettings(tester);

    expect(find.text('Command protocol'), findsOneWidget);
    expect(find.text('TCP (port 5008)'), findsOneWidget);
    expect(find.text('HTTP'), findsOneWidget);
    expect(find.text('HTTPS'), findsOneWidget);
  });

  testWidgets('selecting HTTPS persists the transport choice', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('HTTPS'));
    await tester.pumpAndSettle();
    expect(SettingsStore.shared.commandTransport, CommandTransportMode.https);
  });

  testWidgets('Restore of a non-backup file shows the no-backup notice',
      (tester) async {
    BackupPathPicker.pickBackupFile = () async => BackupPickedFile(
        bytes: Uint8List.fromList(utf8.encode('not a backup')),
        name: 'x.json');
    await pumpSettings(tester);
    await tapAndSettle(tester, find.widgetWithText(OutlinedButton, 'Restore'));

    expect(find.text('No local backup was found.'), findsOneWidget);
  });

  testWidgets(
      'Restore offers fresh-load and migrate options and applies the '
      'backup', (tester) async {
    // The setUp stub already returns a valid v1 fixture from the picker.
    await pumpSettings(tester);
    await tapAndSettle(tester, find.widgetWithText(OutlinedButton, 'Restore'));

    // Step 1: the mode dialog appears with both options.
    expect(find.text('Fresh load'), findsOneWidget);
    expect(find.text('Migrate'), findsOneWidget);
    // The version line also carries the export timestamp, so match on a slice.
    expect(find.textContaining('Backup version 1.0'), findsOneWidget);

    // Step 2: choose migrate and confirm.
    await tester.tap(find.text('Migrate'));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Restore'));

    expect(find.text('Configuration restored from backup.'), findsOneWidget);
  });

testWidgets('Back Up Now writes the backup via the save dialog',
    (tester) async {
    await pumpSettings(tester);
    await tapAndSettle(
        tester, find.widgetWithText(FilledButton, 'Back Up Now'));

    // _backupNow keeps the spinner visible for ~900ms (fake clock) after the
    // write; advance past it so the completed snackbar shows.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();

    expect(File(backupPath(dir)).existsSync(), isTrue);
    expect(find.text('Backup completed.'), findsOneWidget);
  });
}