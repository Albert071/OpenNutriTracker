import 'package:flutter/material.dart';

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

  static const _ageOptions = <_AgeOption>[
    _AgeOption(label: '3 years', duration: Duration(days: 365 * 3)),
    _AgeOption(label: '5 years', duration: Duration(days: 365 * 5)),
    _AgeOption(label: '10 years', duration: Duration(days: 365 * 10)),
    _AgeOption(label: 'Any', duration: null),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ListView(
        children: [
          // l10n: offlineCatalogQualityTitle
          Text(
            'Quality filters',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          // l10n: offlineCatalogQualityBody
          Text(
            'These defaults give you a smaller, more useful catalog. '
            'Turn them off only if you know you want the long tail of '
            'partial entries.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          _buildToggle(
            // l10n: offlineCatalogQualityNutritionLabel
            label: 'Only entries with full nutrition data',
            // l10n: offlineCatalogQualityNutritionBody
            body: 'Drops products that have no calorie or macro '
                'information yet — useful in search results, where '
                'these would otherwise show up as blank cards.',
            value: _requireNutritionGrade,
            onChanged: (v) {
              setState(() => _requireNutritionGrade = v);
              _emit();
            },
          ),
          const SizedBox(height: 16),
          _buildToggle(
            // l10n: offlineCatalogQualityPopularityLabel
            label: 'Only well-scanned products',
            // l10n: offlineCatalogQualityPopularityBody
            body: 'Skips products only scanned once. The long tail of '
                'one-off submissions is unlikely to be what you are '
                'looking at in the supermarket, and dropping it cuts '
                'the catalog size by a third.',
            value: _requireMinPopularity,
            onChanged: (v) {
              setState(() => _requireMinPopularity = v);
              _emit();
            },
          ),
          const SizedBox(height: 24),
          // l10n: offlineCatalogQualityRecencyLabel
          Text(
            'Updated within',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          // l10n: offlineCatalogQualityRecencyBody
          Text(
            'Older entries can drift — packaging changes, recipes get '
            'reformulated. Pick a window that feels right.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final option in _ageOptions)
                ChoiceChip(
                  label: Text(option.label),
                  selected: _maxAge == option.duration,
                  onSelected: (_) {
                    setState(() => _maxAge = option.duration);
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

class _AgeOption {
  final String label;
  final Duration? duration;

  const _AgeOption({required this.label, required this.duration});
}
