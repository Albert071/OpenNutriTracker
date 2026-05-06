import 'package:flutter/material.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// #284: Dialog for setting the weekly weight change rate.
/// Returns a nullable double (kg/week): negative = lose, positive = gain, null = clear/not set.
class SetWeeklyWeightGoalDialog extends StatefulWidget {
  final double? currentGoalKg;
  final bool usesImperialUnits;

  const SetWeeklyWeightGoalDialog({
    super.key,
    required this.currentGoalKg,
    required this.usesImperialUnits,
  });

  @override
  State<SetWeeklyWeightGoalDialog> createState() =>
      _SetWeeklyWeightGoalDialogState();
}

class _SetWeeklyWeightGoalDialogState
    extends State<SetWeeklyWeightGoalDialog> {
  // Slider range in kg/week: -1.0 (lose 1 kg/wk) to +1.0 (gain 1 kg/wk)
  static const double _minKg = -1.0;
  static const double _maxKg = 1.0;
  static const int _divisions = 8; // steps of 0.25 kg

  late double _selectedKg;

  @override
  void initState() {
    super.initState();
    _selectedKg = widget.currentGoalKg ?? 0.0;
    _selectedKg = _selectedKg.clamp(_minKg, _maxKg);
  }

  double get _displayValue => widget.usesImperialUnits
      ? _selectedKg * 2.20462
      : _selectedKg;

  String get _displayLabel {
    if (_selectedKg == 0.0) return S.of(context).goalMaintainWeight;
    final sign = _displayValue > 0 ? '+' : '';
    final formatted = '$sign${_displayValue.toStringAsFixed(2)}';
    return widget.usesImperialUnits
        ? S.of(context).weeklyWeightGoalLbsPerWeek(formatted)
        : S.of(context).weeklyWeightGoalKgPerWeek(formatted);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).chooseWeeklyWeightGoalLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _displayLabel,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Slider(
            min: _minKg,
            max: _maxKg,
            divisions: _divisions,
            value: _selectedKg,
            label: _displayLabel,
            onChanged: (value) => setState(() => _selectedKg = value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.usesImperialUnits ? '-2.2 lbs' : '-1.0 kg',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                widget.usesImperialUnits ? '+2.2 lbs' : '+1.0 kg',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(S.of(context).dialogCancelLabel),
        ),
        // Always offer Reset — users need a way to fall back to the
        // overall weight goal (lose / maintain / gain) even if they
        // opened the slider once and never set an explicit weekly rate.
        TextButton(
          onPressed: () => Navigator.of(context).pop(_kClearSentinel),
          child: Text(S.of(context).buttonResetLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selectedKg),
          child: Text(S.of(context).dialogOKLabel),
        ),
      ],
    );
  }
}

/// Sentinel value returned when the user chooses to clear the weekly goal.
const double _kClearSentinel = double.nan;

/// Returns true when the dialog result signals "clear the goal".
bool isWeeklyGoalClear(double? result) =>
    result != null && result.isNaN;
