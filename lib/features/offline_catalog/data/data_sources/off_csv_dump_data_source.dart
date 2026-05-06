import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/ont_http_client.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Bytes-level progress emitted by [OffCsvDumpDataSource.downloadResumable].
class CsvDownloadProgress {
  final int bytesDone;
  final int bytesTotal;

  const CsvDownloadProgress({
    required this.bytesDone,
    required this.bytesTotal,
  });
}

/// Rows-level progress emitted by [OffCsvDumpDataSource.parseAndFilter].
/// [bytesDone] / [bytesTotal] are the offset into the on-disk gzip
/// file (which the OS streams through the gzip decoder), not the
/// decoded csv stream — we never know the decoded length up-front.
class CsvParseProgress {
  final int bytesDone;
  final int bytesTotal;
  final int rowsKept;
  final int rowsScanned;

  const CsvParseProgress({
    required this.bytesDone,
    required this.bytesTotal,
    required this.rowsKept,
    required this.rowsScanned,
  });
}

/// Streamed download + filter pipeline over OFF's nightly CSV dump.
///
/// The CSV is the smallest of OFF's full-database exports (~900 MB
/// gzipped, ~9 GB decoded) and is served from a static CDN endpoint
/// that, unlike the legacy `cgi/search.pl`, doesn't 503-shed under
/// bulk pulls. We trade a one-time large download for a reliable
/// build path.
///
/// The pipeline runs in two cancellable phases:
///
/// 1. [downloadResumable] HTTPs the gzip into the app cache directory
///    in chunks, with `Range: bytes=<offset>-` so an interrupted
///    transfer resumes from where it stopped rather than starting
///    over. We never decompress the file at this stage — it lives on
///    disk as a ~900 MB blob until phase 2.
/// 2. [parseAndFilter] opens the gzip from disk, streams it through
///    `gzip.decoder` → `utf8.decoder` → `LineSplitter`, parses the
///    header to map column indices, then walks each row and applies
///    the wizard's filter set. Rows that survive are batched into
///    [OFFProductDTO] objects for the caller to upsert; rows that
///    fail any filter never leave the parser.
///
/// After a successful build [deleteCachedFile] is called by the
/// repository to free the ~900 MB. A user who pauses mid-download
/// keeps the partial file so resume works; a user who cancels gets
/// the file deleted with the rest of the partial state.
class OffCsvDumpDataSource {
  static const _csvUrl =
      'https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz';
  static const _localFilename = 'openfoodfacts.csv.gz';

  /// CSV is tab-separated despite the `.csv` extension. Tag-list
  /// columns (categories_tags, countries_tags, …) carry their own
  /// internal separator inside a single tab field; we split those
  /// further only when we read them.
  static const _fieldSeparator = '\t';
  static const _tagListSeparator = ',';

  /// Upper bound on rows-per-batch passed to the caller's onBatch
  /// callback. 500 is a reasonable sqlite Batch size for our row
  /// shape — small enough to keep memory flat, large enough to
  /// avoid one transaction per row.
  static const _batchSize = 500;

  /// How many rows to read between cancellation checks during the
  /// parse loop. Cancellation never aborts mid-row; the loop just
  /// pauses after a complete row has been processed.
  static const _cancellationCheckInterval = 200;

  final _log = Logger('OffCsvDumpDataSource');
  final http.Client Function() _httpClientFactory;

