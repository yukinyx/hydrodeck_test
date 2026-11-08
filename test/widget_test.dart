import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hydrodeck_test/main.dart';
import 'package:hydrodeck_test/weather_service.dart';

void main() {
  testWidgets('HydroDeck logo PNG renders within its square bounds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 112,
            height: 112,
            child: Image.asset(
              'hydrodeck_logo.png',
              fit: BoxFit.contain,
              semanticLabel: 'HydroDeck logo',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(Image)), const Size(112, 112));
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

  test('local status parses flat actuator fields and legacy values', () {
    final local = HydrodeckTelemetry.fromJson({
      'waterPump1': 1,
      'waterPump2': 'off',
      'phUp1': true,
      'nutrient2': '0',
      'growLight': 'on',
    });

    expect(local.actuatorStates['waterPump1'], isTrue);
    expect(local.actuatorStates['waterPump2'], isFalse);
    expect(local.actuatorStates['phUp1'], isTrue);
    expect(local.actuatorStates['nutrient2'], isFalse);
    expect(local.actuatorStates['growLight'], isTrue);
    expect(local.growLightOn, isTrue);
  });

  test(
    'temperature status uses live validity and the strict hot threshold',
    () {
      expect(
        temperatureStatusLabel(temperature: 28, valid: true, fresh: true),
        'Normal',
      );
      expect(
        temperatureStatusLabel(temperature: 28.1, valid: true, fresh: true),
        'Too hot',
      );
      expect(
        temperatureStatusLabel(temperature: 24, valid: true, fresh: false),
        'Unavailable',
      );
      expect(
        temperatureStatusLabel(
          temperature: double.nan,
          valid: true,
          fresh: true,
        ),
        'Unavailable',
      );
      expect(
        GrowBedReading.fromMap({'temp': 'invalid'}).temperatureValid,
        isFalse,
      );
      expect(
        GrowBedReading.fromMap({
          'temp': 24,
          'tempValid': false,
        }).temperatureValid,
        isFalse,
      );
    },
  );

  test(
    'pH threshold settings reject non-finite, out-of-range, and crossed pairs',
    () {
      expect(isValidPhThresholds(5.5, 7.0), isTrue);
      expect(isValidPhThresholds(double.nan, 7), isFalse);
      expect(isValidPhThresholds(3.9, 7), isFalse);
      expect(isValidPhThresholds(5.5, 9.1), isFalse);
      expect(isValidPhThresholds(7, 7), isFalse);
    },
  );

  test('local flat status parses actuator values and wins while fresh', () {
    final local = HydrodeckTelemetry.fromJson({
      'waterPump1': 1,
      'waterPump2': 'off',
      'phUp1': true,
      'nutrient2': '0',
      'growLight': 'on',
    });

    expect(local.actuatorStates['waterPump1'], isTrue);
    expect(local.actuatorStates['waterPump2'], isFalse);
    expect(local.actuatorStates['phUp1'], isTrue);
    expect(local.actuatorStates['nutrient2'], isFalse);
    expect(local.growLightOn, isTrue);
    expect(shouldApplyFirebaseDeviceState(localTelemetryFresh: true), isFalse);
    expect(shouldApplyFirebaseDeviceState(localTelemetryFresh: false), isTrue);
    expect(
      shouldShowWifiSetupPrompt(
        localDeviceReachable: true,
        cloudReachable: false,
      ),
      isFalse,
    );
    expect(
      shouldShowWifiSetupPrompt(
        localDeviceReachable: false,
        cloudReachable: true,
      ),
      isFalse,
    );
    expect(
      shouldShowWifiSetupPrompt(
        localDeviceReachable: false,
        cloudReachable: false,
      ),
      isTrue,
    );
    expect(
      reportedActuatorStateConfirmsRequest(
        requestedState: true,
        reportedState: true,
      ),
      isTrue,
    );
    expect(
      reportedActuatorStateConfirmsRequest(
        requestedState: true,
        reportedState: false,
      ),
      isFalse,
    );
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

  test('offline messaging distinguishes Firebase and local ESP32 access', () {
    expect(
      dashboardOfflineBannerMessage(
        firebaseConnected: true,
        localDeviceReachable: false,
      ),
      isNull,
    );
    expect(
      shouldShowOfflineHotspotPrompt(
        firebaseConnected: true,
        localDeviceReachable: false,
      ),
      isFalse,
    );

    final localOnlyMessage = dashboardOfflineBannerMessage(
      firebaseConnected: false,
      localDeviceReachable: true,
    )!;
    expect(localOnlyMessage, contains('pump control may still work'));
    expect(
      localOnlyMessage,
      contains('Cloud logs and history cannot be loaded or synced'),
    );
    expect(
      localOnlyMessage,
      contains('history already saved on this phone is kept'),
    );
    expect(
      shouldShowOfflineHotspotPrompt(
        firebaseConnected: false,
        localDeviceReachable: true,
      ),
      isFalse,
    );

    expect(
      dashboardOfflineBannerMessage(
        firebaseConnected: false,
        localDeviceReachable: false,
      ),
      contains('Connect to the ESP32 hotspot'),
    );
    expect(
      shouldShowOfflineHotspotPrompt(
        firebaseConnected: false,
        localDeviceReachable: false,
      ),
      isTrue,
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
        'reservoir': {'level': 'full', 'full': true, 'online': true},
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
    expect(find.byIcon(Icons.science_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.water_drop_outlined), findsNWidgets(4));
    expect(find.byIcon(Icons.device_thermostat), findsNWidgets(2));
    expect(find.byIcon(Icons.water), findsNothing);
    expect(find.text('Unavailable'), findsNWidgets(2));
    expect(find.text('Needs water'), findsNWidgets(2));
    expect(find.text('RESERVOIR'), findsOneWidget);
    expect(find.byIcon(Icons.science_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.water_drop_outlined), findsNWidgets(4));
    expect(find.byIcon(Icons.device_thermostat), findsNWidgets(2));
    expect(find.text('Unavailable'), findsNWidgets(2));
    expect(find.text('RAIN offline'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('RESERVOIR')).dy,
      greaterThan(tester.getTopLeft(find.text('Grow Bed 2 Metrics')).dy),
    );

    await tester.tap(find.byTooltip('Connection guide'));
    await tester.pumpAndSettle();
    expect(find.text('Connect the ESP32'), findsOneWidget);
    expect(
      find.textContaining(
        'Wi-Fi alone does not mean internet or cloud access is working.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Grow-bed water level reports whether each bed sensor says Water full or Needs water.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

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
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('ON'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('water-pump-1-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('water-pump-2-toggle')), findsOneWidget);

    await tester.tap(find.byTooltip('Controls help'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Only one water pump may run at a time'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Only one chemical dose runs at a time'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();
    expect(find.text('Network Configuration'), findsNothing);
    expect(find.text('ESP32 IP or Hostname'), findsNothing);
    expect(find.text('hydrodeck.local'), findsNothing);
    expect(find.text('ESP32 Hotspot Setup'), findsOneWidget);
    expect(find.text('Connect to ESP32 Hotspot'), findsOneWidget);
    expect(find.text('Theme'), findsNothing);
    expect(find.text('Light'), findsNothing);
    expect(find.text('System'), findsNothing);

    await tester.tap(find.text('DATA'));
    await tester.pumpAndSettle();
    expect(
      find.text('Saved ESP32 snapshots (every 20 minutes, Manila time):'),
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

  testWidgets('login fields validate on blur and update after correction', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(onSignup: () {}, onAuthenticated: (_) {}),
      ),
    );

    expect(find.text('Please enter a valid email address.'), findsNothing);
    final fields = find.byType(TextField);
    await tester.tap(fields.first);
    await tester.enterText(fields.first, 'not-an-email');
    await tester.tap(fields.at(1));
    await tester.pump();
    expect(find.text('Please enter a valid email address.'), findsOneWidget);

    await tester.tap(fields.first);
    await tester.enterText(fields.first, 'grower@example.com');
    await tester.pump();
    expect(find.text('Please enter a valid email address.'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'example@gmail.com',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '********',
      ),
      findsOneWidget,
    );
  });

  testWidgets('signup validates fields on blur and clears corrected errors', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SignupScreen(onLogin: () {}, onAuthenticated: (_) {}),
      ),
    );

    final fields = find.byType(TextField);
    expect(find.text('Please enter a valid email address.'), findsNothing);
    await tester.tap(fields.first);
    await tester.enterText(fields.first, 'not-an-email');
    await tester.tap(fields.at(1));
    await tester.pump();
    expect(find.text('Please enter a valid email address.'), findsOneWidget);

    await tester.tap(fields.first);
    await tester.enterText(fields.first, 'grower@example.com');
    await tester.pump();
    expect(find.text('Please enter a valid email address.'), findsNothing);
  });

  testWidgets('weather screen uses current location and offers a retry', (
    WidgetTester tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WeatherDetailScreen(
          weatherLoader: () async {
            attempts++;
            if (attempts == 1) {
              throw const WeatherException(
                'Location services are turned off. Turn them on, then retry.',
              );
            }
            return const WeatherConditions(
              location: WeatherLocation(
                name: 'Current location',
                latitude: 14.6,
                longitude: 121.0,
              ),
              temperature: 27,
              feelsLike: 29,
              humidity: 70,
              precipitation: 0,
              windSpeed: 10,
              weatherCode: 0,
              hourly: [],
              forecast: [],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current weather'), findsOneWidget);
    expect(find.text('City or place'), findsNothing);
    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('signup form remains scrollable on a small keyboard viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: SignupScreen(onLogin: () {}, onAuthenticated: (_) {}),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Sign up'));
    expect(find.text('Sign up'), findsOneWidget);
  });
}
