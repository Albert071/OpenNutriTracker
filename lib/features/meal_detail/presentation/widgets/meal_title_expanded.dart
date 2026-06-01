import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:opennutritracker/core/presentation/widgets/meal_value_unit_text.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';

class MealTitleExpanded extends StatelessWidget {
  final MealEntity meal;
  final bool usesImperialUnits;

  const MealTitleExpanded({
    super.key,
    required this.meal,
    required this.usesImperialUnits,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AutoSizeText.rich(
              minFontSize: 6,
              maxFontSize: 16,
              TextSpan(
                text: meal.name ?? '',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: palette.textStrong,
                      fontWeight: FontWeight.w800,
                    ),
                children: [
                  TextSpan(
                    text: ' ${meal.brands ?? ''}',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            meal.mealQuantity != null
                ? Center(
                    child: MealValueUnitText(
                      value: double.tryParse(meal.mealQuantity ?? '') ?? 0,
                      meal: meal,
                      usesImperialUnits: usesImperialUnits,
                      textStyle:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: palette.textMuted,
                              ),
                      prefix: '',
                    ),
                  )
                : const SizedBox(),
          ],
        ),
      ),
    );
  }
}
