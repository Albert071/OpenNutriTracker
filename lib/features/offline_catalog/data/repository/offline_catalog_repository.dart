import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/catalog_download_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';

/// Approximate effective bandwidth for an ETA projection on the
/// estimate page. Real-world transfers can be much faster (fibre,
/// fast Wi-Fi) or much slower (mobile data); 10 MB/s is a midpoint
/// that lands the prediction within the right order of magnitude.
const int _kAssumedBytesPerSecond = 10 * 1024 * 1024;

/// Static row/byte projections per catalog variant id, derived from a
/// real end-to-end build run. These drive the wizard's estimate page
/// without needing a live HEAD probe per filter combination.
///
/// Sourced from the build output:
/// * `s0_n0_*` family — 2.8M–3.2M rows, ~470–520 MB compressed
/// * `s0_n1_*` family — 1.16M–1.37M rows, ~210–240 MB compressed
/// * `s1_n0_*` family — 505k–518k rows, ~99–105 MB compressed
/// * `s1_n1_*` family — 349k–354k rows, ~73 MB compressed
///
/// The compressed-to-uncompressed ratio sits at roughly 7.4x
/// (537 MB unpacked / 73 MB gzipped on the smallest variant), and
/// applies consistently across the family — the row contents are the
/// same shape, only the row count varies.
final Map<String, _VariantSizing> _kVariantSizing = {
  's0_n0_r3': _VariantSizing(2800000, 470 * _mb, 3450 * _mb),
  's0_n0_r5': _VariantSizing(2950000, 490 * _mb, 3600 * _mb),
  's0_n0_r10': _VariantSizing(3050000, 505 * _mb, 3700 * _mb),
  's0_n0_rany': _VariantSizing(3200000, 520 * _mb, 3820 * _mb),
  's0_n1_r3': _VariantSizing(1160000, 210 * _mb, 1550 * _mb),
  's0_n1_r5': _VariantSizing(1230000, 220 * _mb, 1620 * _mb),
  's0_n1_r10': _VariantSizing(1300000, 230 * _mb, 1690 * _mb),
  's0_n1_rany': _VariantSizing(1370000, 240 * _mb, 1760 * _mb),
  's1_n0_r3': _VariantSizing(505000, 99 * _mb, 730 * _mb),
  's1_n0_r5': _VariantSizing(509000, 101 * _mb, 745 * _mb),
  's1_n0_r10': _VariantSizing(514000, 103 * _mb, 760 * _mb),
  's1_n0_rany': _VariantSizing(518000, 105 * _mb, 775 * _mb),
  's1_n1_r3': _VariantSizing(349000, 73 * _mb, 537 * _mb),
  's1_n1_r5': _VariantSizing(351000, 73 * _mb, 537 * _mb),
  's1_n1_r10': _VariantSizing(353000, 73 * _mb, 537 * _mb),
  's1_n1_rany': _VariantSizing(354000, 73 * _mb, 537 * _mb),
};

const int _mb = 1024 * 1024;

class _VariantSizing {
  final int rows;
  final int compressedBytes;
  final int uncompressedBytes;

  const _VariantSizing(
    this.rows,
    this.compressedBytes,
    this.uncompressedBytes,
  );
}

/// Orchestrates the prebuilt-catalog lifecycle.
///
/// The pivot to download-prebuilt collapsed the old CSV parse loop
/// into two short phases: download the gzipped sqlite for the chosen
/// variant, then unpack it and rename it into place. The repository
/// owns the static estimate table, the meta bookkeeping, and the
/// thin pass-through query surface; the heavy I/O lives on
/// [CatalogDownloadDataSource].
///
/// **Pause / cancel semantics**:
/// * Pause during download → partial gzip + sidecar stay on disk;
///   resume sends `Range: bytes=<offset>-` and continues from there.
/// * Pause during install → leaves the partial decompressed file in
///   place; resume restarts the gunzip from the start (the gzip is
///   complete on disk, so this is fast and idempotent).
/// * Cancel any phase → all partial artefacts are deleted and the
///   live catalog (if any) is wiped.
class OfflineCatalogRepository {
  final _log = Logger('OfflineCatalogRepository');
  final OfflineCatalogDataSource _local;
  final CatalogDownloadDataSource _download;

