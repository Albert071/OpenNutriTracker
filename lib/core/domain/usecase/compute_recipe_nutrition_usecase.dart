import 'package:opennutritracker/core/domain/entity/recipe_ingredient_entity.dart';
import 'package:opennutritracker/core/utils/calc/unit_calc.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';

class ComputeRecipeNutritionResult {
  final MealNutrimentsEntity perHundredG;
  final double totalWeightG;

  const ComputeRecipeNutritionResult({
    required this.perHundredG,
    required this.totalWeightG,
  });
}

class ComputeRecipeNutritionUseCase {
  // Treat a serving as the snapshot meal's serving weight in grams.
  // Treat 1 ml ≈ 1 g per the v1 simplification (see plan §3, decision 3).
  // Returns null when the unit can't be converted (e.g. a "serving" unit
  // on an ingredient that has no servingQuantity).
  double? convertAmountToGrams({
    required double amount,
    required String unit,
    double? servingQuantityG,
  }) {
    switch (unit) {
      case 'g':
      case 'gml':
      case 'g/ml':
        return amount;
      case 'ml':
      case 'l':
      case 'cl':
      case 'dl':
        if (unit == 'l') return amount * 1000;
        if (unit == 'cl') return amount * 10;
        if (unit == 'dl') return amount * 100;
        return amount;
      case 'kg':
        return amount * 1000;
      case 'mg':
        return amount / 1000;
      case 'oz':
        return UnitCalc.ozToG(amount);
      case 'fl oz':
      case 'fl.oz':
        return UnitCalc.flOzToMl(amount);
      case 'serving':
        if (servingQuantityG == null || servingQuantityG <= 0) return null;
        return amount * servingQuantityG;
      default:
        return null;
    }
  }

  ComputeRecipeNutritionResult compute(
    List<RecipeIngredientEntity> ingredients, {
    double? totalWeightOverride,
  }) {
    if (ingredients.isEmpty) {
      return ComputeRecipeNutritionResult(
        perHundredG: MealNutrimentsEntity.empty(),
        totalWeightG: 0,
      );
    }

    final totalWeightG = totalWeightOverride ??
        ingredients.fold<double>(
          0,
          (sum, i) => sum + i.convertedAmountG,
        );

    if (totalWeightG <= 0) {
      return ComputeRecipeNutritionResult(
        perHundredG: MealNutrimentsEntity.empty(),
        totalWeightG: 0,
      );
    }

    // For every nutrient field: sum (value100 ?? 0) × convertedAmountG / 100
    // across ingredients, but track whether *any* ingredient had a non-null
    // value for that field. If none did, the recipe field stays null too —
    // that preserves the existing UI behavior of hiding unknown micros.
    double total(double? Function(MealNutrimentsEntity) selector) {
      var sum = 0.0;
      for (final i in ingredients) {
        final v = selector(i.snapshotMeal.nutriments) ?? 0;
        sum += v * i.convertedAmountG / 100;
      }
      return sum;
    }

    bool anyNonNull(double? Function(MealNutrimentsEntity) selector) {
      return ingredients.any((i) => selector(i.snapshotMeal.nutriments) != null);
    }

    double? per100(double? Function(MealNutrimentsEntity) selector) {
      if (!anyNonNull(selector)) return null;
      return total(selector) * 100 / totalWeightG;
    }

    final per = MealNutrimentsEntity(
      energyKcal100: per100((n) => n.energyKcal100),
      carbohydrates100: per100((n) => n.carbohydrates100),
      fat100: per100((n) => n.fat100),
      proteins100: per100((n) => n.proteins100),
      sugars100: per100((n) => n.sugars100),
      saturatedFat100: per100((n) => n.saturatedFat100),
      fiber100: per100((n) => n.fiber100),
      monounsaturatedFat100: per100((n) => n.monounsaturatedFat100),
      polyunsaturatedFat100: per100((n) => n.polyunsaturatedFat100),
      transFat100: per100((n) => n.transFat100),
      cholesterol100: per100((n) => n.cholesterol100),
      sodium100: per100((n) => n.sodium100),
      potassium100: per100((n) => n.potassium100),
      magnesium100: per100((n) => n.magnesium100),
      calcium100: per100((n) => n.calcium100),
      iron100: per100((n) => n.iron100),
      zinc100: per100((n) => n.zinc100),
      phosphorus100: per100((n) => n.phosphorus100),
      vitaminA100: per100((n) => n.vitaminA100),
      vitaminC100: per100((n) => n.vitaminC100),
      vitaminD100: per100((n) => n.vitaminD100),
      vitaminB6100: per100((n) => n.vitaminB6100),
      vitaminB12100: per100((n) => n.vitaminB12100),
      niacin100: per100((n) => n.niacin100),
    );

    return ComputeRecipeNutritionResult(
      perHundredG: per,
      totalWeightG: totalWeightG,
    );
  }
}
