import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/ont_http_client.dart';
import 'package:opennutritracker/core/utils/retry_util.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';

/// Decoded response envelope from a single OFF bulk fetch, before
/// the client-side filter has been applied. Internal to the data
/// source — callers see [BulkSearchPage] which holds the post-filter
/// products.
class _RawPage {
  final int serverTotal;
  final List<Map<String, dynamic>> rawRows;

  const _RawPage({required this.serverTotal, required this.rawRows});
}

/// Wraps a non-200 HTTP response from OFF in a recognisable type so
/// the user-facing error message can say something other than the
/// raw status code, and so the bulk loader could in future apply
/// status-aware backoff (e.g. longer pauses on 503 specifically).
class _TransientHttpException implements Exception {
  final int statusCode;
  final int pageNumber;

  const _TransientHttpException(this.statusCode, this.pageNumber);

  @override
  String toString() {
    if (statusCode == 503) {
      return 'Open Food Facts is busy (HTTP 503). Will retry; if it '
          'keeps happening, pause and try again later.';
    }
    if (statusCode == 429) {
      return 'Open Food Facts rate-limited us (HTTP 429). Will back off.';
    }
    return 'OFF bulk HTTP $statusCode for page $pageNumber';
  }
}

/// One page of bulk-fetched products plus the server's claimed total.
/// `products` is the post-filter list (may be smaller than
/// `pageSize`); `totalCount` is the server-side total for the
/// country selection (used as the loop bound, since OFF caps it at
/// the country level not at the filtered level).
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
/// through products matching the user's selected countries.
///
/// **Server-side filter:** only `countries_tags`. OFF's legacy CGI
/// search has been load-shed to 503 for any non-trivial filtered
/// query, and the newer `search.openfoodfacts.org` v1 endpoint hard-
/// caps results at 10,000 — neither path can deliver a useful UK
/// catalogue if we try to push the rest of the filter set up to OFF.
/// So we keep the server query simple ("UK products, page N") and do
/// every other filter [_passesClientSideFilter] right here, on each
/// page as it arrives, before the rows are written to disk.
///
/// **Always-on client-side filters** the user never sees:
///
/// * Human food only — exclude products tagged `pet-food`,
///   `cosmetics`, `non-food-products`. Pet food and cosmetics
///   sometimes creep onto the world domain.
/// * `completeness` ≥ 0.3 — drops half-empty entries that lack core
///   metadata.
/// * `obsolete` ≠ "1" — skip products OFF has marked delisted.
///
/// **User-controlled client-side filters** from [CatalogFilterEntity]:
///
/// * `unique_scans_n` ≥ 2 when the popularity toggle is on.
/// * `nutrition_grades` ∈ {a, b, c, d, e} when the quality toggle is
///   on (drops "unknown" / "not-applicable").
/// * `last_modified_t` ≥ epoch, derived from the recency selector.
///
/// The cost of this trade is that we download more rows than we keep
/// — roughly 5–10× the eventual catalogue size in bytes. A UK build
/// that ends up with ~15k rows on disk pulls ~180k rows over the
/// wire. This is unavoidable while OFF's endpoint situation is what
/// it is, and we surface it in the wizard's estimate page so the
/// user is not surprised.
///
/// Throughput is throttled to ~1 request/second via a token bucket.
class OffBulkApiDataSource {
  static const _baseUrl = 'world.openfoodfacts.org';
  static const _path = '/cgi/search.pl';
  static const _timeoutDuration = Duration(seconds: 60);
  static const defaultPageSize = 100;

  /// We don't impose an explicit inter-request floor any more. The
  /// 6-attempt retry budget with 1s/2s/4s/8s/16s exponential backoff
  /// self-throttles whenever OFF is load-shedding (503 / 429),
  /// which is the only case where slowing down actually helps. When
  /// OFF is healthy we go as fast as it will serve us.
  static const defaultThrottle = Duration.zero;

