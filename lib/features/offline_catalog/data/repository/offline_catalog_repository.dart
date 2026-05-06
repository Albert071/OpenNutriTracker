import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_bulk_api_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_csv_dump_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';

/// Conservative typical-row count we expect to keep on disk for a
/// single-country build with default filters. Used to build the
/// wizard's "approximately X products" line on the estimate page.
/// Real builds vary widely; this is a friendly order-of-magnitude.
const int _kRoughKeptRowsForSingleCountry = 18000;

/// Average bytes-per-row in the on-disk sqlite catalogue (JSON blob
/// + denormalised name/brand cells + FTS index overhead).
const int _kBytesPerRow = 1024;

/// Orchestrates the catalog lifecycle.
///
/// **Build path** (the heavy one): downloads the OFF CSV dump from
/// `static.openfoodfacts.org` to a local cache, then stream-decodes
/// + filters + writes survivors to sqlite. The CDN endpoint is
/// reliable (unlike the legacy `cgi/search.pl` which 503s under bulk
/// traffic), so a build either runs to completion or stops cleanly
/// at a known byte offset for resume.
///
/// **Refresh path** (the lightweight one): keeps the existing API
/// paginator in place. A few hundred modified-since-last-sync rows
/// are well within the legacy CGI's healthy band.
///
/// **Pause / cancel semantics**:
/// * Pause during download → partial gzip stays on disk, resume
///   sends `Range: bytes=<offset>-` and continues from there.
/// * Pause during parse → gzip stays, resume re-streams from the
///   start; sqlite upserts are idempotent so no data is lost, just
///   parse time is.
/// * Cancel any phase → cached gzip is deleted, sqlite is wiped.
class OfflineCatalogRepository {
  final _log = Logger('OfflineCatalogRepository');
  final OfflineCatalogDataSource _local;
  final OffBulkApiDataSource _remote;
  final OffCsvDumpDataSource _csvDump;

  OfflineCatalogRepository(this._local, this._remote, this._csvDump);

  /// One-shot HEAD probe of the CSV dump. Returns size + a rough
  /// kept-rows projection for the wizard's confirmation page.
  ///
  /// We can't know the exact row count up-front (we'd have to stream
  /// the file to count), so the wizard surfaces both the precise
  /// download-size figure and an honest "approximately X products"
  /// for the post-filter result.
  Future<CatalogEstimateEntity> estimate(CatalogFilterEntity filters) async {
    final dumpBytes = await _csvDump.headTotalBytes();
    if (dumpBytes == null) {
      throw const FormatException(
        'Open Food Facts did not advertise a download size for the CSV.',
      );
    }
    // Rough on-disk catalogue size. Linear with how many countries
    // the user picked. Anything below 1 we still surface as "1
    // country worth" so the number doesn't read as zero.
    final countryFactor = filters.countries.isEmpty
        ? 1.0
        : filters.countries.length.toDouble();
    final keptRows = (_kRoughKeptRowsForSingleCountry * countryFactor).round();
    return CatalogEstimateEntity(
      rows: keptRows,
      // Storage estimate uses the post-filter row count.
      estimatedBytes: keptRows * _kBytesPerRow,
      // "Requests" is repurposed as "download bytes" for the CSV
      // path; the wizard's UI label can call it that. (We could add
      // a separate field on the entity, but reusing avoids a
      // disruptive refactor for one number.)
      requests: dumpBytes,
      // Wall-clock seconds — depends on user's bandwidth, very
      // rough. Assume 10 MB/s effective; that's a fast Wi-Fi link.
      // Real-world will skew higher.
      etaSeconds: (dumpBytes / (10 * 1024 * 1024)).round(),
    );
  }

  /// Run a fresh build (or resume an interrupted one) for [filters].
  ///
  /// Phase 1 — download. Yields [DownloadProgress] with
  /// `phase = downloading` and bytes counters. Cancellation between
  /// chunks. Resume picks up at the on-disk file's existing length.
  ///
  /// Phase 2 — parse + filter. Yields [DownloadProgress] with
  /// `phase = parsing` and rows-kept counter. Cancellation checked
  /// every ~200 rows.
  /// CSV dumps are republished by OFF roughly daily. A cached gzip
  /// younger than this window is reused as-is when the user runs
  /// the wizard again — we skip the re-download and go straight to
  /// the parse phase, since the data on disk is fresh enough.
  static const _cachedDumpFreshness = Duration(hours: 24);

