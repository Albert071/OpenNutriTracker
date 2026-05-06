import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/build_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/delete_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/estimate_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_catalog_stats_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_countries_taxonomy_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/refresh_catalog_usecase.dart';

part 'offline_catalog_event.dart';
part 'offline_catalog_state.dart';

/// Lifecycle bloc for the offline OFF catalog wizard.
///
/// Registered as a **lazy singleton** so an in-flight build survives
/// the wizard screen being popped — the user can navigate away and
/// come back to find their download still progressing. The bloc owns
/// a [CancellationToken] for whatever long-running work is currently
/// running; pause and cancel both flip the token, then the build
/// stream completes naturally between pages.
///
/// Progress emissions from the underlying repository are throttled to
/// at most one per second before reaching the state stream. The
/// repository emits per-page (every 100 rows by default), so without
/// throttling the UI would rebuild ~10x/sec on a fast connection.
class OfflineCatalogBloc extends Bloc<OfflineCatalogEvent, OfflineCatalogState> {
  static const _progressEmitInterval = Duration(milliseconds: 1000);

  final _log = Logger('OfflineCatalogBloc');

  final GetCatalogStatsUseCase _getStats;
  final GetCountriesTaxonomyUseCase _getCountries;
  final EstimateCatalogUseCase _estimate;
  final BuildCatalogUseCase _build;
  final RefreshCatalogUseCase _refresh;
  final DeleteCatalogUseCase _delete;
  final ConfigRepository _configRepository;

  CancellationToken? _activeToken;

  OfflineCatalogBloc(
    this._getStats,
    this._getCountries,
    this._estimate,
    this._build,
    this._refresh,
    this._delete,
    this._configRepository,
  ) : super(OfflineCatalogState.initial) {
    on<LoadCatalogStatusEvent>(_onLoadStatus);
    on<LoadCountriesEvent>(_onLoadCountries);
    on<EstimateCatalogEvent>(_onEstimate);
    on<StartCatalogBuildEvent>(_onStartBuild);
    on<PauseCatalogBuildEvent>(_onPause);
    on<ResumeCatalogBuildEvent>(_onResume);
    on<CancelCatalogBuildEvent>(_onCancel);
    on<RefreshCatalogEvent>(_onRefresh);
    on<DeleteCatalogEvent>(_onDelete);
    on<ToggleCatalogEnabledEvent>(_onToggleEnabled);
  }

  Future<void> _onLoadStatus(
    LoadCatalogStatusEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    final stats = await _getStats();
    final hasResume = await _build.hasResumeableBuild();
    if (hasResume) {
      // Resumeable cursor sitting on disk: catalog is mid-build, the
      // user backgrounded or killed the app. Land on Paused so the
      // wizard's download page surfaces a Resume CTA.
      final filters = await _build.getPersistedFilters();
      emit(state.copyWith(
        phase: OfflineCatalogPhase.paused,
        stats: stats,
        activeFilters: filters,
        clearError: true,
      ));
      return;
    }
    emit(state.copyWith(
      phase: stats.isPopulated
          ? OfflineCatalogPhase.ready
          : OfflineCatalogPhase.idle,
      stats: stats,
      clearError: true,
    ));
  }

  /// Catalog "lifecycle" phases — active operations or meaningful
  /// end states. When we're in one of these, wizard-auxiliary
  /// events (country taxonomy fetch, estimate probe) MUST NOT
  /// overwrite the lifecycle state with a transient phase like
  /// `loadingCountries`. Otherwise the download page would lose
  /// its PausedView / BuildingView and fall through to a bare
  /// spinner — which is exactly the hang we hit when reopening
  /// the wizard onto a paused build.
  ///
  /// Notably `idle` is NOT in this set: idle means "no catalog
  /// yet" and the wizard's normal flow (region page → estimate
  /// page → start build) should be allowed to transition through
  /// loadingCountries / estimating / etc. as it always did.
  static bool _isLifecyclePhase(OfflineCatalogPhase phase) {
    return phase == OfflineCatalogPhase.building ||
        phase == OfflineCatalogPhase.paused ||
        phase == OfflineCatalogPhase.refreshing ||
        phase == OfflineCatalogPhase.ready ||
        phase == OfflineCatalogPhase.error;
  }

