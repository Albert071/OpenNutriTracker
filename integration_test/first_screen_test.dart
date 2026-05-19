import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:introduction_screen/introduction_screen.dart';
import 'package:opennutritracker/features/onboarding/onboarding_screen.dart';
import 'package:opennutritracker/main.dart' as app;

/// First-screen smoke. Bundles three questions that all describe the
/// same observation — "what does a fresh-install user actually see on
/// page one?" — so they share a single boot:
///   - did `hasUserData()` return false and route to OnboardingScreen?
///   - did OnboardingBloc transition past Initial/Loading into Loaded,
///     so the IntroductionScreen widget mounted?
///   - did the intl delegates load and the ARB lookup table reach the
///     intro page body, so a known English string ends up rendered?
///
/// These are three different failure surfaces (routing vs bloc state
/// vs localisation), but in practice they cascade: routing fails →
/// none of the rest is visible; bloc fails → localised text doesn't
/// reach the tree. Asserting them together keeps the test focused on
/// the user-visible outcome rather than the layered implementation.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fresh install lands on a fully-rendered onboarding intro page',
    (WidgetTester tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      // Routing: the OnboardingScreen shell is what the router picked.
      expect(find.byType(OnboardingScreen), findsOneWidget,
          reason: 'with no user data, the first screen should be onboarding');

      // Bloc state: the IntroductionScreen mounts only after
      // OnboardingBloc reaches OnboardingLoadedState.
      expect(find.byType(IntroductionScreen), findsOneWidget,
          reason: 'OnboardingBloc should transition into loaded state');

      // Localisation: a verbatim copy of the English ARB entry for
      // appDescription, rendered by the intro page body. A future
      // copy change forces this test to be updated alongside.
      const appDescription =
          'OpenNutriTracker is a free and open-source calorie and '
          'nutrient tracker that respects your privacy.';
      expect(find.text(appDescription), findsOneWidget,
          reason: 'the localised appDescription should render on the intro page');
    },
  );
}
