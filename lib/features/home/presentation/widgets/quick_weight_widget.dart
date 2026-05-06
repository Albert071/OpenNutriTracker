import 'package:flutter/material.dart';
import 'package:opennutritracker/core/domain/usecase/add_user_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_user_usecase.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/features/profile/presentation/widgets/set_weight_dialog.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// #281: Quick weight update chip on the home screen.
///
/// Reads `weightKg` from `HomeLoadedState` (single source of truth) instead
/// of doing its own DB read; that read used to race with onboarding's user
/// write and silently displayed the dummy 80 kg fallback.
class QuickWeightWidget extends StatelessWidget {
  final double weightKg;
  final bool usesImperialUnits;

  const QuickWeightWidget({
    super.key,
    required this.weightKg,
    required this.usesImperialUnits,
  });

  @override
  Widget build(BuildContext context) {
    final displayWeight =
        usesImperialUnits ? weightKg * 2.20462 : weightKg;
    final unit = usesImperialUnits
        ? S.of(context).lbsLabel
        : S.of(context).kgLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          const Icon(Icons.monitor_weight_outlined, size: 18),
          const SizedBox(width: 8),
          Text(
            '${displayWeight.toStringAsFixed(1)} $unit',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
            tooltip: S.of(context).editMealLabel,
            onPressed: () => _showWeightDialog(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showWeightDialog(BuildContext context) async {
    final displayWeight =
        usesImperialUnits ? weightKg * 2.20462 : weightKg;

    final newWeight = await showDialog<double>(
      context: context,
      builder: (context) => SetWeightDialog(
        userWeight: displayWeight,
        usesImperialUnits: usesImperialUnits,
      ),
    );

    if (newWeight == null || !context.mounted) return;

    final newWeightKg =
        usesImperialUnits ? newWeight / 2.20462 : newWeight;

    final user = await locator<GetUserUsecase>().getUserData();
    user.weightKG = newWeightKg;
    await locator<AddUserUsecase>().addUser(user);

    // Refresh home kcal goal (weight affects TDEE). The state emit will
    // flow back through BlocBuilder and rebuild this widget with the new
    // weight — no local cache needed.
    locator<HomeBloc>().add(const LoadItemsEvent());
  }
}
