import 'package:equatable/equatable.dart';

/// One row from the OFF `/countries.json` taxonomy.
///
/// [code] is the canonical OFF country tag (e.g. `en:france`,
/// `en:united-kingdom`) — this is what we send back as `countries_tags`
/// in the bulk-search query.
/// [name] is localised to the user's selected app locale via the `?lc=`
/// query parameter on the taxonomy fetch.
/// [productCount] reflects the number of products OFF currently has tagged
/// with this country. We surface it next to each chip so the user can
/// gauge what they're committing to before kicking off a download.
class CountryTaxonomyEntry extends Equatable {
  final String code;
  final String name;
  final int productCount;

  const CountryTaxonomyEntry({
    required this.code,
    required this.name,
    required this.productCount,
  });

  @override
  List<Object?> get props => [code, name, productCount];
}
