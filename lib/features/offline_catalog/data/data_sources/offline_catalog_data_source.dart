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
    final db = await openDatabase(
      path,
      version: _schemaVersion,
      onConfigure: (db) async {
        // WAL gives us atomic writes plus much better bulk-insert speed.
        // Synchronous=NORMAL is the right choice for WAL: durable across
        // app crashes, only loses data on hard kernel/power failure.
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
      },
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
    _db = db;
    return db;
  }

  Future<void> _createSchema(Database db, int version) async {
    // The full OFFProductDTO is serialised into the [_kColData] JSON
    // blob so a forward-compatible field addition (nutriscore_grade,
    // eco_score, ingredients_text, allergens_tags, …) is just an
    // extension of the OFF `fields=` projection — the new key flows
    // straight into the JSON without any schema migration. Only fields
    // that need to be queried, sorted, or full-text searched warrant
    // their own column. Pair changes: when you add a sqlite column,
    // also extend the OFF `fields=` list in OffBulkApiDataSource so
    // refreshes and full rebuilds carry the new data forward.
    await db.execute('''
      CREATE TABLE $_kTableProducts (
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
      'CREATE INDEX idx_products_brands ON $_kTableProducts($_kColBrands)',
    );

    // unicode61 + remove_diacritics 2 lets "creme brulee" match "crème
    // brûlée" — important for European catalogues where users won't
    // type the accents that exist in the canonical names.
    await db.execute('''
      CREATE VIRTUAL TABLE $_kTableProductsFts USING fts5(
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
      CREATE TABLE $_kTableMeta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT
      )
    ''');
    await db.insert(_kTableMeta, {
      'key': metaKeySchemaVersion,
      'value': version.toString(),
    });
  }

  /// Upgrade hook for future schema changes. v1 has no migrations yet,
  /// so this is intentionally a no-op — but the callback is wired up
  /// from day one so the next migration becomes a single `if (oldVersion
  /// < N)` block rather than a refactor.
  ///
  /// Two patterns to keep in mind when this fires:
  ///
  /// * **Adding a scalar column** — `ALTER TABLE products ADD COLUMN
  ///   `name` `type``; existing rows hold NULL until the next refresh
  ///   backfills them. Pair with the OFF `fields=` projection.
  /// * **Changing the FTS5 column list** — drop and recreate
  ///   `products_fts`, then `INSERT INTO products_fts SELECT ... FROM
  ///   products` to repopulate. Fast at a few hundred thousand rows
  ///   but worth a one-time progress UI when the user opens the app
  ///   on a release that bumps the FTS shape.
  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    _log.fine('Upgrading offline catalog from v$oldVersion to v$newVersion');
    // Future migrations land here, e.g.:
    //   if (oldVersion < 2) {
    //     await db.execute('ALTER TABLE $_kTableProducts ADD COLUMN '
    //         'nutriscore_grade TEXT');
    //   }
    await db.insert(
      _kTableMeta,
      {'key': metaKeySchemaVersion, 'value': newVersion.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
  Future<void> upsertBatch(
    Iterable<OFFProductDTO> products, {
    Map<String, String>? metaUpdates,
  }) async {
    final db = await _database();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final dto in products) {
        final code = dto.code;
        if (code == null || code.isEmpty) continue;
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
            // last_modified_t is not on the DTO yet — the bulk loader
            // requests it as an extra `fields=` value and stamps it via
            // [upsertBatchWithLastModified] below. Leaving it null here
            // keeps this overload usable from tests and one-off paths.
            _kColLastModifiedT: null,
            _kColFetchedAt: now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
