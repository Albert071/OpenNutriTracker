import 'package:equatable/equatable.dart';

/// User-controlled subset of the prebuilt-catalog selection.
///
/// The pivot to download-prebuilt removed country selection — barcodes
/// are international and the catalog is global. What remains are the
/// three filter axes the build pipeline indexes by, exposed to the
/// user as wizard toggles and a recency chip:
///
/// * [requireMinPopularity] — only include products with at least
///   two scans on Open Food Facts (the well-scanned filter).
/// * [requireNutritionGrade] — only include products with a Nutri-Score
///   grade in `a..e` recorded.
/// * [maxAge] — recency cutoff; `null` means "Any" (no recency filter).
///
/// The trio resolves to a `s{0|1}_n{0|1}_r{3|5|10|any}` variant id
/// via [toVariantId], which is the path component the catalog CDN
/// serves.
class CatalogFilterEntity extends Equatable {
  /// Default recency window. Five years biases toward fresh metadata
  /// without dropping useful long-shelf-life products.
  static const Duration defaultMaxAge = Duration(days: 365 * 5);

  final bool requireNutritionGrade;
  final bool requireMinPopularity;

  /// Maximum age of `last_modified_t`. `null` means "Any" (no recency
  /// filter); the wizard's chip group exposes 3y / 5y / 10y / Any.
  final Duration? maxAge;

  const CatalogFilterEntity({
    this.requireNutritionGrade = true,
    this.requireMinPopularity = true,
    this.maxAge = defaultMaxAge,
  });

  /// Recommended defaults for a first-run user — the smallest
  /// download (~73 MB) with the strictest quality filters.
  static const recommended = CatalogFilterEntity();

  /// Resolve this filter trio to the catalog variant id used by the
  /// CDN URL pattern. Examples: `s1_n1_r5`, `s0_n0_rany`.
  ///
  /// Recency buckets snap to the nearest of `3` / `5` / `10` / `any`.
  /// The wizard chip group only emits those four values, so any other
  /// duration we see is round-tripped through the same buckets.
  String toVariantId() {
    final s = requireMinPopularity ? 1 : 0;
    final n = requireNutritionGrade ? 1 : 0;
    final r = _recencyBucket(maxAge);
    return 's${s}_n${n}_r$r';
  }

  /// Inverse of [toVariantId]. Returns `null` if [variantId] is not
  /// in the canonical `s{0|1}_n{0|1}_r{3|5|10|any}` shape.
  static CatalogFilterEntity? fromVariantId(String variantId) {
    final match = RegExp(r'^s([01])_n([01])_r(3|5|10|any)$')
        .firstMatch(variantId.trim());
    if (match == null) return null;
    final s = match.group(1) == '1';
    final n = match.group(2) == '1';
    final r = match.group(3)!;
    return CatalogFilterEntity(
      requireMinPopularity: s,
      requireNutritionGrade: n,
      maxAge: switch (r) {
        'any' => null,
        '3' => const Duration(days: 365 * 3),
        '10' => const Duration(days: 365 * 10),
        _ => defaultMaxAge,
      },
    );
  }

  static String _recencyBucket(Duration? maxAge) {
    if (maxAge == null) return 'any';
    final days = maxAge.inDays;
    if (days <= 365 * 3) return '3';
    if (days <= 365 * 5) return '5';
    if (days <= 365 * 10) return '10';
    return 'any';
  }

  CatalogFilterEntity copyWith({
    bool? requireNutritionGrade,
    bool? requireMinPopularity,
    Duration? maxAge,
    bool clearMaxAge = false,
  }) =>
      CatalogFilterEntity(
        requireNutritionGrade:
            requireNutritionGrade ?? this.requireNutritionGrade,
        requireMinPopularity: requireMinPopularity ?? this.requireMinPopularity,
        maxAge: clearMaxAge ? null : (maxAge ?? this.maxAge),
      );

  @override
  List<Object?> get props => [
        requireNutritionGrade,
        requireMinPopularity,
        maxAge,
      ];
}
