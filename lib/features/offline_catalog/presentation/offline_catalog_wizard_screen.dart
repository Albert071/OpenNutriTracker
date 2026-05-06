import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:introduction_screen/introduction_screen.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/download_progress_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/estimate_confirm_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/quality_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/region_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/welcome_wizard_page.dart';
import 'package:opennutritracker/features/onboarding/presentation/widgets/highlight_button.dart';

/// Five-page wizard that walks the user through building the offline
/// catalog. Mirrors the visual shape of [OnboardingScreen] so the
/// experience feels native to the app: same `IntroductionScreen`
/// package, same dot indicators, same `HighlightButton` footer.
///
/// State held locally on the orchestrator:
///
/// * The user's filter selection, accumulated across pages 2 and 3.
/// * The current page index (so footer buttons can be gated on the
///   right per-page completion criteria).
/// * Whether the user has typed the confirmation phrase, when the
///   estimate exceeds the hard cap.
///
/// Bloc-owned state — countries taxonomy, estimate, build progress,
/// catalog readiness — comes through `BlocBuilder` inside each page.
class OfflineCatalogWizardScreen extends StatefulWidget {
  /// Optional pre-selected country code (e.g. `en:france`) inferred
  /// from the user's app locale. The region page will mark this
  /// country selected when the wizard opens for the first time.
  final String? initialCountryCode;

  /// Locale code (e.g. `en`, `de`) passed to OFF as `lc=` so the
  /// returned country names are in the user's language.
  final String? locale;

  const OfflineCatalogWizardScreen({
    super.key,
    this.initialCountryCode,
    this.locale,
  });

  @override
  State<OfflineCatalogWizardScreen> createState() =>
      _OfflineCatalogWizardScreenState();
}

