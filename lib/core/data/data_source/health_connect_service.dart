import 'dart:io';

import 'package:health/health.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/settings/data/dto/health_connect_nutrition_record.dart';

/// #295: Thin wrapper around the `health` Flutter plugin so the rest of
/// the app talks to a stable interface and so we have a single place to
/// gate iOS off until v2 ships Apple HealthKit reads as well.
///
/// v1 is **read-only** and **Android-only**. The iOS-side stubs return
/// false / empty so the calling code can short-circuit without having
/// to know the platform itself.
///
/// v2 (follow-up): wire `NSHealthShareUsageDescription` into iOS's
/// `Info.plist`, request `HealthDataType.DIETARY_*` reads, and let
/// `fetchNutritionSince` return a non-empty list on iOS too.
abstract class HealthConnectService {
  /// True on devices where Health Connect (Android) is available and
  /// the plugin is wired up. Returns false on iOS for v1.
  Future<bool> isSupported();

  /// Asks the user to grant the `READ_NUTRITION` permission. Returns
  /// true on success, false if the user denied or the platform is
  /// unsupported.
  Future<bool> requestPermissions();

  /// Pulls every `NUTRITION` record logged since [since], inclusive.
  /// Empty list on permission denial or unsupported platform.
  Future<List<HealthConnectNutritionRecord>> fetchNutritionSince(DateTime since);
}

/// Concrete Android implementation. The iOS branch is deliberately a
/// no-op until v2 — see the class-level comment above.
class HealthConnectServiceImpl implements HealthConnectService {
  static const _log = _LoggerNs();
  // The `health` package's configure() is async-once; we hold a single
  // configured instance for the app's lifetime so a second import call
  // doesn't re-pay the platform-channel handshake.
  final Health _health;
  bool _configured = false;

  HealthConnectServiceImpl({Health? health}) : _health = health ?? Health();

  // The set of data types we ever read. NUTRITION is the only Android
  // surface that carries the full meal payload (kcal + macros + name).
  static const _types = <HealthDataType>[HealthDataType.NUTRITION];

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> isSupported() async {
    // v1 explicitly gates iOS off — Apple HealthKit nutrition reads are
    // a v2 follow-up. iOS users get a localised "coming soon" subtitle
    // in Settings rather than a broken button.
    if (!Platform.isAndroid) return false;
    try {
      await _ensureConfigured();
      return await _health.isHealthConnectAvailable();
    } catch (e, st) {
      _log.warning('isSupported() threw', e, st);
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return false;
    try {
      await _ensureConfigured();
      final already = await _health.hasPermissions(_types) ?? false;
      if (already) return true;
      return await _health.requestAuthorization(_types);
    } catch (e, st) {
      _log.warning('requestPermissions() threw', e, st);
      return false;
    }
  }

  @override
  Future<List<HealthConnectNutritionRecord>> fetchNutritionSince(DateTime since) async {
    if (!Platform.isAndroid) return const [];
    try {
      await _ensureConfigured();
      final now = DateTime.now();
      final start = since.isBefore(now) ? since : now.subtract(const Duration(minutes: 1));
      final points = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: start,
        endTime: now,
      );
      final records = <HealthConnectNutritionRecord>[];
      for (final p in points) {
        final v = p.value;
        if (v is! NutritionHealthValue) continue;
        records.add(
          HealthConnectNutritionRecord(
            mealName: v.name,
            loggedAt: p.dateFrom,
            kcal: v.calories,
            carbs: v.carbs,
            protein: v.protein,
            fat: v.fat,
            fiber: v.fiber,
            sugar: v.sugar,
            saturatedFat: v.fatSaturated,
            cholesterol: v.cholesterol,
            sodium: v.sodium,
            potassium: v.potassium,
            calcium: v.calcium,
            iron: v.iron,
            sourceName: p.sourceName,
          ),
        );
      }
      return records;
    } catch (e, st) {
      _log.warning('fetchNutritionSince() threw', e, st);
      return const [];
    }
  }
}

// Logger namespace shim. The `logging` package is already a dependency
// (see other data sources) — wrapping it here avoids leaking a top-level
// logger constant into every file that imports the service.
class _LoggerNs {
  const _LoggerNs();
  void warning(String msg, [Object? e, StackTrace? st]) {
    Logger('HealthConnectService').warning(msg, e, st);
  }
}