  OffCsvDumpDataSource({http.Client Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Resolve the on-disk path for the cached gzip. Visible for tests;
  /// production callers don't need it.
  Future<File> resolveLocalFile() async {
    final dir = await getApplicationCacheDirectory();
    return File(p.join(dir.path, _localFilename));
  }

  /// HEAD the CSV URL and return its `Content-Length`. Returns null
  /// when the server doesn't advertise one (which OFF's CDN should
  /// always do, but guard anyway).
  Future<int?> headTotalBytes() async {
    final userAgent = await AppConst.getUserAgentString();
    final client = ONTHttpClient(userAgent, _httpClientFactory());
    try {
      final response = await client
          .head(Uri.parse(_csvUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final raw = response.headers['content-length'];
      if (raw == null) return null;
      return int.tryParse(raw);
    } finally {
      client.close();
    }
  }

  /// True when a partial or complete download exists on disk.
  Future<bool> hasLocalFile() async => (await resolveLocalFile()).exists();

  /// Bytes already on disk for the cached gzip, or 0 when no file.
  Future<int> downloadedBytes() async {
    final file = await resolveLocalFile();
    if (!await file.exists()) return 0;
    return file.length();
  }

  /// Resumable streaming download to [resolveLocalFile]. Yields one
  /// [CsvDownloadProgress] approximately every 64 KB of progress;
  /// throttling to a UI-friendly cadence is the caller's job.
  ///
  /// A cancellation interrupts cleanly after the next chunk; the
  /// partial file stays on disk so a future call resumes from there.
  Stream<CsvDownloadProgress> downloadResumable({
    required CancellationToken cancellation,
  }) async* {
    final file = await resolveLocalFile();
    final totalBytes = await headTotalBytes();
    if (totalBytes == null) {
      throw const FormatException(
        'Open Food Facts did not advertise a Content-Length for the CSV '
        'dump. Cannot run a resumable download without it.',
      );
    }

    final existing = await file.exists() ? await file.length() : 0;
    if (existing >= totalBytes) {
      // Already fully downloaded; nothing to do but emit a final
      // progress event so the caller sees 100%.
      yield CsvDownloadProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
      );
      return;
    }

    final userAgent = await AppConst.getUserAgentString();
    final client = ONTHttpClient(userAgent, _httpClientFactory());
    try {
      final request = http.Request('GET', Uri.parse(_csvUrl));
      // `bytes=<offset>-` asks the server for everything from
      // [offset] to end-of-file. OFF's CDN supports range requests.
      if (existing > 0) {
        request.headers['Range'] = 'bytes=$existing-';
      }
      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException(
          'OFF csv dump returned HTTP ${response.statusCode}',
        );
      }

      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      var bytesDone = existing;
      var bytesSinceLastEmit = 0;
      const emitInterval = 64 * 1024;
      try {
        await for (final chunk in response.stream) {
          if (cancellation.isCancelled) {
            // Flush what we have; partial file stays on disk for
            // resume. The CancellationException is then thrown by
            // the caller's [throwIfCancelled].
            break;
          }
          sink.add(chunk);
          bytesDone += chunk.length;
          bytesSinceLastEmit += chunk.length;
          if (bytesSinceLastEmit >= emitInterval) {
            bytesSinceLastEmit = 0;
            yield CsvDownloadProgress(
              bytesDone: bytesDone,
              bytesTotal: totalBytes,
            );
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      cancellation.throwIfCancelled();

      // Final emit so the UI lands on 100%.
      yield CsvDownloadProgress(
        bytesDone: bytesDone,
        bytesTotal: totalBytes,
      );
    } finally {
      client.close();
    }
  }

  /// Stream the local gzip file through the decompress + parse +
  /// filter pipeline. For each batch of [_batchSize] survivors, the
  /// caller's [onBatch] callback is invoked (typically to upsert
  /// into sqlite) and a [CsvParseProgress] is yielded.
  ///
  /// [filter] holds the user's wizard choices: countries, recency
  /// window, popularity / nutrition-grade toggles. Always-on filters
  /// (human-food only, completeness ≥ 0.3, obsolete = 0) are applied
  /// in here too.
  Stream<CsvParseProgress> parseAndFilter({
    required CatalogFilterEntity filter,
    required CancellationToken cancellation,
    required Future<void> Function(List<OFFProductDTO> batch) onBatch,
    DateTime? now,
  }) async* {
    final file = await resolveLocalFile();
    if (!await file.exists()) {
      throw StateError(
        'No cached CSV file to parse — call downloadResumable first.',
      );
    }
    final totalBytes = await file.length();
    final lastModifiedCutoff = filter.lastModifiedSinceEpoch(now ?? DateTime.now());

    // The CountingFileStream lets us report bytes-into-the-gzip-file
    // (not bytes-into-the-decoded-csv) for progress. The decoded
    // stream's total length is unknown up-front, so we tie progress
    // to the gzip file we have on disk instead.
    var bytesRead = 0;
    final byteStream = file.openRead().map<List<int>>((chunk) {
      bytesRead += chunk.length;
      return chunk;
    });

    final lines = byteStream
        .transform(gzip.decoder)
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    Map<String, int>? columnIndex;
    final batch = <OFFProductDTO>[];
    var rowsKept = 0;
    var rowsScanned = 0;

    Future<void> flushBatch() async {
      if (batch.isEmpty) return;
      await onBatch(List.of(batch));
      batch.clear();
    }

    try {
      await for (final line in lines) {
        if (columnIndex == null) {
          columnIndex = _parseHeader(line);
          continue;
        }

        rowsScanned++;
        if (rowsScanned % _cancellationCheckInterval == 0) {
          cancellation.throwIfCancelled();
        }

        final row = _splitRow(line);
        if (!_passesClientSideFilter(
          row,
          columnIndex,
          filter,
          lastModifiedCutoff,
        )) {
          continue;
        }

        final dto = _rowToDto(row, columnIndex);
        if (dto == null) continue;
        batch.add(dto);
        rowsKept++;

        if (batch.length >= _batchSize) {
          await flushBatch();
          yield CsvParseProgress(
            bytesDone: bytesRead,
            bytesTotal: totalBytes,
            rowsKept: rowsKept,
            rowsScanned: rowsScanned,
          );
        }
      }
      // Tail batch.
      await flushBatch();
      yield CsvParseProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
        rowsKept: rowsKept,
        rowsScanned: rowsScanned,
      );
    } catch (e, stack) {
      _log.warning('CSV parse aborted', e, stack);
      // Flush whatever we have so the catalog reflects rows we
      // actually committed before the failure.
      await flushBatch();
      rethrow;
    }
  }

  Future<void> deleteCachedFile() async {
    final file = await resolveLocalFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Exercises the same parse + filter + DTO-mapping pipeline as
  /// [parseAndFilter] but against an in-memory list of CSV lines —
  /// the first line is treated as the header, the rest as data
  /// rows. Returns the DTOs that would have been written to sqlite.
  ///
  /// Visible for tests so we can verify the column mapping and
  /// each filter rule against synthetic inputs without spinning up
  /// the gzip / file-I/O stack.
  @visibleForTesting
  List<OFFProductDTO> filterAndMapForTest({
    required List<String> lines,
    required CatalogFilterEntity filter,
    DateTime? now,
  }) {
    if (lines.isEmpty) return const [];
    final header = _parseHeader(lines.first);
    final cutoff = filter.lastModifiedSinceEpoch(now ?? DateTime.now());
    final out = <OFFProductDTO>[];
    for (var i = 1; i < lines.length; i++) {
      final row = _splitRow(lines[i]);
      if (!_passesClientSideFilter(row, header, filter, cutoff)) continue;
      final dto = _rowToDto(row, header);
      if (dto != null) out.add(dto);
    }
    return out;
  }

  // -------------------------------------------------------------- //
  // Header / row parsing                                            //
  // -------------------------------------------------------------- //

  /// Build a column-name → column-index lookup from the CSV header.
  /// Trims surrounding whitespace per column so we don't fail on a
  /// trailing CR.
  Map<String, int> _parseHeader(String line) {
    final raw = _splitRow(line);
    final out = <String, int>{};
    for (var i = 0; i < raw.length; i++) {
      out[raw[i].trim()] = i;
    }
    return out;
  }

  /// Tab-split a row. OFF's CSV does not generally quote fields, but
  /// we strip a single leading/trailing CR per cell as a defensive
  /// measure on Windows-line-ended dumps.
  List<String> _splitRow(String line) {
    final cells = line.split(_fieldSeparator);
    for (var i = 0; i < cells.length; i++) {
      final s = cells[i];
      if (s.isNotEmpty && s.codeUnitAt(s.length - 1) == 0x0D) {
        cells[i] = s.substring(0, s.length - 1);
      }
    }
    return cells;
  }

  String? _cell(List<String> row, Map<String, int> idx, String name) {
    final i = idx[name];
    if (i == null || i >= row.length) return null;
    final v = row[i];
    return v.isEmpty ? null : v;
  }

  // -------------------------------------------------------------- //
  // Filter — kept in lockstep with OffBulkApiDataSource so the API   //
  // refresh path and the CSV bulk path produce equivalent catalogs.  //
  // -------------------------------------------------------------- //

  static const _excludedCategoryTags = {
    'en:pet-food',
    'pet-food',
    'en:cosmetics',
    'cosmetics',
    'en:non-food-products',
    'non-food-products',
  };

  static const _minCompleteness = 0.3;
  static const _acceptedNutritionGrades = {'a', 'b', 'c', 'd', 'e'};
  static const _minPopularity = 2;

  bool _passesClientSideFilter(
    List<String> row,
    Map<String, int> idx,
    CatalogFilterEntity filter,
    int? lastModifiedCutoff,
  ) {
    // Always-on: drop obsolete rows. OFF stores this as "1" / "" in
    // the CSV.
    final obsolete = _cell(row, idx, 'obsolete');
    if (obsolete != null && obsolete != '0' && obsolete != 'false') {
      return false;
    }

    // Country selection. OFF stores `countries_tags` as a comma-
    // separated list of `en:france` style tags inside one cell.
    if (filter.countries.isNotEmpty) {
      final tags = _cell(row, idx, 'countries_tags');
      if (tags == null) return false;
      var matched = false;
      for (final wanted in filter.countries) {
        // Quick contains() is enough — tags are colon-prefixed and
        // separated by commas, no false positive risk between e.g.
        // "en:france" and "en:french-polynesia" because we split.
        for (final tag in tags.split(_tagListSeparator)) {
          if (tag.trim() == wanted) {
            matched = true;
            break;
          }
        }
        if (matched) break;
      }
      if (!matched) return false;
    }

    // Always-on: human food. Reject products carrying any excluded
    // category tag.
    final categories = _cell(row, idx, 'categories_tags');
    if (categories != null) {
      for (final raw in categories.split(_tagListSeparator)) {
        final tag = raw.trim();
        if (_excludedCategoryTags.contains(tag)) return false;
      }
    }

    // Always-on: minimum completeness.
    final completeness = _toDouble(_cell(row, idx, 'completeness'));
    if (completeness == null || completeness < _minCompleteness) return false;

    // User toggle: nutrition grade present.
    if (filter.requireNutritionGrade) {
      // CSV column is `nutrition_grade_fr` historically; some dumps
      // also expose `nutrition_grades`. Check both.
      final grade =
          _cell(row, idx, 'nutrition_grade_fr') ?? _cell(row, idx, 'nutrition_grades');
      if (grade == null ||
          !_acceptedNutritionGrades.contains(grade.toLowerCase())) {
        return false;
      }
    }

    // User toggle: minimum scan popularity.
    if (filter.requireMinPopularity) {
      final scans = _toInt(_cell(row, idx, 'unique_scans_n'));
      if (scans == null || scans < _minPopularity) return false;
    }

    // User selector: recency cutoff.
    if (lastModifiedCutoff != null) {
      final lastModified = _toInt(_cell(row, idx, 'last_modified_t'));
      if (lastModified == null || lastModified < lastModifiedCutoff) {
        return false;
      }
    }

    return true;
  }

  // -------------------------------------------------------------- //
  // Row → DTO mapping                                               //
  // -------------------------------------------------------------- //

  /// Construct an [OFFProductDTO] from a tokenised CSV row. Returns
  /// null when the row has no usable identifier (no `code`).
  ///
  /// The DTO carries a nested `nutriments` map — we rebuild that map
  /// here from OFF's flat `*_100g` columns. Nutriment names with a
  /// hyphen in the JSON (`energy-kcal_100g`) appear with that same
  /// hyphen in the CSV header, so we read them directly.
  OFFProductDTO? _rowToDto(List<String> row, Map<String, int> idx) {
    final code = _cell(row, idx, 'code');
    if (code == null) return null;

    final nutriments = <String, dynamic>{};
    for (final key in _nutrimentCsvKeys) {
      final raw = _cell(row, idx, key);
      if (raw == null) continue;
      final n = _toDouble(raw);
      if (n != null) nutriments[key] = n;
    }

    final json = <String, dynamic>{
      'code': code,
      'product_name': _cell(row, idx, 'product_name'),
      'product_name_en': _cell(row, idx, 'product_name_en'),
      'product_name_de': _cell(row, idx, 'product_name_de'),
      'product_name_fr': _cell(row, idx, 'product_name_fr'),
      'brands': _cell(row, idx, 'brands'),
      'image_front_thumb_url': _cell(row, idx, 'image_front_small_url') ??
          _cell(row, idx, 'image_front_thumb_url') ??
          _cell(row, idx, 'image_small_url'),
      'image_front_url': _cell(row, idx, 'image_front_url') ??
          _cell(row, idx, 'image_url'),
      'image_ingredients_url': _cell(row, idx, 'image_ingredients_url'),
      'image_nutrition_url': _cell(row, idx, 'image_nutrition_url'),
      'image_url': _cell(row, idx, 'image_url'),
      'url': _cell(row, idx, 'url'),
      'quantity': _cell(row, idx, 'quantity'),
      'product_quantity': _toDouble(_cell(row, idx, 'product_quantity')),
      'serving_quantity': _toDouble(_cell(row, idx, 'serving_quantity')),
      'serving_size': _cell(row, idx, 'serving_size'),
      'nutriments': nutriments,
    };

    try {
      return OFFProductDTO.fromJson(json);
    } catch (e) {
      _log.warning('CSV row could not be mapped to DTO ($code): $e');
      return null;
    }
  }

  /// Names of the per-100g nutriment CSV columns we surface into
  /// the OFF DTO. Mirrors the @JsonKey-mapped fields on
  /// [OFFProductNutrimentsDTO]; hyphens in the column names match
  /// the JSON-key forms exactly.
  static const _nutrimentCsvKeys = [
    'energy-kcal_100g',
    'carbohydrates_100g',
    'fat_100g',
    'proteins_100g',
    'sugars_100g',
    'saturated-fat_100g',
    'fiber_100g',
    'monounsaturated-fat_100g',
    'polyunsaturated-fat_100g',
    'trans-fat_100g',
    'cholesterol_100g',
    'sodium_100g',
    'potassium_100g',
    'magnesium_100g',
    'calcium_100g',
    'iron_100g',
    'zinc_100g',
    'phosphorus_100g',
    'vitamin-a_100g',
    'vitamin-c_100g',
    'vitamin-d_100g',
    'vitamin-b6_100g',
    'vitamin-b12_100g',
    'niacin_100g',
  ];

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
