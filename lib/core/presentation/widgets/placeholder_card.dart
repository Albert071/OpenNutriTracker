import 'package:flutter/material.dart';
import 'package:opennutritracker/core/presentation/widgets/app_card.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/styles/dimens.dart';

class PlaceholderCard extends StatelessWidget {
  final DateTime day;
  final VoidCallback onTap;
  final bool firstListElement;

  /// Stable handle for UI drivers. Differs per list (meals vs activity) so
  /// the right "add" card can be targeted unambiguously.
  final String semanticIdentifier;

  const PlaceholderCard({
    super.key,
    required this.day,
    required this.onTap,
    required this.firstListElement,
    required this.semanticIdentifier,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return Align(
      alignment: Alignment.topLeft,
      child: Row(
        children: [
          SizedBox(
            width: firstListElement ? Dimens.spacing16 : 0, // Add leading padding
          ),
          SizedBox(
            width: 120,
            height: 120,
            child: Semantics(
              identifier: semanticIdentifier,
              child: AppCard(
                color: palette.surfaceMuted,
                borderRadius: Dimens.radiusM,
                onTap: onTap,
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: 32,
                    color: palette.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
