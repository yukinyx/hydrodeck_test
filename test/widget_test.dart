import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hydrodeck_test/main.dart';

void main() {
  test('active persisted session skips the Start Planting route', () {
    expect(
      shouldShowStartPlantingScreen(
        ActivePlantingSession(
          batchNumber: 4,
          startDate: DateTime(2026, 10, 20),
        ),
      ),
      isFalse,
    );
    expect(shouldShowStartPlantingScreen(null), isTrue);
  });
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

  test(
    'grow bed reservoir fields round-trip and default for older records',
    () {
      final current = GrowBedReading.fromMap({
        'temp': 24.5,
        'ph': 6.2,
        'tds': 700,
        'water': 'full',
        'reservoir': 'above_50',
        'rainNodeOnline': true,
      });
      expect(current.toMap()['reservoir'], 'above_50');
      expect(current.toMap()['rainNodeOnline'], isTrue);

      final legacy = GrowBedReading.fromMap({'temp': 24.5, 'ph': 6.2});
      expect(legacy.reservoir, 'unknown');
      expect(legacy.rainNodeOnline, isFalse);
      expect(legacy.toMap()['reservoir'], 'unknown');
    },
  );

  test('scheduled cloud snapshots retain reservoir fields for both beds', () {
    const bed = GrowBedReading(
      temperature: 24.5,
      ph: 6.2,
      tds: 700,
      waterFull: true,
      reservoir: 'full',
      rainNodeOnline: true,
    );
    final snapshot = buildScheduledSnapshot(
      batchNumber: 3,
      at: DateTime.utc(2026, 10, 20, 2, 30),
      bed1: bed,
      bed2: bed,
    );
    final cloudMap = snapshot.toCloudMap();
    expect((cloudMap['bed1'] as Map)['reservoir'], 'full');
    expect((cloudMap['bed2'] as Map)['rainNodeOnline'], isTrue);
  });

  test(
    'telemetry shares reservoir data across both beds and accepts legacy data',
    () {
      final current = HydrodeckTelemetry.fromJson({
        'reservoir': {
          'level': 'full',
          'mid': true,
          'full': true,
          'online': true,
        },
      });
      expect(current.bed1.reservoir, 'full');
      expect(current.bed2.reservoir, 'full');
      expect(current.bed1.rainNodeOnline, isTrue);
      expect(current.bed2.rainNodeOnline, isTrue);

      final localStatus = HydrodeckTelemetry.fromJson({
        'reservoir': 'above_50',
        'rainNodeOnline': true,
      });
      expect(localStatus.bed1.reservoir, 'above_50');
      expect(localStatus.bed2.rainNodeOnline, isTrue);

      final legacy = HydrodeckTelemetry.fromJson({'ph1': 6.2, 'ph2': 6.4});
      expect(legacy.bed1.reservoir, 'unknown');
      expect(legacy.bed2.rainNodeOnline, isFalse);
    },
  );

  testWidgets('active planting session offers continue instead of start', (
    WidgetTester tester,
  ) async {
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

  testWidgets('dashboard shows the dual-bed controls layout', (
    WidgetTester tester,
  ) async {
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
    expect(find.text('RESERVOIR'), findsNWidgets(2));

    await tester.tap(find.text('CONTROLS'));
    await tester.pumpAndSettle();

    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('PH LEVEL'), findsOneWidget);
    expect(find.text('WATER PUMP'), findsOneWidget);
    expect(find.text('NUTRIENT SOLUTION'), findsOneWidget);
    expect(find.text('GROW LIGHT'), findsOneWidget);
    expect(find.text('Rainwater unit offline'), findsNWidgets(2));

    final growLightButton = find.byKey(const ValueKey('grow-light-button'));
    expect(growLightButton, findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(
      find.text('Saved ESP32 snapshots (every 30 minutes, Manila time):'),
      findsOneWidget,
    );

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to ESP32 Hotspot'), findsOneWidget);
    expect(find.text('Send Wi-Fi to ESP32'), findsOneWidget);
  });
}
