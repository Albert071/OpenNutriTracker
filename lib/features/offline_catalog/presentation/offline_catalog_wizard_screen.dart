import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:introduction_screen/introduction_screen.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/download_progress_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/estimate_confirm_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/quality_wizard_page.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/widgets/welcome_wizard_page.dart';
import 'package:opennutritracker/features/onboarding/presentation/widgets/highlight_button.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Four-page wizard that walks the user through downloading the
/// offline catalog. Mirrors the visual shape of `OnboardingScreen`
/// so the experience feels native to the app: same
/// [IntroductionScreen] package, same dot indicators, same
/// [HighlightButton] footer.
///
/// State held locally on the orchestrator:
///
/// * The user's filter selection, accumulated across the quality page.
/// * The current page index (so footer buttons can be gated on the
///   right per-page completion criteria).
///
/// Bloc-owned state — estimate, build progress, catalog readiness —
/// comes through `BlocBuilder` inside each page.
class OfflineCatalogWizardScreen extends StatefulWidget {
  const OfflineCatalogWizardScreen({super.key});

  @override
  State<OfflineCatalogWizardScreen> createState() =>
      _OfflineCatalogWizardScreenState();
}

class _OfflineCatalogWizardScreenState
    extends State<OfflineCatalogWizardScreen> {
  late OfflineCatalogBloc _bloc;
  final _introKey = GlobalKey<IntroductionScreenState>();

  // Filter selection accumulated across the quality page. Defaults
  // match the recommended (smallest, strictest) variant — a user who
  // taps Next without thinking gets the 73 MB tier.
  bool _requireNutritionGrade = true;
  bool _requireMinPopularity = true;
  Duration? _maxAge = CatalogFilterEntity.defaultMaxAge;

  int _currentPage = 0;

  static const _pageQuality = 1;
  static const _pageEstimate = 2;
  static const _pageDownload = 3;

  @override
  void initState() {
    super.initState();
    _bloc = locator<OfflineCatalogBloc>();
    // Kick off the lifecycle: read current state, decide whether we're
    // landing on a fresh wizard or on the resume-build view.
    _bloc.add(const LoadCatalogStatusEvent());
  }

  CatalogFilterEntity get _currentFilters => CatalogFilterEntity(
        requireNutritionGrade: _requireNutritionGrade,
        requireMinPopularity: _requireMinPopularity,
        maxAge: _maxAge,
      );

  void _scrollTo(int page) {
    FocusScope.of(context).requestFocus(FocusNode());
    _introKey.currentState?.animateScroll(page);
  }

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);

    // If the catalog is in a lifecycle phase (paused mid-build, fully
    // ready, etc.) and we landed on a pre-download page, the user
    // doesn't actually want this page — they want the download page
    // where they can resume / view their catalog. This guard catches
    // intermediate landings during the auto-jump animation as well as
    // any back-navigation that doesn't make sense at this lifecycle
    // stage. Defer the re-jump to after the current frame so we don't
    // fight the in-flight page transition.
    final phase = _bloc.state.phase;
    final isLifecycle = phase == OfflineCatalogPhase.paused ||
        phase == OfflineCatalogPhase.downloading ||
        phase == OfflineCatalogPhase.installing ||
        phase == OfflineCatalogPhase.ready;
    if (isLifecycle && page < _pageDownload) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentPage < _pageDownload) _scrollTo(_pageDownload);
      });
      return;
    }

    if (page == _pageEstimate) {
      _bloc.add(EstimateCatalogEvent(_currentFilters));
    } else if (page == _pageDownload) {
      // Only trigger a fresh start if we are not already mid-build /
      // paused / done — those phases mean the bloc is already on
      // task and we should not re-enter.
      if (phase != OfflineCatalogPhase.downloading &&
          phase != OfflineCatalogPhase.installing &&
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
      appBar: AppBar(title: Text(S.of(context).offlineCatalogTitle)),
      body: BlocListener<OfflineCatalogBloc, OfflineCatalogState>(
        bloc: _bloc,
        listenWhen: (previous, current) =>
            previous.phase != current.phase,
        listener: (context, state) {
          // Auto-jump to the download page when the wizard opens onto
          // a paused or ready build. The jump is deferred to after
          // the next frame because IntroductionScreen's PageController
          // isn't always fully initialised when the bloc emits its
          // first state, and a too-early animateScroll lands on an
          // intermediate page (typically the estimate page) where
          // the user gets stranded.
          final wantJump = (state.phase == OfflineCatalogPhase.paused ||
                  state.phase == OfflineCatalogPhase.ready) &&
              _currentPage < _pageDownload;
          if (wantJump) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_currentPage < _pageDownload) _scrollTo(_pageDownload);
            });
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
    final s = S.of(context);
    return [
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: const WelcomeWizardPage(),
        footer: HighlightButton(
          buttonLabel: s.offlineCatalogStartAction,
          onButtonPressed: () => _scrollTo(_pageQuality),
          buttonActive: true,
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
          buttonLabel: s.offlineCatalogNextAction,
          onButtonPressed: () => _scrollTo(_pageEstimate),
          buttonActive: true,
        ),
      ),
      PageViewModel(
        title: '',
        decoration: decoration,
        bodyWidget: const EstimateConfirmWizardPage(),
        footer: BlocBuilder<OfflineCatalogBloc, OfflineCatalogState>(
          bloc: _bloc,
          builder: (context, state) {
            final estimate = state.estimate;
            final canStart = estimate != null && estimate.rows > 0;
            return HighlightButton(
              buttonLabel: s.offlineCatalogDownloadAction,
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
