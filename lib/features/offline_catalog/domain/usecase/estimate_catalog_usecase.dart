import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';

class EstimateCatalogUseCase {
  final OfflineCatalogRepository _repository;

  EstimateCatalogUseCase(this._repository);

  Future<CatalogEstimateEntity> call(CatalogFilterEntity filters) =>
      _repository.estimate(filters);
}
