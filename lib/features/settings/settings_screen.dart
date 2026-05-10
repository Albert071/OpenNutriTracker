import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/domain/entity/app_theme_entity.dart';
import 'package:opennutritracker/core/presentation/widgets/app_banner_version.dart';
import 'package:opennutritracker/core/presentation/widgets/disclaimer_dialog.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/notification_service.dart';
import 'package:opennutritracker/core/utils/locale_provider.dart';
import 'package:opennutritracker/core/utils/theme_mode_provider.dart';
import 'package:opennutritracker/core/utils/url_const.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/calendar_day_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/diary_bloc.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/check_catalog_availability_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/offline_catalog_wizard_screen.dart';
import 'package:opennutritracker/features/profile/presentation/bloc/profile_bloc.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/settings_bloc.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/export_import_dialog.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/import_custom_food_data_dialog.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:opennutritracker/features/settings/presentation/widgets/calculations_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsBloc _settingsBloc;
  late ProfileBloc _profileBloc;
  late HomeBloc _homeBloc;
  late DiaryBloc _diaryBloc;
  late CalendarDayBloc _calendarDayBloc;

  @override
  void initState() {
    _settingsBloc = locator<SettingsBloc>();
    _profileBloc = locator<ProfileBloc>();
    _homeBloc = locator<HomeBloc>();
    _diaryBloc = locator<DiaryBloc>();
    _calendarDayBloc = locator<CalendarDayBloc>();
    super.initState();
    // SettingsBloc is registered as a singleton so the previous
    // SettingsLoadedState survives across screen visits. The cache
    // count and on-disk size in particular are written in the
    // background by search and barcode-scan flows, so reading them
    // once at the bloc's first transition out of SettingsInitial
    // leaves stale values on the screen for the rest of the session.
    // Refresh on every entry instead.
    _settingsBloc.add(LoadSettingsEvent());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).settingsLabel)),
      body: BlocBuilder<SettingsBloc, SettingsState>(
        bloc: _settingsBloc,
        builder: (context, state) {
          if (state is SettingsInitial) {
            _settingsBloc.add(LoadSettingsEvent());
          } else if (state is SettingsLoadingState) {
            return const Center(child: CircularProgressIndicator());
          } else if (state is SettingsLoadedState) {
            return ListView(
              children: [
                const SizedBox(height: 16.0),
                ListTile(
                  leading: const Icon(Icons.ac_unit_outlined),
                  title: Text(S.of(context).settingsUnitsLabel),
                  onTap: () =>
                      _showUnitsDialog(context, state.usesImperialUnits),
                ),
                ListTile(
                  leading: const Icon(Icons.calculate_outlined),
                  title: Text(S.of(context).settingsCalculationsLabel),
                  onTap: () => _showCalculationsDialog(context),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.directions_run_outlined),
                  title: Text(S.of(context).settingsShowActivityTracking),
                  value: state.showActivityTracking,
                  onChanged: (bool value) {
                    _settingsBloc.setShowActivityTracking(value);
                    _settingsBloc.add(LoadSettingsEvent());
                    _homeBloc.add(LoadItemsEvent());
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.bar_chart_outlined),
                  title: Text(S.of(context).settingsShowMealMacros),
                  value: state.showMealMacros,
                  onChanged: (bool value) {
                    _settingsBloc.setShowMealMacros(value);
                    _settingsBloc.add(LoadSettingsEvent());
                    _homeBloc.add(LoadItemsEvent());
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.science_outlined),
                  title: Text(S.of(context).settingsShowMicronutrientsLabel),
                  value: state.showMicronutrients,
                  onChanged: (bool value) {
                    _settingsBloc.setShowMicronutrients(value);
                    _settingsBloc.add(LoadSettingsEvent());
                  },
                ),
                const Divider(),
                // App
                ListTile(
                  leading: const Icon(Icons.brightness_medium_outlined),
                  title: Text(S.of(context).settingsThemeLabel),
                  onTap: () => _showThemeDialog(context, state.appTheme),
                ),
                ListTile(
                  leading: const Icon(Icons.language_outlined),
                  title: Text(S.of(context).settingsLanguageLabel),
                  subtitle: Text(
                      _localeDisplayName(state.selectedLocale) ??
                          S.of(context).settingsThemeSystemDefaultLabel),
                  onTap: () =>
                      _showLanguageDialog(context, state.selectedLocale),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: Text(S.of(context).settingsNotificationsLabel),
                  subtitle: state.notificationsEnabled
                      ? Text(S.of(context).settingsNotificationsTimeLabel(
                          _formatNotificationTime(
                              state.notificationHour, state.notificationMinute)))
                      : null,
                  value: state.notificationsEnabled,
                  onChanged: (bool value) =>
                      _onNotificationToggled(context, value, state),
                ),
                if (state.notificationsEnabled)
                  ListTile(
                    leading: const Icon(Icons.access_time_outlined),
                    title: Text(S.of(context).settingsNotificationsTimeLabel(
                        _formatNotificationTime(state.notificationHour,
                            state.notificationMinute))),
                    onTap: () => _pickNotificationTime(
                        context,
                        TimeOfDay(
                            hour: state.notificationHour,
                            minute: state.notificationMinute)),
                  ),
                const Divider(),
                // Data
                ListTile(
                  leading: const Icon(Icons.restaurant_menu_outlined),
                  title: Text(S.of(context).importCustomFoodDataLabel),
                  onTap: () => _showImportCustomFoodDataDialog(context),
                ),
                ListTile(
                  leading: const Icon(Icons.import_export),
                  title: Text(S.of(context).exportImportAppDataLabel),
                  onTap: () => _showExportImportDialog(context),
                ),
                ListTile(
                  leading: const Icon(Icons.cached_outlined),
                  title: Text(S.of(context).clearOffCacheLabel),
                  subtitle: Text(S.of(context).clearOffCacheSubtitle(
                    state.offCacheCount,
                    _formatBytes(state.offCacheSizeBytes),
                  )),
                  enabled: state.offCacheCount > 0,
                  onTap: () => _confirmClearOffCache(context),
                ),
                _OfflineCatalogTile(formatBytes: _formatBytes),
                const Divider(),
                // About
                ListTile(
                  leading: const Icon(Icons.policy_outlined),
                  title: Text(S.of(context).settingsPrivacySettings),
                  onTap: () =>
                      _showPrivacyDialog(context, state.sendAnonymousData),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(S.of(context).settingsDisclaimerLabel),
                  onTap: () => _showDisclaimerDialog(context),
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: Text(S.of(context).settingsReportErrorLabel),
                  onTap: () => _showReportErrorDialog(context),
                ),
                ListTile(
                  leading: const Icon(Icons.error_outline_outlined),
                  title: Text(S.of(context).settingAboutLabel),
                  onTap: () => _showAboutDialog(context),
                ),
                const SizedBox(height: 32.0),
                AppBannerVersion(versionNumber: state.versionNumber),
              ],
            );
          }
          return const SizedBox();
        },
      ),
    );
  }

  String _formatNotificationTime(int hour, int minute) {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _onNotificationToggled(
      BuildContext context, bool enabled, SettingsLoadedState state) async {
    final l10n = S.of(context);
    final notificationService = locator<NotificationService>();
    await notificationService.initialize();
    if (enabled) {
      final granted = await notificationService.requestPermission();
      if (!granted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.notificationsPermissionDeniedSnack)),
          );
        }
        return;
      }
      await notificationService.scheduleDailyReminder(
        hour: state.notificationHour,
        minute: state.notificationMinute,
        title: l10n.notificationsDailyReminderTitle,
        body: l10n.notificationsDailyReminderBody,
      );
    } else {
      await notificationService.cancelDailyReminder();
    }
    _settingsBloc.setNotificationsEnabled(enabled);
    _settingsBloc.add(LoadSettingsEvent());
  }

  Future<void> _pickNotificationTime(
      BuildContext context, TimeOfDay current) async {
    final l10n = S.of(context);
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
    );
    if (picked == null) return;
    _settingsBloc.setNotificationTime(picked.hour, picked.minute);
    final notificationService = locator<NotificationService>();
    await notificationService.scheduleDailyReminder(
      hour: picked.hour,
      minute: picked.minute,
      title: l10n.notificationsDailyReminderTitle,
      body: l10n.notificationsDailyReminderBody,
    );
    _settingsBloc.add(LoadSettingsEvent());
  }

  void _showUnitsDialog(BuildContext context, bool usesImperialUnits) async {
    SystemDropDownType selectedUnit = usesImperialUnits
        ? SystemDropDownType.imperial
        : SystemDropDownType.metric;
    final shouldUpdate = await showDialog<bool?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(S.of(context).settingsUnitsLabel),
          content: Wrap(
            children: [
              Column(
                children: [
                  DropdownButtonFormField(
                    initialValue: selectedUnit,
                    key: ValueKey(selectedUnit),
                    decoration: InputDecoration(
                      enabled: true,
                      filled: false,
                      labelText: S.of(context).settingsSystemLabel,
                    ),
                    onChanged: (value) {
                      selectedUnit = value ?? SystemDropDownType.metric;
                    },
                    items: [
                      DropdownMenuItem(
                        value: SystemDropDownType.metric,
                        child: Text(S.of(context).settingsMetricLabel),
                      ),
                      DropdownMenuItem(
                        value: SystemDropDownType.imperial,
                        child: Text(S.of(context).settingsImperialLabel),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(true);
              },
              child: Text(S.of(context).dialogOKLabel),
            ),
          ],
        );
      },
    );
    if (shouldUpdate == true) {
      _settingsBloc.setUsesImperialUnits(
        selectedUnit == SystemDropDownType.imperial,
      );
      _settingsBloc.add(LoadSettingsEvent());

      // Update blocs
      _profileBloc.add(LoadProfileEvent());
      _homeBloc.add(LoadItemsEvent());
      _diaryBloc.add(const LoadDiaryYearEvent());
    }
  }

  void _showCalculationsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => CalculationsDialog(
        settingsBloc: _settingsBloc,
        profileBloc: _profileBloc,
        homeBloc: _homeBloc,
        diaryBloc: _diaryBloc,
        calendarDayBloc: _calendarDayBloc,
      ),
    );
  }

  void _showExportImportDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => ExportImportDialog());
  }

  void _showImportCustomFoodDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => ImportCustomFoodDataDialog(),
    );
  }

  Future<void> _confirmClearOffCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of(context).clearOffCacheConfirmTitle),
        content: Text(S.of(context).clearOffCacheConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of(context).dialogCancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of(context).dialogOKLabel),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _settingsBloc.clearOffCache();
    }
  }

  /// Format a byte count for display in the cache-clear tile subtitle.
  /// Uses KB up to 1 MB, then MB with one decimal place above that.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showThemeDialog(BuildContext context, AppThemeEntity currentAppTheme) {
    AppThemeEntity selectedTheme = currentAppTheme;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          contentPadding: EdgeInsets.zero,
          title: Text(S.of(context).settingsThemeLabel),
          content: StatefulBuilder(
            builder: (
              BuildContext context,
              void Function(void Function()) setState,
            ) {
              return RadioGroup(
                groupValue: selectedTheme,
                onChanged: (value) {
                  setState(() {
                    selectedTheme = value as AppThemeEntity;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile(
                      title: Text(S.of(context).settingsThemeSystemDefaultLabel),
                      value: AppThemeEntity.system,
                    ),
                    RadioListTile(
                      title: Text(S.of(context).settingsThemeLightLabel),
                      value: AppThemeEntity.light,
                    ),
                    RadioListTile(
                      title: Text(S.of(context).settingsThemeDarkLabel),
                      value: AppThemeEntity.dark,
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogCancelLabel),
            ),
            TextButton(
              onPressed: () async {
                _settingsBloc.setAppTheme(selectedTheme);
                _settingsBloc.add(LoadSettingsEvent());
                setState(() {
                  // Update Theme
                  Provider.of<ThemeModeProvider>(
                    context,
                    listen: false,
                  ).updateTheme(selectedTheme);
                });
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogOKLabel),
            ),
          ],
        );
      },
    );
  }

  static const _supportedLocales = <String, String>{
    'en': 'English',
    'de': 'Deutsch',
    'tr': 'Türkçe',
    'cs': 'Čeština',
    'it': 'Italiano',
    'uk': 'Українська',
    'zh': '中文',
    'pl': 'Polski',
  };

  String? _localeDisplayName(String? code) => _supportedLocales[code];

  // Sentinel value meaning "follow system locale"
  static const _systemLocale = '';

  void _showLanguageDialog(BuildContext context, String? currentLocale) {
    String selectedCode = currentLocale ?? _systemLocale;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          contentPadding: EdgeInsets.zero,
          title: Text(S.of(context).settingsLanguageLabel),
          content: StatefulBuilder(
            builder: (BuildContext context,
                void Function(void Function()) setState) {
              return RadioGroup<String>(
                groupValue: selectedCode,
                onChanged: (v) => setState(() => selectedCode = v as String),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      title:
                          Text(S.of(context).settingsThemeSystemDefaultLabel),
                      value: _systemLocale,
                    ),
                    ..._supportedLocales.entries.map(
                      (e) => RadioListTile<String>(
                        title: Text(e.value),
                        value: e.key,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(S.of(context).dialogCancelLabel),
            ),
            TextButton(
              onPressed: () {
                final locale =
                    selectedCode.isEmpty ? null : selectedCode;
                _settingsBloc.setSelectedLocale(locale);
                _settingsBloc.add(LoadSettingsEvent());
                Provider.of<LocaleProvider>(context, listen: false)
                    .updateLocale(
                  locale != null ? Locale(locale) : null,
                );
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogOKLabel),
            ),
          ],
        );
      },
    );
  }

  void _showDisclaimerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return const DisclaimerDialog();
      },
    );
  }

  void _showReportErrorDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(S.of(context).settingsReportErrorLabel),
          content: Text(S.of(context).reportErrorDialogText),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogCancelLabel),
            ),
            TextButton(
              onPressed: () async {
                _reportError(context);
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogOKLabel),
            ),
          ],
        );
      },
    );
  }

  Future<void> _reportError(BuildContext context) async {
    final reportUri = Uri.parse(
      "mailto:${AppConst.reportErrorEmail}?subject=Report_Error",
    );

    if (await canLaunchUrl(reportUri)) {
      launchUrl(reportUri);
    } else {
      // Cannot open email app, show error snackbar
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).errorOpeningEmail)),
        );
      }
    }
  }

  void _showPrivacyDialog(
    BuildContext context,
    bool hasAcceptedAnonymousData,
  ) async {
    bool switchActive = hasAcceptedAnonymousData;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(S.of(context).settingsPrivacySettings),
          content: StatefulBuilder(
            builder: (
              BuildContext context,
              void Function(void Function()) setState,
            ) {
              return SwitchListTile(
                title: Text(S.of(context).sendAnonymousUserData),
                value: switchActive,
                onChanged: (bool value) {
                  setState(() {
                    switchActive = value;
                  });
                },
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogCancelLabel),
            ),
            TextButton(
              onPressed: () async {
                _settingsBloc.setHasAcceptedAnonymousData(switchActive);
                if (!switchActive) Sentry.close();
                _settingsBloc.add(LoadSettingsEvent());
                Navigator.of(context).pop();
              },
              child: Text(S.of(context).dialogOKLabel),
            ),
          ],
        );
      },
    );
  }

  void _showAboutDialog(BuildContext context) async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    if (context.mounted) {
      showAboutDialog(
        context: context,
        applicationName: S.of(context).appTitle,
        applicationIcon: SizedBox(
          width: 40,
          child: Image.asset('assets/icon/ont_logo_square.png'),
        ),
        applicationVersion: packageInfo.version,
        applicationLegalese: S.of(context).appLicenseLabel,
        children: [
          TextButton(
            onPressed: () {
              _launchSourceCodeUrl(context);
            },
            child: Row(
              children: [
                const Icon(Icons.code_outlined),
                const SizedBox(width: 8.0),
                Text(S.of(context).settingsSourceCodeLabel),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              _launchPrivacyPolicyUrl(context);
            },
            child: Row(
              children: [
                const Icon(Icons.policy_outlined),
                const SizedBox(width: 8.0),
                Text(S.of(context).privacyPolicyLabel),
              ],
            ),
          ),
        ],
      );
    }
  }

  void _launchSourceCodeUrl(BuildContext context) async {
    final sourceCodeUri = Uri.parse(AppConst.sourceCodeUrl);
    _launchUrl(context, sourceCodeUri);
  }

  void _launchPrivacyPolicyUrl(BuildContext context) async {
    final sourceCodeUri = Uri.parse(URLConst.privacyPolicyURLEn);
    _launchUrl(context, sourceCodeUri);
  }

  void _launchUrl(BuildContext context, Uri url) async {
    if (await canLaunchUrl(url)) {
      launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      // Cannot open browser app, show error snackbar
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).errorOpeningBrowser)),
        );
      }
    }
  }
}

