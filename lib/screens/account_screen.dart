// lib/screens/account_screen.dart
//
// Brief section 3.1 "Account Management and Cloud Synchronization":
// profile details and password change. Backup/restore lives on the Settings
// screen (see SettingsScreen); this screen keeps only the account profile.
import 'package:flutter/material.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';

import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _nameController = TextEditingController(text: 'Alex Popescu');
  final _emailController =
      TextEditingController(text: 'alex.popescu@example.com');

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).accountChangePassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentController,
              obscureText: true,
              decoration: InputDecoration(
                  labelText:
                      AppLocalizations.of(context).accountCurrentPassword),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newController,
              obscureText: true,
              decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).accountNewPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () {
                FocusScope.of(context).unfocus();
                Navigator.pop(context, false);
              },
              child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(
              onPressed: () {
                FocusScope.of(context).unfocus();
                Navigator.pop(context, true);
              },
              child: Text(AppLocalizations.of(context).update)),
        ],
      ),
    );
    currentController.dispose();
    newController.dispose();
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).accountPasswordUpdated)));
    }
  }

  void _saveProfile() {
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).accountProfileUpdated)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.outerPadding),
          children: [
            SectionHeader(l10n.accountProfileSection),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                  labelText: l10n.accountFullName,
                  prefixIcon: const Icon(Icons.person_outline)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              readOnly: true,
              decoration: InputDecoration(
                  labelText: l10n.accountEmail,
                  prefixIcon: const Icon(Icons.mail_outline)),
            ),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: _saveProfile, child: Text(l10n.accountSaveChanges)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _changePassword,
              icon: const Icon(Icons.lock_reset_outlined),
              label: Text(l10n.accountChangePassword),
            ),
          ],
        ),
      ),
    );
  }
}
