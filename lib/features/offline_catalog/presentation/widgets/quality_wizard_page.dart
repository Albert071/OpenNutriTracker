import 'package:flutter/material.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Three-control quality filter page. All defaults are the
/// recommended setting so a user who taps Next without thinking still
/// gets a sensible catalog. Each control has a one-line explanation
/// underneath.
class QualityWizardPage extends StatefulWidget {
  final bool initialRequireNutritionGrade;
  final bool initialRequireMinPopularity;
  final Duration? initialMaxAge;
  final void Function(
    bool requireNutritionGrade,
    bool requireMinPopularity,
    Duration? maxAge,
  ) onChanged;

  const QualityWizardPage({
    super.key,
    required this.initialRequireNutritionGrade,
    required this.initialRequireMinPopularity,
    required this.initialMaxAge,
    required this.onChanged,
  });

  @override
  State<QualityWizardPage> createState() => _QualityWizardPageState();
}

class _QualityWizardPageState extends State<QualityWizardPage> {
  late bool _requireNutritionGrade;
  late bool _requireMinPopularity;
  late Duration? _maxAge;

  static const _ageDurations = <Duration?>[
    Duration(days: 365 * 3),
    Duration(days: 365 * 5),
    Duration(days: 365 * 10),
    null,
  ];

  List<String> _ageLabels(S s) => [
        s.offlineCatalogQualityRecency3Years,
        s.offlineCatalogQualityRecency5Years,
        s.offlineCatalogQualityRecency10Years,
        s.offlineCatalogQualityRecencyAny,
      ];

  @override
  void initState() {
    super.initState();
    _requireNutritionGrade = widget.initialRequireNutritionGrade;
    _requireMinPopularity = widget.initialRequireMinPopularity;
    _maxAge = widget.initialMaxAge;
  }

  void _emit() {
    widget.onChanged(
      _requireNutritionGrade,
      _requireMinPopularity,
      _maxAge,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    final ageLabels = _ageLabels(s);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.offlineCatalogQualityTitle, style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(s.offlineCatalogQualityBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          _buildToggle(
            label: s.offlineCatalogQualityNutritionLabel,
            body: s.offlineCatalogQualityNutritionBody,
            value: _requireNutritionGrade,
            onChanged: (v) {
              setState(() => _requireNutritionGrade = v);
              _emit();
            },
          ),
          const SizedBox(height: 16),
          _buildToggle(
            label: s.offlineCatalogQualityPopularityLabel,
            body: s.offlineCatalogQualityPopularityBody,
            value: _requireMinPopularity,
            onChanged: (v) {
              setState(() => _requireMinPopularity = v);
              _emit();
            },
          ),
          const SizedBox(height: 24),
          Text(s.offlineCatalogQualityRecencyLabel,
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(s.offlineCatalogQualityRecencyBody,
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < _ageDurations.length; i++)
                ChoiceChip(
                  label: Text(ageLabels[i]),
                  selected: _maxAge == _ageDurations[i],
                  onSelected: (_) {
                    setState(() => _maxAge = _ageDurations[i]);
                    _emit();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggle({
    required String label,
    required String body,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleMedium)),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
          const SizedBox(height: 4),
          Text(body, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

