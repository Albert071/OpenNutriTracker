import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_bulk_api_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';

/// Persisted resume state. Lives under
/// [OfflineCatalogDataSource.metaKeyBuildCursor] so a paused build can
/// be picked up after the app is killed or backgrounded for too long.
class _BuildCursor {
  final int nextPage;
  final int totalRows;
  final String filtersHash;

  const _BuildCursor({
    required this.nextPage,
    required this.totalRows,
    required this.filtersHash,
  });

  Map<String, dynamic> toJson() => {
        'nextPage': nextPage,
        'totalRows': totalRows,
        'filtersHash': filtersHash,
      };

  static _BuildCursor? tryParse(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      return _BuildCursor(
        nextPage: map['nextPage'] as int,
        totalRows: map['totalRows'] as int,
        filtersHash: map['filtersHash'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Per-row average size estimate used by the wizard's confirmation
/// page. The number is conservative; real on-disk size after FTS index
/// overhead is typically within ±30% of this.
const int _kBytesPerRow = 1024;

/// Orchestrates the catalog lifecycle: estimate, build, refresh,
/// stats, delete. Lives between the bloc and the two data sources;
/// holds the [BulkSearchPage] → sqlite write loop.
class OfflineCatalogRepository {
  final _log = Logger('OfflineCatalogRepository');
  final OfflineCatalogDataSource _local;
  final OffBulkApiDataSource _remote;

  OfflineCatalogRepository(this._local, this._remote);

  /// One-shot probe of the OFF search envelope. Returns the count and
  /// derived size/time estimates the wizard surfaces on page 4.
  Future<CatalogEstimateEntity> estimate(CatalogFilterEntity filters) async {
    final rows = await _remote.estimateCount(filters);
    final pageSize = OffBulkApiDataSource.defaultPageSize;
    final requests = (rows / pageSize).ceil();
    final etaSeconds = requests * OffBulkApiDataSource.defaultThrottle.inSeconds;
    return CatalogEstimateEntity(
      rows: rows,
      estimatedBytes: rows * _kBytesPerRow,
      requests: requests,
      etaSeconds: etaSeconds,
    );
  }

  /// Run the full build (or resume an interrupted one) for [filters].
  /// Emits one [DownloadProgress] per page. Cooperative cancellation
  /// is checked between pages — the loop never abandons a page
  /// mid-flight, so a cancel never leaves the catalog in an
  /// inconsistent state.
  ///
  /// On success, clears the build cursor and updates
  /// [OfflineCatalogDataSource.metaKeyLastFullSync] +
  /// [OfflineCatalogDataSource.metaKeyTotalCount]. On cancel, the
  /// cursor is preserved so a resume picks up where we left off.
  Stream<DownloadProgress> build({
    required CatalogFilterEntity filters,
    required CancellationToken cancellation,
  }) async* {
    final filtersJson = _serialiseFilters(filters);
    final filtersHash = _hashFilters(filtersJson);

    // Resume state: only honour an existing cursor when the filter
    // hash matches. A different filter set means the user changed
    // their mind and we should start fresh.
    final existing =
        _BuildCursor.tryParse(await _local.getMeta(OfflineCatalogDataSource.metaKeyBuildCursor));
    var startPage = 1;
    var totalRows = 0;
    if (existing != null && existing.filtersHash == filtersHash) {
      startPage = existing.nextPage;
      totalRows = existing.totalRows;
      _log.info(
        'Resuming catalog build at page $startPage of '
        '${(totalRows / OffBulkApiDataSource.defaultPageSize).ceil()}',
      );
    } else {
      // Fresh build. Hit the estimate endpoint to anchor totalRows
      // (so progress reporting has a denominator from page 1).
      totalRows = await _remote.estimateCount(filters);
      await _local.setMeta(
        OfflineCatalogDataSource.metaKeyFiltersJson,
        filtersJson,
      );
      _log.info('Starting fresh catalog build of $totalRows rows');
    }

    final pageSize = OffBulkApiDataSource.defaultPageSize;
    final totalPages = (totalRows / pageSize).ceil();
    final stopwatch = Stopwatch()..start();
    var rowsDownloaded = (startPage - 1) * pageSize;
    if (rowsDownloaded > totalRows) rowsDownloaded = totalRows;

    for (var page = startPage; page <= totalPages; page++) {
      cancellation.throwIfCancelled();

      final fetched = await _remote.fetchPage(
        filters: filters,
        pageNumber: page,
        pageSize: pageSize,
      );

      // Atomic: write rows AND advance the cursor in one transaction.
      // A crash mid-write leaves the catalog consistent at "we did
      // pages 1..page-1, resume at page" rather than "we wrote rows
      // but lost the cursor".
      final cursor = _BuildCursor(
        nextPage: page + 1,
        totalRows: totalRows,
        filtersHash: filtersHash,
      );
      await _local.upsertBatch(
        fetched.products,
        metaUpdates: {
          OfflineCatalogDataSource.metaKeyBuildCursor:
              jsonEncode(cursor.toJson()),
        },
      );
      rowsDownloaded += fetched.products.length;
      if (rowsDownloaded > totalRows) rowsDownloaded = totalRows;

      yield DownloadProgress(
        rowsDownloaded: rowsDownloaded,
        totalRows: totalRows,
        currentPage: page,
        totalPages: totalPages,
        elapsed: stopwatch.elapsed,
      );

      if (fetched.isLast) break;
    }

    // Clean up the cursor and stamp completion metadata. The catalog
    // is now ready for the search/scanner integration to start hitting
    // it; the bloc flips OfflineCatalogReady afterwards.
    await _local.setMeta(OfflineCatalogDataSource.metaKeyBuildCursor, null);
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyLastFullSync,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyTotalCount,
      rowsDownloaded.toString(),
    );
  }

  /// Incremental refresh against the same filter set last used. Pulls
  /// only rows where `last_modified_t` is newer than the previous
  /// full-sync timestamp; upserts them. Does not currently delete rows
  /// OFF has marked obsolete — that would require a second pass over
  /// the obsolete-only filter, which we'll add when there's evidence
  /// the catalog drifts noticeably without it.
  Stream<DownloadProgress> refresh({
    required CancellationToken cancellation,
  }) async* {
    final filtersJson =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyFiltersJson);
    final lastSyncRaw =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyLastFullSync);
    if (filtersJson == null || lastSyncRaw == null) {
      throw StateError('Cannot refresh: catalog has not been built');
    }
    final lastSyncMillis = int.parse(lastSyncRaw);
    final originalFilters = _deserialiseFilters(filtersJson);
    final lastSyncSeconds = lastSyncMillis ~/ 1000;
    final refreshFilters = originalFilters.copyWith(
      // Override the user's recency window with "since last sync" —
      // the user's preference still drives the catalog's overall
      // shape, but the refresh is always anchored to what they
      // already have on disk.
      maxAge: Duration(
        seconds: DateTime.now().millisecondsSinceEpoch ~/ 1000 - lastSyncSeconds,
      ),
    );

    final pageSize = OffBulkApiDataSource.defaultPageSize;
    final totalRows = await _remote.estimateCount(refreshFilters);
    if (totalRows == 0) {
      _log.info('Refresh found no new or modified rows');
      await _local.setMeta(
        OfflineCatalogDataSource.metaKeyLastFullSync,
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      return;
    }

    final totalPages = (totalRows / pageSize).ceil();
    final stopwatch = Stopwatch()..start();
    var rowsDownloaded = 0;

    for (var page = 1; page <= totalPages; page++) {
      cancellation.throwIfCancelled();
      final fetched = await _remote.fetchPage(
        filters: refreshFilters,
        pageNumber: page,
        pageSize: pageSize,
      );
      await _local.upsertBatch(fetched.products);
      rowsDownloaded += fetched.products.length;
      yield DownloadProgress(
        rowsDownloaded: rowsDownloaded,
        totalRows: totalRows,
        currentPage: page,
        totalPages: totalPages,
        elapsed: stopwatch.elapsed,
      );
      if (fetched.isLast) break;
    }

    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyLastFullSync,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final newTotal = await _local.count();
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyTotalCount,
      newTotal.toString(),
    );
  }

  /// Snapshot for the settings tile and wizard's idle/done pages.
  Future<CatalogStatsEntity> getStats() async {
    final productCount = await _local.count();
    if (productCount == 0) return CatalogStatsEntity.empty;
    final sizeBytes = await _local.sizeBytes();
    final lastSyncRaw =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyLastFullSync);
    final lastSync = lastSyncRaw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(lastSyncRaw));
    final filtersJson =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyFiltersJson);
    return CatalogStatsEntity(
      productCount: productCount,
      sizeBytes: sizeBytes,
      lastSyncTime: lastSync,
      filtersJson: filtersJson,
    );
  }

  /// Read the persisted filter set, if any. Returns null when the
  /// catalog has never been built.
  Future<CatalogFilterEntity?> getPersistedFilters() async {
    final filtersJson =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyFiltersJson);
    if (filtersJson == null) return null;
    return _deserialiseFilters(filtersJson);
  }

  /// Read-through to the local data source. Consumers are
  /// `SearchOfflineCatalogUseCase` and friends.
  Future<OFFProductDTO?> getByCode(String code) => _local.getByCode(code);

  Future<List<OFFProductDTO>> searchByText(String query, {int limit = 50}) =>
      _local.searchByText(query, limit: limit);

  Future<void> delete() async {
    await _local.clear();
  }

  /// True when an in-flight build cursor is sitting on disk (the user
  /// paused, or the app crashed mid-build, etc).
  Future<bool> hasResumeableBuild() async {
    final raw =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyBuildCursor);
    return _BuildCursor.tryParse(raw) != null;
  }

  String _serialiseFilters(CatalogFilterEntity filters) {
    return jsonEncode({
      'countries': filters.countries.toList()..sort(),
      'requireNutritionGrade': filters.requireNutritionGrade,
      'requireMinPopularity': filters.requireMinPopularity,
      'maxAgeSeconds': filters.maxAge?.inSeconds,
    });
  }

  CatalogFilterEntity _deserialiseFilters(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final countries = (map['countries'] as List<dynamic>).cast<String>();
    final maxAgeSecondsRaw = map['maxAgeSeconds'];
    return CatalogFilterEntity(
      countries: countries.toSet(),
      requireNutritionGrade:
          (map['requireNutritionGrade'] as bool?) ?? true,
      requireMinPopularity: (map['requireMinPopularity'] as bool?) ?? true,
      maxAge: maxAgeSecondsRaw is int
          ? Duration(seconds: maxAgeSecondsRaw)
          : null,
    );
  }

  /// Stable hash so we can detect filter changes between resume
  /// attempts. Hash content is the serialised filter JSON, which
  /// already canonicalises (sorted countries, fixed key order).
  String _hashFilters(String json) => json.hashCode.toRadixString(16);
}
