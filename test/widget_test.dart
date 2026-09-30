import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hydrodeck_test/main.dart';

void main() {
  test('telemetry recognizes the firmware actuator identifiers', () {
    final telemetry = HydrodeckTelemetry.fromJson({
      'actuators': {
        'waterPump1': true,
        'nutrient1': 1,
        'waterPump2': false,
        'nutrient2': 'on',
      },
    });

    expect(telemetry.actuatorStates['waterPump1'], isTrue);
    expect(telemetry.actuatorStates['nutrient1'], isTrue);
    expect(telemetry.actuatorStates['waterPump2'], isFalse);
    expect(telemetry.actuatorStates['nutrient2'], isTrue);
  });

  testWidgets('active planting session offers continue instead of start', (WidgetTester tester) async {
    var started = false;
    var continued = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StartPlantingScreen(
          onStart: () => started = true,
          onContinue: () => continued = true,
          activeSession: ActivePlantingSession(
            batchNumber: 3,
            startDate: DateTime(2026, 9, 1),
          ),
          history: <PlantingRecord>[],
        ),
      ),
    );

    expect(find.text('Continue Planting'), findsOneWidget);
    expect(find.text('Start Planting'), findsNothing);
    await tester.tap(find.text('Continue Planting'));
    expect(continued, isTrue);
    expect(started, isFalse);
  });

  testWidgets('dashboard shows the dual-bed controls layout', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HydroponicsDashboard(
          startDate: DateTime.now(),
          onEndPlanting: () {},
          initialIp: 'hydrodeck.local',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Grow Bed 1 Metrics'), findsOneWidget);
    expect(find.text('Grow Bed 2 Metrics'), findsOneWidget);

    await tester.tap(find.text('CONTROLS'));
    await tester.pumpAndSettle();

    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('PH LEVEL'), findsOneWidget);
    expect(find.text('WATER PUMP'), findsOneWidget);
    expect(find.text('NUTRIENT SOLUTION'), findsOneWidget);
    expect(find.text('GROW LIGHT'), findsOneWidget);

    final growLightButton = find.byKey(const ValueKey('grow-light-button'));
    expect(growLightButton, findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(find.text('Saved snapshots (uploaded every 5 minutes):'), findsOneWidget);

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to ESP32 Hotspot'), findsOneWidget);
    expect(find.text('Send Wi-Fi to ESP32'), findsOneWidget);
  });
}
