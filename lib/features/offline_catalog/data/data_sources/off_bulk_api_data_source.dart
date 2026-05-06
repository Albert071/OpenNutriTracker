import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/ont_http_client.dart';
import 'package:opennutritracker/core/utils/retry_util.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';

/// One page of bulk-fetched products plus the matching count from the
/// envelope. The count reflects the total *server-side* row count for
/// the active filter set; it never changes between pages, so callers
/// can treat it as the loop bound.
class BulkSearchPage {
  final List<OFFProductDTO> products;
  final int totalCount;
  final int pageNumber;
  final int pageSize;

  const BulkSearchPage({
    required this.products,
    required this.totalCount,
    required this.pageNumber,
    required this.pageSize,
  });

  bool get isLast => pageNumber * pageSize >= totalCount;
}

/// Bulk paged loader over the OFF legacy search endpoint
/// (`/cgi/search.pl`). Used by the offline-catalog wizard to page
/// through products matching the user's filter set.
///
/// **Always-on filters** (not user-tunable) are appended to every
/// query to keep the catalogue honest:
///
/// * Human food only — three "does_not_contain" category exclusions
///   for `pet-food`, `cosmetics`, `non-food-products`. Most of OFF's
///   active editing happens on human food anyway, but the exclusions
///   stop pet food and cosmetics that have crept onto the world domain
///   from polluting the catalogue.
/// * `completeness` ≥ 0.3 — drops half-empty entries that lack core
///   metadata. Stricter than nutrition-grade alone because it also
///   accounts for images, ingredients, and quantities.
/// * `obsolete` = 0 — skip delisted products entirely.
///
/// **User-controlled filters** (from [CatalogFilterEntity]):
///
/// * `countries_tags` — comma-separated, OR semantics across the
///   user's selected countries.
/// * `unique_scans_n` ≥ 2, when the popularity toggle is on. Drops
///   the long tail of one-off submissions.
/// * `nutrition_grades_tags=a,b,c,d,e`, when the quality toggle is on.
/// * `last_modified_t` ≥ epoch, derived from the recency selector.
///
/// Throughput is throttled to ~1 request/second via a token bucket.
/// OFF's documented rate-limit guidance for the legacy endpoint is
/// roughly 100 req/min; 1 req/sec leaves headroom for the user-facing
/// app to keep working on the same connection.
class OffBulkApiDataSource {
  static const _baseUrl = 'world.openfoodfacts.org';
  static const _path = '/cgi/search.pl';
  static const _timeoutDuration = Duration(seconds: 60);
  static const defaultPageSize = 100;
  static const defaultThrottle = Duration(seconds: 1);

  /// Categories we always exclude. The values match OFF's tag slugs.
  static const _excludedCategories = ['pet-food', 'cosmetics', 'non-food-products'];

  /// Field projection requested from OFF. Mirrors the live-API
  /// projection in `OFFConst._returnFields` plus `last_modified_t`,
  /// which the live path doesn't need but the catalog requires for
  /// incremental refresh.
  static const _bulkFields = [
    'code',
    'brands',
    'product_name',
    'product_name_en',
    'product_name_de',
    'product_name_fr',
    'url',
    'image_url',
    'image_front_thumb_url',
    'image_front_url',
    'product_quantity',
    'quantity',
    'serving_quantity',
    'serving_size',
    'nutriments',
    'last_modified_t',
  ];

  final _log = Logger('OffBulkApiDataSource');
  final http.Client Function() _httpClientFactory;
  final Duration _throttle;

  /// When the next request is allowed to be sent. Starts at "now",
  /// advances by [_throttle] on every dispatch.
  DateTime _nextRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  OffBulkApiDataSource({
    http.Client Function()? httpClientFactory,
    Duration throttle = defaultThrottle,
  })  : _httpClientFactory = httpClientFactory ?? http.Client.new,
        _throttle = throttle;

  /// Fire a `page_size=1` probe to read the envelope's `count` for the
  /// active filter set. Returned count matches what the page loop will
  /// fetch end-to-end, so the wizard can show an honest estimate.
  Future<int> estimateCount(CatalogFilterEntity filters) async {
    final page = await fetchPage(
      filters: filters,
      pageNumber: 1,
      pageSize: 1,
    );
    return page.totalCount;
  }

