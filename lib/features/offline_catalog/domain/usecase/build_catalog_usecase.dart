import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';

class BuildCatalogUseCase {
  final OfflineCatalogRepository _repository;

  BuildCatalogUseCase(this._repository);

  /// Streams progress for either a fresh build (no resume cursor) or a
  /// resume of a previously paused build whose filter set matches.
  Stream<DownloadProgress> call({
    required CatalogFilterEntity filters,
    required CancellationToken cancellation,
  }) =>
      _repository.build(filters: filters, cancellation: cancellation);

  Future<bool> hasResumeableBuild() => _repository.hasResumeableBuild();

  Future<CatalogFilterEntity?> getPersistedFilters() =>
      _repository.getPersistedFilters();
}
