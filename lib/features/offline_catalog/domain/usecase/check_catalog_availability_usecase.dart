import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';

/// Probes whether the catalog CDN is reachable. Returns `true` when a
/// HEAD against the recommended default variant's manifest succeeds
/// inside the data source's timeout, `false` otherwise.
///
/// The wizard and the settings tile call this before unlocking the
/// download flow so a user with no connection (or an outage on our
/// side) sees a clear "try again later" message instead of marching
/// into a wizard that will fail at its first network hop.
class CheckCatalogAvailabilityUseCase {
  final OfflineCatalogRepository _repository;

  CheckCatalogAvailabilityUseCase(this._repository);

  Future<bool> call() => _repository.probeAvailability();
}