  /// Fetch a single page of [pageSize] products at [pageNumber] (1-based).
  Future<BulkSearchPage> fetchPage({
    required CatalogFilterEntity filters,
    required int pageNumber,
    int pageSize = defaultPageSize,
    DateTime? now,
  }) async {
    await _waitForThrottle();
    final uri = buildSearchUri(
      filters: filters,
      pageNumber: pageNumber,
      pageSize: pageSize,
      now: now,
    );
    return await withRetry(() async {
      final userAgent = await AppConst.getUserAgentString();
      final client = ONTHttpClient(userAgent, _httpClientFactory());
      try {
        final response = await client.get(uri).timeout(_timeoutDuration);
        if (response.statusCode != 200) {
          // 429 = rate limited — withRetry's exponential backoff handles
          // the wait. Other 4xx/5xx also retry up to 3 times.
          throw Exception(
            'OFF bulk HTTP ${response.statusCode} for page $pageNumber',
          );
        }
        return _parseResponse(response.body, pageNumber, pageSize);
      } finally {
        client.close();
      }
    });
  }

  /// Build the URL for a given page. Visible for tests so we can verify
  /// the filter-to-query-params mapping without mocking HTTP.
  Uri buildSearchUri({
    required CatalogFilterEntity filters,
    required int pageNumber,
    int pageSize = defaultPageSize,
    DateTime? now,
  }) {
    final params = <String, String>{
      'action': 'process',
      'json': '1',
      'page': pageNumber.toString(),
      'page_size': pageSize.toString(),
      'fields': _bulkFields.join(','),
      // Always-on positive constraints
      'completeness_min': '0.3',
      'obsolete': '0',
    };

    if (filters.countries.isNotEmpty) {
      // Comma-separated tag values in `<field>_tags`. OFF treats this
      // as an OR across the values, which is what we want.
      params['countries_tags'] = filters.countries.join(',');
    }

    if (filters.requireMinPopularity) {
      params['unique_scans_n_min'] = '2';
    }

    if (filters.requireNutritionGrade) {
      params['nutrition_grades_tags'] = 'a,b,c,d,e';
    }

    final since = filters.lastModifiedSinceEpoch(now ?? DateTime.now());
    if (since != null) {
      params['last_modified_t_min'] = since.toString();
    }

    // Negative category filters. OFF's legacy search uses a numbered
    // tag-triplet style for these — each excluded category gets its
    // own (tagtype_N, tag_contains_N, tag_N) triplet AND'd with the
    // rest of the query.
    for (var i = 0; i < _excludedCategories.length; i++) {
      params['tagtype_$i'] = 'categories';
      params['tag_contains_$i'] = 'does_not_contain';
      params['tag_$i'] = _excludedCategories[i];
    }

    return Uri.https(_baseUrl, _path, params);
  }

  BulkSearchPage _parseResponse(String body, int pageNumber, int pageSize) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('OFF bulk response not a JSON object');
    }
    final count = decoded['count'];
    final products = decoded['products'];
    if (count is! num) {
      throw const FormatException('OFF bulk response missing "count"');
    }
    if (products is! List) {
      throw const FormatException('OFF bulk response missing "products" list');
    }
    final dtos = <OFFProductDTO>[];
    for (final raw in products) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        dtos.add(OFFProductDTO.fromJson(raw));
      } catch (e) {
        // A single malformed row shouldn't kill the whole page; OFF
        // occasionally returns rows with type drift on a nutriment
        // field (a string "trace" where we expect a number, etc).
        _log.warning('Skipping malformed product row: $e');
      }
    }
    return BulkSearchPage(
      products: dtos,
      totalCount: count.toInt(),
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  }

  /// Sleep just long enough that we don't fire two requests inside a
  /// single throttle window. Stateful across calls on a shared
  /// instance, so concurrent callers serialise here too.
  Future<void> _waitForThrottle() async {
    final now = DateTime.now();
    if (now.isBefore(_nextRequestAt)) {
      final wait = _nextRequestAt.difference(now);
      await Future.delayed(wait);
    }
    _nextRequestAt = DateTime.now().add(_throttle);
  }
}
