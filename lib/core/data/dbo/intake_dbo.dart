import 'package:hive_ce/hive.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:opennutritracker/core/data/dbo/intake_type_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';

part 'intake_dbo.g.dart';

@HiveType(typeId: 0)
@JsonSerializable()
class IntakeDBO extends HiveObject {
  @HiveField(0)
  String id;
  @HiveField(1)
  String unit;
  @HiveField(2)
  double amount;
  @HiveField(3)
  IntakeTypeDBO type;

  @HiveField(4)
  MealDBO meal;

  @HiveField(5)
  DateTime dateTime;

  /// #295: Tag for intakes that were imported from an external source so
  /// we can deduplicate on re-import and let the UI surface the origin
  /// later. Null means "logged inside OpenNutriTracker" — every existing
  /// entry on disk is implicitly null until the user touches an import
  /// flow, so no migration is needed. Current known values: `health_connect`.
  @HiveField(6)
  String? importSource;

  IntakeDBO({
    required this.id,
    required this.unit,
    required this.amount,
    required this.type,
    required this.meal,
    required this.dateTime,
    this.importSource,
  });

  factory IntakeDBO.fromIntakeEntity(IntakeEntity entity) {
    return IntakeDBO(
      id: entity.id,
      unit: entity.unit,
      amount: entity.amount,
      type: IntakeTypeDBO.fromIntakeTypeEntity(entity.type),
      meal: MealDBO.fromMealEntity(entity.meal),
      dateTime: entity.dateTime,
      importSource: entity.importSource,
    );
  }

  factory IntakeDBO.fromJson(Map<String, dynamic> json) =>
      _$IntakeDBOFromJson(json);

  Map<String, dynamic> toJson() => _$IntakeDBOToJson(this);
}
