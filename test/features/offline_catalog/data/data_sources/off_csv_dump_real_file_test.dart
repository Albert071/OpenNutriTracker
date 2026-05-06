@Tags(['slow'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_csv_dump_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';

/// Fixture path. The pipeline test points the data source's local
/// file resolver at this path, so the real OFF CSV gzip can sit on
/// disk under /tmp without going through Flutter's path_provider
/// (which is unavailable outside the widget binding anyway).
///
/// To run this test, first download the dump to the fixture path:
///
///   curl -A "OpenNutriTracker - dev test" -L \
///     -o /tmp/ont-csv-test/openfoodfacts.csv.gz \
///     https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz
///
/// then:
///
///   flutter test \
///     test/features/offline_catalog/data/data_sources/off_csv_dump_real_file_test.dart
///
/// Without the fixture file the test self-skips with an explanation
/// rather than failing — so a developer running the full suite
/// without the dump on disk gets a clean run, not red CI.
const _fixturePath = '/tmp/ont-csv-test/openfoodfacts.csv.gz';

void main() {
  final fixture = File(_fixturePath);
  final fixtureExists = fixture.existsSync();

  group('OffCsvDumpDataSource against the real OFF CSV dump', () {
    late OffCsvDumpDataSource source;

    setUp(() {
      source = OffCsvDumpDataSource(
        localFileResolver: () async => fixture,
      );
    });

    test(
      'streams a UK + default-filters build to completion and keeps a '
      'reasonable share of rows',
      () async {
        if (!fixtureExists) {
          markTestSkipped(
            'No fixture at $_fixturePath — see the file-level docs for '
            'how to download it before running this test.',
          );
          return;
        }

        final filter = CatalogFilterEntity(
          countries: const {'en:united-kingdom'},
        );
        final cancellation = CancellationToken();

        final kept = <OFFProductDTO>[];
        var lastBytes = 0;
        var lastRows = 0;
        var lastReportAt = DateTime.now();
        final stopwatch = Stopwatch()..start();

        await for (final progress in source.parseAndFilter(
          filter: filter,
          cancellation: cancellation,
          onBatch: (batch) async {
            kept.addAll(batch);
          },
        )) {
          lastBytes = progress.bytesDone;
          lastRows = progress.rowsScanned;
          // Periodic progress log so a human watching the test run
          // has a sense the stream is moving and isn't stuck.
          final now = DateTime.now();
          if (now.difference(lastReportAt).inSeconds >= 10) {
            lastReportAt = now;
            // ignore: avoid_print
            print(
              '  scanned ${progress.rowsScanned} rows '
              '(${(progress.bytesDone / (1024 * 1024)).toStringAsFixed(0)} MB '
              'of ${(progress.bytesTotal / (1024 * 1024)).toStringAsFixed(0)} MB), '
              'kept ${progress.rowsKept}',
            );
          }
        }

        stopwatch.stop();

        // ignore: avoid_print
        print(
          'Stream finished in ${stopwatch.elapsed} — '
          'scanned $lastRows rows, '
          'consumed ${(lastBytes / (1024 * 1024)).toStringAsFixed(0)} MB, '
          'kept ${kept.length} UK products',
        );

        // ---------- Sanity checks on the output ----------

        // The real OFF dataset has hundreds of thousands of UK
        // products. After applying the default filter set we expect
        // roughly 5k–50k survivors. The bounds are wide on purpose:
        // exact counts drift as OFF's catalogue grows.
        expect(
          kept.length,
          inInclusiveRange(2000, 200000),
          reason: 'UK + default filters should keep a meaningful but not '
              'absurd number of rows',
        );

        // Every kept row must have a code; no code = no way to look
        // it up later.
        for (final dto in kept) {
          expect(dto.code, isNotNull);
          expect(dto.code, isNotEmpty);
        }

        // Spot-check that nutriment mapping rebuilt the kcal field
        // for at least most rows. The wizard's "Has nutrition data"
        // toggle is on by default so this should be very high.
        final kcalPresent = kept
            .where((d) => d.nutriments?.energy_kcal_100g != null)
            .length;
        expect(
          kcalPresent / kept.length,
          greaterThan(0.7),
          reason: 'Most surviving rows should carry energy_kcal_100g '
              '(the nutrition-grade gate already required a grade)',
        );

        // Names should be populated in at least the English column
        // for most rows — these are UK products.
        final namedInEn = kept
            .where((d) =>
                (d.product_name_en != null && d.product_name_en!.isNotEmpty) ||
                (d.product_name != null && d.product_name!.isNotEmpty))
            .length;
        expect(
          namedInEn / kept.length,
          greaterThan(0.95),
          reason: 'UK rows should have either product_name or '
              'product_name_en populated',
        );

        // Print a couple of representative rows so a human running
        // the test has something concrete to eyeball.
        // ignore: avoid_print
        print('Sample rows:');
        for (final dto in kept.take(3)) {
          // ignore: avoid_print
          print(
            '  - ${dto.code}: ${dto.product_name ?? dto.product_name_en} '
            '(${dto.brands ?? "no brand"}) — '
            '${dto.nutriments?.energy_kcal_100g ?? "?"} kcal/100g',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  });
}
