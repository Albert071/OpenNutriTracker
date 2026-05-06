import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_nutriments_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

OFFProductDTO _dto(
  String code, {
  String name = 'Test',
  int? lastModifiedT,
  num? kcal = 100,
}) =>
    OFFProductDTO(
      code: code,
      product_name: name,
      product_name_en: null,
      product_name_de: null,
      product_name_fr: null,
      brands: 'Brand',
      image_front_thumb_url: null,
      image_front_url: null,
      image_ingredients_url: null,
      image_nutrition_url: null,
      image_url: null,
      url: null,
      quantity: null,
      product_quantity: null,
      serving_quantity: null,
      serving_size: null,
      nutriments: OFFProductNutrimentsDTO(
        energy_kcal_100g: kcal,
        carbohydrates_100g: null,
        fat_100g: null,
        proteins_100g: null,
        sugars_100g: null,
        saturated_fat_100g: null,
        fiber_100g: null,
      ),
      last_modified_t: lastModifiedT,
    );

void main() {
  // Sqflite FFI for unit tests outside the Flutter binding. Same
  // setup as `lib/main.dart` does for desktop runtimes.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('OfflineCatalogDataSource.deleteStaleRows', () {
    late Directory tmp;
    late OfflineCatalogDataSource source;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('offline-catalog-test-');
      // Point the source at a temp file by overriding the path
      // resolution. The data source uses path_provider in
      // production; in tests we patch the lookup by writing the
      // file at the resolved location ourselves before the source
      // opens its db. Simpler: subclass with the override.
      source = _TestDataSource(p.join(tmp.path, 'test_catalog.db'));
    });

    tearDown(() async {
      await source.close();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('drops only rows whose fetched_at is strictly older than cutoff',
        () async {
      // Write three rows. Sleep between writes so each gets a
      // distinct `fetched_at` timestamp. The data source stamps
      // `fetched_at` from `DateTime.now()` inside upsertBatch, so
      // we need a real wall-clock delay (not a mock).
      await source.upsertBatch([_dto('aaa', name: 'old-1')]);
      await Future.delayed(const Duration(milliseconds: 30));
      await source.upsertBatch([_dto('bbb', name: 'old-2')]);
      await Future.delayed(const Duration(milliseconds: 30));
      final cutoff = DateTime.now().millisecondsSinceEpoch;
      await Future.delayed(const Duration(milliseconds: 30));
      await source.upsertBatch([_dto('ccc', name: 'fresh')]);

      expect(await source.count(), 3);

      final removed = await source.deleteStaleRows(cutoff);
      expect(removed, 2,
          reason: 'old-1 and old-2 are pre-cutoff; fresh row stays');
      expect(await source.count(), 1);

      final survivor = await source.getByCode('ccc');
      expect(survivor, isNotNull);
      expect(survivor!.product_name, 'fresh');

      final goneA = await source.getByCode('aaa');
      final goneB = await source.getByCode('bbb');
      expect(goneA, isNull);
      expect(goneB, isNull);
    });

    test('also deletes the matching FTS5 entries', () async {
      await source.upsertBatch([_dto('aaa', name: 'Yoghurt')]);
      await Future.delayed(const Duration(milliseconds: 30));
      final cutoff = DateTime.now().millisecondsSinceEpoch;
      await Future.delayed(const Duration(milliseconds: 30));
      await source.upsertBatch([_dto('bbb', name: 'Yorkshire pudding')]);

      // Both rows match a "Yo" prefix search before the sweep.
      final beforeSweep = await source.searchByText('Yo');
      expect(beforeSweep.map((d) => d.code), containsAll(['aaa', 'bbb']));

      await source.deleteStaleRows(cutoff);

      // After sweep only 'bbb' remains. If the FTS index were not
      // kept in lockstep with the main table, the search would
      // still return a phantom hit for 'aaa' even though the
      // products row is gone.
      final afterSweep = await source.searchByText('Yo');
      expect(afterSweep.map((d) => d.code), ['bbb']);
    });

    test('returns zero when no rows are old enough to drop', () async {
      await source.upsertBatch([_dto('aaa')]);
      await source.upsertBatch([_dto('bbb')]);

      final cutoff = 1; // Far in the past.
      final removed = await source.deleteStaleRows(cutoff);
      expect(removed, 0);
      expect(await source.count(), 2);
    });

    test('treats a re-upsert as a re-stamp — row survives sweep', () async {
      // Models the "filter change keeps overlapping rows" case:
      // the row was written by a previous build, the new build
      // re-encounters it (passes the new filters), upsertBatch
      // bumps its fetched_at. The post-build sweep should not
      // drop it.
      await source.upsertBatch([_dto('shared', name: 'old version')]);
      await Future.delayed(const Duration(milliseconds: 30));
      final newBuildStart = DateTime.now().millisecondsSinceEpoch;
      await Future.delayed(const Duration(milliseconds: 30));
      // New build re-writes the same code with refreshed data.
      await source.upsertBatch([_dto('shared', name: 'new version')]);

      await source.deleteStaleRows(newBuildStart);

      final survivor = await source.getByCode('shared');
      expect(survivor, isNotNull);
      expect(survivor!.product_name, 'new version');
    });
  });

  group('OfflineCatalogDataSource.upsertBatch (last_modified_t short-circuit)',
      () {
    late Directory tmp;
    late OfflineCatalogDataSource source;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('offline-catalog-lm-');
      source = _TestDataSource(p.join(tmp.path, 'test_catalog.db'));
    });

    tearDown(() async {
      await source.close();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('full-writes a brand-new row', () async {
      await source.upsertBatch(
        [_dto('aaa', name: 'fresh', lastModifiedT: 1700000000)],
      );
      final stored = await source.getByCode('aaa');
      expect(stored, isNotNull);
      expect(stored!.product_name, 'fresh');
      expect(stored.last_modified_t, 1700000000);
    });

    test(
      're-upserting with an unchanged last_modified_t is touch-only — '
      'data is preserved, only fetched_at advances',
      () async {
        // First write: stash the original product data.
        await source.upsertBatch(
          [
            _dto(
              'aaa',
              name: 'original name',
              kcal: 480,
              lastModifiedT: 1700000000,
            ),
          ],
        );
        await Future.delayed(const Duration(milliseconds: 30));
        final boundary = DateTime.now().millisecondsSinceEpoch;
        await Future.delayed(const Duration(milliseconds: 30));

        // Second write: SAME last_modified_t but diverging data.
        // The short-circuit should detect the row is unchanged
        // upstream and skip the data write — so the divergent
        // payload here is intentionally never persisted.
        await source.upsertBatch(
          [
            _dto(
              'aaa',
              name: 'POISONED PAYLOAD',
              kcal: 1,
              lastModifiedT: 1700000000,
            ),
          ],
        );

        final stored = await source.getByCode('aaa');
        expect(
          stored!.product_name,
          'original name',
          reason: 'data write should be skipped on unchanged last_modified_t',
        );
        expect(stored.nutriments?.energy_kcal_100g, 480);

        // But the row WAS touched — so a sweep cutting at the
        // boundary keeps it.
        final removed = await source.deleteStaleRows(boundary);
        expect(removed, 0);
        expect(await source.count(), 1);
      },
    );

    test(
      're-upserting with a newer last_modified_t triggers a full write '
      'and the new payload lands',
      () async {
        await source.upsertBatch(
          [_dto('aaa', name: 'old', kcal: 480, lastModifiedT: 1700000000)],
        );
        await source.upsertBatch(
          [_dto('aaa', name: 'updated', kcal: 475, lastModifiedT: 1800000000)],
        );

        final stored = await source.getByCode('aaa');
        expect(stored!.product_name, 'updated');
        expect(stored.nutriments?.energy_kcal_100g, 475);
        expect(stored.last_modified_t, 1800000000);
      },
    );

    test(
      'falls back to full-write when the existing row has no '
      'last_modified_t (legacy row written before this column was '
      'populated)',
      () async {
        // Simulate a pre-optimisation row by writing without a
        // last_modified_t, then re-upserting with one. The first
        // write goes through the same code path and stores null;
        // the second should detect the null and full-write so the
        // column is backfilled going forward.
        await source.upsertBatch([_dto('aaa', name: 'legacy')]);
        await source.upsertBatch(
          [_dto('aaa', name: 'modern', lastModifiedT: 1800000000)],
        );

        final stored = await source.getByCode('aaa');
        expect(stored!.product_name, 'modern');
        expect(stored.last_modified_t, 1800000000);
      },
    );

    test(
      'falls back to full-write when the incoming row has no '
      'last_modified_t (e.g. live API path with no projection of '
      'that field)',
      () async {
        await source.upsertBatch(
          [_dto('aaa', name: 'old', lastModifiedT: 1700000000)],
        );
        // Live API path — no last_modified_t.
        await source.upsertBatch([_dto('aaa', name: 'live api refresh')]);

        final stored = await source.getByCode('aaa');
        expect(stored!.product_name, 'live api refresh');
      },
    );

    test(
      'mixed batch — partitions correctly between touch-only and '
      'full-write rows',
      () async {
        // Seed three rows with distinct last_modified_t.
        await source.upsertBatch([
          _dto('unchanged', name: 'old A', lastModifiedT: 1700000000),
          _dto('changed', name: 'old B', lastModifiedT: 1700000000),
          _dto('disappearing', name: 'old C', lastModifiedT: 1700000000),
        ]);
        await Future.delayed(const Duration(milliseconds: 30));
        final boundary = DateTime.now().millisecondsSinceEpoch;
        await Future.delayed(const Duration(milliseconds: 30));

        // Refresh batch:
        // - 'unchanged' arrives with the same last_modified_t →
        //   touch-only.
        // - 'changed' arrives with a newer last_modified_t →
        //   full-write.
        // - 'new' is a brand-new code → full-write.
        // - 'disappearing' is absent from the batch — the sweep
        //   will catch it.
        await source.upsertBatch([
          _dto('unchanged',
              name: 'POISON unchanged', lastModifiedT: 1700000000),
          _dto('changed', name: 'new B', lastModifiedT: 1800000000),
          _dto('new', name: 'new D', lastModifiedT: 1800000000),
        ]);
        await source.deleteStaleRows(boundary);

        final unchanged = await source.getByCode('unchanged');
        final changed = await source.getByCode('changed');
        final newRow = await source.getByCode('new');
        final disappearing = await source.getByCode('disappearing');

        expect(unchanged?.product_name, 'old A',
            reason: 'unchanged row keeps its original payload');
        expect(changed?.product_name, 'new B',
            reason: 'changed row picks up the newer payload');
        expect(newRow?.product_name, 'new D',
            reason: 'new row is added');
        expect(disappearing, isNull,
            reason: 'absent row is swept');
      },
    );
  });
}

/// Subclass that points the catalog at a caller-provided sqlite
/// path so tests don't depend on `path_provider` (which only works
/// inside a Flutter widget binding).
class _TestDataSource extends OfflineCatalogDataSource {
  final String _dbPath;

  _TestDataSource(this._dbPath);

  @override
  Future<String> resolveDbPath() async => _dbPath;
}