/// Settings entry that surfaces the offline-catalog state and routes
/// the user into the wizard. Lives next to the live-OFF cache row so
/// the two related controls sit together.
///
/// The tile listens to [OfflineCatalogBloc] so the subtitle reflects
/// the current state (not built / building NN% / X products, Y MB)
/// without requiring the user to leave settings to know what's
/// happening. Long-press / trailing menu offers refresh and delete
/// actions when a catalog exists.
class _OfflineCatalogTile extends StatefulWidget {
  final String Function(int bytes) formatBytes;

  const _OfflineCatalogTile({required this.formatBytes});

  @override
  State<_OfflineCatalogTile> createState() => _OfflineCatalogTileState();
}

class _OfflineCatalogTileState extends State<_OfflineCatalogTile> {
  late OfflineCatalogBloc _bloc;
  late ConfigRepository _configRepo;
  late CheckCatalogAvailabilityUseCase _checkAvailability;

  /// Cached snapshot of the auto-disabled flag from
  /// [ConfigRepository]. Polled in initState and refreshed after
  /// the user re-enables — that's all we need; this widget is
  /// short-lived (the user navigates away before the value can
  /// drift in any meaningful way).
  bool _autoDisabled = false;

  /// True while a tap-time CDN probe is in flight. The bloc has its
  /// own mount-time probe, but the bloc is a lazy singleton so its
  /// cached `idle` / `ready` state from a previous session is what
  /// the tile renders for the very first frame, before the new
  /// `LoadCatalogStatusEvent` has had a chance to run. A fast tap
  /// during that window would otherwise fall through to the wizard
  /// because the cached phase is still `idle`. Running the probe
  /// inline on every tap closes that race and also gates wizard
  /// entry for users with an installed catalog (where the bloc skips
  /// the mount-time probe entirely so search keeps working offline).
  bool _tapProbing = false;

