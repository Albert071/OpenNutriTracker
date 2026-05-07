part of 'offline_catalog_bloc.dart';

abstract class OfflineCatalogEvent extends Equatable {
  const OfflineCatalogEvent();

  @override
  List<Object?> get props => [];
}

/// Read the current catalog state from disk and emit the right
/// lifecycle phase: [OfflineCatalogPhase.idle] for a brand-new user,
/// [OfflineCatalogPhase.paused] when a partial download is sitting on
/// disk, [OfflineCatalogPhase.ready] when the catalog is installed.
class LoadCatalogStatusEvent extends OfflineCatalogEvent {
  const LoadCatalogStatusEvent();
}

/// Compute a static estimate for [filters] so the wizard's
/// confirmation page can show download size, on-disk size, and ETA
/// before the user kicks off the build.
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

/// Pause an in-flight download. The partial gzip + sidecar stay on
/// disk so resume picks up where we left off.
class PauseCatalogBuildEvent extends OfflineCatalogEvent {
  const PauseCatalogBuildEvent();
}

/// Resume a previously paused download (or one interrupted by app
/// kill). Filters are recovered from the on-disk sidecar.
class ResumeCatalogBuildEvent extends OfflineCatalogEvent {
  const ResumeCatalogBuildEvent();
}

/// Hard cancel: stop the loop AND wipe the partial gzip + sidecar so
/// the next build starts fresh.
class CancelCatalogBuildEvent extends OfflineCatalogEvent {
  const CancelCatalogBuildEvent();
}

/// Re-download the currently-persisted variant. Triggered from the
/// settings-tile Refresh action; same progress UI as a first build.
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
