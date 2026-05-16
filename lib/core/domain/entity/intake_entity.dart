import 'package:equatable/equatable.dart';
import 'package:opennutritracker/core/data/dbo/intake_dbo.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';

class IntakeEntity extends Equatable {
  final String id;
  final String unit;
  final double amount;
  final IntakeTypeEntity type;
  final DateTime dateTime;

  final MealEntity meal;

  /// #295: Where this intake came from. Null for entries logged inside
  /// OpenNutriTracker (the default). Currently the only non-null value
  /// produced anywhere in the app is `health_connect`.
  final String? importSource;

  const IntakeEntity({
    required this.id,
    required this.unit,
    required this.amount,
    required this.type,
    required this.meal,
    required this.dateTime,
    this.importSource,
  });

  factory IntakeEntity.fromIntakeDBO(IntakeDBO intakeDBO) {
    return IntakeEntity(
      id: intakeDBO.id,
      unit: intakeDBO.unit,
      amount: intakeDBO.amount,
      type: IntakeTypeEntity.fromIntakeTypeDBO(intakeDBO.type),
      meal: MealEntity.fromMealDBO(intakeDBO.meal),
      dateTime: intakeDBO.dateTime,
      importSource: intakeDBO.importSource,
    );
  }

  double get totalKcal => amount * (meal.nutriments.energyPerUnit ?? 0);

  double get totalCarbsGram =>
      amount * (meal.nutriments.carbohydratesPerUnit ?? 0);

  double get totalFatsGram => amount * (meal.nutriments.fatPerUnit ?? 0);

  double get totalProteinsGram =>
      amount * (meal.nutriments.proteinsPerUnit ?? 0);

  @override
  List<Object?> get props => [id, unit, amount, type, dateTime, importSource];
}
