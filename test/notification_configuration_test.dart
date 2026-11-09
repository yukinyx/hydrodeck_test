import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrodeck_test/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notification IDs stay within the Android integer range', () {
    final largeTimestampId = notificationIdFor('1794195673734000');
    final invalidId = notificationIdFor('not-a-number');

    expect(largeTimestampId, inInclusiveRange(0, 0x7FFFFFFF));
    expect(invalidId, inInclusiveRange(0, 0x7FFFFFFF));
  });

  test('initializes the pH alert channel with its raw custom sound', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const notificationChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationChannel, null);
      debugDefaultTargetPlatformOverride = previousPlatform;
    });

    await NotificationHelper.init();

    final createChannelCall = calls.firstWhere(
      (call) => call.method == 'createNotificationChannel',
    );
    final arguments = createChannelCall.arguments! as Map<Object?, Object?>;
    expect(arguments['id'], 'ph_alerts_channel_v2');
    expect(arguments['name'], 'pH Level Alerts');
    expect(arguments['description'], 'Alerts when pH is out of range');
    expect(arguments['importance'], Importance.max.value);
    expect(arguments['playSound'], isTrue);
    expect(arguments['sound'], 'hydrodeck_drop');
  });
}
