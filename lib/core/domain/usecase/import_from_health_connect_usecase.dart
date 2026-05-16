import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/data_source/config_data_source.dart';
import 'package:opennutritracker/core/data/data_source/health_connect_service.dart';
import 'package:opennutritracker/core/data/repository/intake_repository.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/core/utils/id_generator.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/settings/data/dto/health_connect_nutrition_record.dart';

/// #295: Outcome reported back to the Settings UI after a Health Connect
/// import run. `errors` collects non-fatal per-record failures so the
/// snackbar can be honest about partial success.
class ImportResult {
  final int imported;
  final int skipped;
  final bool permissionDenied;
  final List<String> errors;

  const ImportResult({
    required this.imported,
    required this.skipped,
    required this.permissionDenied,
    required this.errors,
  });

  factory ImportResult.permissionDenied() => const ImportResult(
        imported: 0,
        skipped: 0,
        permissionDenied: true,
        errors: [],
      );
}

/// #295: Pulls NUTRITION records from Health Connect and appends them to
/// the local intake log as `IntakeEntity`s tagged with
/// `importSource: 'health_connect'`.
///
/// Dedup is a same-source, same-timestamp, same-kcal match: we never
/// touch records the user logged themselves, and a second run over the
/// same Health Connect window won't double-up rows.
class ImportFromHealthConnectUseCase {
  static const sourceTag = 'health_connect';
  static const _defaultLookback = Duration(days: 30);

  final _log = Logger('ImportFromHealthConnectUseCase');

  final HealthConnectService _service;
  final IntakeRepository _intakeRepository;
  final ConfigDataSource _configDataSource;

  ImportFromHealthConnectUseCase(
    this._service,
    this._intakeRepository,
    this._configDataSource,
  );

  Future<ImportResult> run({DateTime? now}) async {
    final granted = await _service.requestPermissions();
    if (!granted) {
      return ImportResult.permissionDenied();
    }

    final clock = now ?? DateTime.now();
    final lastImport = await _configDataSource.getLastHealthConnectImportAt();
    final since = lastImport ?? clock.subtract(_defaultLookback);

    final records = await _service.fetchNutritionSince(since);

    // Build a small in-memory index of already-imported HC records so we
    // can dedupe in O(n+m) rather than scanning the whole intake list
    // per incoming record.
    final existing = await _intakeRepository.getAllIntakesDBO();
    final seen = <String>{};
    for (final dbo in existing) {
      if (dbo.importSource != sourceTag) continue;
      seen.add(_dedupKey(dbo.dateTime, dbo.amount * (dbo.meal.nutriments.energyKcal100 ?? 0)));
    }

    var imported = 0;
    var skipped = 0;
    final errors = <String>[];

    for (final record in records) {
      final kcal = record.kcal ?? 0;
      final key = _dedupKey(record.loggedAt, kcal);
      if (seen.contains(key)) {
        skipped++;
        continue;
      }
      try {
        await _intakeRepository.addIntake(_toIntakeEntity(record));
        seen.add(key);
        imported++;
      } catch (e, st) {
        _log.warning('Failed to import Health Connect record', e, st);
        errors.add('${record.mealName ?? 'unknown'} @ ${record.loggedAt}');
      }
    }

    // Persist the high-water mark even on a zero-record run — a daily
    // user shouldn't keep replaying the same fortnight.
    await _configDataSource.setLastHealthConnectImportAt(clock);

    return ImportResult(
      imported: imported,
      skipped: skipped,
      permissionDenied: false,
      errors: errors,
    );
  }

  String _dedupKey(DateTime when, double kcal) =>
      '${when.toUtc().millisecondsSinceEpoch}|${kcal.toStringAsFixed(2)}';

  IntakeEntity _toIntakeEntity(HealthConnectNutritionRecord record) {
    // We treat each Health Connect record as a 1-unit "ephemeral" meal:
    // the per-100 nutriment fields carry the *total* for the record, and
    // amount = 1. This mirrors the pattern used elsewhere for one-off
    // imports where we don't have a real product to anchor to.
    final nutriments = MealNutrimentsEntity(
      energyKcal100: record.kcal,
      carbohydrates100: record.carbs,
      fat100: record.fat,
      proteins100: record.protein,
      sugars100: record.sugar,
      saturatedFat100: record.saturatedFat,
      fiber100: record.fiber,
      cholesterol100: record.cholesterol,
      sodium100: record.sodium,
      potassium100: record.potassium,
      calcium100: record.calcium,
      iron100: record.iron,
    );

    final meal = MealEntity(
      code: IdGenerator.getUniqueID(),
      name: record.mealName,
      url: null,
      mealQuantity: null,
      mealUnit: 'g',
      servingQuantity: null,
      servingUnit: 'g',
      servingSize: null,
      nutriments: nutriments,
      source: MealSourceEntity.unknown,
    );

    return IntakeEntity(
      id: IdGenerator.getUniqueID(),
      unit: 'g',
      amount: 1,
      type: _bucketMealType(record.loggedAt),
      meal: meal,
      dateTime: record.loggedAt,
      importSource: sourceTag,
    );
  }

  // Health Connect doesn't carry an OpenNutriTracker-style meal slot, so
  // we map by wall-clock hour to the closest sensible bucket. People can
  // re-bucket from the intake card later if they want to. This logic is
  // intentionally simple — the goal is to land the data, not to outsmart
  // someone whose breakfast is at 4am.
  IntakeTypeEntity _bucketMealType(DateTime when) {
    final h = when.hour;
    if (h < 11) return IntakeTypeEntity.breakfast;
    if (h < 15) return IntakeTypeEntity.lunch;
    if (h < 21) return IntakeTypeEntity.dinner;
    return IntakeTypeEntity.snack;
  }
}
