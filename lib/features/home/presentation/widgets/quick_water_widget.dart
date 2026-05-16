import 'package:flutter/material.dart';
import 'package:opennutritracker/features/home/presentation/widgets/log_water_dialog.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// #32: hydration chip that sits next to the weight chip on the home
/// screen. Reads `waterMlToday` and `waterGoalMl` from `HomeLoadedState`
/// so it stays consistent with whatever logical day the rest of the
/// home view is using.
class QuickWaterWidget extends StatelessWidget {
  final int waterMlToday;
  final int waterGoalMl;

  const QuickWaterWidget({
    super.key,
    required this.waterMlToday,
    required this.waterGoalMl,
  });

  @override
  Widget build(BuildContext context) {
    final label = S.of(context).waterChipLabel(waterMlToday, waterGoalMl);

    return Semantics(
      identifier: 'home-water-chip',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.water_drop_outlined, size: 18),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 4),
          Semantics(
            identifier: 'home-water-edit',
            container: true,
            child: IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              tooltip: S.of(context).logWaterDialogTitle,
              onPressed: () => _showDialog(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const LogWaterDialog(),
    );
  }
}
