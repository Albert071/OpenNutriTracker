import 'package:opennutritracker/core/domain/entity/calories_profile_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';

///
/// Calculates BMR of UserEntity based on the 1918 Harris-Benedict equation
/// from the paper 'A Biometric Study of Human Basal Metabolism'
/// by Harris & Benedict
/// https://pubmed.ncbi.nlm.nih.gov/16576330/
///
class BMRCalc {
  static double getBMRHarrisBenedict1918(UserEntity user) {
    return _dispatch(
      user,
      male: _harrisBenedict1918Male,
      female: _harrisBenedict1918Female,
    );
  }

  static double _harrisBenedict1918Male(UserEntity user) {
    return 66.4730 +
        13.7516 * user.weightKG +
        5.0033 * user.heightCM -
        6.7550 * user.age;
  }

  static double _harrisBenedict1918Female(UserEntity user) {
    return 655.0955 +
        9.5634 * user.weightKG +
        1.8496 * user.heightCM -
        4.6756 * user.age;
  }

  ///
  /// Calculates BMR of UserEntity based on the 1984 revised
  /// Harris-Benedict equation from the paper
  /// 'The Harris Benedict equation reevaluated: resting energy
  /// requirements and the body cell mass' by Roza & Shizgal
  /// https://academic.oup.com/ajcn/article-abstract/40/1/168/4691315
  ///
  static double getBMRRevisedHarrisBenedict1984(UserEntity user) {
    return _dispatch(
      user,
      male: _revisedHarrisBenedict1984Male,
      female: _revisedHarrisBenedict1984Female,
    );
  }

  static double _revisedHarrisBenedict1984Male(UserEntity user) {
    return 88.362 +
        13.397 * user.weightKG +
        4.799 * user.heightCM -
        5.677 * user.age;
  }

  static double _revisedHarrisBenedict1984Female(UserEntity user) {
    return 447.593 +
        9.247 * user.weightKG +
        3.098 * user.heightCM -
        4.330 * user.age;
  }

  ///
  /// Calculates BMR of UserEntity based on the 1990 Mifflin-St.Jeor equation
  /// from the paper 'A new predictive equation for resting energy
  /// expenditure in healthy individuals'
  /// by Mifflin & St.Jeor
  /// https://academic.oup.com/ajcn/article-abstract/51/2/241/4695104
  ///
  static double getBMRMifflinStJeor1990(UserEntity user) {
    return _dispatch(
      user,
      male: _mifflinStJeor1990Male,
      female: _mifflinStJeor1990Female,
    );
  }

  static double _mifflinStJeor1990Male(UserEntity user) {
    return 10 * user.weightKG + 6.25 * user.heightCM - 5 * user.age + 5;
  }

  static double _mifflinStJeor1990Female(UserEntity user) {
    return 10 * user.weightKG + 6.25 * user.heightCM - 5 * user.age - 161;
  }

  /// Calculates BMR of UserEntity based on the 1985 Schofield equation
  /// from the paper 'Predicting basal metabolic rate, new standards and
  /// review of previous work' by Schofield
  /// https://pubmed.ncbi.nlm.nih.gov/4044297/
  ///
  static double getBMRSchofield11985(UserEntity user) {
    return _dispatch(
      user,
      male: _schofield1985Male,
      female: _schofield1985Female,
    );
  }

  static double _schofield1985Male(UserEntity user) {
    final age = user.age;
    if (age < 3) return 59.512 * user.weightKG - 30.4;
    if (age < 10) return 22.706 * user.weightKG + 504.3;
    if (age < 18) return 17.686 * user.weightKG + 658.2;
    if (age < 30) return 15.057 * user.weightKG + 692.2;
    if (age < 60) return 11.472 * user.weightKG + 873.1;
    return 11.711 * user.weightKG + 587.7;
  }

  static double _schofield1985Female(UserEntity user) {
    final age = user.age;
    if (age < 3) return 58.317 * user.weightKG - 31.1;
    if (age < 10) return 20.315 * user.weightKG + 485.9;
    if (age < 18) return 13.384 * user.weightKG + 692.6;
    if (age < 30) return 14.818 * user.weightKG + 486.6;
    if (age < 60) return 8.126 * user.weightKG + 845.6;
    return 9.082 * user.weightKG + 658.5;
  }

  /// Routes a binary-gendered formula to the right reference for the user.
  /// Non-binary users default to the mean of the male / female outputs unless
  /// they have explicitly opted into the estrogen-typical or testosterone-
  /// typical reference via [CaloriesProfileEntity].
  static double _dispatch(
    UserEntity user, {
    required double Function(UserEntity) male,
    required double Function(UserEntity) female,
  }) {
    switch (user.gender) {
      case UserGenderEntity.male:
        return male(user);
      case UserGenderEntity.female:
        return female(user);
      case UserGenderEntity.nonBinary:
        switch (user.caloriesProfile ?? CaloriesProfileEntity.averaged) {
          case CaloriesProfileEntity.averaged:
            return (male(user) + female(user)) / 2;
          case CaloriesProfileEntity.estrogenTypical:
            return female(user);
          case CaloriesProfileEntity.testosteroneTypical:
            return male(user);
        }
    }
  }
}
