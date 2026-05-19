import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/main.dart' as app;

/// Anyone wiring up a new Hive type, a new locator dependency, or a
/// new plugin can quietly land a `FlutterError.onError` callback that
/// fires during boot but doesn't actually crash the app. The user
/// never sees it because the error sits in the logs while a half-built
/// screen renders. This test installs an error listener around the
/// boot path and fails loudly if anything trips during launch — a
/// canary for "the app starts but something is already broken
/// underneath."
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'boot path raises no FlutterError callbacks',
    (WidgetTester tester) async {
      final caught = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        caught.add(details);
        original?.call(details);
      };
      addTearDown(() => FlutterError.onError = original);

      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      expect(
        caught,
        isEmpty,
        reason: 'no Flutter errors should fire during boot, got: '
            '${caught.map((e) => e.exception).toList()}',
      );
    },
  );
}
