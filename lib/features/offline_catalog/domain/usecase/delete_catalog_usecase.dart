import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';

class DeleteCatalogUseCase {
  final OfflineCatalogRepository _repository;
  final ConfigRepository _configRepository;

  DeleteCatalogUseCase(this._repository, this._configRepository);

  /// Drops the on-device catalog file and clears the
  /// `offlineCatalogEnabled` flag so the search/scanner integration
  /// stops consulting the (now empty) catalog. The user can rebuild
  /// from settings whenever they want.
  Future<void> call() async {
    await _repository.delete();
    await _configRepository.setOfflineCatalogEnabled(false);
  }
}