  /// Set by a failed tap-time probe so the tile subtitle flips to
  /// "try again later" until the user taps again. Cleared at the
  /// start of every probe and on probe success. Independent of the
  /// bloc state because it has to override even a `ready` phase
  /// where the bloc itself thinks everything is fine.
  bool _tapProbeFailed = false;

  @override
  void initState() {
    super.initState();
    _bloc = locator<OfflineCatalogBloc>();
    _configRepo = locator<ConfigRepository>();
    _checkAvailability = locator<CheckCatalogAvailabilityUseCase>();
    // Read current state so the subtitle is correct on first paint.
    _bloc.add(const LoadCatalogStatusEvent());
    _loadAutoDisabledFlag();
  }

  Future<void> _loadAutoDisabledFlag() async {
    final value = await _configRepo.getCatalogAutoDisabled();
    if (!mounted) return;
    setState(() => _autoDisabled = value);
  }

  Future<void> _reenable() async {
    await _configRepo.setOfflineCatalogEnabled(true);
    await _configRepo.setCatalogAutoDisabled(false);
    await _configRepo.setCatalogConsecutiveCrashes(0);
    if (!mounted) return;
    setState(() => _autoDisabled = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // l10n: offlineCatalogReenabledSnack
        content: const Text('Offline catalog re-enabled'),
      ),
    );
  }

  void _openWizard() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const OfflineCatalogWizardScreen(),
      ),
    );
  }

  /// Tap handler. Runs an unconditional CDN probe before opening the
  /// wizard, regardless of what the bloc state currently says. This
  /// catches both the cached-state race (lazy-singleton bloc holding
  /// `idle` / `ready` from a previous session) and the
  /// installed-catalog case (where the bloc's mount-time probe is
  /// skipped because search works offline). The probe is the single
  /// source of truth for whether the wizard should open.
  void _handleTileTap(OfflineCatalogState state) {
    if (_tapProbing) return;
    if (state.phase == OfflineCatalogPhase.checking) return;
    _probeThenOpen();
  }

  Future<void> _probeThenOpen() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = S.of(context);
    setState(() {
      _tapProbing = true;
      _tapProbeFailed = false;
    });
    try {
      final available = await _checkAvailability();
      if (!mounted) return;
      if (!available) {
        // Re-run the bloc's mount-time probe so a no-catalog user
        // sees the bloc settle on `unavailable` (and the regression
        // tests that pin that contract still apply). For an
        // installed-catalog user the bloc stays on `ready` and
        // _tapProbeFailed shadows the subtitle until the next tap.
        _bloc.add(const LoadCatalogStatusEvent());
        setState(() => _tapProbeFailed = true);
        messenger.showSnackBar(
          SnackBar(content: Text(s.offlineCatalogTileUnavailable)),
        );
        return;
      }
      _openWizard();
    } finally {
      if (mounted) setState(() => _tapProbing = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.offlineCatalogDeleteConfirmTitle),
        content: Text(s.offlineCatalogDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.offlineCatalogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.offlineCatalogActionDelete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _bloc.add(const DeleteCatalogEvent());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OfflineCatalogBloc, OfflineCatalogState>(
      bloc: _bloc,
      builder: (context, state) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_autoDisabled) _buildAutoDisabledBanner(context),
            ListTile(
              leading: const Icon(Icons.travel_explore_outlined),
              title: Text(S.of(context).offlineCatalogTitle),
              subtitle: Text(_subtitleFor(context, state)),
              trailing: _trailingFor(context, state),
              onTap: () => _handleTileTap(state),
              enabled: state.phase != OfflineCatalogPhase.checking &&
                  !_tapProbing,
            ),
          ],
        );
      },
    );
  }

  Widget _buildAutoDisabledBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // l10n: offlineCatalogAutoDisabledTitle
                Text(
                  'Offline catalog turned off',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                // l10n: offlineCatalogAutoDisabledBody
                const Text(
                  'The app crashed twice in a row, so we paused the '
                  'offline catalog to keep things running. Your '
                  'downloaded products are still on disk — re-enable '
                  'when you\'re ready, or delete and rebuild from the '
                  'tile below.',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _reenable,
                    icon: const Icon(Icons.power_settings_new),
                    // l10n: offlineCatalogReenableAction
                    label: const Text('Re-enable'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _subtitleFor(BuildContext context, OfflineCatalogState state) {
    final s = S.of(context);
    // When the catalog is auto-disabled by the crash safety switch
    // we shadow the usual "ready / X products" subtitle with the
    // disabled state plus the data-still-on-disk hint, so even a
    // user who scrolls past the banner still sees that the catalog
    // is paused (not gone).
    if (_autoDisabled) {
      final stats = state.stats ?? CatalogStatsEntity.empty;
      if (stats.isPopulated) {
        // l10n: offlineCatalogTileAutoDisabledWithData
        return 'Paused after repeated crashes — '
            '${stats.productCount} products kept on disk';
      }
      // l10n: offlineCatalogTileAutoDisabled
      return 'Paused after repeated crashes — tap to set up again';
    }
    // Local tap-time probe outranks the bloc state: the bloc may
    // think the catalog is `ready` (data on disk) while a tap-time
    // probe just confirmed the CDN is unreachable. The subtitle
    // should reflect what the user just learned.
    if (_tapProbing) return s.offlineCatalogTileCheckingAvailability;
    if (_tapProbeFailed) return s.offlineCatalogTileUnavailable;
    switch (state.phase) {
      case OfflineCatalogPhase.checking:
        return s.offlineCatalogTileCheckingAvailability;
      case OfflineCatalogPhase.unavailable:
        return s.offlineCatalogTileUnavailable;
      case OfflineCatalogPhase.downloading:
      case OfflineCatalogPhase.installing:
        final p = state.progress;
        if (p == null) return s.offlineCatalogTileBuilding;
        return s.offlineCatalogTileBuildingPercent(
          (p.fraction * 100).toStringAsFixed(0),
        );
      case OfflineCatalogPhase.paused:
        return s.offlineCatalogTilePaused;
      case OfflineCatalogPhase.ready:
        final stats = state.stats ?? CatalogStatsEntity.empty;
        if (!stats.isPopulated) return s.offlineCatalogTileNotBuilt;
        final base = s.offlineCatalogTileReady(
          stats.productCount,
          widget.formatBytes(stats.sizeBytes),
        );
        if (stats.lastSyncTime == null) return base;
        return base +
            s.offlineCatalogTileLastRefreshed(
              _relative(context, stats.lastSyncTime!),
            );
      case OfflineCatalogPhase.idle:
      default:
        return s.offlineCatalogTileNotBuilt;
    }
  }

  Widget? _trailingFor(BuildContext context, OfflineCatalogState state) {
    final stats = state.stats;
    if (stats == null || !stats.isPopulated) return null;
    if (state.phase == OfflineCatalogPhase.downloading ||
        state.phase == OfflineCatalogPhase.installing) {
      return null;
    }
    final s = S.of(context);
    return PopupMenuButton<String>(
      onSelected: (action) {
        if (action == 'refresh') {
          _bloc.add(const RefreshCatalogEvent());
        } else if (action == 'delete') {
          _confirmDelete(context);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'refresh',
          child: ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(s.offlineCatalogActionRefresh),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(s.offlineCatalogActionDelete),
          ),
        ),
      ],
    );
  }

  String _relative(BuildContext context, DateTime when) {
    final s = S.of(context);
    final diff = DateTime.now().difference(when);
    if (diff.inDays >= 30) {
      return s.offlineCatalogTimeMonthsAgo((diff.inDays / 30).floor());
    }
    if (diff.inDays >= 7) {
      return s.offlineCatalogTimeWeeksAgo((diff.inDays / 7).floor());
    }
    if (diff.inDays >= 1) {
      return s.offlineCatalogTimeDaysAgo(diff.inDays);
    }
    if (diff.inHours >= 1) {
      return s.offlineCatalogTimeHoursAgo(diff.inHours);
    }
    return s.offlineCatalogTimeJustNow;
  }
}
