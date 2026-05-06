import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_nutriments_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

OFFProductDTO _dto(String code, {String name = 'Test'}) => OFFProductDTO(
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
        energy_kcal_100g: 100,
        carbohydrates_100g: null,
        fat_100g: null,
        proteins_100g: null,
        sugars_100g: null,
        saturated_fat_100g: null,
        fiber_100g: null,
      ),
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