  Future<void> _onLoadCountries(
    LoadCountriesEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    final preservePhase = _isLifecyclePhase(state.phase);
    emit(state.copyWith(
      phase: preservePhase
          ? state.phase
          : OfflineCatalogPhase.loadingCountries,
    ));
    try {
      final countries = await _getCountries(
        locale: event.locale,
        forceRefresh: event.forceRefresh,
      );
      // Detect fallback mode by sniffing for the small static list:
      // when the live fetch fails the data source returns 12 hand-
      // picked countries. The wizard surfaces an offline notice in
      // that case.
      final fromFallback = countries.length <= 12;
      emit(state.copyWith(
        phase: preservePhase
            ? state.phase
            : OfflineCatalogPhase.countriesLoaded,
        countries: countries,
        countriesFromFallback: fromFallback,
        // Clearing the error when we have a meaningful lifecycle
        // phase would mask catalog-side errors that the user still
        // needs to see.
        clearError: !preservePhase,
      ));
    } catch (e, stack) {
      _log.warning('LoadCountries failed', e, stack);
      // If we have a meaningful lifecycle running, swallow this —
      // the user is dealing with the catalog, not the country
      // picker, and we don't want a taxonomy 503 to derail them.
      if (preservePhase) return;
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        errorRecoverable: true,
      ));
    }
  }

  Future<void> _onEstimate(
    EstimateCatalogEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    // Same lifecycle protection as _onLoadCountries — never let an
    // estimate probe overwrite a paused / building / ready state.
    if (_isLifecyclePhase(state.phase)) {
      _log.fine(
        'Skipping estimate; catalog lifecycle phase ${state.phase} '
        'is in flight',
      );
      return;
    }
    emit(state.copyWith(
      phase: OfflineCatalogPhase.estimating,
      activeFilters: event.filters,
      clearEstimate: true,
      clearError: true,
    ));
    try {
      final estimate = await _estimate(event.filters);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.estimated,
        estimate: estimate,
      ));
    } catch (e, stack) {
      _log.warning('Estimate failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        errorRecoverable: true,
      ));
    }
  }

  Future<void> _onStartBuild(
    StartCatalogBuildEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    await _runBuild(event.filters, emit, isResume: false);
  }

  Future<void> _onResume(
    ResumeCatalogBuildEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    // Resume always uses the on-disk filter set captured when the
    // paused build was originally started. The bloc deliberately
    // ignores [state.activeFilters] here — that's the user's
    // current wizard selection, which may have drifted away from
    // what's actually being resumed (paused with UK selected,
    // navigated back, picked France, hit Resume → without this
    // pin, we'd silently swap mid-build). If the user wants
    // different filters, they have to Cancel and start over from
    // the wizard.
    final filters = await _build.getPersistedFilters();
    if (filters == null) {
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: 'No paused build to resume',
        errorRecoverable: false,
      ));
      return;
    }
    await _runBuild(filters, emit, isResume: true);
  }

  Future<void> _runBuild(
    CatalogFilterEntity filters,
    Emitter<OfflineCatalogState> emit, {
    required bool isResume,
  }) async {
    final token = CancellationToken();
    _activeToken = token;

    emit(state.copyWith(
      phase: OfflineCatalogPhase.building,
      activeFilters: filters,
      clearError: true,
    ));

    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    DownloadProgress? lastProgress;

    try {
      await for (final progress in _build(
        filters: filters,
        cancellation: token,
      )) {
        lastProgress = progress;
        // The parser only checks cancellation between batches, so a
        // fraction of a second can elapse between the user tapping
        // Pause / Cancel and the parser actually stopping. During
        // that window we'd otherwise re-emit `building` and
        // overwrite the paused / idle state the handler just set,
        // leaving the UI flipped back to a frozen progress bar.
        // Drop late events whose target phase has already moved on.
        if (state.phase != OfflineCatalogPhase.building) continue;
        final now = DateTime.now();
        if (now.difference(lastEmit) >= _progressEmitInterval) {
          lastEmit = now;
          emit(state.copyWith(
            phase: OfflineCatalogPhase.building,
            progress: progress,
          ));
        }
      }
      // Final emit so the wizard sees 100% before the phase flips.
      // Same guard — if the user paused mid-stream we don't want to
      // unwind their pause with a final 100% snapshot.
      if (lastProgress != null && state.phase == OfflineCatalogPhase.building) {
        emit(state.copyWith(
          phase: OfflineCatalogPhase.building,
          progress: lastProgress,
        ));
      }
      // Build completed successfully: enable the catalog by default
      // (it's the user's reasonable expectation after going through
      // the wizard) and refresh stats so the done page can show them.
      await _configRepository.setOfflineCatalogEnabled(true);
      final stats = await _getStats();
      emit(state.copyWith(
        phase: OfflineCatalogPhase.ready,
        stats: stats,
        clearProgress: false,
      ));
    } on CancellationException {
      // Cancelled or paused: the [_onPause] / [_onCancel] handlers
      // have already moved us to the right phase. Re-emit progress
      // so the UI keeps the latest snapshot.
      _log.fine('Build interrupted (resume=$isResume)');
      if (lastProgress != null && state.phase == OfflineCatalogPhase.building) {
        emit(state.copyWith(progress: lastProgress));
      }
    } catch (e, stack) {
      _log.warning('Build failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        errorRecoverable: true,
        progress: lastProgress,
      ));
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  Future<void> _onPause(
    PauseCatalogBuildEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    final token = _activeToken;
    if (token == null) return;
    token.cancel();
    emit(state.copyWith(
      phase: OfflineCatalogPhase.paused,
      progress: state.progress,
    ));
  }

  Future<void> _onCancel(
    CancelCatalogBuildEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    final token = _activeToken;
    token?.cancel();
    // Drop the partial catalog so the next attempt starts fresh.
    await _delete();
    emit(state.copyWith(
      phase: OfflineCatalogPhase.idle,
      stats: CatalogStatsEntity.empty,
      clearProgress: true,
      clearEstimate: true,
      clearError: true,
    ));
  }

  Future<void> _onRefresh(
    RefreshCatalogEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    final token = CancellationToken();
    _activeToken = token;
    emit(state.copyWith(
      phase: OfflineCatalogPhase.refreshing,
      clearError: true,
    ));
    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final progress in _refresh(cancellation: token)) {
        // Same race guard as [_runBuild]: drop late progress events
        // that arrived after the user paused / cancelled, so they
        // don't overwrite the post-pause state and leave the UI
        // stuck on a frozen progress bar.
        if (state.phase != OfflineCatalogPhase.refreshing) continue;
        final now = DateTime.now();
        if (now.difference(lastEmit) >= _progressEmitInterval) {
          lastEmit = now;
          emit(state.copyWith(
            phase: OfflineCatalogPhase.refreshing,
            progress: progress,
          ));
        }
      }
      final stats = await _getStats();
      emit(state.copyWith(
        phase: OfflineCatalogPhase.ready,
        stats: stats,
        clearProgress: true,
      ));
    } on CancellationException {
      final stats = await _getStats();
      emit(state.copyWith(
        phase: OfflineCatalogPhase.ready,
        stats: stats,
        clearProgress: true,
      ));
    } catch (e, stack) {
      _log.warning('Refresh failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        errorRecoverable: true,
      ));
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  Future<void> _onDelete(
    DeleteCatalogEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    try {
      await _delete();
      emit(state.copyWith(
        phase: OfflineCatalogPhase.idle,
        stats: CatalogStatsEntity.empty,
        clearProgress: true,
        clearEstimate: true,
        clearError: true,
      ));
    } catch (e, stack) {
      _log.warning('Delete failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        errorRecoverable: true,
      ));
    }
  }

  Future<void> _onToggleEnabled(
    ToggleCatalogEnabledEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    await _configRepository.setOfflineCatalogEnabled(event.enabled);
  }

  @override
  Future<void> close() async {
    _activeToken?.cancel();
    await super.close();
  }
}
