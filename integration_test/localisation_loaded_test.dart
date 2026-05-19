import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/main.dart' as app;

/// After boot, a known English string from `lib/l10n/intl_en.arb`
/// renders on the onboarding intro page. Proves three things in one
/// pass: the `intl`/`S` delegates loaded into MaterialApp, the ARB
/// lookup table was generated and bundled with the build, and the
/// onboarding intro body actually reached its build phase (so the
/// localised text node is in the widget tree).
///
/// We anchor on `appDescription` rather than `appTitle` because
/// "OpenNutriTracker" appears in several places — the description is
/// only ever rendered by the intro page body, which keeps the
/// assertion specific.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'intro page localises into the active locale',
    (WidgetTester tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      // English ARB entry, copied verbatim from intl_en.arb so a future
      // copy change forces the test to be updated alongside.
      const expected =
          'OpenNutriTracker is a free and open-source calorie and '
          'nutrient tracker that respects your privacy.';

      expect(find.text(expected), findsOneWidget,
          reason: 'the localised appDescription should be rendered on '
              'the onboarding intro page');
    },
  );
}
