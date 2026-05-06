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

/// Raised when the cache directory doesn't have enough free space
/// to hold the OFF dump download. Surfaced as a recoverable error
/// so the user can free space and retry.
class DiskSpaceException implements Exception {
  final int bytesNeeded;
  final String underlying;

  const DiskSpaceException({
    required this.bytesNeeded,
    required this.underlying,
  });

  @override
  String toString() {
    final mb = (bytesNeeded / (1024 * 1024)).toStringAsFixed(0);
    return 'Not enough free space on the device to download the Open Food '
        'Facts dump. Need at least $mb MB. ($underlying)';
  }
}

/// One worker's slice of the parallel download. Sidecar-serialised
/// so an interrupted download can pick up exactly where each
/// worker stopped rather than restarting the whole 1+ GB transfer.
class _RangeState {
  /// Inclusive byte offset where this worker's slice starts.
  final int start;

  /// Inclusive byte offset where this worker's slice ends.
  /// Range length is `end - start + 1`.
  final int end;

  /// Bytes this worker has successfully written. Survivor across
  /// app restarts via the `.parts` sidecar.
  int downloaded;

  _RangeState({
    required this.start,
    required this.end,
    required this.downloaded,
  });

  int get length => end - start + 1;
  bool get isComplete => downloaded >= length;

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'downloaded': downloaded,
      };

  factory _RangeState.fromJson(Map<String, dynamic> json) => _RangeState(
        start: json['start'] as int,
        end: json['end'] as int,
        downloaded: json['downloaded'] as int,
      );
}

/// Whole-download state — total size + per-worker ranges. Lives
/// next to the gzip in the cache directory as `<filename>.parts`.
class _DownloadState {
  final int totalBytes;
  final List<_RangeState> ranges;

  _DownloadState({required this.totalBytes, required this.ranges});

  /// Sum of bytes already on disk across every range. Drives the
  /// initial progress emission so the UI shows where we're picking
  /// up from on a resume.
  int get completedBytes =>
      ranges.fold<int>(0, (acc, r) => acc + r.downloaded);

  Map<String, dynamic> toJson() => {
        'totalBytes': totalBytes,
        'ranges': ranges.map((r) => r.toJson()).toList(),
      };

  static _DownloadState parse(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final ranges = (map['ranges'] as List<dynamic>)
        .map((r) => _RangeState.fromJson(r as Map<String, dynamic>))
        .toList();
    return _DownloadState(
      totalBytes: map['totalBytes'] as int,
      ranges: ranges,
    );
  }

