import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrodeck_test/main.dart';

void main() {
  testWidgets('signup requires policy consent and keeps phone validation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SignupScreen(onLogin: () {}, onAuthenticated: (_) {}),
      ),
    );

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.ensureVisible(find.text('Sign up'));
    await tester.tap(find.text('Sign up'));
    await tester.pump();
    expect(
      find.text('Accept the Terms of Use and Privacy Policy to sign up.'),
      findsOneWidget,
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.ensureVisible(find.text('Sign up'));
    await tester.tap(find.text('Sign up'));
    await tester.pump();
    expect(
      find.text('Accept the Terms of Use and Privacy Policy to sign up.'),
      findsNothing,
    );

    final phoneField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Phone number',
      ),
    );
    expect(phoneField.maxLength, 11);
    expect(phoneField.decoration!.counterText, '');

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Phone number',
      ),
      '08123456789',
    );
    await tester.ensureVisible(find.text('Sign up'));
    await tester.tap(find.text('Sign up'));
    await tester.pump();
    expect(
      find.text('Phone number must be 11 digits and start with 09.'),
      findsOneWidget,
    );
  });

  testWidgets('policy links in Settings open both complete documents', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PolicySettingsSection(onContactSupport: () {})),
      ),
    );

    await tester.tap(find.text('Terms of Use'));
    await tester.pumpAndSettle();
    final termsScreen = tester.widget<PolicyDocumentScreen>(
      find.byType(PolicyDocumentScreen),
    );
    expect(termsScreen.title, 'Terms of Use');
    expect(termsScreen.document, contains('14. Contact'));
    expect(termsScreen.document, contains('hydrodecknt@gmail.com'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    final privacyScreen = tester.widget<PolicyDocumentScreen>(
      find.byType(PolicyDocumentScreen),
    );
    expect(privacyScreen.title, 'Privacy Policy');
    expect(privacyScreen.document, contains('6. Retention and deletion'));
    expect(privacyScreen.document, contains('Retention schedule'));
    expect(
      privacyScreen.document,
      contains('Official Personal Information Controller'),
    );
  });

  testWidgets('signup policy links open the same policy screens', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SignupScreen(onLogin: () {}, onAuthenticated: (_) {}),
      ),
    );

    await tester.ensureVisible(find.byKey(const ValueKey('signup-terms-link')));
    await tester.tap(find.byKey(const ValueKey('signup-terms-link')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PolicyDocumentScreen>(find.byType(PolicyDocumentScreen))
          .document,
      contains('1. About HydroDeck'),
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('signup-privacy-link')),
    );
    await tester.tap(find.byKey(const ValueKey('signup-privacy-link')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PolicyDocumentScreen>(find.byType(PolicyDocumentScreen))
          .document,
      contains('1. Who is responsible for your information?'),
    );
  });

  testWidgets('support form shows success and blocks duplicate submissions', (
    WidgetTester tester,
  ) async {
    final response = Completer<http.Response>();
    var requestCount = 0;
    final client = MockClient((request) {
      requestCount++;
      expect(request.url, hydrodeckSupportEndpoint);
      expect(jsonDecode(request.body), {
        'name': 'Hydroponics User',
        'email': 'grower@example.com',
        'subject': 'Sensor question',
        'message': 'The pH reading is not updating.',
      });
      return response.future;
    });

    await tester.pumpWidget(
      MaterialApp(home: SupportRequestScreen(client: client)),
    );
    await _fillSupportForm(tester);
    await tester.tap(find.byKey(const ValueKey('support-submit')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('support-submit')),
      warnIfMissed: false,
    );
    expect(requestCount, 1);

    response.complete(http.Response('{}', 200));
    await tester.pumpAndSettle();
    expect(
      find.text('Your support request was submitted successfully.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    client.close();
  });

  testWidgets('support form reports unsuccessful Formspree responses', (
    WidgetTester tester,
  ) async {
    final client = MockClient((_) async => http.Response('not accepted', 500));
    await tester.pumpWidget(
      MaterialApp(home: SupportRequestScreen(client: client)),
    );
    await _fillSupportForm(tester);
    await tester.tap(find.byKey(const ValueKey('support-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'We could not submit your request. Please check your connection and try again.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    client.close();
  });

  testWidgets('support app bar inherits the current theme', (
    WidgetTester tester,
  ) async {
    const surface = Color(0xFF103C36);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          appBarTheme: const AppBarTheme(
            backgroundColor: surface,
            foregroundColor: Color(0xFFEAF3EF),
          ),
        ),
        home: SupportRequestScreen(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      ),
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, isNull);
    expect(appBar.foregroundColor, isNull);
    final appBarMaterial = tester.widget<Material>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first,
    );
    expect(appBarMaterial.color, surface);
  });
}

Future<void> _fillSupportForm(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('support-name')),
    'Hydroponics User',
  );
  await tester.enterText(
    find.byKey(const ValueKey('support-email')),
    'grower@example.com',
  );
  await tester.enterText(
    find.byKey(const ValueKey('support-subject')),
    'Sensor question',
  );
  await tester.enterText(
    find.byKey(const ValueKey('support-message')),
    'The pH reading is not updating.',
  );
}
