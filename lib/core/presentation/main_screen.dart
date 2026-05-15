import 'dart:async';

import 'package:flutter/material.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/presentation/widgets/add_item_bottom_sheet.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/diary/diary_page.dart';
import 'package:opennutritracker/core/presentation/widgets/home_appbar.dart';
import 'package:opennutritracker/features/home/home_page.dart';
import 'package:opennutritracker/core/presentation/widgets/main_appbar.dart';
import 'package:opennutritracker/features/profile/profile_page.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/edit_meal/presentation/edit_meal_screen.dart';
import 'package:opennutritracker/features/recipes/presentation/bloc/recipes_bloc.dart';
import 'package:opennutritracker/features/recipes/presentation/screens/recipes_page.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/custom_meals_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  /// Boot-time crash counter is reset after the home shell has
  /// been mounted for this long without the app dying. Long enough
  /// to be confident the offline-catalog code paths the user
  /// might trigger on launch (settings tile load, scanner cache
  /// peek) are stable; short enough that a quick "open and
  /// close" by the user before the timer fires doesn't keep us
  /// stuck on a non-crashing launch.
  static const Duration _kCrashCounterResetDelay = Duration(seconds: 30);

  int _selectedPageIndex = 0;

  Timer? _crashCounterResetTimer;

  late List<Widget> _bodyPages;
  late List<PreferredSizeWidget> _appbarPages;

  @override
  void initState() {
    super.initState();
    // Schedule the second half of the crash safety switch. If the
    // app dies before this fires we'll come back next launch with
    // the counter still elevated; once it does fire we know the
    // launch was healthy and reset the count plus clear the auto-
    // disable flag.
    _crashCounterResetTimer = Timer(
      _kCrashCounterResetDelay,
      _resetCrashCounter,
    );
    // Surface the crash-safety auto-disable as a snackbar exactly
    // once per event. We schedule via post-frame so the
    // ScaffoldMessenger is mounted and the home shell has had a
    // chance to draw — popping a snackbar before the user sees
    // the screen would feel jarring.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowCatalogAutoDisableNotice();
    });
  }

  @override
  void dispose() {
    _crashCounterResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _resetCrashCounter() async {
    final configRepo = locator<ConfigRepository>();
    await configRepo.setCatalogConsecutiveCrashes(0);
    // We deliberately leave [catalogAutoDisabled] alone here — it
    // stays true so the settings tile keeps showing the "auto-
    // disabled" banner until the user actively chooses to re-
    // enable. Clearing it here would silently flip the catalog
    // back on the user without their knowledge.
  }

  Future<void> _maybeShowCatalogAutoDisableNotice() async {
    final configRepo = locator<ConfigRepository>();
    final autoDisabled = await configRepo.getCatalogAutoDisabled();
    if (!autoDisabled) return;
    final acknowledged =
        await configRepo.getCatalogAutoDisableNoticeAcknowledged();
    if (acknowledged) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        // l10n: offlineCatalogAutoDisableNotice
        content: const Text(
          'Offline food catalog paused after repeated crashes — your '
          'downloaded data is safe.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          // l10n: offlineCatalogAutoDisableNoticeAction
          label: 'Settings',
          onPressed: () => Navigator.of(context).pushNamed(
            NavigationOptions.settingsRoute,
          ),
        ),
      ),
    );
    // Mark acknowledged whether the user takes the action or just
    // lets the snackbar dismiss itself. The settings tile's banner
    // remains the persistent affordance — the snackbar's job is
    // just to make sure the user knows something happened.
    await configRepo.setCatalogAutoDisableNoticeAcknowledged(true);
  }

  @override
  void didChangeDependencies() {
    _bodyPages = [
      const HomePage(),
      const DiaryPage(),
      const RecipesPage(),
      const ProfilePage(),
    ];
    _appbarPages = [
      const HomeAppbar(),
      MainAppbar(title: S.of(context).diaryLabel, iconData: Icons.book),
      AppBar(
        leading: const Icon(Icons.menu_book),
        title: Text(S.of(context).recipesLabel),
        actions: [
          PopupMenuButton<_RecipesAction>(
            tooltip: S.of(context).addLabel,
            icon: const Icon(Icons.add),
            onSelected: (action) => _onRecipesAddSelected(context, action),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _RecipesAction.newRecipe,
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_outlined),
                    const SizedBox(width: 12),
                    Text(S.of(context).createRecipeTitle),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _RecipesAction.newCustomMeal,
                child: Row(
                  children: [
                    const Icon(Icons.restaurant_outlined),
                    const SizedBox(width: 12),
                    Text(S.of(context).newCustomMealLabel),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _RecipesAction.importRecipe,
                child: Row(
                  children: [
                    const Icon(Icons.qr_code_scanner_outlined),
                    const SizedBox(width: 12),
                    Text(S.of(context).importRecipeLabel),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: S.of(context).settingsLabel,
            onPressed: () => Navigator.of(
              context,
            ).pushNamed(NavigationOptions.settingsRoute),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      MainAppbar(
        title: S.of(context).profileLabel,
        iconData: Icons.account_circle,
      ),
    ];
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appbarPages[_selectedPageIndex],
      body: _bodyPages[_selectedPageIndex],
      floatingActionButton: _selectedPageIndex == 0
          ? Semantics(
              identifier: 'fab-add-item',
              child: FloatingActionButton(
                onPressed: () => _onFabPressed(context),
                tooltip: S.of(context).addLabel,
                child: const Icon(Icons.add),
              ),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedPageIndex,
        onDestinationSelected: _setPage,
        destinations: [
          NavigationDestination(
            icon: Semantics(
              identifier: 'nav-home',
              child: _selectedPageIndex == 0
                  ? const Icon(Icons.home)
                  : const Icon(Icons.home_outlined),
            ),
            label: S.of(context).homeLabel,
          ),
          NavigationDestination(
            icon: Semantics(
              identifier: 'nav-diary',
              child: _selectedPageIndex == 1
                  ? const Icon(Icons.book)
                  : const Icon((Icons.book_outlined)),
            ),
            label: S.of(context).diaryLabel,
          ),
          NavigationDestination(
            icon: Semantics(
              identifier: 'nav-recipes',
              child: _selectedPageIndex == 2
                  ? const Icon(Icons.menu_book)
                  : const Icon(Icons.menu_book_outlined),
            ),
            label: S.of(context).recipesLabel,
          ),
          NavigationDestination(
            icon: Semantics(
              identifier: 'nav-profile',
              child: _selectedPageIndex == 3
                  ? const Icon(Icons.account_circle)
                  : const Icon(Icons.account_circle_outlined),
            ),
            label: S.of(context).profileLabel,
          ),
        ],
      ),
    );
  }

  void _setPage(int selectedIndex) {
    setState(() {
      _selectedPageIndex = selectedIndex;
    });
  }

  Future<void> _onRecipesAddSelected(
    BuildContext context,
    _RecipesAction action,
  ) async {
    switch (action) {
      case _RecipesAction.newRecipe:
        await Navigator.of(
          context,
        ).pushNamed(NavigationOptions.recipeBuilderRoute);
        locator<RecipesBloc>().add(const LoadRecipesEvent());
      case _RecipesAction.newCustomMeal:
        await Navigator.of(context).pushNamed(
          NavigationOptions.editMealRoute,
          arguments: EditMealScreenArguments(
            DateTime.now(),
            MealEntity.empty(),
            IntakeTypeEntity.breakfast,
            false,
            editOnly: true,
          ),
        );
        locator<CustomMealsBloc>().add(LoadCustomMealsEvent());
      case _RecipesAction.importRecipe:
        await Navigator.of(
          context,
        ).pushNamed(NavigationOptions.importRecipeScannerRoute);
        // The scanner screen itself dispatches LoadRecipesEvent on success,
        // but cover the cancel-then-reopen flow here too.
        locator<RecipesBloc>().add(const LoadRecipesEvent());
    }
  }

  void _onFabPressed(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
      ),
      builder: (BuildContext context) {
        return AddItemBottomSheet(day: DateTime.now());
      },
    );
  }
}

enum _RecipesAction { newRecipe, newCustomMeal, importRecipe }