  /// Initial state for a brand-new download. Splits [totalBytes]
  /// into [workerCount] approximately-equal byte ranges. The last
  /// range absorbs any remainder so the total exactly covers the
  /// file end.
  factory _DownloadState.fresh({
    required int totalBytes,
    required int workerCount,
  }) {
    final perWorker = totalBytes ~/ workerCount;
    final ranges = <_RangeState>[];
    for (var i = 0; i < workerCount; i++) {
      final start = i * perWorker;
      final end = (i == workerCount - 1) ? totalBytes - 1 : start + perWorker - 1;
      ranges.add(_RangeState(start: start, end: end, downloaded: 0));
    }
    return _DownloadState(totalBytes: totalBytes, ranges: ranges);
  }
}

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
  final Future<File> Function()? _localFileOverride;

  OffCsvDumpDataSource({
    http.Client Function()? httpClientFactory,
    Future<File> Function()? localFileResolver,
  })  : _httpClientFactory = httpClientFactory ?? http.Client.new,
        _localFileOverride = localFileResolver;

  /// Resolve the on-disk path for the cached gzip. Production
  /// callers go through [getApplicationCacheDirectory]; tests can
  /// supply a [localFileResolver] override in the constructor to
  /// point at a fixture file outside the Flutter binding.
  Future<File> resolveLocalFile() async {
    final override = _localFileOverride;
    if (override != null) return override();
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

  /// Bytes successfully downloaded for the cached gzip. Honours the
  /// sidecar's per-range progress when present — the gzip itself is
  /// pre-allocated to its full size as soon as the parallel
  /// downloader starts, so `file.length()` no longer reflects how
  /// much we've actually written.
  Future<int> downloadedBytes() async {
    final file = await resolveLocalFile();
    if (!await file.exists()) return 0;
    final sidecar = File('${file.path}.parts');
    if (await sidecar.exists()) {
      try {
        final state =
            _DownloadState.parse(await sidecar.readAsString());
        return state.completedBytes;
      } catch (e) {
        _log.warning('Failed to parse download sidecar: $e');
        // Fall through to the conservative file-length answer.
      }
    }
    // No sidecar means the download finished cleanly (we delete it
    // on completion), so the file IS the truth.
    return file.length();
  }

  /// Best-effort pre-flight check that the cache directory has at
  /// least [bytesNeeded] of free space. Writes a sentinel file of
  /// the requested size and rolls it back; if that succeeds the
  /// real download has at least the same headroom. If the write
  /// fails (typically `errno=ENOSPC`), throws
  /// [DiskSpaceException] so the build aborts cleanly with a
  /// human-readable message rather than crashing partway through
  /// a multi-hundred-MB download.
  ///
  /// Pass the **largest** size we expect to need on disk
  /// concurrently — that's the gzip itself plus a margin. We don't
  /// pre-flight the decoded stream because it never lands as a
  /// file; it streams through the parser.
  Future<void> preflightDiskSpace(int bytesNeeded) async {
    final dir = await getApplicationCacheDirectory();
    final sentinel = File(p.join(dir.path, '.ont_disk_probe'));
    try {
      // Write in 1 MB chunks so we don't allocate a huge buffer
      // up-front; intermediate failures fail fast at the right
      // boundary.
      final sink = sentinel.openWrite();
      try {
        const chunk = 1024 * 1024;
        final buf = List<int>.filled(chunk, 0);
        var written = 0;
        while (written < bytesNeeded) {
          final remaining = bytesNeeded - written;
          if (remaining >= chunk) {
            sink.add(buf);
            written += chunk;
          } else {
            sink.add(List<int>.filled(remaining, 0));
            written += remaining;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (e) {
      // Anything that fails the sentinel write is treated as a
      // disk-space problem. Permission issues would be the same
      // failure surface; either way we abort.
      try {
        if (await sentinel.exists()) await sentinel.delete();
      } catch (_) {/* best effort cleanup */}
      throw DiskSpaceException(
        bytesNeeded: bytesNeeded,
        underlying: e.toString(),
      );
    }
    // Roll back regardless — we only wanted to know the write
    // would succeed.
    try {
      if (await sentinel.exists()) await sentinel.delete();
    } catch (_) {/* best effort cleanup */}
  }

  /// How many parallel HTTP connections to fan out across. Four is
  /// the empirical sweet spot for CDNs that throttle individual
  /// connections (which OFF's does): each connection is bounded
  /// independently, so 4 connections move the bottleneck to the
  /// link instead. Going higher risks tripping the CDN's
  /// per-IP-abuse heuristics for marginal additional throughput.
  static const _parallelDownloadWorkers = 4;

  /// Resumable streaming download to [resolveLocalFile]. The OFF
  /// gzip is split into [_parallelDownloadWorkers] non-overlapping
  /// byte ranges; each is fetched concurrently with `Range: bytes=
  /// A-B` and written into a sparse file at the right offset via
  /// [RandomAccessFile.setPosition]. Aggregate progress is yielded
  /// roughly every 256 KB of cross-worker bytes.
  ///
  /// **Resumability.** A sidecar `.parts` JSON file tracks how many
  /// bytes each worker has written. An interrupted download leaves
  /// both the sparse file and the sidecar on disk; the next call
  /// resumes each worker from `start + downloaded` rather than
  /// restarting from scratch. The sidecar is updated after every
  /// chunk so a crash loses at most one chunk per worker.
  ///
  /// **Layout invalidation.** If the upstream file size or the
  /// configured worker count changes between sessions, the sidecar
  /// won't match. We wipe and start fresh in that case rather than
  /// trying to merge.
  ///
  /// **Cancellation** propagates to all workers — each checks the
  /// token between chunks and returns cleanly. The sparse file and
  /// sidecar stay on disk so a subsequent call can resume.
  Stream<CsvDownloadProgress> downloadResumable({
    required CancellationToken cancellation,
  }) async* {
    final file = await resolveLocalFile();
    final sidecar = File('${file.path}.parts');
    final totalBytes = await headTotalBytes();
    if (totalBytes == null) {
      throw const FormatException(
        'Open Food Facts did not advertise a Content-Length for the CSV '
        'dump. Cannot run a resumable download without it.',
      );
    }

    // Load or initialise the per-range download state.
    final state = await _loadOrInitState(
      file: file,
      sidecar: sidecar,
      totalBytes: totalBytes,
      workerCount: _parallelDownloadWorkers,
    );

    if (state.completedBytes >= totalBytes) {
      yield CsvDownloadProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
      );
      return;
    }

    // Pre-allocate the sparse file if it isn't already at the
    // target size. On Linux / macOS / Windows this just sets the
    // file length without writing zeros — the OS materialises
    // pages on demand as workers write into them.
    if (!await file.exists() || await file.length() < totalBytes) {
      final raf = await file.open(mode: FileMode.write);
      try {
        await raf.truncate(totalBytes);
      } finally {
        await raf.close();
      }
    }

    final userAgent = await AppConst.getUserAgentString();

    // Shared progress channel — workers push deltas, the generator
    // here aggregates and yields. Throttling to ~256 KB of
    // aggregate progress across 4 workers gives a UI-friendly
    // cadence without hammering the bloc.
    final progressUpdates = StreamController<int>(sync: true);
    var aggregate = state.completedBytes;

    Future<void> persistSidecar() async {
      await sidecar.writeAsString(jsonEncode(state.toJson()));
    }

    Future<void> runWorker(_RangeState range) async {
      if (range.isComplete) return;
      final client = ONTHttpClient(userAgent, _httpClientFactory());
      RandomAccessFile? raf;
      try {
        raf = await file.open(mode: FileMode.writeOnlyAppend);
        // FileMode.writeOnlyAppend doesn't allow setPosition on
        // some platforms — reopen in `write` mode instead, which
        // does. Each worker has its own RandomAccessFile so seeks
        // don't interfere.
        await raf.close();
        raf = await file.open(mode: FileMode.write);

        final start = range.start + range.downloaded;
        final end = range.end; // inclusive
        final request = http.Request('GET', Uri.parse(_csvUrl));
        request.headers['Range'] = 'bytes=$start-$end';

        final response = await client.send(request);
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw HttpException(
            'OFF csv dump returned HTTP ${response.statusCode} for '
            'range $start-$end',
          );
        }

        var localOffset = start;
        await for (final chunk in response.stream) {
          if (cancellation.isCancelled) break;
          await raf.setPosition(localOffset);
          await raf.writeFrom(chunk);
          localOffset += chunk.length;
          range.downloaded += chunk.length;
          progressUpdates.add(chunk.length);
          // Persist sidecar every chunk. A few KB of writes per
          // chunk is cheap; the worst-case loss from a crash is
          // one chunk's worth of redundant download.
          await persistSidecar();
        }
      } finally {
        try {
          await raf?.close();
        } catch (_) {/* best effort */}
        client.close();
      }
    }

    // Spawn all workers, set up a future that signals "all done"
    // by closing the progress controller.
    final workers =
        state.ranges.map(runWorker).toList(growable: false);
    unawaited(Future.wait(workers).whenComplete(() {
      progressUpdates.close();
    }));

    var bytesSinceLastEmit = 0;
    const emitInterval = 256 * 1024;
    try {
      await for (final delta in progressUpdates.stream) {
        aggregate += delta;
        bytesSinceLastEmit += delta;
        if (bytesSinceLastEmit >= emitInterval) {
          bytesSinceLastEmit = 0;
          yield CsvDownloadProgress(
            bytesDone: aggregate,
            bytesTotal: totalBytes,
          );
        }
      }
    } finally {
      // Make sure all workers have actually completed before we
      // return — the controller can close before Future.wait
      // resolves on a fast cancel path.
      await Future.wait(workers, eagerError: false);
    }

    cancellation.throwIfCancelled();

    // If every range is complete, drop the sidecar so a future
    // build doesn't think there's resumeable state.
    if (state.completedBytes >= totalBytes) {
      try {
        if (await sidecar.exists()) await sidecar.delete();
      } catch (_) {/* best effort */}
    }

    // Final emit so the UI lands on 100% / a definite stop.
    yield CsvDownloadProgress(
      bytesDone: aggregate,
      bytesTotal: totalBytes,
    );
  }

  /// Load the per-range state from the sidecar or initialise a
  /// fresh one. Wipes both the file and sidecar when the layout
  /// has changed (different total size or worker count) — there's
  /// no safe way to splice partial bytes into a layout that
  /// disagrees with the on-disk reality.
  Future<_DownloadState> _loadOrInitState({
    required File file,
    required File sidecar,
    required int totalBytes,
    required int workerCount,
  }) async {
    if (await sidecar.exists()) {
      try {
        final raw = await sidecar.readAsString();
        final state = _DownloadState.parse(raw);
        if (state.totalBytes == totalBytes &&
            state.ranges.length == workerCount) {
          return state;
        }
        _log.info(
          'Sidecar layout mismatch (totalBytes=${state.totalBytes} vs '
          '$totalBytes, workers=${state.ranges.length} vs '
          '$workerCount); restarting fresh',
        );
      } catch (e) {
        _log.warning('Sidecar parse failed; restarting fresh: $e');
      }
      // Fallthrough — drop both the sparse file and the sidecar.
      try {
        if (await file.exists()) await file.delete();
        if (await sidecar.exists()) await sidecar.delete();
      } catch (_) {/* best effort */}
    }
    return _DownloadState.fresh(
      totalBytes: totalBytes,
      workerCount: workerCount,
    );
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
    final sidecar = File('${file.path}.parts');
    if (await sidecar.exists()) {
      await sidecar.delete();
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
      // The CSV's column is `nutriscore_grade` (verified against
      // OFF's 2026 dump). The legacy `nutrition_grade_fr` /
      // `nutrition_grades` names are kept as fallbacks because the
      // API path's response surface uses `nutrition_grades`, and a
      // future schema change might bring it back here. Trying all
      // three is cheap.
      final grade = _cell(row, idx, 'nutriscore_grade') ??
          _cell(row, idx, 'nutrition_grade_fr') ??
          _cell(row, idx, 'nutrition_grades');
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

    // The CSV dump has a single `product_name` column rather than
    // the per-language `product_name_en` / `product_name_de` / etc.
    // that the live API exposes. We populate the generic field from
    // the CSV and leave the localised fields null; the meal entity's
    // `getLocaleName` fallback chain will pick up the generic name
    // for every locale.
    final productName = _cell(row, idx, 'product_name');

    final json = <String, dynamic>{
      'code': code,
      'product_name': productName,
      'product_name_en': null,
      'product_name_de': null,
      'product_name_fr': null,
      'brands': _cell(row, idx, 'brands'),
      // The CSV publishes `image_url` and `image_small_url` (the
      // front photo of each product). It does NOT publish the
      // `image_front_url` family the live API does. Map both into
      // the DTO's image-front slots so downstream code that asks
      // for the front-thumb or front-full URL gets the same image.
      'image_front_thumb_url': _cell(row, idx, 'image_small_url') ??
          _cell(row, idx, 'image_url'),
      'image_front_url': _cell(row, idx, 'image_url'),
      'image_ingredients_url': _cell(row, idx, 'image_ingredients_url'),
      'image_nutrition_url': _cell(row, idx, 'image_nutrition_url'),
      'image_url': _cell(row, idx, 'image_url'),
      'url': _cell(row, idx, 'url'),
      'quantity': _cell(row, idx, 'quantity'),
      'product_quantity': _toDouble(_cell(row, idx, 'product_quantity')),
      'serving_quantity': _toDouble(_cell(row, idx, 'serving_quantity')),
      'serving_size': _cell(row, idx, 'serving_size'),
      'nutriments': nutriments,
      // OFF's per-row last-modified epoch. The catalog data source
      // uses this to short-circuit upserts on refresh: if the row
      // already exists with the same value, we just bump fetched_at
      // and skip the (much costlier) data write + FTS reindex.
      'last_modified_t': _toInt(_cell(row, idx, 'last_modified_t')),
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
