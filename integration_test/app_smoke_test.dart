import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/main.dart' as app;

/// End-to-end smoke test that exercises the whole app boot path on a real
/// device or simulator: Hive init, secure-storage AES key creation, locator
/// wiring, route registration, and reaching a first user-visible screen
/// without throwing.
///
/// On a clean install (fresh simulator), the app routes to the onboarding
/// flow because [UserDataSource.hasUserData] returns false. We do not try
/// to navigate past onboarding here — driving inputs requires platform-
/// specific keyboard / picker handling that is out of scope for a basic
/// boot-smoke.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app boots, reaches a MaterialApp screen, no uncaught exceptions',
    (WidgetTester tester) async {
      final caughtErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        caughtErrors.add(details);
        originalOnError?.call(details);
      };

      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      expect(find.byType(MaterialApp), findsOneWidget,
          reason: 'app should reach a MaterialApp');
      expect(caughtErrors, isEmpty,
          reason: 'no Flutter errors should fire during boot, got: '
              '${caughtErrors.map((e) => e.exception).toList()}');

      FlutterError.onError = originalOnError;
    },
  );
}
