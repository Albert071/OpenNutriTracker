import 'package:equatable/equatable.dart';

/// Snapshot of the on-device catalog state, surfaced on the settings
/// tile and the wizard's idle/done pages. `productCount == 0` means the
/// catalog has not been built yet (or has just been deleted); the tile
/// reflects that with a "Not built" subtitle.
class CatalogStatsEntity extends Equatable {
  final int productCount;
  final int sizeBytes;
  final DateTime? lastSyncTime;

  /// Serialised JSON of the [CatalogFilterEntity] last used to build
  /// or refresh the catalog. Stored so the wizard can detect filter
  /// changes mid-life and prompt "Replace existing catalog" vs
  /// "Add to it" before kicking off a fresh build.
  final String? filtersJson;

  const CatalogStatsEntity({
    required this.productCount,
    required this.sizeBytes,
    required this.lastSyncTime,
    required this.filtersJson,
  });

  static const empty = CatalogStatsEntity(
    productCount: 0,
    sizeBytes: 0,
    lastSyncTime: null,
    filtersJson: null,
  );

  bool get isPopulated => productCount > 0;

  @override
  List<Object?> get props => [productCount, sizeBytes, lastSyncTime, filtersJson];
}