  /// Categories whose presence on a product disqualifies it from the
  /// catalogue. OFF tags use the `en:` namespace prefix; we accept
  /// either form when matching.
  static const _excludedCategoryTags = {
    'en:pet-food',
    'pet-food',
    'en:cosmetics',
    'cosmetics',
    'en:non-food-products',
    'non-food-products',
  };

  /// Minimum `completeness` score we keep. OFF returns this as a 0–1
  /// fractional float. Below 0.3 the entry usually lacks core
  /// metadata (image, name, quantity).
  static const _minCompleteness = 0.3;

  /// Nutrition grade values the user's "full nutrition data" toggle
  /// keeps. Anything outside this set (most commonly `unknown` or
  /// `not-applicable`) is dropped when the toggle is on.
  static const _acceptedNutritionGrades = {'a', 'b', 'c', 'd', 'e'};

  /// Minimum `unique_scans_n` when the popularity toggle is on.
  static const _minPopularity = 2;

  /// Field projection requested from OFF. The live-API path uses a
  /// smaller list; we add the filter-relevant fields
  /// (`categories_tags`, `nutrition_grades`, `unique_scans_n`,
  /// `completeness`, `obsolete`, `last_modified_t`) so we can decide
  /// per-row whether to keep it.
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
    'categories_tags',
    'nutrition_grades',
    'unique_scans_n',
    'completeness',
    'obsolete',
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

  /// Fire a `page_size=1` probe to read the envelope's server-side
  /// `count` for the country selection. Note: this is the **pre-
  /// filter** total — the actual stored catalogue will be smaller
  /// because the client-side filters reduce it further. The wizard's
  /// estimate page surfaces both numbers so the user understands
  /// what they're committing to.
  Future<int> estimateServerCount(CatalogFilterEntity filters) async {
    final page = await _fetchRawPage(
      filters: filters,
      pageNumber: 1,
      pageSize: 1,
    );
    return page.serverTotal;
  }

  /// Backwards-compatible alias for the server-side count probe.
  Future<int> estimateCount(CatalogFilterEntity filters) =>
      estimateServerCount(filters);

