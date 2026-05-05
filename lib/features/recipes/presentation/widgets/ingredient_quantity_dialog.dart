import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/generated/l10n.dart';

class IngredientQuantitySelection {
  final double amount;
  final String unit;
  const IngredientQuantitySelection({required this.amount, required this.unit});
}

/// Modal bottom sheet that asks for the amount + unit of an ingredient.
/// Returns an [IngredientQuantitySelection] or null if cancelled.
Future<IngredientQuantitySelection?> showIngredientQuantityDialog(
  BuildContext context, {
  required MealEntity meal,
  double? initialAmount,
  String? initialUnit,
}) {
  return showModalBottomSheet<IngredientQuantitySelection>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _IngredientQuantitySheet(
      meal: meal,
      initialAmount: initialAmount,
      initialUnit: initialUnit,
    ),
  );
}

class _IngredientQuantitySheet extends StatefulWidget {
  final MealEntity meal;
  final double? initialAmount;
  final String? initialUnit;

  const _IngredientQuantitySheet({
    required this.meal,
    this.initialAmount,
    this.initialUnit,
  });

  @override
  State<_IngredientQuantitySheet> createState() =>
      _IngredientQuantitySheetState();
}

class _IngredientQuantitySheetState extends State<_IngredientQuantitySheet> {
  late TextEditingController _amountController;
  late String _unit;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.initialAmount != null
          ? widget.initialAmount!.toString()
          : '',
    );
    _unit = widget.initialUnit ?? _defaultUnit(widget.meal);
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  String _defaultUnit(MealEntity meal) {
    if (meal.hasServingValues) return 'serving';
    if (meal.isLiquid) return 'ml';
    return 'g';
  }

  List<DropdownMenuItem<String>> _unitItems(BuildContext context) {
    final items = <DropdownMenuItem<String>>[];
    if (widget.meal.hasServingValues) {
      items.add(const DropdownMenuItem(
        value: 'serving',
        child: Text('serving'),
      ));
    }
    if (widget.meal.isSolid ||
        (!widget.meal.isLiquid && !widget.meal.isSolid)) {
      items.add(const DropdownMenuItem(value: 'g', child: Text('g')));
      items.add(const DropdownMenuItem(value: 'kg', child: Text('kg')));
      items.add(const DropdownMenuItem(value: 'oz', child: Text('oz')));
    }
    if (widget.meal.isLiquid ||
        (!widget.meal.isLiquid && !widget.meal.isSolid)) {
      items.add(const DropdownMenuItem(value: 'ml', child: Text('ml')));
      items.add(const DropdownMenuItem(value: 'l', child: Text('l')));
      items.add(const DropdownMenuItem(value: 'fl.oz', child: Text('fl.oz')));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.meal.name ?? '?',
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _amountController,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+([.,]\d{0,2})?$'),
                      ),
                    ],
                    decoration: InputDecoration(
                      labelText: S.of(context).recipeIngredientAmountLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _unit,
                    decoration: InputDecoration(
                      labelText: S.of(context).recipeIngredientUnitLabel,
                      border: const OutlineInputBorder(),
                    ),
                    items: _unitItems(context),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _unit = value);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _onConfirm,
                child: Text(S.of(context).addLabel),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _onConfirm() {
    final raw = _amountController.text.replaceAll(',', '.');
    final amount = double.tryParse(raw);
    if (amount == null || amount <= 0) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(
      IngredientQuantitySelection(amount: amount, unit: _unit),
    );
  }
}
