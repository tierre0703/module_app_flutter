// lib/services/module_status/background_status_worker.dart
//
// Native background worker that keeps checking module online/offline status
// while the app is backgrounded or suspended.
//
// Rationale: the pure-Dart [ModuleStatusScheduler] can only run its polling
// [Timer] while the Flutter engine / OS keeps the process alive. Once the OS
// suspends the app (or the worker process is killed), that timer stops. This
// wrapper hands the same lightweight connectivity poll (see
// [ModuleStatusService.pollAll]) to the OS's own background scheduler so it is
// re-run even when the Dart UI layer is not running:
//
//   - Android: WorkManager (periodic work request, min 15 min).
//   - iOS: BGAppRefreshTask via the workmanager plugin's BGTaskScheduler
//     registration.
//
// The worker only reads/writes the locally persisted module list
// (shared_preferences), so it needs no network beyond the module LAN and no
// cloud dependency. Each poll opens the module's 5008 Control API port and
// sends a `hello`, updating every module's online/unknown/offline
// `ConnectionStatus` - the same reachability source the foreground uses (see
// [ModuleApiHealthService]).
//
// `callbackDispatcher` must remain a top-level function: the plugin invokes it
// by its callback handle from a fresh background isolate.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../models/models.dart';
import '../module_store.dart';
import '../notification_service.dart';
import '../settings_store.dart';
import '../status_log_store.dart';
import 'module_api_health_service.dart';

/// Thin wrapper around the [Workmanager] plugin.
abstract final class BackgroundStatusWorker {
  /// Unique name of the periodic task (also the identifier used on iOS for the
  /// BGAppRefreshTask; it must match Info.plist `BGTaskSchedulerPermittedIdentifiers`).
  static const String uniqueTaskName = 'com.soleux.sdm.statusPoll';

  /// How often the OS is asked to run the background poll. Android enforces a
  /// 15-minute floor; iOS schedules opportunistically and does not guarantee it.
  static const Duration backgroundPollFrequency = Duration(minutes: 1);

  static bool _initialized = false;

  /// Platforms that have a real background worker.
  static bool get _nativeSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Registers the [callbackDispatcher] with the plugin. Called once from the
  /// app entry point. No-op outside Android/iOS.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (_nativeSupported) {
      await Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: kDebugMode,
      );
    }
  }

  /// Schedules the periodic background poll. Idempotent (uses `ExistingWorkPolicy.update`).
  static Future<void> schedule() async {
    if (!_nativeSupported) return;
    await initialize();
    await Workmanager().registerPeriodicTask(
      uniqueTaskName,
      uniqueTaskName,
      frequency: backgroundPollFrequency,
      existingWorkPolicy: ExistingWorkPolicy.update,
    );
  }

  /// Cancels the periodic background poll. No-op when not scheduled.
  static Future<void> cancel() async {
    if (!_nativeSupported) return;
    await initialize();
    await Workmanager().cancelByUniqueName(uniqueTaskName);
  }

  /// Runs one background poll pass and reports success. Safe to call from the
  /// background isolate: `executeTask` initialises the registered plugins and
  /// the store reads straight from persisted storage. Any module whose
  /// connectivity flips during the poll is surfaced as a local notification
  /// (respecting the notification preferences), so alerts work even while the
  /// app is suspended.
  static Future<bool> runPoll() async {
    try {
      debugPrint('BackgroundStatusWorker: starting poll');
      await SettingsStore.shared.init();
      // No permission requests from the background isolate: the plugin's
      // activity context is null there (headless process), which would throw
      // in requestNotificationsPermission. Permission was already granted on
      // the first foreground launch; only channel setup + show are needed.
      await LocalNotificationService.shared
          .initialize(requestPermissions: false);
      await StatusLogStore.shared.init();

      await ModuleStore.shared.init();
      final before = <String, ConnectionStatus>{
        for (final m in ModuleStore.shared.modules) m.id: m.status,
      };

      // Run the 5008 Control API check: one `hello` round-trip per module
      // updates each module's lastSeenAt / ConnectionStatus (the same status
      // source the foreground uses), driving the diffed notifications below.
      await ModuleApiHealthService.shared.checkAll();

      final notifier = LocalNotificationService.shared;
      for (final entry in before.entries) {
        final module = ModuleStore.shared.byId(entry.key);
        final now = module?.status;
        if (module == null || now == null || now == entry.value) continue;
        if (now == ConnectionStatus.offline) {
          await StatusLogStore.shared.recordOffline(module.name);
        } else {
          await StatusLogStore.shared.recordRestored(module.name);
        }
        await notifier.showModuleStatusChanged(
            module, now == ConnectionStatus.online);
      }
      debugPrint('BackgroundStatusWorker: poll complete');
      return true;
    } catch (e, st) {
      debugPrint('BackgroundStatusWorker: poll failed: $e\n$st');
      return false;
    }
  }
}

/// Top-level entry point invoked by the OS from a fresh background isolate.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) {
    debugPrint('BackgroundStatusWorker: task=$taskName input=$inputData');
    return BackgroundStatusWorker.runPoll();
  });
}
