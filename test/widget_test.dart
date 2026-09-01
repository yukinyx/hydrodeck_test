import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hydrodeck_test/main.dart';

void main() {
  testWidgets('dashboard shows dual-bed metrics and a single grow-light toggle', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HydroponicsDashboard(
          startDate: DateTime.now(),
          onEndPlanting: () {},
          initialIp: 'hydrodeck.local',
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Grow Bed 1 Metrics'), findsOneWidget);
    expect(find.text('Grow Bed 2 Metrics'), findsOneWidget);

    await tester.tap(find.text('CONTROLS'));
    await tester.pumpAndSettle();

    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('Grow Lights'), findsOneWidget);

    final growLightButton = find.byKey(const ValueKey('grow-light-button'));
    expect(growLightButton, findsOneWidget);
    expect(find.text('OFF'), findsWidgets);

    await tester.tap(growLightButton);
    await tester.pump();

    expect(find.text('ON'), findsWidgets);
  });
}
