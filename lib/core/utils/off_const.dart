class OFFConst {
  static const offWebsiteUrl = "https://world.openfoodfacts.org/";
  static const _offBaseUrl = "world.openfoodfacts.org";
  static const _offProductSearchTag = "/api/v2/product";

  // Text search moved off the deprecated /cgi/search.pl to Open Food Facts'
  // Elasticsearch-backed Search-a-licious service. Barcode lookups stay on the
  // still-healthy v2 product endpoint, which also serves as the hydration
  // source for the thinner Search-a-licious results.
  static const _salBaseUrl = "search.openfoodfacts.org";
  static const _salSearchTag = "/search";

  // We fetch a larger relevance-ordered candidate pool than we display so the
  // repository can re-rank it (fusing relevance position with popularity_key)
  // before trimming to the shown results. A bare relevance page buries popular,
  // well-maintained products under near-duplicate and sparse entries.
  static const searchCandidatePoolSize = 100;

  static const offHttpSuccessCode = 200;
  static const offHttpDownCodes = [502, 503, 500];
  static const offProductNotFoundCode = 404;

  static const _salQueryTag = "q";
  static const _salFieldsTag = "fields";
  static const _salLangsTag = "langs";
  static const _salPageSizeTag = "page_size";
  static const _salPageTag = "page";

  static const _offFieldsTag = "fields";
  static const _offJsonTag = "json";
  static const _offJsonValue = "true";

  static const _offProductNameTag = "product_name";
  static const _offProductNameENTag = "product_name_en";
  static const _offProductNameDETag = "product_name_de";
  static const _offProductNameFRTag = "product_name_fr";
  static const _offCodeTag = "code";
  static const _offBrandsTag = "brands";

  static const _offUrlTag = "url";
  static const _offImageUrlTag = "image_url";
  static const _offImageThumbUrlTag = "image_front_thumb_url";
  static const _offImageFrontUrlTag = "image_front_url";

  static const _offProductQuantityTag = "product_quantity";
  static const _offQuantityTag = "quantity";
  static const _offServingQuantityTag = "serving_quantity";
  static const _offServingSizeTag = "serving_size";
  static const _offNutrimentsTag = "nutriments";
  static const _offPopularityKeyTag = "popularity_key";
  static const _offCountriesTagsTag = "countries_tags";

  // Search-a-licious only indexes a thin projection of each product: the
  // serving_* and product_quantity fields are absent from its index, so they
  // are dropped here and recovered on hydration via the full v2 product call.
  static const _searchReturnFields = [
    _offCodeTag,
    _offBrandsTag,
    _offProductNameTag,
    _offProductNameENTag,
    _offProductNameDETag,
    _offProductNameFRTag,
    _offUrlTag,
    _offImageUrlTag,
    _offImageThumbUrlTag,
    _offImageFrontUrlTag,
    _offQuantityTag,
    _offNutrimentsTag,
    _offPopularityKeyTag,
    _offCountriesTagsTag,
  ];

  // The v2 product endpoint carries the full record, including the serving
  // fields and micronutrients Search-a-licious omits.
  static const _productReturnFields = [
    _offCodeTag,
    _offBrandsTag,
    _offProductNameTag,
    _offProductNameENTag,
    _offProductNameDETag,
    _offProductNameFRTag,
    _offUrlTag,
    _offImageUrlTag,
    _offImageThumbUrlTag,
    _offImageFrontUrlTag,
    _offProductQuantityTag,
    _offQuantityTag,
    _offServingQuantityTag,
    _offServingSizeTag,
    _offNutrimentsTag,
  ];

  static String _joinFields(List<String> fields) => fields.join(",");

  static Uri getOffWordSearchUrl(String searchString, {String langs = 'en'}) {
    final queryParameters = {
      _salQueryTag: searchString,
      _salFieldsTag: _joinFields(_searchReturnFields),
      _salLangsTag: langs,
      _salPageSizeTag: '$searchCandidatePoolSize',
      _salPageTag: '1',
    };

    return Uri.https(_salBaseUrl, _salSearchTag, queryParameters);
  }

  static Uri getOffBarcodeSearchUri(String barcode) {
    final queryParameters = {
      _offFieldsTag: _joinFields(_productReturnFields),
      _offJsonTag: _offJsonValue,
    };

    return Uri.https(
      _offBaseUrl,
      '$_offProductSearchTag/$barcode',
      queryParameters,
    );
  }
}
