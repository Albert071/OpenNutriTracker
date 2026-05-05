import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:opennutritracker/core/presentation/widgets/meal_value_unit_text.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/presentation/add_meal_type.dart';
import 'package:opennutritracker/features/meal_detail/meal_detail_screen.dart';
import 'package:opennutritracker/generated/l10n.dart';

class MealItemCard extends StatelessWidget {
  final DateTime day;
  final AddMealType addMealType;
  final MealEntity mealEntity;
  final bool usesImperialUnits;

  const MealItemCard({
    super.key,
    required this.day,
    required this.mealEntity,
    required this.addMealType,
    required this.usesImperialUnits,
  });

  @override
  Widget build(BuildContext context) {
    final isRecipe = mealEntity.source == MealSourceEntity.recipe;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isRecipe
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
          width: isRecipe ? 1.5 : 1.0,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: InkWell(
        child: SizedBox(
          height: 100,
          child: Center(
            child: ListTile(
              leading: mealEntity.thumbnailImageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CachedNetworkImage(
                        cacheManager: locator<CacheManager>(),
                        fit: BoxFit.cover,
                        width: 60,
                        height: 60,
                        imageUrl: mealEntity.thumbnailImageUrl ?? "",
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 60,
                        height: 60,
                        color: isRecipe
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.secondaryContainer,
                        child: Icon(
                          isRecipe
                              ? Icons.menu_book
                              : Icons.restaurant_outlined,
                          color: isRecipe
                              ? Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer
                              : null,
                        ),
                      ),
                    ),
              title: AutoSizeText.rich(
                TextSpan(
                  text: mealEntity.name ?? "?",
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                  children: [
                    TextSpan(
                      text: ' ${mealEntity.brands ?? ""}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.8),
                          ),
                    ),
                  ],
                ),
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: isRecipe
                  ? Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            S.of(context).additionalInfoLabelRecipe,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                ),
                          ),
                        ),
                      ],
                    )
                  : (mealEntity.mealQuantity != null
                      ? MealValueUnitText(
                          value: double.parse(mealEntity.mealQuantity ?? "0"),
                          meal: mealEntity,
                          usesImperialUnits: usesImperialUnits,
                        )
                      : const SizedBox()),
              trailing: IconButton(
                style: IconButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                ),
                icon: const Icon(Icons.add_outlined),
                onPressed: () => _onItemPressed(context),
              ),
            ),
          ),
        ),
        onTap: () => _onItemPressed(context),
      ),
    );
  }

  void _onItemPressed(BuildContext context) {
    Navigator.of(context).pushNamed(
      NavigationOptions.mealDetailRoute,
      arguments: MealDetailScreenArguments(
        mealEntity,
        addMealType.getIntakeType(),
        day,
        usesImperialUnits,
      ),
    );
  }
}
