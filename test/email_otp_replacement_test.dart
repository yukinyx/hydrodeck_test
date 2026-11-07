import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:email_otp/email_otp.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrodeck_test/main.dart';

void main() {
  test(
    'sending a replacement OTP invalidates the previously sent code',
    () async {
      final smtpServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        1025,
      );
      final sentMessages = <String>[];
      final smtpSubscription = smtpServer.listen((socket) {
        socket.write('220 HydroDeck test SMTP\r\n');
        var readingData = false;
        final message = StringBuffer();
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (readingData) {
                if (line == '.') {
                  sentMessages.add(message.toString());
                  message.clear();
                  readingData = false;
                  socket.write('250 Message accepted\r\n');
                } else {
                  message.writeln(line);
                }
                return;
              }

              if (line.startsWith('EHLO') || line.startsWith('HELO')) {
                socket.write('250-HydroDeck test SMTP\r\n250 SIZE 1000000\r\n');
              } else if (line.startsWith('MAIL FROM') ||
                  line.startsWith('RCPT TO')) {
                socket.write('250 OK\r\n');
              } else if (line == 'DATA') {
                readingData = true;
                socket.write('354 End data with <CR><LF>.<CR><LF>\r\n');
              } else if (line == 'QUIT') {
                socket.write('221 Bye\r\n');
                unawaited(socket.close());
              } else {
                socket.write('250 OK\r\n');
              }
            });
      });
      final previousDebugPrint = debugPrint;

      try {
        debugPrint = (String? message, {int? wrapWidth}) {};
        EmailOTP.config(
          appName: 'HydroDeck test',
          appEmail: 'test@example.com',
          otpLength: 6,
          otpType: OTPType.numeric,
          expiry: 0,
        );
        EmailOTP.setTemplate(template: '<p>Replacement test code: {{otp}}</p>');
        EmailOTP.setSMTP(
          emailPort: EmailPort.port1025,
          secureType: SecureType.none,
          host: '127.0.0.1',
          username: '',
          password: '',
        );

        final service = EmailOtpCodeService();
        expect(await service.sendCode('grower@example.com'), isTrue);
        final firstCode = EmailOTP.getOTP()!;
        expect(await service.sendCode('grower@example.com'), isTrue);
        var replacementCode = EmailOTP.getOTP()!;
        while (replacementCode == firstCode) {
          expect(await service.sendCode('grower@example.com'), isTrue);
          replacementCode = EmailOTP.getOTP()!;
        }

        expect(sentMessages, hasLength(greaterThanOrEqualTo(2)));
        expect(replacementCode, isNot(firstCode));
        expect(
          service.verifyCode(email: 'grower@example.com', code: firstCode),
          isFalse,
        );
        expect(
          service.verifyCode(
            email: 'grower@example.com',
            code: replacementCode,
          ),
          isTrue,
        );
      } finally {
        debugPrint = previousDebugPrint;
        await smtpSubscription.cancel();
        await smtpServer.close();
      }
    },
  );
}
