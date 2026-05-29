import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/entity/tracked_day_entity.dart';
import 'package:opennutritracker/core/domain/entity/weight_log_entity.dart';
import 'package:opennutritracker/core/presentation/widgets/app_card.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/styles/dimens.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/trends/presentation/bloc/trends_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

class TrendsPage extends StatelessWidget {
  const TrendsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TrendsBloc>(
      create: (_) => locator<TrendsBloc>()..add(const LoadTrendsEvent()),
      child: const _TrendsView(),
    );
  }
}

class _TrendsView extends StatelessWidget {
  const _TrendsView();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return BlocBuilder<TrendsBloc, TrendsState>(
      builder: (context, state) {
        if (state is! TrendsLoaded) {
          return const Center(child: CircularProgressIndicator());
        }
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final weekStart = today.subtract(const Duration(days: 6));
        final week = state.days.where((d) => !d.day.isBefore(weekStart)).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(
              Dimens.spacing16, Dimens.spacing8, Dimens.spacing16, Dimens.spacing32),
          children: [
            _StreakCard(week: week, priorWeek: state.priorWeek, palette: palette),
            const SizedBox(height: Dimens.spacing16),
            _RangeSelector(rangeDays: state.rangeDays),
            const SizedBox(height: Dimens.spacing16),
            _CaloriesTrendCard(days: state.days, rangeDays: state.rangeDays, palette: palette),
            const SizedBox(height: Dimens.spacing16),
            _MacrosTrendCard(days: state.days, palette: palette),
            const SizedBox(height: Dimens.spacing16),
            _WeightCard(entries: state.weight, palette: palette),
          ],
        );
      },
    );
  }
}

class _RangeSelector extends StatelessWidget {
  final int rangeDays;
  const _RangeSelector({required this.rangeDays});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 7, label: Text('7d')),
          ButtonSegment(value: 30, label: Text('30d')),
          ButtonSegment(value: 90, label: Text('90d')),
        ],
        selected: {rangeDays},
        onSelectionChanged: (s) =>
            context.read<TrendsBloc>().add(LoadTrendsEvent(rangeDays: s.first)),
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  final List<TrackedDayEntity> week;
  final List<TrackedDayEntity> priorWeek;
  final AppPalette palette;
  const _StreakCard({required this.week, required this.priorWeek, required this.palette});

  int _onTrackCount(BuildContext context, List<TrackedDayEntity> days) {
    final errorColor = Theme.of(context).colorScheme.error;
    return days.where((d) => d.getCalendarDayRatingColor(context) != errorColor).length;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final onTrack = _onTrackCount(context, week);
    final delta = onTrack - _onTrackCount(context, priorWeek);
    final text = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(Dimens.spacing20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(Dimens.spacing12),
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(Icons.local_fire_department_rounded, color: accent, size: 28),
          ),
          const SizedBox(width: Dimens.spacing16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$onTrack / 7', style: text.titleLarge),
                Text(S.of(context).trendsDaysOnTrack,
                    style: text.bodyMedium?.copyWith(color: palette.textMuted)),
              ],
            ),
          ),
          if (delta != 0) _WeekDeltaChip(delta: delta, palette: palette),
        ],
      ),
    );
  }
}

/// Week-over-week change in on-track days, shown as a coloured arrow + number
/// (locale-neutral — no wording needed).
class _WeekDeltaChip extends StatelessWidget {
  final int delta;
  final AppPalette palette;
  const _WeekDeltaChip({required this.delta, required this.palette});

