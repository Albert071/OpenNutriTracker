import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/main.dart' as app;

/// Boot-health smoke. Bundles two questions that share the same boot:
///   - did `main()` actually finish and land a MaterialApp on screen?
///   - did anything trip `FlutterError.onError` along the way?
///
/// The first catches the loud failures — Hive can't open, secure
/// storage can't derive an AES key, Supabase init throws, GetIt has a
/// missing dependency. The second catches the quiet ones — a Hive
/// type-id collision, a dropped `await` in plugin init, a half-broken
/// notification re-register — that don't crash the app but leave
/// something half-initialised in the logs while the user sees a
/// rendered screen. Splitting them into separate files would mean
/// paying the simulator boot cost twice for two questions that share
/// the same setup window.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app boots cleanly and raises no Flutter errors',
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

      expect(find.byType(MaterialApp), findsOneWidget,
          reason: 'app should reach a MaterialApp');
      expect(
        caught,
        isEmpty,
        reason: 'no Flutter errors should fire during boot, got: '
            '${caught.map((e) => e.exception).toList()}',
      );
    },
  );
}
