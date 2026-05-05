import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:opennutritracker/core/data/data_source/user_activity_dbo.dart';
import 'package:opennutritracker/core/data/dbo/app_theme_dbo.dart';
import 'package:opennutritracker/core/data/dbo/config_dbo.dart';
import 'package:opennutritracker/core/data/dbo/intake_dbo.dart';
import 'package:opennutritracker/core/data/dbo/intake_type_dbo.dart';
import 'package:opennutritracker/core/data/dbo/physical_activity_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_nutriments_dbo.dart';
import 'package:opennutritracker/core/data/dbo/recipe_dbo.dart';
import 'package:opennutritracker/core/data/dbo/recipe_ingredient_dbo.dart';
import 'package:opennutritracker/core/data/dbo/tracked_day_dbo.dart';
import 'package:opennutritracker/core/data/dbo/user_dbo.dart';
import 'package:opennutritracker/core/data/dbo/user_gender_dbo.dart';
import 'package:opennutritracker/core/data/dbo/user_pal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/user_weight_goal_dbo.dart';

class HiveDBProvider extends ChangeNotifier {
  static const configBoxName = 'ConfigBox';
  static const intakeBoxName = 'IntakeBox';
  static const userActivityBoxName = 'UserActivityBox';
  static const userBoxName = 'UserBox';
  static const trackedDayBoxName = 'TrackedDayBox';
  static const customMealBoxName = 'CustomMealBox';
  static const recipeBoxName = 'RecipeBox';
  static const cachedOffMealBoxName = 'CachedOffMealBox';
  // Sidecar to cachedOffMealBox: maps meal `code` -> millisSinceEpoch of
  // last "touch" (creation or user re-select). Used by the TTL sweep so
  // unused cache entries age out after 90 days.
  static const cachedOffMealTimestampsBoxName = 'CachedOffMealTimestampsBox';

  late Box<ConfigDBO> configBox;
  late Box<IntakeDBO> intakeBox;
  late Box<UserActivityDBO> userActivityBox;
  late Box<UserDBO> userBox;
  late Box<TrackedDayDBO> trackedDayBox;
  late Box<MealDBO> customMealBox;
  late Box<RecipeDBO> recipeBox;
  late Box<MealDBO> cachedOffMealBox;
  late Box<int> cachedOffMealTimestampsBox;

  Future<void> initHiveDB(Uint8List encryptionKey) async {
    final encryptionCypher = HiveAesCipher(encryptionKey);
    await Hive.initFlutter();
    Hive.registerAdapter(ConfigDBOAdapter());
    Hive.registerAdapter(IntakeDBOAdapter());
    Hive.registerAdapter(MealDBOAdapter());
    Hive.registerAdapter(MealNutrimentsDBOAdapter());
    Hive.registerAdapter(MealSourceDBOAdapter());
    Hive.registerAdapter(IntakeTypeDBOAdapter());
    Hive.registerAdapter(UserDBOAdapter());
    Hive.registerAdapter(UserGenderDBOAdapter());
    Hive.registerAdapter(UserWeightGoalDBOAdapter());
    Hive.registerAdapter(UserPALDBOAdapter());
    Hive.registerAdapter(TrackedDayDBOAdapter());
    Hive.registerAdapter(UserActivityDBOAdapter());
    Hive.registerAdapter(PhysicalActivityDBOAdapter());
    Hive.registerAdapter(PhysicalActivityTypeDBOAdapter());
    Hive.registerAdapter(AppThemeDBOAdapter());
    Hive.registerAdapter(RecipeDBOAdapter());
    Hive.registerAdapter(RecipeIngredientDBOAdapter());

    configBox = await Hive.openBox(
      configBoxName,
      encryptionCipher: encryptionCypher,
    );
    intakeBox = await Hive.openBox(
      intakeBoxName,
      encryptionCipher: encryptionCypher,
    );
    userActivityBox = await Hive.openBox(
      userActivityBoxName,
      encryptionCipher: encryptionCypher,
    );
    userBox = await Hive.openBox(
      userBoxName,
      encryptionCipher: encryptionCypher,
    );
    trackedDayBox = await Hive.openBox(
      trackedDayBoxName,
      encryptionCipher: encryptionCypher,
    );
    customMealBox = await Hive.openBox(
      customMealBoxName,
      encryptionCipher: encryptionCypher,
    );
    recipeBox = await Hive.openBox(
      recipeBoxName,
      encryptionCipher: encryptionCypher,
    );
    cachedOffMealBox = await Hive.openBox(
      cachedOffMealBoxName,
      encryptionCipher: encryptionCypher,
    );
    cachedOffMealTimestampsBox = await Hive.openBox(
      cachedOffMealTimestampsBoxName,
      encryptionCipher: encryptionCypher,
    );
  }

  static List<int> generateNewHiveEncryptionKey() => Hive.generateSecureKey();
}
