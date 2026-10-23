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

  test('telemetry keeps MAIN readiness and heartbeat separate', () {
    final telemetry = HydrodeckTelemetry.fromJson({
      'wifiConnected': true,
      'firebaseReady': false,
      'firebaseHeartbeatFresh': true,
      'rainNodeOnline': false,
    });

    expect(telemetry.wifiConnected, isTrue);
    expect(telemetry.firebaseReady, isFalse);
    expect(telemetry.firebaseHeartbeatFresh, isTrue);
    expect(telemetry.reservoir.online, isFalse);
    expect(telemetry.reservoir.level, 'not_full');
    expect(
      ReservoirReading.fromSources(
        shared: {'level': 'full', 'online': false},
      ).level,
      'full',
    );
  });

  test('dashboard status has exactly three reachability labels', () {
    expect(
      dashboardConnectionStatus(
        localTelemetryFresh: true,
        firebaseHeartbeatFresh: false,
      ),
      'Connected locally',
    );
    expect(
      dashboardConnectionStatus(
        localTelemetryFresh: false,
        firebaseHeartbeatFresh: true,
      ),
      'Online',
    );
    expect(
      dashboardConnectionStatus(
        localTelemetryFresh: false,
        firebaseHeartbeatFresh: false,
      ),
      'ESP32 offline',
    );
  });

  test('reservoir model prefers shared data and reads legacy bed fields', () {
    final shared = ReservoirReading.fromSources(
      shared: {'level': 'full', 'online': true},
      bed1: {'reservoir': '50_or_below', 'rainNodeOnline': false},
    );
    expect(shared.level, 'full');
    expect(shared.online, isTrue);

    final legacy = ReservoirReading.fromSources(
      bed1: {'reservoir': 'above_50', 'rainNodeOnline': true},
    );
    expect(legacy.level, 'not_full');
    expect(legacy.online, isTrue);

    final legacyBed2 = ReservoirReading.fromSources(
      bed2: {'reservoir': 'full', 'rainNodeOnline': true},
    );
    expect(legacyBed2.level, 'full');
    expect(legacyBed2.online, isTrue);

    final legacySqlite = ReservoirReading.fromSources(
      bed1: '{"reservoir":"50_or_below","rainNodeOnline":true}',
    );
    expect(legacySqlite.level, 'not_full');
    expect(legacySqlite.online, isTrue);
    final legacyOffline = ReservoirReading.fromSources(
      shared: {'level': '50_or_below', 'online': false},
    );
    expect(legacyOffline.level, 'not_full');
    expect(legacyOffline.online, isFalse);
    final currentOffline = ReservoirReading.fromSources(
      shared: {'level': 'full', 'online': false},
    );
    expect(currentOffline.level, 'full');
    expect(reservoirLabel('full'), 'Full');
    expect(reservoirLabel('not_full'), 'Not full');
    expect(reservoirColor('full'), Colors.green.shade800);
    expect(reservoirColor('not_full'), Colors.orange);
  });

  test('scheduled cloud snapshots retain reservoir fields for both beds', () {
    const bed = GrowBedReading(
      temperature: 24.5,
      ph: 6.2,
      tds: 700,
      waterFull: true,
    );
    final snapshot = buildScheduledSnapshot(
      batchNumber: 3,
      at: DateTime.utc(2026, 10, 20, 2, 30),
      bed1: bed,
      bed2: bed,
      reservoir: const ReservoirReading(level: 'full', online: true),
    );
    final cloudMap = snapshot.toCloudMap();
    expect((cloudMap['reservoir'] as Map)['level'], 'full');
    expect((cloudMap['reservoir'] as Map)['online'], isTrue);
    expect((cloudMap['bed1'] as Map).containsKey('reservoir'), isFalse);
    expect((cloudMap['bed2'] as Map).containsKey('rainNodeOnline'), isFalse);
  });

  test(
    'telemetry shares reservoir data across both beds and accepts legacy data',
    () {
      final current = HydrodeckTelemetry.fromJson({
        'reservoir': {
          'level': 'full',
          'full': true,
          'online': true,
        },
      });
      expect(current.reservoir.level, 'full');
      expect(current.reservoir.online, isTrue);

      final localStatus = HydrodeckTelemetry.fromJson({
        'reservoir': 'above_50',
        'rainNodeOnline': true,
      });
      expect(localStatus.reservoir.level, 'not_full');
      expect(localStatus.reservoir.online, isTrue);

      final legacy = HydrodeckTelemetry.fromJson({
        'ph1': 6.2,
        'ph2': 6.4,
        'bed1': {'reservoir': 'above_50', 'rainNodeOnline': true},
      });
      expect(legacy.reservoir.level, 'not_full');
      expect(legacy.reservoir.online, isTrue);
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
    expect(find.text('RESERVOIR'), findsOneWidget);
    expect(find.text('RAIN offline'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('RESERVOIR')).dy,
      greaterThan(tester.getTopLeft(find.text('Grow Bed 2 Metrics')).dy),
    );

    await tester.tap(find.text('CONTROLS'));
    await tester.pumpAndSettle();

    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('PH LEVEL'), findsOneWidget);
    expect(find.text('WATER PUMP'), findsOneWidget);
    expect(find.text('NUTRIENT SOLUTION'), findsOneWidget);
    expect(find.text('GROW LIGHT'), findsOneWidget);
    expect(find.text('Rainwater unit offline'), findsNothing);

    final growLightButton = find.byKey(const ValueKey('grow-light-button'));
    expect(growLightButton, findsOneWidget);
    expect(find.text('OFF'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('water-pump-1-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('water-pump-2-toggle')), findsOneWidget);

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

  testWidgets('historical detail shows one shared reservoir card', (
    WidgetTester tester,
  ) async {
    const reading = GrowBedReading(
      temperature: 24.5,
      ph: 6.2,
      tds: 700,
      waterFull: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SnapshotDetailScreen(
          data: HistoricalData(
            timestamp: DateTime.utc(2026, 10, 20),
            pH: 6.2,
            temperature: '24.5°C',
            waterLevel: 'Water full',
            tds: 700,
            bed1: reading,
            bed2: reading,
            reservoir: const ReservoirReading(level: 'full', online: true),
          ),
          formattedTime: 'October 20, 2026',
        ),
      ),
    );

    expect(find.text('RESERVOIR'), findsOneWidget);
    expect(find.text('RAIN online'), findsOneWidget);
    expect(find.text('Grow Bed 1 (Historical Metrics)'), findsOneWidget);
    expect(find.text('Grow Bed 2 (Historical Metrics)'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('RESERVOIR')).dy,
      greaterThan(
        tester.getTopLeft(find.text('Grow Bed 2 (Historical Metrics)')).dy,
      ),
    );
  });
}
