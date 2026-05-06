part of 'offline_catalog_bloc.dart';

/// Phase of the catalog lifecycle. Drives which subset of the
/// [OfflineCatalogState] payload fields are meaningful at any given
/// moment. The wizard pages key off this enum to decide what to show.
enum OfflineCatalogPhase {
  initial,
  idle,
  loadingCountries,
  countriesLoaded,
  estimating,
  estimated,
  building,
  paused,
  refreshing,
  ready,
  error,
}

/// Single mutable-by-copyWith state class for the offline-catalog
/// wizard. Subclasses-per-phase would carry too much boilerplate for
/// the surface area here — the wizard's pages need a stable view onto
/// recent payloads (taxonomy, estimate, progress) even while the
/// phase progresses, and a single class with nullable fields is the
/// simplest way to express that.
class OfflineCatalogState extends Equatable {
  final OfflineCatalogPhase phase;
  final CatalogStatsEntity? stats;
  final List<CountryTaxonomyEntry>? countries;
  final CatalogEstimateEntity? estimate;
  final DownloadProgress? progress;
  final CatalogFilterEntity? activeFilters;
  final String? errorMessage;
  final bool errorRecoverable;

  /// True when [countries] is the static fallback list rather than a
  /// live taxonomy fetch. The wizard surfaces a non-blocking notice
  /// when this is the case.
  final bool countriesFromFallback;

  const OfflineCatalogState({
    required this.phase,
    this.stats,
    this.countries,
    this.estimate,
    this.progress,
    this.activeFilters,
    this.errorMessage,
    this.errorRecoverable = true,
    this.countriesFromFallback = false,
  });

  static const initial = OfflineCatalogState(phase: OfflineCatalogPhase.initial);

  OfflineCatalogState copyWith({
    OfflineCatalogPhase? phase,
    CatalogStatsEntity? stats,
    List<CountryTaxonomyEntry>? countries,
    CatalogEstimateEntity? estimate,
    DownloadProgress? progress,
    CatalogFilterEntity? activeFilters,
    String? errorMessage,
    bool? errorRecoverable,
    bool? countriesFromFallback,
    bool clearEstimate = false,
    bool clearProgress = false,
    bool clearError = false,
  }) =>
      OfflineCatalogState(
        phase: phase ?? this.phase,
        stats: stats ?? this.stats,
        countries: countries ?? this.countries,
        estimate: clearEstimate ? null : (estimate ?? this.estimate),
        progress: clearProgress ? null : (progress ?? this.progress),
        activeFilters: activeFilters ?? this.activeFilters,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        errorRecoverable: errorRecoverable ?? this.errorRecoverable,
        countriesFromFallback:
            countriesFromFallback ?? this.countriesFromFallback,
      );

  @override
  List<Object?> get props => [
        phase,
        stats,
        countries,
        estimate,
        progress,
        activeFilters,
        errorMessage,
        errorRecoverable,
        countriesFromFallback,
      ];
}