  OfflineCatalogRepository(this._local, this._download);

  /// Static estimate for [filters] derived from the variant sizing
  /// table. No network round-trip is needed — the build pipeline
  /// produces the same set of variants every week, so the projections
  /// drift only with corpus growth (a few percent per quarter on the
  /// loosest tier).
  Future<CatalogEstimateEntity> estimate(CatalogFilterEntity filters) async {
    final sizing = _kVariantSizing[filters.toVariantId()];
    if (sizing == null) {
      throw FormatException(
        'No size table entry for variant ${filters.toVariantId()}',
      );
    }
    return CatalogEstimateEntity(
      rows: sizing.rows,
      // What the wizard's "On-disk size" line surfaces.
      estimatedBytes: sizing.uncompressedBytes,
      // The legacy "requests" field is repurposed as the download
      // bytes figure; see lib/features/offline_catalog/domain/entity/
      // catalog_estimate_entity.dart for the field's notes.
      requests: sizing.compressedBytes,
      etaSeconds:
          (sizing.compressedBytes / _kAssumedBytesPerSecond).ceil(),
    );
  }

  /// Run a fresh build (or resume an interrupted one) for [filters].
  ///
  /// Phase 1 — download. Yields [DownloadProgress] with
  /// `phase = downloading` and bytes counters. Cancellation between
  /// chunks. Resume picks up at the on-disk file's existing length.
  ///
  /// Phase 2 — install. Yields [DownloadProgress] with
  /// `phase = installing` and uncompressed-bytes counters as the
  /// gunzip stream lands on disk; ends with the atomic rename.
  Stream<DownloadProgress> build({
    required CatalogFilterEntity filters,
    required CancellationToken cancellation,
  }) async* {
    final variantId = filters.toVariantId();
    final sizing = _kVariantSizing[variantId];
    if (sizing == null) {
      throw FormatException('No variant for filter $variantId');
    }
    _log.info('Catalog build: variant=$variantId, '
        'compressed=${sizing.compressedBytes ~/ _mb} MB, '
        'rows=${sizing.rows}');

    final dbPath = await _local.resolveDbPath();

    yield* _download.downloadAndInstall(
      variantId: variantId,
      catalogDbPath: dbPath,
      expectedUncompressedBytes: sizing.uncompressedBytes,
      cancellation: cancellation,
      // Close the live sqflite handle before the rename so the
      // platform lets us swap the file (Windows, in particular,
      // refuses to rename over an open file handle).
      beforeInstall: () => _local.close(),
    );

    cancellation.throwIfCancelled();

    // After the rename, the data source's cached handle has been
    // closed. The next access reopens the new file and we can write
    // our own meta entries (filters JSON + last sync time) so the
    // settings tile and resume path know what was just installed.
    final filtersJson = _serialiseFilters(filters);
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyFiltersJson,
      filtersJson,
    );
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyLastFullSync,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final stored = await _local.count();
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyTotalCount,
      stored.toString(),
    );
    _log.info('Catalog install complete: $stored rows on disk');
  }

  /// Re-download whatever variant the user last installed. Intended
  /// for the settings-tile Refresh button: same progress UI as a
  /// first build, no filter re-selection needed. The CDN serves a
  /// fresh weekly artefact so the user picks up new products without
  /// re-running the wizard.
  Stream<DownloadProgress> refresh({
    required CancellationToken cancellation,
  }) async* {
    final filters = await getPersistedFilters();
    if (filters == null) {
      throw StateError(
        'Cannot refresh: catalog has not been built yet',
      );
    }
    yield* build(filters: filters, cancellation: cancellation);
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

  /// The filter set the user last completed. Recovery hierarchy:
  ///
  /// 1. Live catalog's `catalog_meta.filters_json` — set by the
  ///    repository after a successful install.
  /// 2. Partial download's URL — the variant id parses back into a
  ///    filter set when only a paused download is sitting on disk
  ///    and the live catalog doesn't yet exist.
  /// 3. Row-count inference against the variant sizing table — for
  ///    catalogs that landed on disk before this code wrote a
  ///    `filters_json` meta entry (a transient state from earlier
  ///    install bugs). Each variant has a distinctive row count, so
  ///    the closest match is unambiguous.
  Future<CatalogFilterEntity?> getPersistedFilters() async {
    final filtersJson =
        await _local.getMeta(OfflineCatalogDataSource.metaKeyFiltersJson);
    if (filtersJson != null) {
      return _deserialiseFilters(filtersJson);
    }
    // Fall back to the partial download. The user paused a build that
    // is mid-flight and we have nothing in catalog_meta yet (because
    // the file hasn't been renamed into place).
    for (final variantId in _kVariantSizing.keys) {
      if (await _download.hasResumeablePartial(variantId)) {
        return CatalogFilterEntity.fromVariantId(variantId);
      }
    }
    // Last resort: infer from row count. A catalog file is on disk
    // and populated, but the meta entry is missing — possibly from a
    // user who upgraded through a release where the post-install
    // meta-write step crashed. Pick the variant whose expected row
    // count is closest to what's actually on disk; the natural drift
    // between weekly rebuilds is well within the gap between any two
    // variants in the table, so the closest match is decisive.
    final stored = await _local.count();
    if (stored == 0) return null;
    String? bestMatch;
    var bestDelta = double.infinity;
    for (final entry in _kVariantSizing.entries) {
      final delta = (entry.value.rows - stored).abs().toDouble();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestMatch = entry.key;
      }
    }
    if (bestMatch == null) return null;
    final inferred = CatalogFilterEntity.fromVariantId(bestMatch);
    if (inferred == null) return null;
    // Backfill the meta entry so subsequent calls hit the fast path
    // and the catalog is no longer in the orphan state.
    await _local.setMeta(
      OfflineCatalogDataSource.metaKeyFiltersJson,
      _serialiseFilters(inferred),
    );
    _log.info(
      'Inferred catalog filters from row count: $stored rows '
      '→ variant $bestMatch (delta $bestDelta); meta backfilled',
    );
    return inferred;
  }

  Future<OFFProductDTO?> getByCode(String code) => _local.getByCode(code);

  Future<List<OFFProductDTO>> searchByText(String query, {int limit = 50}) =>
      _local.searchByText(query, limit: limit);

  /// Drop the catalog AND any partial download artefacts.
  Future<void> delete() async {
    await _local.clear();
    await _download.cleanupPartials();
  }

  /// True when there's a partial download on disk to resume. The
  /// presence of a `.tmp.gz` plus its sidecar is the signal — when
  /// either is missing, there is no meaningful resume.
  Future<bool> hasResumeableBuild() async {
    for (final variantId in _kVariantSizing.keys) {
      if (await _download.hasResumeablePartial(variantId)) {
        return true;
      }
    }
    return false;
  }

  String _serialiseFilters(CatalogFilterEntity filters) {
    return jsonEncode({
      'requireNutritionGrade': filters.requireNutritionGrade,
      'requireMinPopularity': filters.requireMinPopularity,
      'maxAgeSeconds': filters.maxAge?.inSeconds,
      'variantId': filters.toVariantId(),
    });
  }

  CatalogFilterEntity _deserialiseFilters(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final maxAgeSecondsRaw = map['maxAgeSeconds'];
    return CatalogFilterEntity(
      requireNutritionGrade: (map['requireNutritionGrade'] as bool?) ?? true,
      requireMinPopularity: (map['requireMinPopularity'] as bool?) ?? true,
      maxAge: maxAgeSecondsRaw is int
          ? Duration(seconds: maxAgeSecondsRaw)
          : null,
    );
  }
}
