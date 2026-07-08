// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_ezw_ble_example/main.dart';

void main() {
  testWidgets('shows auto reconnect demo', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    expect(find.text('BLE Auto Reconnect'), findsOneWidget);
    expect(find.text('No device added'), findsOneWidget);
    expect(find.text('Add device'), findsOneWidget);

    await tester.tap(find.text('Add device'));
    await tester.pumpAndSettle();

    expect(find.text('Add BLE Device'), findsOneWidget);
    expect(find.text('BLE Config:'), findsOneWidget);
    expect(find.text('Add Config'), findsOneWidget);
    expect(find.text('Add a BLE config to start scanning'), findsOneWidget);
    expect(find.text('BLE config JSON'), findsNothing);

    await tester.tap(find.text('Add Config'));
    await tester.pumpAndSettle();

    expect(find.text('BLE config JSON'), findsOneWidget);
    expect(find.text('Paste BleConfig JSON or JSON array'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('BLE config JSON'), findsNothing);
    expect(find.text('Add Config'), findsOneWidget);
  });
}