  @override
  Widget build(BuildContext context) {
    final up = delta > 0;
    final color = up ? palette.proteinColor : palette.fatColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Dimens.spacing12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: Dimens.borderRadiusS,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, color: color, size: 16),
          const SizedBox(width: 2),
          Text('${delta.abs()}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _CaloriesTrendCard extends StatelessWidget {
  final List<TrackedDayEntity> days;
  final int rangeDays;
  final AppPalette palette;
  const _CaloriesTrendCard({required this.days, required this.rangeDays, required this.palette});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final byDay = {for (final d in days) DateTime(d.day.year, d.day.month, d.day.day): d};
    // Full per-day series across the window; missing days contribute 0 tracked.
    final spots = <FlSpot>[];
    final goals = <double>[];
    for (int i = 0; i < rangeDays; i++) {
      final day = today.subtract(Duration(days: rangeDays - 1 - i));
      final d = byDay[DateTime(day.year, day.month, day.day)];
      spots.add(FlSpot(i.toDouble(), d?.caloriesTracked ?? 0));
      if (d != null && d.calorieGoal > 0) goals.add(d.calorieGoal);
    }
    final avgGoal = goals.isEmpty ? 0.0 : goals.reduce((a, b) => a + b) / goals.length;
    final maxTracked = spots.fold<double>(0, (m, s) => s.y > m ? s.y : m);
    final maxY = [maxTracked, avgGoal].reduce((a, b) => a > b ? a : b) * 1.15 + 1;

    return AppCard(
      padding: const EdgeInsets.all(Dimens.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of(context).trendsCaloriesLabel, style: text.titleMedium),
          const SizedBox(height: Dimens.spacing20),
          Semantics(
            label: S.of(context).trendsCaloriesLabel,
            child: SizedBox(
            height: 140,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (rangeDays - 1).toDouble(),
                minY: 0,
                maxY: maxY,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: const FlTitlesData(show: false),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => [
                      for (final s in spots)
                        LineTooltipItem(
                          s.y.toInt().toString(),
                          text.labelMedium ?? const TextStyle(),
                        ),
                    ],
                  ),
                ),
                // Dashed average-goal reference: the line above/below it reads
                // as days over / under goal at a glance.
                extraLinesData: avgGoal <= 0
                    ? const ExtraLinesData()
                    : ExtraLinesData(horizontalLines: [
                        HorizontalLine(
                          y: avgGoal,
                          color: palette.textMuted,
                          strokeWidth: 1.2,
                          dashArray: const [6, 4],
                        ),
                      ]),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    preventCurveOverShooting: true,
                    color: accent,
                    barWidth: 3,
                    dotData: FlDotData(show: rangeDays <= 7),
                    belowBarData: BarAreaData(show: true, color: accent.withValues(alpha: 0.12)),
                  ),
                ],
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }
}

class _MacrosTrendCard extends StatelessWidget {
  final List<TrackedDayEntity> days;
  final AppPalette palette;
  const _MacrosTrendCard({required this.days, required this.palette});

  double _avg(Iterable<double?> values) {
    final present = values.whereType<double>().toList();
    if (present.isEmpty) return 0;
    return present.reduce((a, b) => a + b) / present.length;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rows = [
      (S.of(context).carbsLabel, _avg(days.map((d) => d.carbsTracked)),
          _avg(days.map((d) => d.carbsGoal)), palette.carbs),
      (S.of(context).fatLabel, _avg(days.map((d) => d.fatTracked)),
          _avg(days.map((d) => d.fatGoal)), palette.fat),
      (S.of(context).proteinLabel, _avg(days.map((d) => d.proteinTracked)),
          _avg(days.map((d) => d.proteinGoal)), palette.protein),
    ];
    return AppCard(
      padding: const EdgeInsets.all(Dimens.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Average intake vs goal over the window — daily-average macros.
          Text(S.of(context).trendsDailyAverageLabel, style: text.titleMedium),
          const SizedBox(height: Dimens.spacing16),
          for (final (label, intake, goal, color) in rows) ...[
            Row(
              children: [
                Text(label, style: text.labelMedium),
                const Spacer(),
                Text('${intake.toInt()} / ${goal.toInt()} g',
                    style: text.bodySmall?.copyWith(color: palette.textStrong, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: goal <= 0 ? 0 : (intake / goal).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: palette.surfaceMuted,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: Dimens.spacing16),
          ],
        ],
      ),
    );
  }
}

class _WeightCard extends StatelessWidget {
  final List<WeightLogEntity> entries;
  final AppPalette palette;
  const _WeightCard({required this.entries, required this.palette});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(Dimens.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of(context).weightHistoryWeightLabel, style: text.titleMedium),
          const SizedBox(height: Dimens.spacing20),
          Semantics(
            label: S.of(context).weightHistoryWeightLabel,
            child: SizedBox(height: 150, child: _buildChart(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (entries.length < 2) {
      return Center(
        child: Text(
          S.of(context).weightHistoryChartEmptyState,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: palette.textMuted),
        ),
      );
    }
    final accent = Theme.of(context).colorScheme.primary;
    final start = entries.first.date;
    final spots = [
      for (final e in entries) FlSpot(e.date.difference(start).inDays.toDouble(), e.weightKg),
    ];
    final ys = spots.map((s) => s.y);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = ((maxY - minY) * 0.2).clamp(0.5, 5.0);
    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  s.y.toStringAsFixed(1),
                  text.labelMedium ?? const TextStyle(),
                ),
            ],
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            color: accent,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true, color: accent.withValues(alpha: 0.12)),
          ),
        ],
      ),
    );
  }
}
