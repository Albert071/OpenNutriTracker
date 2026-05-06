import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/ont_http_client.dart';
import 'package:opennutritracker/core/utils/retry_util.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';

/// Fetches and caches the OFF country taxonomy.
///
/// `https://world.openfoodfacts.org/countries.json?lc=<locale>` returns
/// every OFF country tag with its localised display name and a
/// best-effort product count. We fetch it once when the wizard's region
/// page loads, store the parsed result in [OfflineCatalogDataSource]'s
/// meta table, and re-use the cached copy for [_cacheTtl] before
/// re-fetching. Re-opening the wizard within that window is therefore
/// instant and offline-friendly.
///
/// On any failure (offline, 5xx, schema drift) we return the
/// [_fallbackCountries] list so the wizard remains functional. The
/// wizard surfaces a non-blocking warning when a fallback is used.
class OffTaxonomyDataSource {
  static const _baseUrl = 'world.openfoodfacts.org';
  static const _path = '/countries.json';
  static const _timeoutDuration = Duration(seconds: 30);
  static const _cacheTtl = Duration(days: 7);

  /// Hand-picked fallback when the network fetch fails on a fresh
  /// install. Twelve countries with the largest OFF catalogues — enough
  /// for the wizard to be useful without a network round trip. Counts
  /// are intentionally rounded so the user reads them as estimates
  /// rather than current truth.
  static const _fallbackCountries = <CountryTaxonomyEntry>[
    CountryTaxonomyEntry(
      code: 'en:france',
      name: 'France',
      productCount: 1500000,
    ),
    CountryTaxonomyEntry(
      code: 'en:germany',
      name: 'Germany',
      productCount: 200000,
    ),
    CountryTaxonomyEntry(
      code: 'en:united-kingdom',
      name: 'United Kingdom',
      productCount: 100000,
    ),
    CountryTaxonomyEntry(
      code: 'en:united-states',
      name: 'United States',
      productCount: 80000,
    ),
    CountryTaxonomyEntry(
      code: 'en:spain',
      name: 'Spain',
      productCount: 100000,
    ),
    CountryTaxonomyEntry(
      code: 'en:italy',
      name: 'Italy',
      productCount: 100000,
    ),
    CountryTaxonomyEntry(
      code: 'en:belgium',
      name: 'Belgium',
      productCount: 80000,
    ),
    CountryTaxonomyEntry(
      code: 'en:netherlands',
      name: 'Netherlands',
      productCount: 50000,
    ),
    CountryTaxonomyEntry(
      code: 'en:switzerland',
      name: 'Switzerland',
      productCount: 50000,
    ),
    CountryTaxonomyEntry(
      code: 'en:poland',
      name: 'Poland',
      productCount: 40000,
    ),
    CountryTaxonomyEntry(
      code: 'en:austria',
      name: 'Austria',
      productCount: 30000,
    ),
    CountryTaxonomyEntry(
      code: 'en:portugal',
      name: 'Portugal',
      productCount: 30000,
    ),
  ];

  final _log = Logger('OffTaxonomyDataSource');
  final OfflineCatalogDataSource _catalog;
  final http.Client Function() _httpClientFactory;

