import 'package:opennutritracker/features/offline_catalog/data/repository/offline_catalog_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';

class RefreshCatalogUseCase {
  final OfflineCatalogRepository _repository;

  RefreshCatalogUseCase(this._repository);

  /// Pulls only rows modified since the last full sync, using the
  /// originally-chosen filter set. See [OfflineCatalogRepository.refresh]
  /// for the limitation around obsolete-row deletion.
  Stream<DownloadProgress> call({
    required CancellationToken cancellation,
  }) =>
      _repository.refresh(cancellation: cancellation);
}
