import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/edit_meal/presentation/edit_meal_screen.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/custom_meals_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Embeddable list of user-created custom meals (formerly the body of
/// CustomMealsScreen in Settings). Hosted inside RecipesPage's TabBarView.
class CustomMealsTab extends StatelessWidget {
  final bool usesImperialUnits;

  const CustomMealsTab({super.key, required this.usesImperialUnits});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CustomMealsBloc, CustomMealsState>(
      builder: (context, state) {
        if (state is CustomMealsLoadingState ||
            state is CustomMealsInitial) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state is CustomMealsLoadedState) {
          if (state.meals.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  S.of(context).customMealsEmptyLabel,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: state.meals.length,
            itemBuilder: (context, index) {
              final meal = state.meals[index];
              return ListTile(
                title: Text(meal.name ?? ''),
                subtitle: meal.brands != null ? Text(meal.brands!) : null,
                onTap: () => _openEditMeal(context, meal),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, meal),
                ),
              );
            },
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _openEditMeal(BuildContext context, MealEntity meal) async {
    final bloc = context.read<CustomMealsBloc>();
    await Navigator.of(context).pushNamed(
      NavigationOptions.editMealRoute,
      arguments: EditMealScreenArguments(
        DateTime.now(),
        meal,
        IntakeTypeEntity.breakfast,
        usesImperialUnits,
        editOnly: true,
      ),
    );
    bloc.add(LoadCustomMealsEvent());
  }

  Future<void> _confirmDelete(BuildContext context, MealEntity meal) async {
    final bloc = context.read<CustomMealsBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of(context).customMealsDeleteConfirmTitle),
        content: Text(S.of(context).customMealsDeleteConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of(context).dialogCancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of(context).dialogDeleteLabel),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      bloc.add(DeleteCustomMealEvent(meal.code ?? meal.name ?? ''));
    }
  }
}
