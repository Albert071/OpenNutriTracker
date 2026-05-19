import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opennutritracker/main.dart' as app;

/// The narrowest possible end-to-end check: `main()` finishes and a
/// MaterialApp ends up on screen. Exercises the platform-plugin boot
/// path — Hive open, AES key creation in flutter_secure_storage,
/// Supabase init, GetIt wiring, route registration — on a real
/// device or simulator. If any of those throw, this fails.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app boots and reaches a MaterialApp screen',
    (WidgetTester tester) async {
      await app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      expect(find.byType(MaterialApp), findsOneWidget,
          reason: 'app should reach a MaterialApp');
    },
  );
}
