part of 'offline_catalog_bloc.dart';

abstract class OfflineCatalogEvent extends Equatable {
  const OfflineCatalogEvent();

  @override
  List<Object?> get props => [];
}

/// Read the current catalog state from disk and emit either
/// [OfflineCatalogPhase.idle] (no catalog or partial cursor) or
/// [OfflineCatalogPhase.ready] / [OfflineCatalogPhase.paused].
class LoadCatalogStatusEvent extends OfflineCatalogEvent {
  const LoadCatalogStatusEvent();
}

/// Fetch the OFF country taxonomy for [locale] and store it on the
/// state for the wizard's region page.
class LoadCountriesEvent extends OfflineCatalogEvent {
  final String? locale;
  final bool forceRefresh;

  const LoadCountriesEvent({this.locale, this.forceRefresh = false});

  @override
  List<Object?> get props => [locale, forceRefresh];
}

/// Probe `count` for [filters] so the wizard's confirmation page can
/// show an honest size + ETA before the user kicks off the build.
class EstimateCatalogEvent extends OfflineCatalogEvent {
  final CatalogFilterEntity filters;

  const EstimateCatalogEvent(this.filters);

  @override
  List<Object?> get props => [filters];
}

class StartCatalogBuildEvent extends OfflineCatalogEvent {
  final CatalogFilterEntity filters;

  const StartCatalogBuildEvent(this.filters);

  @override
  List<Object?> get props => [filters];
}

/// Pause an in-flight build. The cursor stays on disk so resume picks
/// up where we left off.
class PauseCatalogBuildEvent extends OfflineCatalogEvent {
  const PauseCatalogBuildEvent();
}

/// Resume a previously paused build (or one interrupted by app kill).
class ResumeCatalogBuildEvent extends OfflineCatalogEvent {
  const ResumeCatalogBuildEvent();
}

/// Hard cancel: stop the loop AND wipe the partial catalog so the
/// next build starts fresh.
class CancelCatalogBuildEvent extends OfflineCatalogEvent {
  const CancelCatalogBuildEvent();
}

/// Manual incremental refresh from the settings tile.
class RefreshCatalogEvent extends OfflineCatalogEvent {
  const RefreshCatalogEvent();
}

class DeleteCatalogEvent extends OfflineCatalogEvent {
  const DeleteCatalogEvent();
}

/// Toggle whether the search/scanner integration consults the catalog.
class ToggleCatalogEnabledEvent extends OfflineCatalogEvent {
  final bool enabled;

  const ToggleCatalogEnabledEvent(this.enabled);

  @override
  List<Object?> get props => [enabled];
}
