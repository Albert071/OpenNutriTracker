import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/entity/tracked_day_entity.dart';
import 'package:opennutritracker/core/domain/entity/weight_log_entity.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_tracked_day_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_user_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_water_intake_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_weight_log_usecase.dart';

part 'trends_event.dart';
part 'trends_state.dart';

class TrendsBloc extends Bloc<TrendsEvent, TrendsState> {
  final GetTrackedDayUsecase _getTrackedDayUsecase;
  final GetWeightLogUsecase _getWeightLogUsecase;
  final GetUserUsecase _getUserUsecase;
  final GetConfigUsecase _getConfigUsecase;
  final GetWaterIntakeUsecase _getWaterIntakeUsecase;

  TrendsBloc(
    this._getTrackedDayUsecase,
    this._getWeightLogUsecase,
    this._getUserUsecase,
    this._getConfigUsecase,
    this._getWaterIntakeUsecase,
  ) : super(const TrendsInitial()) {
    on<LoadTrendsEvent>((event, emit) async {
      emit(const TrendsLoading());
      try {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final days = await _getTrackedDayUsecase.getTrackedDaysByRange(
          today.subtract(Duration(days: event.rangeDays - 1)),
          today,
        );
        // The full weight history; the chart windows it for display. This
        // mirrors the weight-history screen, so a reading from weeks ago
        // still shows once the range is wide enough to include it.
        final weight = await _getWeightLogUsecase.getAllEntries();
        weight.sort((a, b) => a.date.compareTo(b.date));
        // The 7 days before this week, for a week-over-week consistency delta.
        final priorWeek = await _getTrackedDayUsecase.getTrackedDaysByRange(
          today.subtract(const Duration(days: 13)),
          today.subtract(const Duration(days: 7)),
        );
        final user = await _getUserUsecase.getUserData();
        final config = await _getConfigUsecase.getConfig();

        // Water totalled per calendar day; the card fills missing days with 0.
        final waterEntries = await _getWaterIntakeUsecase.getAllEntries();
        final waterByDay = <DateTime, int>{};
        for (final e in waterEntries) {
          final d = DateTime(e.dateTime.year, e.dateTime.month, e.dateTime.day);
          waterByDay[d] = (waterByDay[d] ?? 0) + e.amountMl;
        }

        emit(TrendsLoaded(
          rangeDays: event.rangeDays,
          days: days,
          priorWeek: priorWeek,
          weight: weight,
          usesImperialUnits: config.usesImperialUnits,
          targetWeightKg: user.targetWeightKg,
          waterByDay: waterByDay,
          waterGoalMl: config.effectiveDailyWaterGoalMl(
            user.gender,
            caloriesProfile: user.caloriesProfile,
          ),
        ));
      } catch (e) {
        emit(TrendsFailed(e.toString()));
      }
    });
  }
}
