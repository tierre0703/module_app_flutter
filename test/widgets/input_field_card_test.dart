// Tests for the module-screen input card behaviour: a disabled input stays
// visible (greyed out with a "Disabled" badge) instead of being hidden, it
// exposes an edit button, and it never dispatches a virtual-input command.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/l10n/gen/app_localizations.dart';
import 'package:soleux_device_manager/models/models.dart';
import 'package:soleux_device_manager/widgets/common_widgets.dart';

PhysicalInput _input({required bool enabled}) => PhysicalInput(
      id: 'i1',
      name: 'Switch 1',
      mode: InputMode.momentary,
      enabled: enabled,
    );

Future<void> _pump(
  WidgetTester tester,
  PhysicalInput input, {
  required Future<void> Function(bool) onHoldChanged,
  VoidCallback? onEdit,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: InputFieldCard(
        input: input,
        onHoldChanged: onHoldChanged,
        onEdit: onEdit ?? () {},
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('an enabled input dispatches a virtual-input press',
      (tester) async {
    final calls = <bool>[];
    final input = _input(enabled: true);
    await _pump(tester, input, onHoldChanged: (v) async => calls.add(v));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(calls, [true, false],
        reason: 'a press drives the virtual input true then false');
    expect(find.text('Disabled'), findsNothing);
  });

  testWidgets('a disabled input stays visible, shows the state and is inert',
      (tester) async {
    final calls = <bool>[];
    final input = _input(enabled: false);
    await _pump(tester, input, onHoldChanged: (v) async => calls.add(v));

    // Still rendered - not hidden from the module screen.
    expect(find.text('Switch 1'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(calls, isEmpty,
        reason: 'a disabled input must not be operable from the app');
  });

  testWidgets('the edit button opens the input configuration',
      (tester) async {
    var edits = 0;
    final input = _input(enabled: false);
    await _pump(tester, input,
        onHoldChanged: (_) async {}, onEdit: () => edits++);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    expect(edits, 1);
  });
}
