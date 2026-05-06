import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_csv_dump_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';

/// Tab-separated CSV header used by these tests. Mirrors the column
/// names the OFF dump publishes for the fields we care about. Adding
/// columns to the production projection means adding them here too.
const _header = [
  'code',
  'product_name',
  'product_name_en',
  'product_name_de',
  'product_name_fr',
  'brands',
  'categories_tags',
  'countries_tags',
  'nutrition_grade_fr',
  'unique_scans_n',
  'completeness',
  'last_modified_t',
  'obsolete',
  'product_quantity',
  'quantity',
  'serving_quantity',
  'serving_size',
  'image_front_url',
  'energy-kcal_100g',
  'proteins_100g',
  'carbohydrates_100g',
  'fat_100g',
];

String _headerLine() => _header.join('\t');

/// Build a CSV row from a sparse map of column-name → value. Any
/// column not in the map is left empty. Keeps the test rows readable
/// — only the cells that matter for the case under test are
/// specified, the rest fall through to the always-on filter
/// defaults.
String _row(Map<String, String> cells) {
  final out = <String>[];
  for (final col in _header) {
    out.add(cells[col] ?? '');
  }
  return out.join('\t');
}

/// A "good" UK product that survives every filter at default
/// settings. Tests start from this and mutate one field at a time
/// to verify each filter rule in isolation.
String _goodUkRow({
  String code = '5012345678901',
  String? country = 'en:united-kingdom',
  String? grade = 'a',
  String? scans = '12',
  String? completeness = '0.65',
  String? obsolete = '0',
  String? lastModified,
  String? categories = 'en:foods,en:beverages',
}) {
  // Default last_modified_t to "yesterday" so the recency filter
  // doesn't drop it accidentally.
  final yesterday =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) - (24 * 60 * 60);
  return _row({
    'code': code,
    'product_name': 'Bourbon Biscuits',
    'product_name_en': 'Bourbon Biscuits',
    'brands': 'Test Brand',
    'categories_tags': categories ?? '',
    'countries_tags': country ?? '',
    'nutrition_grade_fr': grade ?? '',
    'unique_scans_n': scans ?? '',
    'completeness': completeness ?? '',
    'last_modified_t': lastModified ?? yesterday.toString(),
    'obsolete': obsolete ?? '',
    'product_quantity': '300',
    'quantity': '300 g',
    'serving_size': '4 biscuits (28 g)',
    'image_front_url': 'https://images.openfoodfacts.org/x/front_en.jpg',
    'energy-kcal_100g': '480',
    'proteins_100g': '6.5',
    'carbohydrates_100g': '70',
    'fat_100g': '20',
  });
}

CatalogFilterEntity _filter({
  Set<String>? countries,
  bool requireNutritionGrade = true,
  bool requireMinPopularity = true,
  Duration? maxAge = const Duration(days: 365 * 5),
}) =>
    CatalogFilterEntity(
      countries: countries ?? const {'en:united-kingdom'},
      requireNutritionGrade: requireNutritionGrade,
      requireMinPopularity: requireMinPopularity,
      maxAge: maxAge,
    );