  Stream<DownloadProgress> build({
    required CatalogFilterEntity filters,
    required CancellationToken cancellation,
  }) async* {
    final filtersJson = _serialiseFilters(filters);
    final filtersHash = _hashFilters(filtersJson);
    final stopwatch = Stopwatch()..start();

    // The build's start time stamps every row that survives the
    // parse via [OfflineCatalogDataSource.upsertBatch]'s `fetched_at`
    // write. After the parse completes we drop any row whose
    // `fetched_at` predates this — those are leftover from a prior
    // build that the new filter set (or new dump contents) would
    // not have kept. This handles two distinct user flows:
    //
    //   1. Refresh — same filters, fresher OFF dump. Stale entries
    //      that have been removed from OFF or no longer pass the
    //      always-on filters get swept.
    //   2. Filter change — different countries, toggles, recency.
    //      Rows that match the old filters but not the new ones
    //      get swept, while rows that match both are simply
    //      re-stamped (kept).
    final buildStartedAtMillis = DateTime.now().millisecondsSinceEpoch;

    // Persist the filter set so the resume / refresh paths can find
    // what the catalog was built for.
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyFiltersJson,
      filtersJson,
    );
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyBuildCursor,
      jsonEncode({'phase': 'downloading', 'filtersHash': filtersHash}),
    );

    // Skip the download phase entirely when a fresh-enough gzip is
    // already on disk. The user's wizard run still gets the most
    // recent OFF data they have access to without paying for a
    // second 1+ GB transfer.
    final cacheIsFresh = await _isCachedDumpFresh();
    if (cacheIsFresh) {
      _log.info('Catalog build phase 1: skipped (cached dump is fresh)');
      // Emit a single 100% progress event so the UI doesn't sit on
      // 0% for the duration of the (skipped) download phase.
      final cachedSize = await _csvDump.downloadedBytes();
      yield DownloadProgress(
        phase: DownloadPhase.downloading,
        bytesDone: cachedSize,
        bytesTotal: cachedSize,
        rowsKept: 0,
        rowsScanned: 0,
        elapsed: stopwatch.elapsed,
      );
    } else {
      _log.info('Catalog build phase 1: download');
      await for (final p in _csvDump.downloadResumable(
        cancellation: cancellation,
      )) {
        yield DownloadProgress(
          phase: DownloadPhase.downloading,
          bytesDone: p.bytesDone,
          bytesTotal: p.bytesTotal,
          rowsKept: 0,
          rowsScanned: 0,
          elapsed: stopwatch.elapsed,
        );
      }
    }
    cancellation.throwIfCancelled();

    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyBuildCursor,
      jsonEncode({'phase': 'parsing', 'filtersHash': filtersHash}),
    );

    _log.info('Catalog build phase 2: parse + filter');
    await for (final p in _csvDump.parseAndFilter(
      filter: filters,
      cancellation: cancellation,
      onBatch: (batch) async => _local.upsertBatch(batch),
    )) {
      yield DownloadProgress(
        phase: DownloadPhase.parsing,
        bytesDone: p.bytesDone,
        bytesTotal: p.bytesTotal,
        rowsKept: p.rowsKept,
        rowsScanned: p.rowsScanned,
        elapsed: stopwatch.elapsed,
      );
    }
    cancellation.throwIfCancelled();

    // Phase 3 — sweep stale rows from any prior build, then clean
    // up the cached gzip. Order matters: the sweep happens before
    // the cursor is cleared so an interruption between the two
    // still leaves the catalogue in a consistent state.
    final sweptCount = await _local.deleteStaleRows(buildStartedAtMillis);
    if (sweptCount > 0) {
      _log.info('Swept $sweptCount stale rows from prior build');
    }
    await _csvDump.deleteCachedFile();
    final stored = await _local.count();
    await _local.setMeta(OfflineCatalogDataSource.metaKeyBuildCursor, null);
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyLastFullSync,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyTotalCount,
      stored.toString(),
    );
    _log.info('Catalog build complete: $stored rows on disk');
  }

  Future<bool> _isCachedDumpFresh() async {
    if (!await _csvDump.hasLocalFile()) return false;
    final file = await _csvDump.resolveLocalFile();
    final mtime = await file.lastModified();
    final age = DateTime.now().difference(mtime);
    if (age > _cachedDumpFreshness) return false;
    // Sanity check: the file must be the FULL dump (not a partial
    // download from an interrupted session). HEAD the URL and
    // compare lengths. If the HEAD fails we err on the side of
    // re-downloading rather than reusing potentially-incomplete
    // data.
    final localBytes = await file.length();
    final remoteBytes = await _csvDump.headTotalBytes();
    if (remoteBytes == null) return false;
    return localBytes >= remoteBytes;
  }

  /// Incremental refresh against the same filter set last used.
  /// Uses the API paginator (small queries are still healthy on the
  /// legacy CGI). Does not currently delete rows OFF has marked
  /// obsolete — that would require a second pass we'll add when
  /// there's evidence the catalogue drifts.
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
    var rowsScanned = 0;
    var rowsKept = 0;

    for (var page = 1; page <= totalPages; page++) {
      cancellation.throwIfCancelled();
      final fetched = await _remote.fetchPage(
        filters: refreshFilters,
        pageNumber: page,
        pageSize: pageSize,
      );
      await _local.upsertBatch(fetched.products);
      rowsScanned += pageSize;
      rowsKept += fetched.products.length;
      yield DownloadProgress(
        // Refresh is fast and small — we report it as a "parsing"
        // phase so the UI uses the rows-progress view rather than
        // the bytes-progress view.
        phase: DownloadPhase.parsing,
        bytesDone: rowsScanned,
        bytesTotal: totalRows,
        rowsKept: rowsKept,
        rowsScanned: rowsScanned,
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

  Future<CatalogFilterEntity?> getPersistedFilters() async {
    final filtersJson =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyFiltersJson);
    if (filtersJson == null) return null;
    return _deserialiseFilters(filtersJson);
  }

  Future<OFFProductDTO?> getByCode(String code) => _local.getByCode(code);

  Future<List<OFFProductDTO>> searchByText(String query, {int limit = 50}) =>
      _local.searchByText(query, limit: limit);

  /// Drop the catalog AND any cached CSV download.
  Future<void> delete() async {
    await _local.clear();
    await _csvDump.deleteCachedFile();
  }

  /// True when there's a paused build to resume — either a partial
  /// CSV download on disk, or a build_cursor recording phase=parsing.
  Future<bool> hasResumeableBuild() async {
    final cursor =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyBuildCursor);
    return cursor != null;
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

  String _hashFilters(String json) => json.hashCode.toRadixString(16);
}
