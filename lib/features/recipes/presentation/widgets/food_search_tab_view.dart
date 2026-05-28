import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:opennutritracker/core/presentation/widgets/error_dialog.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/food_bloc.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/products_bloc.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/recent_meal_bloc.dart';
import 'package:opennutritracker/features/add_meal/presentation/widgets/default_results_widget.dart';
import 'package:opennutritracker/features/add_meal/presentation/widgets/meal_search_bar.dart';
import 'package:opennutritracker/features/add_meal/presentation/widgets/no_results_widget.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Reusable 3-tab food search (Products / Food / Recently) that delegates the
/// "selected" action to a callback rather than pushing MealDetailScreen.
/// Used by the recipe builder to add ingredients without touching the
/// existing AddMealScreen flow.
class FoodSearchTabView extends StatefulWidget {
  final void Function(MealEntity meal) onMealSelected;
  // When non-null, the search bar shows a barcode-scan suffix icon and
  // taps are forwarded here. The recipe builder uses this to push the
  // scanner in pick mode and feed the result back through [onMealSelected].
  final VoidCallback? onBarcodePressed;

  const FoodSearchTabView({
    super.key,
    required this.onMealSelected,
    this.onBarcodePressed,
  });

  @override
  State<FoodSearchTabView> createState() => _FoodSearchTabViewState();
}

class _FoodSearchTabViewState extends State<FoodSearchTabView>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<String> _searchStringListener = ValueNotifier('');

  late ProductsBloc _productsBloc;
  late FoodBloc _foodBloc;
  late RecentMealBloc _recentMealBloc;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _productsBloc = locator<ProductsBloc>();
    _foodBloc = locator<FoodBloc>();
    _recentMealBloc = locator<RecentMealBloc>();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      _onSearchSubmit(_searchStringListener.value);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          MealSearchBar(
            searchStringListener: _searchStringListener,
            onSearchSubmit: _onSearchSubmit,
            onSearchChanged: _onSearchChanged,
            onBarcodePressed: widget.onBarcodePressed,
          ),
          const SizedBox(height: 16),
          TabBar(
            tabs: [
              Tab(text: S.of(context).searchProductsPage),
              Tab(text: S.of(context).searchFoodPage),
              Tab(text: S.of(context).recentlyAddedLabel),
            ],
            controller: _tabController,
            indicatorSize: TabBarIndicatorSize.tab,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildProductsTab(context),
                _buildFoodTab(context),
                _buildRecentTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductsTab(BuildContext context) {
    return BlocBuilder<ProductsBloc, ProductsState>(
      bloc: _productsBloc,
      builder: (context, state) {
        if (state is ProductsInitial) return const DefaultsResultsWidget();
        if (state is ProductsLoadingState) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 32),
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }
        if (state is ProductsLoadedState) {
          if (state.products.isEmpty) return const NoResultsWidget();
          return ListView.builder(
            itemCount:
                state.products.length + (state.remoteSourceEmpty ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == state.products.length) {
                return const NoResultsWidget();
              }
              return _PickableMealCard(
                meal: state.products[index],
                onTap: widget.onMealSelected,
              );
            },
          );
        }
        if (state is ProductsFailedState) {
          return ErrorDialog(
            errorText: S.of(context).errorFetchingProductData,
            onRefreshPressed: () =>
                _productsBloc.add(const RefreshProductsEvent()),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildFoodTab(BuildContext context) {
    return BlocBuilder<FoodBloc, FoodState>(
      bloc: _foodBloc,
      builder: (context, state) {
        if (state is FoodInitial) return const DefaultsResultsWidget();
        if (state is FoodLoadingState) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 32),
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }
        if (state is FoodLoadedState) {
          if (state.food.isEmpty) return const NoResultsWidget();
          return ListView.builder(
            itemCount: state.food.length + (state.remoteSourceEmpty ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == state.food.length) return const NoResultsWidget();
              return _PickableMealCard(
                meal: state.food[index],
                onTap: widget.onMealSelected,
              );
            },
          );
        }
        if (state is FoodFailedState) {
          return ErrorDialog(
            errorText: S.of(context).errorFetchingProductData,
            onRefreshPressed: () => _foodBloc.add(const RefreshFoodEvent()),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildRecentTab(BuildContext context) {
    return BlocBuilder<RecentMealBloc, RecentMealState>(
      bloc: _recentMealBloc,
      builder: (context, state) {
        if (state is RecentMealInitial) {
          _recentMealBloc.add(const LoadRecentMealEvent(searchString: ''));
          return const SizedBox.shrink();
        }
        if (state is RecentMealLoadingState) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 32),
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }
        if (state is RecentMealLoadedState) {
          if (state.recentMeals.isEmpty) return const NoResultsWidget();
          return ListView.builder(
            itemCount: state.recentMeals.length,
            itemBuilder: (context, index) => _PickableMealCard(
              meal: state.recentMeals[index],
              onTap: widget.onMealSelected,
            ),
          );
        }
        if (state is RecentMealFailedState) {
          return ErrorDialog(
            errorText: S.of(context).noMealsRecentlyAddedLabel,
            onRefreshPressed: () => _recentMealBloc.add(
              const LoadRecentMealEvent(searchString: ''),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  void _onSearchSubmit(String inputText) {
    switch (_tabController.index) {
      case 0:
        _productsBloc.add(LoadProductsEvent(searchString: inputText));
      case 1:
        _foodBloc.add(LoadFoodEvent(searchString: inputText));
      case 2:
        _recentMealBloc.add(LoadRecentMealEvent(searchString: inputText));
    }
  }

  /// Debounced search-as-you-type for the ingredient picker. Recent-added
  /// (tab 2) stays submit-only — local-history filter, nothing to debounce.
  void _onSearchChanged(String inputText) {
    switch (_tabController.index) {
      case 0:
        _productsBloc.add(SearchInputChangedEvent(searchString: inputText));
      case 1:
        _foodBloc.add(SearchFoodInputChangedEvent(searchString: inputText));
    }
  }
}

class _PickableMealCard extends StatelessWidget {
  final MealEntity meal;
  final void Function(MealEntity meal) onTap;

  const _PickableMealCard({required this.meal, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outline),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: InkWell(
        onTap: () => onTap(meal),
        child: SizedBox(
          height: 100,
          child: Center(
            child: ListTile(
              leading: meal.thumbnailImageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CachedNetworkImage(
                        cacheManager: locator<CacheManager>(),
                        fit: BoxFit.cover,
                        width: 60,
                        height: 60,
                        imageUrl: meal.thumbnailImageUrl ?? '',
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 60,
                        height: 60,
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: Icon(
                          meal.source == MealSourceEntity.recipe
                              ? Icons.menu_book_outlined
                              : Icons.restaurant_outlined,
                        ),
                      ),
                    ),
              title: AutoSizeText.rich(
                TextSpan(
                  text: meal.name ?? '?',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                  children: [
                    TextSpan(
                      text: ' ${meal.brands ?? ''}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.8),
                          ),
                    ),
                  ],
                ),
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.add_outlined),
            ),
          ),
        ),
      ),
    );
  }
}
