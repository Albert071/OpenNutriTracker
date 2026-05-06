import 'package:opennutritracker/core/domain/entity/user_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_pal_entity.dart';

class PalCalc {
  ///
  /// Return the physical activity level (PAL) value fom the PAL category
  /// based on the IOM Physical Activity Recommendations 2004
  /// 'Chronicle of the Institute of Medicine physical activity recommendation:
  /// how a physical activity recommendation came to be among dietary
  /// recommendations'
  /// by Brooks et al.
  /// https://pubmed.ncbi.nlm.nih.gov/15113740/
  ///
  static double getPALValueFromActivityCategory(UserEntity userEntity) {
    double palValue;
    switch (userEntity.pal) {
      case UserPALEntity.sedentary:
        palValue = 1.25;
        break;
      case UserPALEntity.lowActive:
        palValue = 1.5;
        break;
      case UserPALEntity.active:
        palValue = 1.75;
        break;
      case UserPALEntity.veryActive:
        palValue = 2.2;
        break;
    }
    return palValue;
  }

  ///
  /// Returns the physical activity coefficient (PA) from the PAL value
  /// and the formula's gender reference based on IOM recommendation.
  ///
  /// `isMaleFormula` decouples the PA constant from the user's stored
  /// gender — needed so non-binary `averaged` TDEE feeds male PA into the
  /// male half of the average and female PA into the female half. Picking
  /// PA from `userEntity.gender` directly would route both halves to the
  /// female constant for any non-binary user.
  ///
  /// Institute of Medicine. 2005. Dietary Reference Intakes for Energy,
  /// Carbohydrate, Fiber, Fat, Fatty Acids, Cholesterol, Protein,
  /// and Amino Acids. (p.204)
  /// Washington, DC: The National Academies Press.
  /// https://doi.org/10.17226/10490.
  /// https://nap.nationalacademies.org/catalog/10490/dietary-reference-intakes-for-energy-carbohydrate-fiber-fat-fatty-acids-cholesterol-protein-and-amino-acids
  static double getPAValueForFormula({
    required double palValue,
    required bool isMaleFormula,
  }) {
    if (palValue < 1.4) return 1.0;
    if (palValue < 1.6) return isMaleFormula ? 1.12 : 1.14;
    if (palValue < 1.9) return 1.27;
    return isMaleFormula ? 1.54 : 1.45;
  }

  /// Convenience wrapper that picks the PA constant from the user's stored
  /// gender. Non-binary users go through the female PA — callers that need
  /// to compute male and female references separately (e.g. averaged TDEE)
  /// should call [getPAValueForFormula] directly with explicit flags.
  static double getPAValueFromPALValue(UserEntity userEntity, double palValue) {
    return getPAValueForFormula(
      palValue: palValue,
      isMaleFormula: userEntity.gender == UserGenderEntity.male,
    );
  }
}
