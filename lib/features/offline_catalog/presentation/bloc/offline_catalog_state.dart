part of 'offline_catalog_bloc.dart';

/// Phase of the catalog lifecycle. Drives which subset of the
/// [OfflineCatalogState] payload fields are meaningful at any given
/// moment. The wizard pages key off this enum to decide what to show.
enum OfflineCatalogPhase {
  initial,
  idle,
  estimating,
  estimated,
  downloading,
  installing,
  paused,
  ready,
  error,
}

/// Single mutable-by-copyWith state class for the offline-catalog
/// wizard. Subclasses-per-phase would carry too much boilerplate for
/// the surface area here — the wizard's pages need a stable view onto
/// recent payloads (estimate, progress) even while the phase
/// progresses, and a single class with nullable fields is the
/// simplest way to express that.
class OfflineCatalogState extends Equatable {
  final OfflineCatalogPhase phase;
  final CatalogStatsEntity? stats;
  final CatalogEstimateEntity? estimate;
  final DownloadProgress? progress;
  final CatalogFilterEntity? activeFilters;
  final String? errorMessage;
  final bool errorRecoverable;

  const OfflineCatalogState({
    required this.phase,
    this.stats,
    this.estimate,
    this.progress,
    this.activeFilters,
    this.errorMessage,
    this.errorRecoverable = true,
  });

  static const initial = OfflineCatalogState(phase: OfflineCatalogPhase.initial);

  OfflineCatalogState copyWith({
    OfflineCatalogPhase? phase,
    CatalogStatsEntity? stats,
    CatalogEstimateEntity? estimate,
    DownloadProgress? progress,
    CatalogFilterEntity? activeFilters,
    String? errorMessage,
    bool? errorRecoverable,
    bool clearEstimate = false,
    bool clearProgress = false,
    bool clearError = false,
  }) =>
      OfflineCatalogState(
        phase: phase ?? this.phase,
        stats: stats ?? this.stats,
        estimate: clearEstimate ? null : (estimate ?? this.estimate),
        progress: clearProgress ? null : (progress ?? this.progress),
        activeFilters: activeFilters ?? this.activeFilters,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        errorRecoverable: errorRecoverable ?? this.errorRecoverable,
      );

  @override
  List<Object?> get props => [
        phase,
        stats,
        estimate,
        progress,
        activeFilters,
        errorMessage,
        errorRecoverable,
      ];
}
