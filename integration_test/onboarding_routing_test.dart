import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/features/onboarding/onboarding_screen.dart';
import 'package:opennutritracker/main.dart' as app;

/// On a clean install (fresh simulator, no Hive user box), main.dart
/// calls `UserDataSource.hasUserData()`, gets back `false`, and routes
/// to [OnboardingScreen] instead of the main shell. This test guards
/// that routing decision — a regression here is how someone hits a
/// blank Home screen with no user profile underneath it.
///
/// We don't drive any onboarding inputs here. Walking the flow needs
/// platform keyboard / picker handling that belongs in a per-feature
/// integration test, not a routing smoke.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fresh install routes to the onboarding screen',
    (WidgetTester tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      expect(find.byType(OnboardingScreen), findsOneWidget,
          reason: 'with no user data, the first screen should be onboarding');
    },
  );
}
