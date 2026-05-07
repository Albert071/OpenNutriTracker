// ignore_for_file: non_constant_identifier_names

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/utils/supported_language.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_dto.dart';
import 'package:opennutritracker/features/add_meal/data/dto/off/off_product_nutriments_dto.dart';

void main() {
  group('OFFProductDTO getLocaleName', () {
    test('Case 1: English Language - Valid Name', () {
      final product = OFFProductDTO(
        code: '123 - testValue',
        product_name: 'Name - testValue',
        product_name_en: 'English Name - testValue',
        product_name_fr: 'Nom Français - testValue',
        product_name_de: 'Deutscher Name - testValue',
        brands: 'Brand - testValue',
        image_front_thumb_url: 'thumb - testValue',
        image_front_url: 'front - testValue',
        image_ingredients_url: 'ingredients - testValue',
        image_nutrition_url: 'nutrition - testValue',
        image_url: 'image - testValue',
        url: 'url - testValue',
        quantity: '100g - testValue',
        product_quantity: '100 - testValue',
        serving_quantity: '50 - testValue',
        serving_size: '50g - testValue',
        nutriments: OFFProductNutrimentsDTO(
          energy_kcal_100g: 1,
          carbohydrates_100g: 1,
          fat_100g: 1,
          proteins_100g: 1,
          sugars_100g: 1,
          saturated_fat_100g: 1,
          fiber_100g: 1,
        ),
      );

      final result = product.getLocaleName(SupportedLanguage.en);

      expect(result, equals('English Name - testValue'));
    });

    test('Case 2: Deutscher Language - Valid Name', () {
      final product = OFFProductDTO(
        code: '123 - testValue',
        product_name: 'Default Name - testValue',
        product_name_en: 'English Name - testValue',
        product_name_fr: 'Nom Français - testValue',
        product_name_de: 'Deutscher Name - testValue',
        brands: 'Brand - testValue',
        image_front_thumb_url: 'thumb - testValue',
        image_front_url: 'front - testValue',
        image_ingredients_url: 'ingredients - testValue',
        image_nutrition_url: 'nutrition - testValue',
        image_url: 'image - testValue',
        url: 'url - testValue',
        quantity: '100g - testValue',
        product_quantity: '100 - testValue',
        serving_quantity: '50 - testValue',
        serving_size: '50g - testValue',
        nutriments: OFFProductNutrimentsDTO(
          energy_kcal_100g: 1,
          carbohydrates_100g: 1,
          fat_100g: 1,
          proteins_100g: 1,
          sugars_100g: 1,
          saturated_fat_100g: 1,
          fiber_100g: 1
        ),
      );

      final result = product.getLocaleName(SupportedLanguage.de);

      expect(result, equals('Deutscher Name - testValue'));
    });

    test('Case 3: English Language - Null Name', () {
      final product = _buildProduct(
        product_name: 'Default Name - testValue',
        product_name_en: null,
        product_name_fr: 'Nom Français - testValue',
        product_name_de: 'Deutscher Name - testValue',
      );

      final result = product.getLocaleName(SupportedLanguage.en);

      expect(result, equals('Default Name - testValue'));
    });

    test('Case 4: English Language - Empty Name', () {
      final product = _buildProduct(
        product_name: 'Default Name - testValue',
        product_name_en: '',
        product_name_fr: 'Nom Français - testValue',
        product_name_de: 'Deutscher Name - testValue',
      );

      final result = product.getLocaleName(SupportedLanguage.en);

      expect(result, equals('Default Name - testValue'));
    });

    test('Case 5: Polish Language - returns product_name', () {
      final product = _buildProduct(
        product_name: 'Default Name - testValue',
        product_name_en: 'English Name - testValue',
        product_name_de: 'Deutscher Name - testValue',
      );

      final result = product.getLocaleName(SupportedLanguage.pl);

      expect(result, equals('Default Name - testValue'));
    });

    test('Case 6: Chinese Language - returns product_name', () {
      final product = _buildProduct(
        product_name: 'Default Name - testValue',
        product_name_en: 'English Name - testValue',
        product_name_de: 'Deutscher Name - testValue',
      );

      final result = product.getLocaleName(SupportedLanguage.zh);

      expect(result, equals('Default Name - testValue'));
    });

    test('Case 7: All names null - returns null', () {
      final product = _buildProduct();

      final result = product.getLocaleName(SupportedLanguage.en);

      expect(result, isNull);
    });

    test('Case 8: English fallback walks chain to product_name_fr', () {
      // product_name_en is null, product_name is null — the implementation's
      // fallback chain `product_name ?? product_name_en ?? product_name_fr ?? product_name_de`
      // should return the French name.
      final product = _buildProduct(
        product_name_fr: 'Nom Français - testValue',
        product_name_de: 'Deutscher Name - testValue',
      );

      final result = product.getLocaleName(SupportedLanguage.en);

      expect(result, equals('Nom Français - testValue'));
    });

    test('Case 9: Czech locale returns product_name_cs when present', () {
      final product = _buildProduct(product_name_cs: 'Český název');
      expect(product.getLocaleName(SupportedLanguage.cs),
          equals('Český název'));
    });

    test('Case 10: Italian locale returns product_name_it when present', () {
      final product = _buildProduct(product_name_it: 'Nome italiano');
      expect(product.getLocaleName(SupportedLanguage.it),
          equals('Nome italiano'));
    });

    test('Case 11: Turkish locale returns product_name_tr when present', () {
      final product = _buildProduct(product_name_tr: 'Türkçe isim');
      expect(product.getLocaleName(SupportedLanguage.tr),
          equals('Türkçe isim'));
    });

    test('Case 12: Ukrainian locale returns product_name_uk when present', () {
      final product = _buildProduct(product_name_uk: 'Українська назва');
      expect(product.getLocaleName(SupportedLanguage.uk),
          equals('Українська назва'));
    });

    test(
        'Case 13: Czech locale falls back through product_name when '
        'product_name_cs is null', () {
      final product = _buildProduct(product_name: 'Default name');
      expect(product.getLocaleName(SupportedLanguage.cs),
          equals('Default name'));
    });
  });
}

OFFProductDTO _buildProduct({
  String? product_name,
  String? product_name_en,
  String? product_name_fr,
  String? product_name_de,
  String? product_name_cs,
  String? product_name_it,
  String? product_name_tr,
  String? product_name_uk,
}) {
  return OFFProductDTO(
    code: '123',
    product_name: product_name,
    product_name_en: product_name_en,
    product_name_fr: product_name_fr,
    product_name_de: product_name_de,
    product_name_cs: product_name_cs,
    product_name_it: product_name_it,
    product_name_tr: product_name_tr,
    product_name_uk: product_name_uk,
    brands: null,
    image_front_thumb_url: null,
    image_front_url: null,
    image_ingredients_url: null,
    image_nutrition_url: null,
    image_url: null,
    url: null,
    quantity: null,
    product_quantity: null,
    serving_quantity: null,
    serving_size: null,
    nutriments: null,
  );
}
