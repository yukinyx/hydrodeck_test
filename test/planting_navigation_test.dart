import 'package:flutter_test/flutter_test.dart';

import 'package:hydrodeck_test/planting_navigation.dart';
import 'package:hydrodeck_test/main.dart' show ActivePlantingSession;

void main() {
  group('planting navigation', () {
    test('a new authenticated app session starts at Start/Continue', () {
      final navigation = PlantingNavigationState();
      final activeSession = ActivePlantingSession(
        batchNumber: 4,
        startDate: DateTime(2026, 10, 20),
      );

      expect(activeSession.batchNumber, 4);
      expect(navigation.page, PlantingNavigationPage.startContinue);
    });

    test('starting or continuing opens the dashboard and preserves the run', () {
      final navigation = PlantingNavigationState();
      final activeSession = ActivePlantingSession(
        batchNumber: 4,
        startDate: DateTime(2026, 10, 20),
      );

      navigation.showDashboard();

      expect(navigation.page, PlantingNavigationPage.dashboard);
      expect(activeSession.batchNumber, 4);
      expect(activeSession.startDate, DateTime(2026, 10, 20));
    });

    test('session refreshes and duplicate updates keep the dashboard selected', () {
      final navigation = PlantingNavigationState()
        ..showDashboard()
        ..showDashboard();

      final refreshedSession = ActivePlantingSession(
        batchNumber: 4,
        startDate: DateTime(2026, 10, 20),
      );

      expect(refreshedSession.batchNumber, 4);
      expect(navigation.page, PlantingNavigationPage.dashboard);
    });

    test('ending planting returns to Start/Continue', () {
      final navigation = PlantingNavigationState()..showDashboard();

      navigation.showStartContinue();

      expect(navigation.page, PlantingNavigationPage.startContinue);
    });

    test('sign-out followed by login starts a fresh planting flow', () {
      final signedInNavigation = PlantingNavigationState()
        ..showDashboard();

      final navigationAfterLogin = PlantingNavigationState();

      expect(signedInNavigation.page, PlantingNavigationPage.dashboard);
      expect(
        navigationAfterLogin.page,
        PlantingNavigationPage.startContinue,
      );
    });
  });
}