void main() {
  late OffCsvDumpDataSource source;

  setUp(() {
    source = OffCsvDumpDataSource();
  });

  group('OffCsvDumpDataSource.filterAndMapForTest', () {
    test('keeps a UK product that satisfies every filter', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow()],
        filter: _filter(),
      );

      expect(result, hasLength(1));
      final dto = result.single;
      expect(dto.code, '5012345678901');
      expect(dto.product_name, 'Bourbon Biscuits');
      expect(dto.brands, 'Test Brand');
      expect(dto.image_front_url,
          'https://images.openfoodfacts.org/x/front_en.jpg');
      // Nutriments survived the round-trip from the flat CSV columns
      // into the nested DTO map.
      expect(dto.nutriments, isNotNull);
      expect(dto.nutriments!.energy_kcal_100g, 480.0);
      expect(dto.nutriments!.proteins_100g, 6.5);
      expect(dto.nutriments!.fat_100g, 20.0);
    });

    test('drops a product whose country tag does not match the filter', () {
      // Filter wants UK; row is French only.
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(country: 'en:france')],
        filter: _filter(countries: {'en:united-kingdom'}),
      );
      expect(result, isEmpty);
    });

    test('keeps a row that matches any of the OR-ed country tags', () {
      // Filter wants UK or France; row is French.
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(country: 'en:france')],
        filter: _filter(countries: {'en:united-kingdom', 'en:france'}),
      );
      expect(result, hasLength(1));
    });

    test('keeps any country when the country filter is empty', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(country: 'en:france')],
        filter: _filter(countries: const {}),
      );
      expect(result, hasLength(1));
    });

    test('drops a pet-food row regardless of user filters', () {
      final petRow = _goodUkRow(
        categories: 'en:foods,en:pet-food,en:dog-food',
      );
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), petRow],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('drops a cosmetics row regardless of user filters', () {
      final cosmeticsRow = _goodUkRow(
        categories: 'en:cosmetics,en:lipstick',
      );
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), cosmeticsRow],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('drops a row with completeness below the always-on threshold', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(completeness: '0.2')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('drops a row whose completeness column is empty', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(completeness: '')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('drops a row marked obsolete', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(obsolete: '1')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('drops a row with unknown nutrition grade when toggle is on', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(grade: 'unknown')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('keeps a row with unknown nutrition grade when toggle is off', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(grade: 'unknown')],
        filter: _filter(requireNutritionGrade: false),
      );
      expect(result, hasLength(1));
    });

    test('drops a one-time-scanned row when popularity toggle is on', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(scans: '1')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('keeps a one-time-scanned row when popularity toggle is off', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(scans: '1')],
        filter: _filter(requireMinPopularity: false),
      );
      expect(result, hasLength(1));
    });

    test('drops a row whose last-modified is older than the recency window',
        () {
      final tenYearsAgo = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
          (10 * 365 * 24 * 60 * 60);
      final result = source.filterAndMapForTest(
        lines: [
          _headerLine(),
          _goodUkRow(lastModified: tenYearsAgo.toString()),
        ],
        // 5-year recency window — 10y old row is too stale.
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('keeps an old row when the recency window is set to "any"', () {
      final tenYearsAgo = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
          (10 * 365 * 24 * 60 * 60);
      final result = source.filterAndMapForTest(
        lines: [
          _headerLine(),
          _goodUkRow(lastModified: tenYearsAgo.toString()),
        ],
        filter: _filter(maxAge: null),
      );
      expect(result, hasLength(1));
    });

    test('processes a mixed batch and keeps only the survivors', () {
      final lines = [
        _headerLine(),
        _goodUkRow(code: 'keep-1'),
        _goodUkRow(code: 'drop-pet', categories: 'en:foods,en:pet-food'),
        _goodUkRow(code: 'drop-fr', country: 'en:france'),
        _goodUkRow(code: 'keep-2'),
        _goodUkRow(code: 'drop-low-pop', scans: '1'),
        _goodUkRow(code: 'drop-low-comp', completeness: '0.1'),
        _goodUkRow(code: 'drop-obsolete', obsolete: '1'),
      ];
      final kept = source.filterAndMapForTest(
        lines: lines,
        filter: _filter(),
      );
      expect(kept.map((d) => d.code), unorderedEquals(['keep-1', 'keep-2']));
    });

    test('handles an empty input gracefully', () {
      expect(source.filterAndMapForTest(lines: const [], filter: _filter()),
          isEmpty);
    });

    test('header-only input produces no rows', () {
      expect(
        source.filterAndMapForTest(
          lines: [_headerLine()],
          filter: _filter(),
        ),
        isEmpty,
      );
    });

    test('drops a row with no `code` even if every other filter passes', () {
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(code: '')],
        filter: _filter(),
      );
      expect(result, isEmpty);
    });

    test('country tag matching is exact, not substring', () {
      // Filter wants `en:france`; row is tagged `en:french-polynesia`.
      // A naive substring match would incorrectly accept this; we
      // split on commas and compare full tags so the row is dropped.
      final result = source.filterAndMapForTest(
        lines: [_headerLine(), _goodUkRow(country: 'en:french-polynesia')],
        filter: _filter(countries: const {'en:france'}),
      );
      expect(result, isEmpty);
    });
  });
}
