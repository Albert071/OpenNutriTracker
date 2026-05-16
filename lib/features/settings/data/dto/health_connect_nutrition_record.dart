/// #295: A single nutrition entry pulled out of Android Health Connect.
///
/// Lives at the DTO layer because the shape mirrors what the `health`
/// package gives us, before we map it into OpenNutriTracker's own
/// `IntakeEntity` / `MealEntity` graph inside the import use case.
///
/// All micronutrient fields are optional — Health Connect entries from
/// third-party apps tend to carry only kcal + macros, and the import
/// flow falls back gracefully when a field is missing.
class HealthConnectNutritionRecord {
  /// Display name for the food (e.g. "Porridge with oats"). May be
  /// missing for some upstream apps; fall back to a localised generic
  /// label at render time.
  final String? mealName;

  /// When the meal was logged in Health Connect — passes straight into
  /// the imported `IntakeEntity.dateTime`.
  final DateTime loggedAt;

  /// Energy in kilocalories.
  final double? kcal;

  final double? carbs;
  final double? protein;
  final double? fat;

  // Optional micronutrients in grams. Names match the `health` package's
  // `NutritionHealthValue` fields so future plumbing is one-to-one.
  final double? fiber;
  final double? sugar;
  final double? saturatedFat;
  final double? cholesterol;
  final double? sodium;
  final double? potassium;
  final double? calcium;
  final double? iron;

  /// Where the record originated in Health Connect (e.g. "MyFitnessPal").
  /// Surfaced for diagnostics; not yet shown to the user.
  final String? sourceName;

  const HealthConnectNutritionRecord({
    required this.loggedAt,
    this.mealName,
    this.kcal,
    this.carbs,
    this.protein,
    this.fat,
    this.fiber,
    this.sugar,
    this.saturatedFat,
    this.cholesterol,
    this.sodium,
    this.potassium,
    this.calcium,
    this.iron,
    this.sourceName,
  });
}
