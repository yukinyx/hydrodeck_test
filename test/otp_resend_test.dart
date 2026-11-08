import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrodeck_test/main.dart';

void main() {
  testWidgets(
    'OTP resend countdown updates and successful resend replaces code',
    (WidgetTester tester) async {
      var now = DateTime(2026, 11, 6);
      final service = _FakeOtpCodeService();
      await tester.pumpWidget(
        MaterialApp(
          home: OtpVerificationScreen(
            email: 'grower@example.com',
            flow: 'signup',
            otpService: service,
            now: () => now,
          ),
        ),
      );

      expect(find.text('Resend code in 00:03'), findsOneWidget);
      var resendButton = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Resend code in 00:03'),
          matching: find.byType(TextButton),
        ),
      );
      expect(resendButton.onPressed, isNull);

      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 00:02'), findsOneWidget);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Resend code'), findsOneWidget);

      service.failNextSend = true;
      await tester.tap(find.text('Resend code'));
      await tester.pump();
      expect(find.text('The mail service is unavailable.'), findsOneWidget);
      expect(find.text('Resend code'), findsOneWidget);

      service.failNextSend = false;
      await tester.tap(find.text('Resend code'));
      await tester.pump();
      expect(find.text('Resend code in 03:00'), findsOneWidget);
      expect(
        service.verifyCode(email: 'grower@example.com', code: '111111'),
        isFalse,
      );
      expect(
        service.verifyCode(email: 'grower@example.com', code: '222222'),
        isTrue,
      );

      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 02:59'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _FakeOtpCodeService implements OtpCodeService {
  String activeCode = '111111';
  bool failNextSend = false;

  @override
  String? get lastError =>
      failNextSend ? 'The mail service is unavailable.' : null;

  @override
  Future<bool> sendCode(String email) async {
    if (failNextSend) return false;
    activeCode = '222222';
    return true;
  }

  @override
  bool isCodeExpired(String email) => false;

  @override
  bool verifyCode({required String email, required String code}) =>
      email == 'grower@example.com' && code == activeCode;
}
