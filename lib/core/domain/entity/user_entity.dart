import 'package:opennutritracker/core/data/dbo/user_dbo.dart';
import 'package:opennutritracker/core/domain/entity/calories_profile_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_pal_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_weight_goal_entity.dart';

class UserEntity {
  DateTime birthday;
  double heightCM;
  double weightKG;
  UserGenderEntity gender;
  UserWeightGoalEntity goal;
  UserPALEntity pal;
  double? weeklyWeightGoalKg;

  /// Optional calorie-reference profile. Only meaningful when [gender] is
  /// [UserGenderEntity.nonBinary]; for binary users this is `null` and the
  /// existing male/female formulas apply directly. When null for non-binary
  /// users, the calc layer treats it as [CaloriesProfileEntity.averaged].
  CaloriesProfileEntity? caloriesProfile;

  UserEntity({
    required this.birthday,
    required this.heightCM,
    required this.weightKG,
    required this.gender,
    required this.goal,
    required this.pal,
    this.weeklyWeightGoalKg,
    this.caloriesProfile,
  });

  factory UserEntity.fromUserDBO(UserDBO userDBO) {
    return UserEntity(
      birthday: userDBO.birthday,
      heightCM: userDBO.heightCM,
      weightKG: userDBO.weightKG,
      gender: UserGenderEntity.fromUserGenderDBO(userDBO.gender),
      goal: UserWeightGoalEntity.fromUserWeightGoalDBO(userDBO.goal),
      pal: UserPALEntity.fromUserPALDBO(userDBO.pal),
      weeklyWeightGoalKg: userDBO.weeklyWeightGoalKg,
      caloriesProfile: userDBO.caloriesProfile == null
          ? null
          : CaloriesProfileEntity.fromDBO(userDBO.caloriesProfile!),
    );
  }

  int get age => DateTime.now().difference(birthday).inDays ~/ 365;
}
