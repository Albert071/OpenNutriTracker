import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:opennutritracker/core/data/dbo/recipe_dbo.dart';

class RecipeDataSource {
  final Box<RecipeDBO> _recipeBox;

  RecipeDataSource(this._recipeBox);

  // Upsert by stable id. Recipe ids are uuids assigned at first save and
  // never change, so we can safely overwrite the matching record.
  Future<void> saveRecipe(RecipeDBO recipe) async {
    final existing = _recipeBox.values.cast<RecipeDBO?>().firstWhere(
          (r) => r?.id == recipe.id,
          orElse: () => null,
        );
    if (existing != null) {
      await _recipeBox.put(existing.key, recipe);
    } else {
      await _recipeBox.add(recipe);
    }
  }

  List<RecipeDBO> getAllRecipes() => _recipeBox.values.toList();

  RecipeDBO? getRecipeById(String id) {
    for (final recipe in _recipeBox.values) {
      if (recipe.id == id) return recipe;
    }
    return null;
  }

  Future<void> deleteRecipe(String id) async {
    final toDelete = _recipeBox.values.where((r) => r.id == id).toList();
    for (final recipe in toDelete) {
      await recipe.delete();
    }
  }
}
