import 'package:equatable/equatable.dart';

/// User-controlled subset of the OFF bulk-search query.
///
/// Always-on server-side filters (human-food-only category exclusions,
/// `completeness > 0.3`, `obsolete=0`) are not represented here — they
/// live as constants on the bulk data source so the user cannot toggle
/// them off accidentally.
///
/// [countries] holds canonical OFF country tags (e.g. `en:france`).
/// An empty set means "no country filter" and triggers the typed-
/// confirmation footgun on page 4 of the wizard.
class CatalogFilterEntity extends Equatable {
  /// Default recency window. Five years biases toward fresh metadata
  /// without dropping useful long-shelf-life products.
  static const Duration defaultMaxAge = Duration(days: 365 * 5);

  final Set<String> countries;
  final bool requireNutritionGrade;
  final bool requireMinPopularity;

  /// Maximum age of `last_modified_t`. `null` means "Any" (no recency
  /// filter); the wizard's chip group exposes 3y / 5y / 10y / Any.
  final Duration? maxAge;

  const CatalogFilterEntity({
    required this.countries,
    this.requireNutritionGrade = true,
    this.requireMinPopularity = true,
    this.maxAge = defaultMaxAge,
  });

  /// Epoch seconds threshold for `last_modified_t > <epoch>` queries,
  /// or `null` when [maxAge] is null.
  int? lastModifiedSinceEpoch(DateTime now) {
    final age = maxAge;
    if (age == null) return null;
    return now.subtract(age).millisecondsSinceEpoch ~/ 1000;
  }

  CatalogFilterEntity copyWith({
    Set<String>? countries,
    bool? requireNutritionGrade,
    bool? requireMinPopularity,
    Duration? maxAge,
    bool clearMaxAge = false,
  }) =>
      CatalogFilterEntity(
        countries: countries ?? this.countries,
        requireNutritionGrade:
            requireNutritionGrade ?? this.requireNutritionGrade,
        requireMinPopularity: requireMinPopularity ?? this.requireMinPopularity,
        maxAge: clearMaxAge ? null : (maxAge ?? this.maxAge),
      );

  @override
  List<Object?> get props => [
        countries,
        requireNutritionGrade,
        requireMinPopularity,
        maxAge,
      ];
}
