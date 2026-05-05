import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/usecase/delete_recipe_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/recipes/presentation/bloc/recipes_bloc.dart';
import 'package:opennutritracker/features/recipes/presentation/screens/recipe_detail_screen.dart';
import 'package:opennutritracker/features/recipes/presentation/widgets/custom_meals_tab.dart';
import 'package:opennutritracker/features/recipes/presentation/widgets/recipe_list_item.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/custom_meals_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late RecipesBloc _bloc;
  late CustomMealsBloc _customMealsBloc;
  late TabController _tabController;
  late TextEditingController _searchController;
  String _searchQuery = '';
  String? _activeTag;
  bool _usesImperialUnits = false;
  // Multi-select state. Empty set = normal mode.
  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bloc = locator<RecipesBloc>();
    _customMealsBloc = locator<CustomMealsBloc>()..add(LoadCustomMealsEvent());
    _tabController = TabController(length: 2, vsync: this);
    _searchController = TextEditingController();
    _bloc.add(const LoadRecipesEvent());
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await locator<GetConfigUsecase>().getConfig();
    if (mounted) {
      setState(() => _usesImperialUnits = config.usesImperialUnits);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bloc.add(const LoadRecipesEvent());
      _customMealsBloc.add(LoadCustomMealsEvent());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _customMealsBloc,
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: S.of(context).recipesLabel),
              Tab(text: S.of(context).settingsCustomMealsLabel),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildRecipesTab(),
                CustomMealsTab(usesImperialUnits: _usesImperialUnits),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecipesTab() {
    return BlocBuilder<RecipesBloc, RecipesState>(
      bloc: _bloc,
      builder: (context, state) {
        if (state is RecipesLoading || state is RecipesInitial) {
          return const Center(child: CircularProgressIndicator());
        } else if (state is RecipesFailed) {
          // Don't expose raw exception text to users; show a friendly label.
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                S.of(context).recipesLoadErrorLabel,
                textAlign: TextAlign.center,
              ),
            ),
          );
        } else if (state is RecipesLoaded) {
          if (state.recipes.isEmpty) return _buildEmptyState(context);
          final q = _searchQuery.trim().toLowerCase();
          // Build the union of all tags across recipes (sorted) for the
          // filter chip row. Skipped entirely when no recipe has tags.
          final allTags = state.recipes
              .expand((r) => r.tags)
              .toSet()
              .toList()
            ..sort();
          // Reset _activeTag if the chosen tag no longer exists (e.g. user
          // removed it from every recipe).
          if (_activeTag != null && !allTags.contains(_activeTag)) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => setState(() => _activeTag = null),
            );
          }
          final filtered = state.recipes.where((r) {
            final matchesQuery =
                q.isEmpty || r.name.toLowerCase().contains(q);
            final matchesTag =
                _activeTag == null || r.tags.contains(_activeTag);
            return matchesQuery && matchesTag;
          }).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: S.of(context).searchLabel,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              if (allTags.isNotEmpty)
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(S.of(context).recipesFilterAllLabel),
                          selected: _activeTag == null,
                          onSelected: (_) =>
                              setState(() => _activeTag = null),
                        ),
                      ),
                      for (final tag in allTags)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          child: ChoiceChip(
                            label: Text(tag),
                            selected: _activeTag == tag,
                            onSelected: (selected) => setState(
                              () => _activeTag = selected ? tag : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            S.of(context).recipesEmptyLabel,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          if (_selectionMode) _buildSelectionBar(context),
                          Expanded(
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final recipe = filtered[index];
                                final isSelected =
                                    _selectedIds.contains(recipe.id);
                                return RecipeListItem(
                                  recipe: recipe,
                                  isSelected: isSelected,
                                  onTap: () async {
                                    if (_selectionMode) {
                                      setState(() {
                                        if (isSelected) {
                                          _selectedIds.remove(recipe.id);
                                        } else {
                                          _selectedIds.add(recipe.id);
                                        }
                                      });
                                      return;
                                    }
                                    await Navigator.of(context).pushNamed(
                                      NavigationOptions.recipeDetailRoute,
                                      arguments: RecipeDetailArguments(
                                          recipeId: recipe.id),
                                    );
                                    if (mounted) {
                                      _bloc.add(const LoadRecipesEvent());
                                    }
                                  },
                                  onLongPress: () {
                                    setState(() => _selectedIds.add(recipe.id));
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: s.dialogCancelLabel,
              icon: const Icon(Icons.close),
              onPressed: () => setState(_selectedIds.clear),
            ),
            Expanded(
              child: Text(
                s.selectionCountLabel(_selectedIds.length),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: s.dialogDeleteLabel,
              icon: const Icon(Icons.delete_outline),
              onPressed: _onBulkDelete,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onBulkDelete() async {
    final s = S.of(context);
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteSelectedRecipesConfirmTitle(count)),
        content: Text(s.recipeDeleteConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.dialogCancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.dialogDeleteLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleteUseCase = locator<DeleteRecipeUseCase>();
    for (final id in _selectedIds) {
      await deleteUseCase.delete(id);
    }
    if (!mounted) return;
    setState(_selectedIds.clear);
    _bloc.add(const LoadRecipesEvent());
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 96,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).recipesEmptyLabel,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).recipesEmptyHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