  /// Fetch a single page of [pageSize] products at [pageNumber]
  /// (1-based) and apply the client-side filter set from [filters]
  /// before returning. The returned [BulkSearchPage] holds only the
  /// rows that survived the filter, plus the server's claimed total
  /// for the country selection (used for the loop bound).
  Future<BulkSearchPage> fetchPage({
    required CatalogFilterEntity filters,
    required int pageNumber,
    int pageSize = defaultPageSize,
    DateTime? now,
  }) async {
    final raw = await _fetchRawPage(
      filters: filters,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
    final cutoffEpoch = filters.lastModifiedSinceEpoch(now ?? DateTime.now());
    final kept = <OFFProductDTO>[];
    for (final row in raw.rawRows) {
      if (!_passesClientSideFilter(row, filters, cutoffEpoch)) continue;
      try {
        kept.add(OFFProductDTO.fromJson(row));
      } catch (e) {
        _log.warning('Skipping malformed product row: $e');
      }
    }
    return BulkSearchPage(
      products: kept,
      totalCount: raw.serverTotal,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  }

  Future<_RawPage> _fetchRawPage({
    required CatalogFilterEntity filters,
    required int pageNumber,
    required int pageSize,
  }) async {
    await _waitForThrottle();
    final uri = buildSearchUri(
      filters: filters,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
    // Bigger retry budget than the live-API path. OFF's legacy CGI
    // is load-shedding heavily for bulk traffic — a single page can
    // 503 several times in a row before settling. Six attempts with
    // exponential backoff give us up to roughly a minute of patience
    // per page (1s + 2s + 4s + 8s + 16s = 31s of waiting between
    // attempts, plus the request time). The 1 req/sec throttle still
    // applies on top, so a healthy run averages ~1 page/sec.
    return await withRetry(
      () async {
        final userAgent = await AppConst.getUserAgentString();
        final client = ONTHttpClient(userAgent, _httpClientFactory());
        try {
          final response = await client.get(uri).timeout(_timeoutDuration);
          if (response.statusCode != 200) {
            throw _TransientHttpException(
              response.statusCode,
              pageNumber,
            );
          }
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException(
              'OFF bulk response not a JSON object',
            );
          }
          final count = decoded['count'];
          final products = decoded['products'];
          if (count is! num) {
            throw const FormatException('OFF bulk response missing "count"');
          }
          if (products is! List) {
            throw const FormatException(
              'OFF bulk response missing "products" list',
            );
          }
          final rows = <Map<String, dynamic>>[];
          for (final raw in products) {
            if (raw is Map<String, dynamic>) rows.add(raw);
          }
          return _RawPage(serverTotal: count.toInt(), rawRows: rows);
        } finally {
          client.close();
        }
      },
      attempts: 6,
    );
  }

  /// Build the URL for a given page. The query is intentionally
  /// minimal — OFF's legacy CGI 503s on richer filter combinations,
  /// so we only ask the server for `countries_tags` and do every
  /// other filter client-side in [_passesClientSideFilter]. Visible
  /// for tests.
  Uri buildSearchUri({
    required CatalogFilterEntity filters,
    required int pageNumber,
    int pageSize = defaultPageSize,
  }) {
    final params = <String, String>{
      'action': 'process',
      'json': '1',
      'page': pageNumber.toString(),
      'page_size': pageSize.toString(),
      'fields': _bulkFields.join(','),
    };
    if (filters.countries.isNotEmpty) {
      // Comma-separated tag values in `countries_tags`. OFF treats
      // this as an OR across the values.
      params['countries_tags'] = filters.countries.join(',');
    }
    return Uri.https(_baseUrl, _path, params);
  }

  /// Apply the client-side filter set to a raw OFF product map.
  /// Returns true when the row should be kept.
  ///
  /// Field types in the OFF response are inconsistent — some are
  /// stringly-typed numbers, some are real numbers, some are nullable
  /// in awkward ways. Defensive parsing here avoids a single weird
  /// row killing a whole page.
  bool _passesClientSideFilter(
    Map<String, dynamic> row,
    CatalogFilterEntity filters,
    int? lastModifiedCutoff,
  ) {
    // Always-on: skip obsolete rows. OFF sets `obsolete` to "1" /
    // "on" / true when a product has been delisted.
    final obsolete = row['obsolete'];
    if (obsolete == true || obsolete == 1 || obsolete == '1' ||
        obsolete == 'on') {
      return false;
    }

    // Always-on: human food. Reject anything tagged with one of the
    // excluded categories. `categories_tags` is a list of strings.
    final categoriesTags = row['categories_tags'];
    if (categoriesTags is List) {
      for (final tag in categoriesTags) {
        if (tag is String && _excludedCategoryTags.contains(tag)) {
          return false;
        }
      }
    }

    // Always-on: minimum completeness.
    final completeness = _toDouble(row['completeness']);
    if (completeness == null || completeness < _minCompleteness) {
      return false;
    }

    // User toggle: nutrition grade present.
    if (filters.requireNutritionGrade) {
      final grade = row['nutrition_grades'];
      if (grade is! String ||
          !_acceptedNutritionGrades.contains(grade.toLowerCase())) {
        return false;
      }
    }

    // User toggle: minimum scan popularity.
    if (filters.requireMinPopularity) {
      final scans = _toInt(row['unique_scans_n']);
      if (scans == null || scans < _minPopularity) return false;
    }

    // User selector: recency cutoff.
    if (lastModifiedCutoff != null) {
      final lastModified = _toInt(row['last_modified_t']);
      if (lastModified == null || lastModified < lastModifiedCutoff) {
        return false;
      }
    }

    return true;
  }

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
