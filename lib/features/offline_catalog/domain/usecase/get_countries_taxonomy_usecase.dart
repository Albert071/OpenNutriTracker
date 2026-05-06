import 'package:opennutritracker/features/offline_catalog/data/data_sources/off_taxonomy_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';

class GetCountriesTaxonomyUseCase {
  final OffTaxonomyDataSource _taxonomy;

  GetCountriesTaxonomyUseCase(this._taxonomy);

  /// [locale] is the user's app locale (e.g. `en`, `de`, `pl`); it
  /// controls which language OFF returns the country names in. Pass
  /// null to let OFF pick its default.
  Future<List<CountryTaxonomyEntry>> call({
    String? locale,
    bool forceRefresh = false,
  }) =>
      _taxonomy.getCountries(locale: locale, forceRefresh: forceRefresh);
}
