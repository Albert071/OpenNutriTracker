import 'package:equatable/equatable.dart';

/// What page 4 of the wizard shows the user before they tap Download.
///
/// All fields are derived from a single `page_size=1` probe against
/// the OFF search API with the user's exact filter set, so the row
/// count matches what the loader will actually fetch.
class CatalogEstimateEntity extends Equatable {
  /// Total products matching the user's filters server-side.
  final int rows;

  /// Approximate bytes the on-device sqlite file will occupy
  /// (rows × ~1 KB each, including FTS index overhead).
  final int estimatedBytes;

  /// Number of paged search requests that will be fired
  /// (`(rows / pageSize).ceil()`).
  final int requests;

  /// Wall-clock seconds at the configured throttle (~1 req/sec).
  final int etaSeconds;

  const CatalogEstimateEntity({
    required this.rows,
    required this.estimatedBytes,
    required this.requests,
    required this.etaSeconds,
  });

  /// Footgun threshold. Above this, page 4 requires typed confirmation.
  static const int hardCapRows = 1000000;

  bool get isAboveHardCap => rows > hardCapRows;

  @override
  List<Object?> get props => [rows, estimatedBytes, requests, etaSeconds];
}
