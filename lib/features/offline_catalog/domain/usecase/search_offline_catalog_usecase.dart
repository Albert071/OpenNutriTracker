import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';

/// Read-only search facade over the on-device catalog. Constructs
/// [MealEntity] via the same `fromOFFProduct` factory the live API
/// path uses, so a hit here is indistinguishable from a fresh remote
/// hit downstream.
class SearchOfflineCatalogUseCase {
  final OfflineCatalogRepository _repository;

  SearchOfflineCatalogUseCase(this._repository);

  Future<MealEntity?> getByBarcode(String code) async {
    final dto = await _repository.getByCode(code);
    if (dto == null) return null;
    return MealEntity.fromOFFProduct(dto);
  }

  Future<List<MealEntity>> searchByText(String query, {int limit = 50}) async {
    final dtos = await _repository.searchByText(query, limit: limit);
    return [for (final dto in dtos) MealEntity.fromOFFProduct(dto)];
  }
}
