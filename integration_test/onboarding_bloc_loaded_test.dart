import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:introduction_screen/introduction_screen.dart';
import 'package:opennutritracker/main.dart' as app;

/// `OnboardingScreen` shows a `CircularProgressIndicator` while
/// `OnboardingBloc` is in its initial / loading state, and only swaps
/// in the `IntroductionScreen` once `OnboardingLoadedState` arrives.
/// Verifying that the IntroductionScreen ends up mounted proves the
/// bloc reached its loaded state — which exercises both the bloc's
/// state machine and whatever repository lookup it does on load.
///
/// This is one layer deeper than [onboarding_routing_test.dart]: that
/// one just checks the OnboardingScreen shell routed; this one checks
/// the shell actually finished initialising and rendered its content.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'OnboardingBloc reaches loaded state and renders IntroductionScreen',
    (WidgetTester tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      expect(find.byType(IntroductionScreen), findsOneWidget,
          reason: 'OnboardingBloc should transition into OnboardingLoadedState '
              'so the IntroductionScreen widget mounts');
    },
  );
}
