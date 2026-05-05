import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/calendar_day_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/diary_bloc.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/features/recipes/presentation/bloc/recipes_bloc.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/export_import_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

/// CSV import + sample download. Lives in its own settings entry
/// ("Import Custom Food Data") so it isn't visually mixed with the
/// app-wide ZIP export/import flow.
class ImportCustomFoodDataDialog extends StatelessWidget {
  static final _offAndroidUrl = Uri.parse(
      'https://play.google.com/store/apps/details?id=org.openfoodfacts.scanner');
  static final _offIosUrl = Uri.parse(
      'https://apps.apple.com/us/app/open-food-facts-product-scan/id588797948');

  final exportImportBloc = locator<ExportImportBloc>();

  final _homeBloc = locator<HomeBloc>();
  final _diaryBloc = locator<DiaryBloc>();
  final _calendarDayBloc = locator<CalendarDayBloc>();

  ImportCustomFoodDataDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        S.of(context).importCustomFoodDataLabel,
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      ),
      content: Wrap(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BlocBuilder<ExportImportBloc, ExportImportState>(
                bloc: exportImportBloc,
                builder: (context, state) {
                  if (state is ExportImportInitial) {
                    return Text(
                      S.of(context).importCustomFoodDataDescription,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 15,
                    );
                  } else if (state is ExportImportLoadingState) {
                    return const LinearProgressIndicator();
                  } else if (state is ExportImportSuccess) {
                    return Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(S.of(context).exportImportSuccessLabel),
                      ],
                    );
                  } else if (state is ExportImportError) {
                    return Row(
                      children: [
                        Icon(
                          Icons.error,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Text(S.of(context).exportImportErrorLabel),
                      ],
                    );
                  } else if (state is CsvImportResultState) {
                    refreshScreens();
                    return _buildCsvResult(context, state);
                  } else if (state is RecipeCsvImportResultState) {
                    refreshScreens();
                    locator<RecipesBloc>().add(const LoadRecipesEvent());
                    final summary = state.skipped == 0
                        ? S
                            .of(context)
                            .csvImportSuccessLabel(state.imported)
                        : S
                            .of(context)
                            .csvImportPartialLabel(
                              state.imported,
                              state.skipped,
                            );
                    return Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(summary)),
                      ],
                    );
                  } else if (state is CsvImportErrorState) {
                    return Row(
                      children: [
                        Icon(
                          Icons.error,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(S.of(context).csvImportErrorLabel),
                        ),
                      ],
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => exportImportBloc.add(DownloadSampleCsvEvent()),
          child: Text(S.of(context).downloadSampleCsvAction),
        ),
        TextButton(
          onPressed: () => exportImportBloc.add(ImportMealsCsvEvent()),
          child: Text(S.of(context).importMealsCsvAction),
        ),
        TextButton(
          onPressed: () =>
              exportImportBloc.add(DownloadSampleRecipesCsvEvent()),
          child: Text(S.of(context).downloadSampleRecipesCsvAction),
        ),
        TextButton(
          onPressed: () => exportImportBloc.add(ImportRecipesCsvEvent()),
          child: Text(S.of(context).importRecipesCsvAction),
        ),
      ],
    );
  }

  Widget _buildCsvResult(BuildContext context, CsvImportResultState state) {
    final summary = state.skipped == 0
        ? S.of(context).csvImportSuccessLabel(state.imported)
        : S
            .of(context)
            .csvImportPartialLabel(state.imported, state.skipped);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(summary)),
          ],
        ),
        if (state.anyHadBarcode) ...[
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: S.of(context).csvImportContributeOffPrefix,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: S.of(context).csvImportContributeOffAndroidLink,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrl(_offAndroidUrl,
                        mode: LaunchMode.externalApplication),
                ),
                const TextSpan(text: ' / '),
                TextSpan(
                  text: S.of(context).csvImportContributeOffIosLink,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrl(_offIosUrl,
                        mode: LaunchMode.externalApplication),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void refreshScreens() {
    _homeBloc.add(const LoadItemsEvent());
    _diaryBloc.add(const LoadDiaryYearEvent());
    _calendarDayBloc.add(RefreshCalendarDayEvent());
  }
}
