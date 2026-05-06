import 'package:flutter/material.dart';
import 'package:opennutritracker/core/domain/entity/calories_profile_entity.dart';
import 'package:opennutritracker/generated/l10n.dart';

class CaloriesProfileInfoDialog extends StatefulWidget {
  final CaloriesProfileEntity initialProfile;

  const CaloriesProfileInfoDialog({
    super.key,
    this.initialProfile = CaloriesProfileEntity.averaged,
  });

  @override
  State<CaloriesProfileInfoDialog> createState() =>
      _CaloriesProfileInfoDialogState();
}

class _CaloriesProfileInfoDialogState extends State<CaloriesProfileInfoDialog> {
  late CaloriesProfileEntity _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialProfile;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).caloriesProfileInfoTitle),
      icon: const Icon(Icons.tune_outlined),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.of(context).caloriesProfileInfoBody,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            RadioGroup<CaloriesProfileEntity>(
              groupValue: _selected,
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selected = value);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final profile in CaloriesProfileEntity.values)
                    RadioListTile<CaloriesProfileEntity>(
                      value: profile,
                      contentPadding: EdgeInsets.zero,
                      title: Text(profile.getName(context)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.of(context).dialogCancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Text(S.of(context).dialogOKLabel),
        ),
      ],
    );
  }
}
