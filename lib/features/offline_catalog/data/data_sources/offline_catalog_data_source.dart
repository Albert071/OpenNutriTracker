import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// On-device SQLite catalog of OFF products.
///
/// We keep one row per product. The full [OFFProductDTO] is serialised
/// into a JSON [_kColData] column so the live-API mapping path
/// (`MealEntity.fromOFFProduct`) is reused verbatim — there is no
/// second mapping layer to drift out of sync. Only the columns we
/// actually need for FTS lookup or refresh bookkeeping are
/// denormalised: name fields, brands, the OFF `last_modified_t`,
/// and a local [_kColFetchedAt] timestamp.
///
/// The catalog file lives next to the app's documents directory rather
/// than inside the encrypted Hive store: OFF data is public, the user
/// did the work of downloading it, and there is no privacy benefit to
/// encrypting it. The user's intake history, profile, and recipes stay
/// in the encrypted Hive boxes, untouched.
class OfflineCatalogDataSource {
  static const _dbFilename = 'offline_catalog.db';
  static const _schemaVersion = 1;

  static const _kTableProducts = 'products';
  static const _kTableProductsFts = 'products_fts';
  static const _kTableMeta = 'catalog_meta';

  static const _kColCode = 'code';
  static const _kColProductName = 'product_name';
  static const _kColProductNameEn = 'product_name_en';
  static const _kColProductNameDe = 'product_name_de';
  static const _kColProductNameFr = 'product_name_fr';
  static const _kColBrands = 'brands';
  static const _kColData = 'data';
  static const _kColLastModifiedT = 'last_modified_t';
  static const _kColFetchedAt = 'fetched_at';

  /// Meta keys we read/write. Listed here so callers don't sprinkle
  /// magic strings around.
  static const metaKeySchemaVersion = 'schema_version';
  static const metaKeyLastFullSync = 'last_full_sync_t';
  static const metaKeyFiltersJson = 'filters_json';
  static const metaKeyBuildCursor = 'build_cursor';
  static const metaKeyTotalCount = 'total_count';
  static const metaKeyCountriesTaxonomyJson = 'countries_taxonomy_json';
  static const metaKeyCountriesTaxonomyFetchedAt =
      'countries_taxonomy_fetched_at';

  final _log = Logger('OfflineCatalogDataSource');

  Database? _db;
  String? _dbPath;
  Future<Database>? _opening;

  /// True between [beginBulkInsertSession] and [endBulkInsertSession].
  /// While set, [upsertBatch] skips its per-row FTS5 delete-and-
  /// reinsert (the FTS index is rebuilt from scratch by
  /// [endBulkInsertSession]) and the data source uses fast-but-
  /// non-durable sqlite pragmas. See those two methods for the full
  /// trade.
  bool _bulkSessionActive = false;

  /// Resolve the database file path. Visible for tests; production
  /// callers should rely on [_database] which uses this internally.
  Future<String> resolveDbPath() async {
    if (_dbPath != null) return _dbPath!;
    final dir = await getApplicationDocumentsDirectory();
    return _dbPath = p.join(dir.path, _dbFilename);
  }

  Future<Database> _database() {
    final existing = _db;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final path = await resolveDbPath();
    _log.fine('Opening offline catalog at $path');
    // We deliberately do not pass sqflite's `version: / onCreate: /
    // onUpgrade:` machinery. Catalogs we download from the CDN come
    // with their schema already shipped (and may be a higher minor
    // than this client knows about — the schema convention is that
    // higher minors only add tables/columns, never rename or remove
    // them). Letting sqflite manage `PRAGMA user_version` would force
    // us into its rigid migrate-or-downgrade flow against artefacts
    // it didn't create. Instead, after the open succeeds we run an
    // idempotent CREATE-IF-NOT-EXISTS pass so a brand-new install
    // (no downloaded catalog yet) gets an empty schema and any
    // already-populated catalog is left untouched.
    final db = await openDatabase(
      path,
      onConfigure: (db) async {
        // WAL gives us atomic writes plus better insert speed if we
        // ever go back to writing rows on-device. Synchronous=NORMAL
        // is the right choice for WAL: durable across app crashes,
        // only loses recent data on hard kernel/power failure.
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
      },
    );
    await _ensureSchema(db);
    _db = db;
    return db;
  }