class _OfflineCatalogWizardScreenState
    extends State<OfflineCatalogWizardScreen> {
  late OfflineCatalogBloc _bloc;
  final _introKey = GlobalKey<IntroductionScreenState>();

  // Mutable filter selection accumulated across pages 2 and 3.
  late Set<String> _selectedCountries;
  bool _requireNutritionGrade = true;
  bool _requireMinPopularity = true;
  Duration? _maxAge = CatalogFilterEntity.defaultMaxAge;

  bool _hardCapConfirmed = false;
  int _currentPage = 0;

  static const _pageRegion = 1;
  static const _pageQuality = 2;
  static const _pageEstimate = 3;
  static const _pageDownload = 4;

  @override
  void initState() {
    super.initState();
    _bloc = locator<OfflineCatalogBloc>();
    _selectedCountries = {
      if (widget.initialCountryCode != null) widget.initialCountryCode!,
    };

    // Kick off the lifecycle: read current state, decide whether we're
    // landing on a fresh wizard or on the resume-build view.
    _bloc.add(const LoadCatalogStatusEvent());
    _bloc.add(LoadCountriesEvent(locale: widget.locale));
  }

  CatalogFilterEntity get _currentFilters => CatalogFilterEntity(
        countries: _selectedCountries,
        requireNutritionGrade: _requireNutritionGrade,
        requireMinPopularity: _requireMinPopularity,
        maxAge: _maxAge,
      );

  void _scrollTo(int page) {
    FocusScope.of(context).requestFocus(FocusNode());
    _introKey.currentState?.animateScroll(page);
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
      // Reset typed-confirmation state when leaving / re-entering the
      // estimate page so a previous "I understand" doesn't carry into
      // a new filter set.
      if (page != _pageEstimate) _hardCapConfirmed = false;
    });
    if (page == _pageEstimate) {
      _bloc.add(EstimateCatalogEvent(_currentFilters));
    } else if (page == _pageDownload) {
      // Only trigger a fresh start if we are not already mid-build /
      // paused / done — those phases mean the bloc is already on
      // task and we should not re-enter.
      final phase = _bloc.state.phase;
      if (phase != OfflineCatalogPhase.building &&
          phase != OfflineCatalogPhase.paused &&
          phase != OfflineCatalogPhase.ready) {
        _bloc.add(StartCatalogBuildEvent(_currentFilters));
      }
    }
  }

  void _close() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // l10n: offlineCatalogWizardAppBarTitle
      appBar: AppBar(title: const Text('Offline food catalog')),
      body: BlocListener<OfflineCatalogBloc, OfflineCatalogState>(
        bloc: _bloc,
        listenWhen: (previous, current) =>
            previous.phase != current.phase,
        listener: (context, state) {
          // Auto-jump to the download page when the wizard opens onto
          // a paused build. Without this, the user would see the
          // welcome page and be confused that "Start" is disabled.
          if (state.phase == OfflineCatalogPhase.paused &&
              _currentPage < _pageDownload) {
            _scrollTo(_pageDownload);
          }
        },
        child: BlocProvider.value(
          value: _bloc,
          child: SafeArea(child: _buildIntroductionScreen(context)),
        ),
      ),
    );
  }

  Widget _buildIntroductionScreen(BuildContext context) {
    return IntroductionScreen(
      key: _introKey,
      scrollPhysics: const NeverScrollableScrollPhysics(),
      back: const Icon(Icons.arrow_back_outlined),
      showBackButton: true,
      showNextButton: false,
      showDoneButton: false,
      isProgressTap: false,
      dotsFlex: 0,
      dotsDecorator: DotsDecorator(
        size: const Size(10.0, 10.0),
        activeColor: Theme.of(context).colorScheme.primary,
        activeSize: const Size(22.0, 10.0),
        activeShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(25.0)),
        ),
      ),
      onChange: _onPageChanged,
      pages: _buildPages(),
    );
  }

  List<PageViewModel> _buildPages() {
    const decoration = PageDecoration(
      safeArea: 0,
      bodyAlignment: Alignment.topCenter,
      bodyFlex: 6,
    );
    return [
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: const WelcomeWizardPage(),
        footer: HighlightButton(
          // l10n: offlineCatalogStartLabel
          buttonLabel: 'Get started',
          onButtonPressed: () => _scrollTo(_pageRegion),
          buttonActive: true,
        ),
      ),
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: RegionWizardPage(
          initialSelection: _selectedCountries,
          onSelectionChanged: (selection) {
            setState(() => _selectedCountries = selection);
          },
        ),
        footer: HighlightButton(
          // l10n: offlineCatalogNextLabel
          buttonLabel: 'Next',
          onButtonPressed: () => _scrollTo(_pageQuality),
          buttonActive: _selectedCountries.isNotEmpty,
        ),
      ),
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: QualityWizardPage(
          initialRequireNutritionGrade: _requireNutritionGrade,
          initialRequireMinPopularity: _requireMinPopularity,
          initialMaxAge: _maxAge,
          onChanged: (nutrition, popularity, maxAge) {
            setState(() {
              _requireNutritionGrade = nutrition;
              _requireMinPopularity = popularity;
              _maxAge = maxAge;
            });
          },
        ),
        footer: HighlightButton(
          buttonLabel: 'Next',
          onButtonPressed: () => _scrollTo(_pageEstimate),
          buttonActive: true,
        ),
      ),
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: EstimateConfirmWizardPage(
          onConfirmedChanged: (confirmed) {
            setState(() => _hardCapConfirmed = confirmed);
          },
        ),
        footer: BlocBuilder<OfflineCatalogBloc, OfflineCatalogState>(
          bloc: _bloc,
          builder: (context, state) {
            final estimate = state.estimate;
            final canStart = estimate != null &&
                estimate.rows > 0 &&
                (!estimate.isAboveHardCap || _hardCapConfirmed);
            return HighlightButton(
              // l10n: offlineCatalogDownloadLabel
              buttonLabel: 'Download',
              onButtonPressed: () => _scrollTo(_pageDownload),
              buttonActive: canStart,
            );
          },
        ),
      ),
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: DownloadProgressWizardPage(onDone: _close),
        footer: const SizedBox.shrink(),
      ),
    ];
  }
}
