import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/catalog_download_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/build_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/delete_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/estimate_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_catalog_stats_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/refresh_catalog_usecase.dart';

part 'offline_catalog_event.dart';
part 'offline_catalog_state.dart';

/// Lifecycle bloc for the offline catalog wizard.
///
/// Registered as a **lazy singleton** so an in-flight download survives
/// the wizard screen being popped — the user can navigate away and
/// come back to find their download still progressing. The bloc owns
/// a [CancellationToken] for whatever long-running work is currently
/// running; pause and cancel both flip the token, then the build
/// stream completes naturally.
///
/// Progress emissions from the underlying repository are throttled to
/// at most one per second before reaching the state stream so the
/// LinearProgressIndicator does not thrash on a fast connection.
class OfflineCatalogBloc extends Bloc<OfflineCatalogEvent, OfflineCatalogState> {
  static const _progressEmitInterval = Duration(milliseconds: 1000);

  final _log = Logger('OfflineCatalogBloc');

  final GetCatalogStatsUseCase _getStats;
  final EstimateCatalogUseCase _estimate;
  final BuildCatalogUseCase _build;
  final RefreshCatalogUseCase _refresh;
  final DeleteCatalogUseCase _delete;
  final ConfigRepository _configRepository;

  CancellationToken? _activeToken;

  OfflineCatalogBloc(
    this._getStats,
    this._estimate,
    this._build,
    this._refresh,
    this._delete,
    this._configRepository,
  ) : super(OfflineCatalogState.initial) {
    on<LoadCatalogStatusEvent>(_onLoadStatus);
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
      // A partial gzip is sitting on disk. Land on Paused so the
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
  /// events (estimate probe) MUST NOT overwrite the lifecycle state
  /// with a transient phase. Otherwise the download page would lose
  /// its Paused/Downloading view and fall through to a bare spinner.
  ///
  /// Notably `idle` is NOT in this set: idle means "no catalog yet"
  /// and the wizard's normal flow (estimate page → start build)
  /// should be allowed to transition through `estimating` etc. as
  /// it always did.
  static bool _isLifecyclePhase(OfflineCatalogPhase phase) {
    return phase == OfflineCatalogPhase.downloading ||
        phase == OfflineCatalogPhase.installing ||
        phase == OfflineCatalogPhase.paused ||
        phase == OfflineCatalogPhase.ready ||
        phase == OfflineCatalogPhase.error;
  }

  Future<void> _onEstimate(
    EstimateCatalogEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
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
    // current wizard selection, which may have drifted.
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

  Future<void> _onRefresh(
    RefreshCatalogEvent event,
    Emitter<OfflineCatalogState> emit,
  ) async {
    // Refresh re-runs the download for the persisted variant. The
    // inner stream is the same `build` pipeline, so the UI uses the
    // same downloading/installing phases as a first install.
    final token = CancellationToken();
    _activeToken = token;
    emit(state.copyWith(
      phase: OfflineCatalogPhase.downloading,
      clearError: true,
      clearProgress: true,
    ));
    DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    DownloadProgress? lastProgress;
    try {
      await for (final progress in _refresh(cancellation: token)) {
        lastProgress = progress;
        final targetPhase = _phaseForProgress(progress);
        if (state.phase != OfflineCatalogPhase.downloading &&
            state.phase != OfflineCatalogPhase.installing) {
          continue;
        }
        final now = DateTime.now();
        if (now.difference(lastEmit) >= _progressEmitInterval ||
            targetPhase != state.phase) {
          lastEmit = now;
          emit(state.copyWith(phase: targetPhase, progress: progress));
        }
      }
      if (lastProgress != null &&
          (state.phase == OfflineCatalogPhase.downloading ||
              state.phase == OfflineCatalogPhase.installing)) {
        emit(state.copyWith(
          phase: _phaseForProgress(lastProgress),
          progress: lastProgress,
        ));
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
        phase: stats.isPopulated
            ? OfflineCatalogPhase.ready
            : OfflineCatalogPhase.idle,
        stats: stats,
        clearProgress: true,
      ));
    } catch (e, stack) {
      _log.warning('Refresh failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        // Same reasoning as in _runBuild: a schema-version mismatch
        // is permanent until the app updates, so don't offer retry.
        errorRecoverable: e is! CatalogSchemaVersionException,
      ));
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  Future<void> _runBuild(
    CatalogFilterEntity filters,
    Emitter<OfflineCatalogState> emit, {
    required bool isResume,
  }) async {
    final token = CancellationToken();
    _activeToken = token;

    emit(state.copyWith(
      phase: OfflineCatalogPhase.downloading,
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
        // The stream only checks cancellation between chunks, so a
        // fraction of a second can elapse between the user tapping
        // Pause / Cancel and the loop actually stopping. During
        // that window we'd otherwise re-emit `downloading` and
        // overwrite the paused / idle state the handler just set,
        // leaving the UI flipped back to a frozen progress bar.
        if (state.phase != OfflineCatalogPhase.downloading &&
            state.phase != OfflineCatalogPhase.installing) {
          continue;
        }
        final targetPhase = _phaseForProgress(progress);
        final now = DateTime.now();
        // Always emit when phase changes (downloading → installing),
        // even mid-throttle window — the user expects to see the
        // bar flip from one phase to the next without waiting.
        if (now.difference(lastEmit) >= _progressEmitInterval ||
            targetPhase != state.phase) {
          lastEmit = now;
          emit(state.copyWith(phase: targetPhase, progress: progress));
        }
      }
      // Final emit so the wizard sees 100% before the phase flips.
      if (lastProgress != null &&
          (state.phase == OfflineCatalogPhase.downloading ||
              state.phase == OfflineCatalogPhase.installing)) {
        emit(state.copyWith(
          phase: _phaseForProgress(lastProgress),
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
      if (lastProgress != null && state.phase == OfflineCatalogPhase.paused) {
        emit(state.copyWith(progress: lastProgress));
      }
    } catch (e, stack) {
      _log.warning('Build failed', e, stack);
      emit(state.copyWith(
        phase: OfflineCatalogPhase.error,
        errorMessage: e.toString(),
        // A schema-version mismatch means the CDN has rolled forward
        // to a major version this app version cannot read. Retrying
        // the same download will hit the same error every time, so
        // the wizard renders the fatal-body copy without a retry
        // button. The user keeps whatever they already have on disk
        // and updates the app to pick up the new format.
        errorRecoverable: e is! CatalogSchemaVersionException,
        progress: lastProgress,
      ));
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  /// Map the data source's progress phase to the bloc's lifecycle
  /// phase. The two are deliberately separate enums — the data
  /// source phase is purely a data-shape signal (which fields on
  /// [DownloadProgress] are meaningful), while the bloc phase
  /// drives the UI's higher-level lifecycle.
  static OfflineCatalogPhase _phaseForProgress(DownloadProgress p) {
    return switch (p.phase) {
      DownloadPhase.downloading => OfflineCatalogPhase.downloading,
      DownloadPhase.installing => OfflineCatalogPhase.installing,
    };
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