  /// Idempotent schema creation. Runs after every open. For a
  /// downloaded catalog the build script already shipped these tables
  /// and the CREATE-IF-NOT-EXISTS calls are no-ops; for a brand-new
  /// install with no catalog yet they materialise an empty shape so
  /// `count() == 0` and getStats falls through cleanly.
  ///
  /// Forward compatibility: a future build that adds columns or
  /// tables we don't know about will leave them in place — sqlite
  /// has no notion of "drop this thing the client didn't define"
  /// and our queries name specific columns, so the unknown bits sit
  /// quietly in the file. Major-version bumps that rename or remove
  /// what we depend on are caught upstream by
  /// [CatalogDownloadDataSource._verifyStagedSchema], which refuses
  /// to install them.
  Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kTableProducts (
        $_kColCode TEXT PRIMARY KEY NOT NULL,
        $_kColProductName TEXT,
        $_kColProductNameEn TEXT,
        $_kColProductNameDe TEXT,
        $_kColProductNameFr TEXT,
        $_kColBrands TEXT,
        $_kColData TEXT NOT NULL,
        $_kColLastModifiedT INTEGER,
        $_kColFetchedAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_brands '
      'ON $_kTableProducts($_kColBrands)',
    );

    // unicode61 + remove_diacritics 2 lets "creme brulee" match "crème
    // brûlée" — important for European catalogues where users won't
    // type the accents that exist in the canonical names.
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS $_kTableProductsFts USING fts5(
        $_kColCode UNINDEXED,
        $_kColProductName,
        $_kColProductNameEn,
        $_kColProductNameDe,
        $_kColProductNameFr,
        $_kColBrands,
        tokenize = 'unicode61 remove_diacritics 2'
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kTableMeta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT
      )
    ''');
    // Fresh-install fallback: if we just created an empty schema
    // (no downloaded catalog yet) seed `schema_version` with our
    // current major. INSERT OR IGNORE so a downloaded catalog that
    // already carries its own value is preserved.
    await db.rawInsert(
      'INSERT OR IGNORE INTO $_kTableMeta(key, value) VALUES (?, ?)',
      [metaKeySchemaVersion, _schemaVersion.toString()],
    );
  }

  /// Switch the database into "bulk insert" mode for the duration
  /// of a build's parse phase. The trade is durability for speed:
  ///
  /// * `synchronous=OFF` — sqlite stops fsyncing on every commit.
  ///   A power loss mid-build can lose recent rows. Fine for our
  ///   workload because (a) the build cursor will detect the crash
  ///   on next launch and we'll rebuild from the gzip on disk,
  ///   and (b) the cancelled-build sweep cleans up partial state
  ///   anyway.
  /// * `journal_mode=MEMORY` — the rollback journal lives in RAM
  ///   instead of being fsynced to disk. Same trade.
  /// * Per-row FTS5 work is suspended. [upsertBatch] checks
  ///   [_bulkSessionActive] and skips the FTS delete + insert pair
  ///   for every row. The index is rebuilt in one pass by
  ///   [endBulkInsertSession] when the build completes
  ///   successfully.
  ///
  /// Must be balanced with exactly one [endBulkInsertSession] call
  /// — even on failure paths.
  Future<void> beginBulkInsertSession() async {
    if (_bulkSessionActive) return;
    final db = await _database();
    // journal_mode change must happen outside any transaction —
    // sqflite's `execute` runs at the connection level.
    await db.execute('PRAGMA journal_mode=MEMORY');
    await db.execute('PRAGMA synchronous=OFF');
    _bulkSessionActive = true;
    _log.info('Bulk insert session begun (FTS suspended, '
        'pragmas relaxed)');
  }

  /// Close the bulk-insert session and (when [rebuildFts] is true)
  /// rebuild the FTS5 index in a single bulk INSERT from the
  /// products table. Always restores the safe pragmas.
  ///
  /// On a successful build the caller passes `rebuildFts: true`.
  /// On a cancel / error path the caller passes `rebuildFts: false`
  /// — the FTS index is left empty and the next successful build
  /// will repopulate it. (Search returns zero results in the
  /// meantime, which is honest about what's actually on disk.)
  Future<void> endBulkInsertSession({required bool rebuildFts}) async {
    if (!_bulkSessionActive) return;
    final db = await _database();
    try {
      if (rebuildFts) {
        // Wipe whatever's left in the FTS index (could be stale
        // from before the session) and repopulate from the products
        // table in a single statement. SQLite's bulk INSERT INTO ...
        // SELECT is dramatically faster than per-row inserts even
        // when the row count matches.
        await db.execute('DELETE FROM $_kTableProductsFts');
        await db.rawInsert(
          'INSERT INTO $_kTableProductsFts ('
          '$_kColCode, $_kColProductName, $_kColProductNameEn, '
          '$_kColProductNameDe, $_kColProductNameFr, $_kColBrands'
          ') '
          'SELECT $_kColCode, '
          'COALESCE($_kColProductName, \'\'), '
          'COALESCE($_kColProductNameEn, \'\'), '
          'COALESCE($_kColProductNameDe, \'\'), '
          'COALESCE($_kColProductNameFr, \'\'), '
          'COALESCE($_kColBrands, \'\') '
          'FROM $_kTableProducts',
        );
        _log.info('FTS5 index rebuilt from products table');
      }
    } finally {
      // Always restore the safe pragmas even if the FTS rebuild
      // threw. Leaving synchronous=OFF in effect across normal
      // operation would put user data at risk.
      await db.execute('PRAGMA synchronous=NORMAL');
      await db.execute('PRAGMA journal_mode=WAL');
      _bulkSessionActive = false;
      _log.info('Bulk insert session ended (pragmas restored)');
    }
  }

  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
    }
    _db = null;
    _opening = null;
  }

  /// Bulk-insert (or replace) a page of products. Wrapped in a single
  /// transaction so a partially-written page never lands on disk; the
  /// builder also commits its [metaKeyBuildCursor] inside the same
  /// transaction so resume is atomic.
  ///
  /// **Refresh short-circuit.** OFF stamps every product with a
  /// `last_modified_t` (epoch seconds). When the incoming row's
  /// value matches what we already have stored for the same `code`,
  /// the data is unchanged and we skip the JSON write + FTS reindex
  /// — we just bump `fetched_at` so the post-build stale-row sweep
  /// doesn't drop the row. On a typical refresh against a UK
  /// catalogue this turns ~30k full row replacements into ~30k
  /// cheap "touch" updates, with full writes only for rows OFF
  /// has actually changed.
  Future<void> upsertBatch(
    Iterable<OFFProductDTO> products, {
    Map<String, String>? metaUpdates,
  }) async {
    final productsList = products.toList(growable: false);
    final db = await _database();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      // Pre-fetch existing `last_modified_t` for the codes in this
      // batch in a single SELECT. Lookups in subsequent loop
      // iterations are O(1) against the resulting Map.
      final codes = <String>[];
      for (final dto in productsList) {
        final code = dto.code;
        if (code == null || code.isEmpty) continue;
        codes.add(code);
      }
      final existingLastModified = <String, int?>{};
      if (codes.isNotEmpty) {
        // Avoid a single SELECT with thousands of placeholders by
        // chunking. SQLite tolerates large IN lists but most drivers
        // cap parameter counts at 999; we stay safely under that.
        const chunkSize = 500;
        for (var i = 0; i < codes.length; i += chunkSize) {
          final slice = codes.sublist(
            i,
            i + chunkSize > codes.length ? codes.length : i + chunkSize,
          );
          final placeholders = List.filled(slice.length, '?').join(',');
          final rows = await txn.rawQuery(
            'SELECT $_kColCode, $_kColLastModifiedT '
            'FROM $_kTableProducts '
            'WHERE $_kColCode IN ($placeholders)',
            slice,
          );
          for (final row in rows) {
            existingLastModified[row[_kColCode] as String] =
                row[_kColLastModifiedT] as int?;
          }
        }
      }

      final batch = txn.batch();
      final touchOnlyCodes = <String>[];

      for (final dto in productsList) {
        final code = dto.code;
        if (code == null || code.isEmpty) continue;

        final incomingLm = _coerceInt(dto.last_modified_t);
        final existingLm = existingLastModified[code];

        // Touch-only path: row is in the catalog already, with the
        // same `last_modified_t`. The data hasn't changed; we just
        // re-stamp `fetched_at` so the sweep keeps it.
        final unchanged = incomingLm != null &&
            existingLm != null &&
            incomingLm == existingLm;
        if (unchanged) {
          touchOnlyCodes.add(code);
          continue;
        }

        // Full-write path: new code, or row's `last_modified_t`
        // differs (typically newer). Replace the row + (outside a
        // bulk session) reindex FTS.
        final json = jsonEncode(dto.toJson());
        batch.insert(
          _kTableProducts,
          {
            _kColCode: code,
            _kColProductName: dto.product_name,
            _kColProductNameEn: dto.product_name_en,
            _kColProductNameDe: dto.product_name_de,
            _kColProductNameFr: dto.product_name_fr,
            _kColBrands: dto.brands,
            _kColData: json,
            _kColLastModifiedT: incomingLm,
            _kColFetchedAt: now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        // Inside a bulk-insert session the FTS index is rebuilt in
        // one shot at the end (see [endBulkInsertSession]), so we
        // skip the per-row FTS work — that's where the bulk of the
        // parse-phase speedup comes from.
        if (_bulkSessionActive) continue;
        // FTS5 has no native "upsert" — delete + insert keeps it in
        // sync with the products table on every write.
        batch.delete(
          _kTableProductsFts,
          where: '$_kColCode = ?',
          whereArgs: [code],
        );
        batch.insert(_kTableProductsFts, {
          _kColCode: code,
          _kColProductName: dto.product_name ?? '',
          _kColProductNameEn: dto.product_name_en ?? '',
          _kColProductNameDe: dto.product_name_de ?? '',
          _kColProductNameFr: dto.product_name_fr ?? '',
          _kColBrands: dto.brands ?? '',
        });
      }

      // Single bulk UPDATE to bump fetched_at on all touch-only
      // codes. Drives the sweep's "did we see this row again this
      // build?" signal without rewriting any data or FTS state.
      if (touchOnlyCodes.isNotEmpty) {
        const chunkSize = 500;
        for (var i = 0; i < touchOnlyCodes.length; i += chunkSize) {
          final slice = touchOnlyCodes.sublist(
            i,
            i + chunkSize > touchOnlyCodes.length
                ? touchOnlyCodes.length
                : i + chunkSize,
          );
          final placeholders = List.filled(slice.length, '?').join(',');
          batch.rawUpdate(
            'UPDATE $_kTableProducts SET $_kColFetchedAt = ? '
            'WHERE $_kColCode IN ($placeholders)',
            [now, ...slice],
          );
        }
      }

      if (metaUpdates != null) {
        for (final entry in metaUpdates.entries) {
          batch.insert(
            _kTableMeta,
            {'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  /// Delete rows whose [_kColFetchedAt] is strictly older than
  /// [cutoffMillis]. Used by the build path as a sweep step after a
  /// successful refresh / filter-change rerun:
  ///
  /// 1. Build start time is captured.
  /// 2. Every row written during the build picks up a `fetched_at`
  ///    that's >= build start.
  /// 3. After the parse phase completes, this method drops any row
  ///    whose `fetched_at` is older than the build start — those are
  ///    products that no longer pass the user's filters, or that OFF
  ///    has dropped from its dataset since the previous build.
  ///
  /// Returns the number of rows removed. The matching FTS5 entries
  /// are deleted in the same transaction so the index never points
  /// at gone rows.
  Future<int> deleteStaleRows(int cutoffMillis) async {
    final db = await _database();
    return await db.transaction((txn) async {
      // FTS5 has no foreign-key cascade — we delete from it
      // explicitly, looking up the codes we're about to drop from
      // the main table.
      await txn.rawDelete(
        '''
          DELETE FROM $_kTableProductsFts
          WHERE $_kColCode IN (
            SELECT $_kColCode FROM $_kTableProducts
            WHERE $_kColFetchedAt < ?
          )
        ''',
        [cutoffMillis],
      );
      return await txn.delete(
        _kTableProducts,
        where: '$_kColFetchedAt < ?',
        whereArgs: [cutoffMillis],
      );
    });
  }

  /// Delete rows whose code is in [codes]. Used by the refresh path to
  /// drop products OFF has marked obsolete.
  Future<void> deleteByCodes(Iterable<String> codes) async {
    final list = codes.where((c) => c.isNotEmpty).toList();
    if (list.isEmpty) return;
    final db = await _database();
    await db.transaction((txn) async {
      final placeholders = List.filled(list.length, '?').join(',');
      await txn.delete(
        _kTableProducts,
        where: '$_kColCode IN ($placeholders)',
        whereArgs: list,
      );
      await txn.delete(
        _kTableProductsFts,
        where: '$_kColCode IN ($placeholders)',
        whereArgs: list,
      );
    });
  }

  /// Look up a single product by barcode/code. Returns null when the
  /// catalog has no row for it — the caller falls back to the live API.
  Future<OFFProductDTO?> getByCode(String code) async {
    if (code.isEmpty) return null;
    final db = await _database();
    final rows = await db.query(
      _kTableProducts,
      columns: [_kColData],
      where: '$_kColCode = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeProduct(rows.first[_kColData] as String);
  }

  /// Full-text search across all four name columns plus brands. The
  /// query is split on whitespace; each non-empty token gets a `*`
  /// suffix so prefix matches work as the user types.
  ///
  /// FTS5's `MATCH` accepts the query string verbatim, so we sanitise
  /// any embedded quotes / control characters out before splitting.
  Future<List<OFFProductDTO>> searchByText(
    String query, {
    int limit = 50,
  }) async {
    final cleaned = _normaliseFtsQuery(query);
    if (cleaned.isEmpty) return const [];
    final db = await _database();
    final rows = await db.rawQuery(
      '''
        SELECT p.$_kColData
        FROM $_kTableProducts p
        JOIN $_kTableProductsFts f ON f.$_kColCode = p.$_kColCode
        WHERE $_kTableProductsFts MATCH ?
        ORDER BY rank
        LIMIT ?
      ''',
      [cleaned, limit],
    );
    return [
      for (final row in rows) _decodeProduct(row[_kColData] as String),
    ];
  }

  Future<int> count() async {
    final db = await _database();
    final result =
        await db.rawQuery('SELECT COUNT(*) AS c FROM $_kTableProducts');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Count rows whose [_kColFetchedAt] is at or after [sinceMillis].
  /// Used by the repository's wipe-protection guard to verify that
  /// a build wrote enough rows before the sweep applies — a tiny
  /// "kept" count vs a large pre-existing catalogue means something
  /// went wrong upstream (typically an OFF schema change).
  Future<int> countWrittenSince(int sinceMillis) async {
    final db = await _database();
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_kTableProducts '
      'WHERE $_kColFetchedAt >= ?',
      [sinceMillis],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// On-disk size in bytes. Sums the .db file plus any WAL/SHM
  /// sidecars SQLite may have spilled to. Returns 0 when the file
  /// doesn't exist yet (catalog never built).
  Future<int> sizeBytes() async {
    final path = await resolveDbPath();
    var total = 0;
    for (final candidate in [path, '$path-wal', '$path-shm']) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      total += await file.length();
    }
    return total;
  }

  /// Drop the entire catalog. Closes the open database first so the
  /// OS lets us delete the file on Windows; no-op when the catalog
  /// doesn't exist on disk.
  Future<void> clear() async {
    await close();
    final path = await resolveDbPath();
    for (final candidate in [path, '$path-wal', '$path-shm']) {
      final file = File(candidate);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<String?> getMeta(String key) async {
    final db = await _database();
    final rows = await db.query(
      _kTableMeta,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String? value) async {
    final db = await _database();
    if (value == null) {
      await db.delete(_kTableMeta, where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert(
      _kTableMeta,
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  OFFProductDTO _decodeProduct(String json) =>
      OFFProductDTO.fromJson(jsonDecode(json) as Map<String, dynamic>);

  /// Coerce the stringly-/dynamically-typed `last_modified_t` value
  /// off an [OFFProductDTO] to a clean int. CSV rows arrive as
  /// strings, live API responses as ints; either becomes a Dart int
  /// here so the comparison in [upsertBatch] is type-safe.
  static int? _coerceInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Strip FTS5 query special characters and append `*` to every
  /// non-empty token for prefix matching as the user types.
  String _normaliseFtsQuery(String raw) {
    final sanitised = raw.replaceAll(RegExp(r'["\(\)\*:]'), ' ').trim();
    if (sanitised.isEmpty) return '';
    final tokens = sanitised
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '$t*')
        .toList();
    return tokens.join(' ');
  }
}
