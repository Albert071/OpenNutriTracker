import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';

class GetCatalogStatsUseCase {
  final OfflineCatalogRepository _repository;

  GetCatalogStatsUseCase(this._repository);

  Future<CatalogStatsEntity> call() => _repository.getStats();
}