  OffTaxonomyDataSource(
    this._catalog, {
    http.Client Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Returns the country list, sorted by product count descending. Uses
  /// the cached copy when fresh; otherwise fetches, caches, and returns
  /// the new list. Falls back to [_fallbackCountries] when the network
  /// fetch fails.
  ///
  /// [locale] should be the user's selected app locale (e.g. `en`,
  /// `de`, `pl`). It controls the language of the localised country
  /// names returned by OFF; pass `null` to let OFF pick its default.
  ///
  /// When [forceRefresh] is true, the cache is bypassed even if fresh.
  Future<List<CountryTaxonomyEntry>> getCountries({
    String? locale,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _readCache();
      if (cached != null) {
        _log.fine('Using cached countries taxonomy (${cached.length} entries)');
        return _sortByProductCount(cached);
      }
    }

    try {
      final fresh = await _fetch(locale: locale);
      await _writeCache(fresh);
      return _sortByProductCount(fresh);
    } catch (e, stack) {
      _log.warning('Country taxonomy fetch failed; using fallback list', e, stack);
      // If we have an *expired* cache, prefer it over the static
      // fallback — stale localised data is better than a generic
      // English list when offline.
      final expired = await _readCache(ignoreTtl: true);
      if (expired != null && expired.isNotEmpty) {
        return _sortByProductCount(expired);
      }
      return _sortByProductCount(_fallbackCountries);
    }
  }

  Future<List<CountryTaxonomyEntry>> _fetch({String? locale}) async {
    final uri = Uri.https(
      _baseUrl,
      _path,
      {if (locale != null && locale.isNotEmpty) 'lc': locale},
    );
    return await withRetry(() async {
      final userAgent = await AppConst.getUserAgentString();
      final client = ONTHttpClient(userAgent, _httpClientFactory());
      try {
        final response = await client.get(uri).timeout(_timeoutDuration);
        if (response.statusCode != 200) {
          throw Exception('Taxonomy HTTP ${response.statusCode}');
        }
        return _parseTaxonomyBody(response.body);
      } finally {
        client.close();
      }
    });
  }

  List<CountryTaxonomyEntry> _parseTaxonomyBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Taxonomy response not a JSON object');
    }
    final tags = decoded['tags'];
    if (tags is! List) {
      throw const FormatException('Taxonomy response missing "tags" list');
    }
    final entries = <CountryTaxonomyEntry>[];
    for (final raw in tags) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'];
      final name = raw['name'];
      final products = raw['products'];
      if (id is! String || name is! String) continue;
      // Some taxonomy rows have no products count; skip them — they
      // would surface as "0 products" in the UI which is misleading.
      final productCount = (products is num) ? products.toInt() : null;
      if (productCount == null || productCount <= 0) continue;
      entries.add(
        CountryTaxonomyEntry(
          code: id,
          name: name,
          productCount: productCount,
        ),
      );
    }
    return entries;
  }

  Future<List<CountryTaxonomyEntry>?> _readCache({bool ignoreTtl = false}) async {
    final json = await _catalog
        .getMeta(OfflineCatalogDataSource.metaKeyCountriesTaxonomyJson);
    if (json == null) return null;
    if (!ignoreTtl) {
      final fetchedAtRaw = await _catalog.getMeta(
        OfflineCatalogDataSource.metaKeyCountriesTaxonomyFetchedAt,
      );
      final fetchedAt = int.tryParse(fetchedAtRaw ?? '');
      if (fetchedAt == null) return null;
      final age =
          DateTime.now().millisecondsSinceEpoch - fetchedAt;
      if (age > _cacheTtl.inMilliseconds) return null;
    }
    try {
      final list = jsonDecode(json);
      if (list is! List) return null;
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            CountryTaxonomyEntry(
              code: item['code'] as String,
              name: item['name'] as String,
              productCount: item['productCount'] as int,
            ),
      ];
    } catch (e) {
      _log.warning('Failed to deserialise cached taxonomy: $e');
      return null;
    }
  }

  Future<void> _writeCache(List<CountryTaxonomyEntry> entries) async {
    final list = [
      for (final e in entries)
        {'code': e.code, 'name': e.name, 'productCount': e.productCount},
    ];
    await _catalog.setMeta(
      OfflineCatalogDataSource.metaKeyCountriesTaxonomyJson,
      jsonEncode(list),
    );
    await _catalog.setMeta(
      OfflineCatalogDataSource.metaKeyCountriesTaxonomyFetchedAt,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  List<CountryTaxonomyEntry> _sortByProductCount(
    List<CountryTaxonomyEntry> entries,
  ) {
    final sorted = [...entries];
    sorted.sort((a, b) => b.productCount.compareTo(a.productCount));
    return sorted;
  }
}
