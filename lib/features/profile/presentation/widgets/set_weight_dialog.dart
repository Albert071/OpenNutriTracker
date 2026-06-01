import 'package:flutter/material.dart';
import 'package:horizontal_picker/horizontal_picker.dart';
import 'package:opennutritracker/features/profile/presentation/utils/profile_picker_bounds.dart';
import 'package:opennutritracker/generated/l10n.dart';

class SetWeightDialog extends StatefulWidget {
  final double userWeight;
  final bool usesImperialUnits;

  /// When true, the dialog shows a date selector so a reading can be logged
  /// against a past day (backfilling history from the Trends view), and it
  /// pops `(weight: ..., date: ...)`. When false — the default, used by the
  /// home chip — it logs against today and pops just the weight, so existing
  /// callers are unaffected.
  final bool allowDateSelection;

  const SetWeightDialog({
    super.key,
    required this.userWeight,
    required this.usesImperialUnits,
    this.allowDateSelection = false,
  });

  @override
  State<SetWeightDialog> createState() => _SetWeightDialogState();
}

class _SetWeightDialogState extends State<SetWeightDialog> {
  late double selectedWeight;
  // Date-only (midnight) so it never sits after the date-only lastDate bound.
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    selectedWeight = widget.userWeight;
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final minWeight =
        minSelectableWeight(widget.userWeight, widget.usesImperialUnits);
    final maxWeight =
        maxSelectableWeight(widget.userWeight, widget.usesImperialUnits);

    return AlertDialog(
      title: Text(S.of(context).selectWeightDialogLabel),
      content: Wrap(
        children: [
          Column(
            children: [
              HorizontalPicker(
                height: 100,
                backgroundColor: Colors.transparent,
                minValue: minWeight,
                maxValue: maxWeight,
                initialPosition: InitialPosition.center,
                divisions: 1000, // Supports decimal values (#244)
                suffix: widget.usesImperialUnits
                    ? S.of(context).lbsLabel
                    : S.of(context).kgLabel,
                onChanged: (value) {
                  setState(() {
                    selectedWeight = value;
                  });
                },
              ),
              if (widget.allowDateSelection) ...[
                const SizedBox(height: 8),
                Semantics(
                  identifier: 'weight-date-picker',
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_rounded, size: 18),
                    label: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(_selectedDate)),
                    onPressed: _pickDate,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(S.of(context).dialogCancelLabel),
        ),
        TextButton(
          onPressed: () {
            final weight = clampWeightSelection(selectedWeight, minWeight);
            if (widget.allowDateSelection) {
              Navigator.pop(context, (weight: weight, date: _selectedDate));
            } else {
              Navigator.pop(context, weight);
            }
          },
          child: Text(S.of(context).dialogOKLabel),
        ),
      ],
    );
  }
}
