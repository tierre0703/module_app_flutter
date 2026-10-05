// Widget tests for the Account screen's profile section. Backup/restore moved
// to the Settings screen (see test/screens/settings_screen_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';
import 'package:soleux_device_manager/screens/account_screen.dart';

void main() {
  testWidgets('Account screen renders the profile section', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AccountScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Alex Popescu'), findsOneWidget);
    expect(find.text('alex.popescu@example.com'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Change password'), findsOneWidget);
    // Backup/restore no longer lives on this screen.
    expect(find.text('Back Up Now'), findsNothing);
    expect(find.text('Restore'), findsNothing);
  });
}
