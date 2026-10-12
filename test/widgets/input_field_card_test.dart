// Tests for the module-screen input card behaviour: a disabled input stays
// visible (greyed out) instead of being hidden, the toggle switch shows and
// changes the enabled/disabled state in place, tapping the card body opens the
// editor (there is no separate edit icon), and a disabled input never
// dispatches a virtual-input command.
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
  ValueChanged<bool>? onEnabledChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: InputFieldCard(
        input: input,
        onHoldChanged: onHoldChanged,
        onEdit: onEdit ?? () {},
        onEnabledChanged: onEnabledChanged,
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
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('a disabled input stays visible, shows the state and is inert',
      (tester) async {
    final calls = <bool>[];
    final input = _input(enabled: false);
    await _pump(tester, input, onHoldChanged: (v) async => calls.add(v));

    // Still rendered - not hidden from the module screen.
    expect(find.text('Switch 1'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(calls, isEmpty,
        reason: 'a disabled input must not be operable from the app');
  });

  testWidgets('the toggle switch reports a new enabled state', (tester) async {
    final changes = <bool>[];
    await _pump(tester, _input(enabled: true),
        onHoldChanged: (_) async {}, onEnabledChanged: changes.add);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(changes, [false],
        reason: 'flipping the switch reports the input must be disabled');
  });

  testWidgets('tapping the card body opens the editor and has no edit icon',
      (tester) async {
    var edits = 0;
    await _pump(tester, _input(enabled: false),
        onHoldChanged: (_) async {}, onEdit: () => edits++);

    // The separate edit icon was replaced by the toggle switch.
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    await tester.tap(find.text('Switch 1'));
    await tester.pump();

    expect(edits, 1);
  });
}
