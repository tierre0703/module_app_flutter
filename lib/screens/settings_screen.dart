// lib/screens/settings_screen.dart
//
// Brief section III "Settings Section": account, notifications, language
// and appearance, plus a reminder that the architecture is multi-location
// ready even though v1 manages a single location (brief section 4.2). The
// "Command protocol" section picks the Control API transport the app uses to
// talk to modules: the persistent TCP session on port 5008 or the stateless
// HTTP/HTTPS POST /api/v1/command endpoint
// (doc/Soleux_Control_API_Command_Specification_v0.2.md §"Transport mapping").
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../services/backup_service.dart';
import '../services/event_log_store.dart';
// import '../services/session_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/module_keep_alive_settings.dart';
import 'appearance_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DateTime _lastBackup = DateTime.now().subtract(const Duration(hours: 6));
  bool _backingUp = false;
  bool _restoring = false;

  Future<void> _backupNow() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _backingUp = true);
    // The write completes almost instantly, so keep the spinner visible for a
    // moment to make the completed state obvious.
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = await BackupService.shared.exportBytes();
      // "Save as" dialog (SAF on Android / UIDocumentPicker on iOS) lets the
      // user designate the external destination; bail out when cancelled.
      final file = await BackupPathPicker.saveBackupFile(bytes);
      if (file == null) {
        if (mounted) setState(() => _backingUp = false);
        return;
      }
      final remaining = 900 - stopwatch.elapsedMilliseconds;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining));
      }
      if (!mounted) return;
      setState(() {
        _backingUp = false;
        _lastBackup = DateTime.now();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.accountBackupCompleted)));
    } on Exception {
      if (!mounted) return;
      setState(() => _backingUp = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.backupExportFailed)));
    }
  }

  Future<void> _restoreBackup() async {
    final l10n = AppLocalizations.of(context);

    // Native JSON file picker lets the user designate the backup file; bail
    // out when the dialog is cancelled.
    final picked = await BackupPathPicker.pickBackupFile();
    if (picked == null || !mounted) return;

    final backup = BackupService.parseBackupBytes(picked.bytes);
    if (backup == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.backupNoBackupFound)));
      return;
    }
    final BackupDocument doc = backup;

    // A backup from a structurally newer build cannot be downgraded.
    if (doc.schema.compareTo(BackupService.currentVersion) > 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.backupNewerVersion)));
      return;
    }

    final needsMigration =
        doc.schema.major < BackupService.currentVersion.major;

    final mode = await showDialog<BackupRestoreMode>(
      context: context,
      builder: (ctx) {
        var selected = needsMigration
            ? BackupRestoreMode.migrate
            : BackupRestoreMode.freshLoad;
        final created = doc.exportedAt == null
            ? ''
            : l10n
                .backupCreatedLabel(formatLogTimestamp(doc.exportedAt!, l10n));
        final versionLine = l10n.backupVersionLabel(doc.schema.toString());
        final onSurface = Theme.of(ctx).colorScheme.onSurface;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(l10n.accountRestoreDialog),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$versionLine\n$created',
                    style: TextStyle(
                      fontSize: 12,
                      color: onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.accountRestoreMsg),
                  const SizedBox(height: 12),
                  RadioGroup<BackupRestoreMode>(
                    groupValue: selected,
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selected = v);
                    },
                    child: Column(
                      children: [
                        RadioListTile<BackupRestoreMode>(
                          value: BackupRestoreMode.freshLoad,
                          title: Text(l10n.backupFreshLoad),
                          subtitle: Text(l10n.backupFreshLoadDesc),
                          secondary: const Icon(Icons.restore_page_outlined),
                        ),
                        const Divider(height: 1),
                        RadioListTile<BackupRestoreMode>(
                          value: BackupRestoreMode.migrate,
                          title: Text(l10n.backupMigrate),
                          subtitle: Text(l10n.backupMigrateDesc),
                          secondary: const Icon(Icons.auto_fix_high_outlined),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: Text(l10n.restore),
              ),
            ],
          ),
        );
      },
    );
    if (mode == null || !mounted) return;

    setState(() => _restoring = true);
    try {
      await BackupService.shared.restore(doc, mode: mode);
      if (!mounted) return;
      setState(() => _restoring = false);
      final migrated = mode == BackupRestoreMode.migrate && needsMigration;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(migrated
              ? l10n.backupMigratedRestored
              : l10n.accountConfigRestored)));
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _restoring = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.backupRestoreFailed}\n$e')));
    }
  }

  Future<void> _clearEventHistory(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final bool confirmed = await showConfirmDialog(
      context,
      title: l10n.settingsClearEventHistory,
      message: l10n.settingsClearHistoryMsg,
      confirmLabel: l10n.settingsClear,
    );
    if (confirmed) {
      await EventLogStore.shared.clear();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.settingsHistoryCleared)),
        );
      }
    }
  }

  // Future<void> _signOut(BuildContext context) async {
  //   final l10n = AppLocalizations.of(context);
  //   final bool confirmed = await showConfirmDialog(
  //     context,
  //     title: l10n.settingsSignOutDialog,
  //     message: l10n.settingsSignOutMsg,
  //     confirmLabel: l10n.settingsSignOutDialog,
  //   );
  //   if (confirmed && context.mounted) {
  //     SessionStore.shared.setSignedIn(false);
  //     Navigator.of(context)
  //         .restorablePushNamedAndRemoveUntil('/login', (route) => false);
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            // skip login in current publish
            // Card(
            //   child: ListTile(
            //     contentPadding: const EdgeInsets.all(12),
            //     leading: CircleAvatar(
            //       radius: 26,
            //       backgroundColor: onSurface,
            //       child: Text('AP',
            //           style: TextStyle(
            //               color: Theme.of(context).colorScheme.surface,
            //               fontWeight: FontWeight.w800)),
            //     ),
            //     title: const Text('Alex Popescu',
            //         style:
            //             TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            //     subtitle: const Text('alex.popescu@example.com'),
            //     trailing: const Icon(Icons.chevron_right),
            //     onTap: () => Navigator.of(context)
            //         .restorablePushNamed('/settings/account'),
            //   ),
            // ),
            // const SizedBox(height: 24),
            SectionHeader(l10n.settingsPreferences),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(l10n.settingsNotifications),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .restorablePushNamed('/settings/notifications'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.language_outlined),
                    title: Text(l10n.settingsLanguage),
                    subtitle: Text(l10n.settingsLanguageEn),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .restorablePushNamed('/settings/language'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.history_outlined),
                    title: Text(l10n.settingsClearEventHistory),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _clearEventHistory(context),
                  ),
                  const Divider(height: 1),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: themeModeNotifier,
                    builder: (context, mode, _) => ListTile(
                      leading: const Icon(Icons.contrast_outlined),
                      title: Text(l10n.settingsAppearance),
                      subtitle: Text(appearanceLabel(mode, l10n)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context)
                          .restorablePushNamed('/settings/appearance'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const ModuleKeepAliveSettings(),
            const SizedBox(height: 24),
            SectionHeader(l10n.settingsLocation),
            ListenableBuilder(
              listenable: SettingsStore.shared,
              builder: (context, _) => Card(
                child: ListTile(
                  leading: const Icon(Icons.other_houses_outlined),
                  title: Text(l10n.settingsHome),
                  subtitle: Text(
                    SettingsStore.shared.locationName.isNotEmpty
                        ? SettingsStore.shared.locationName
                        : l10n.settingsSingleLocation,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SectionHeader(l10n.settingsCommandProtocol),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.settingsCommandProtocolHint,
                style: TextStyle(
                  color: onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            ),
            ListenableBuilder(
              listenable: SettingsStore.shared,
              builder: (context, _) => Card(
                child: RadioGroup<CommandTransportMode>(
                  groupValue: SettingsStore.shared.commandTransport,
                  onChanged: (v) {
                    if (v != null) SettingsStore.shared.setCommandTransport(v);
                  },
                  child: Column(
                    children: [
                      RadioListTile<CommandTransportMode>(
                        value: CommandTransportMode.tcp,
                        title: Text(l10n.settingsCommandProtocolTcp),
                        subtitle: Text(l10n.settingsCommandProtocolTcpHint),
                        secondary: const Icon(Icons.dns_outlined),
                      ),
                      const Divider(height: 1),
                      RadioListTile<CommandTransportMode>(
                        value: CommandTransportMode.http,
                        title: Text(l10n.settingsCommandProtocolHttp),
                        subtitle: Text(l10n.settingsCommandProtocolHttpHint),
                        secondary: const Icon(Icons.http_outlined),
                      ),
                      const Divider(height: 1),
                      RadioListTile<CommandTransportMode>(
                        value: CommandTransportMode.https,
                        title: Text(l10n.settingsCommandProtocolHttps),
                        subtitle: Text(l10n.settingsCommandProtocolHttpsHint),
                        secondary: const Icon(Icons.https_outlined),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // skip login in current publish
            // const SizedBox(height: 24),
            // SizedBox(
            //   width: double.infinity,
            //   height: 48,
            //   child: OutlinedButton.icon(
            //     style: OutlinedButton.styleFrom(
            //       foregroundColor: AppColors.offlineAlert,
            //       side: const BorderSide(
            //           color: AppColors.offlineAlert, width: 1.4),
            //     ),
            //     onPressed: () => _signOut(context),
            //     icon: const Icon(Icons.logout),
            //     label: Text(l10n.settingsSignOut),
            //   ),
            // ),
            const SizedBox(height: 24),
            SectionHeader(l10n.accountCloudSection),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.cloud_done_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(l10n.accountLastBackup(
                                formatLogTimestamp(_lastBackup, l10n)))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.accountBackupDesc,
                      style: TextStyle(
                          fontSize: 12,
                          color: onSurface.withValues(alpha: 0.6)),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                              onPressed: _restoring ? null : _restoreBackup,
                              child: _restoring
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    )
                                  : Text(l10n.restore)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _backingUp ? null : _backupNow,
                            child: _backingUp
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
                                    ),
                                  )
                                : Text(l10n.accountBackUpNow),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final String version =
                      snapshot.data?.version ?? (snapshot.hasError ? '?' : '');
                  return Text(l10n.appVersion(version),
                      style: TextStyle(
                          fontSize: 12,
                          color: onSurface.withValues(alpha: 0.4)));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
