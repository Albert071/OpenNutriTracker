import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/presentation/widgets/app_card.dart';
import 'package:opennutritracker/core/presentation/widgets/meal_value_unit_text.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/styles/dimens.dart';
import 'package:opennutritracker/core/utils/energy_display.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/user_image_storage.dart';

class IntakeCard extends StatelessWidget {
  final IntakeEntity intake;
  final Function(BuildContext, IntakeEntity)? onItemLongPressed;
  final Function(BuildContext, IntakeEntity, bool)? onItemTapped;
  final bool firstListElement;
  final bool usesImperialUnits;

  const IntakeCard({
    required super.key,
    required this.intake,
    this.onItemLongPressed,
    this.onItemTapped,
    required this.firstListElement,
    required this.usesImperialUnits,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final radius = BorderRadius.circular(Dimens.radiusM);
    return Row(
      children: [
        SizedBox(width: firstListElement ? Dimens.spacing16 : 0),
        SizedBox(
          width: 120,
          height: 120,
          child: AppCard(
            padding: EdgeInsets.zero,
            borderRadius: Dimens.radiusM,
            child: ClipRRect(
              borderRadius: radius,
              child: InkWell(
                onLongPress: onItemLongPressed != null
                    ? () => onLongPressedItem(context)
                    : null,
                onTap: onItemTapped != null
                    ? () => onTappedItem(context, usesImperialUnits)
                    : null,
                child: Stack(
                  children: [
                    // Prefer the user-attached local photo for custom meals
                    // (#64 follow-up). Falls through to the OFF / FDC remote
                    // image when the user hasn't picked one, and finally to
                    // the placeholder icon for entries that have neither.
                    if (intake.meal.localImagePath != null)
                      _LocalMealBackground(
                          relativePath: intake.meal.localImagePath!)
                    else if (intake.meal.mainImageUrl != null)
                      CachedNetworkImage(
                        cacheManager: locator<CacheManager>(),
                        imageUrl: intake.meal.mainImageUrl ?? "",
                        imageBuilder: (context, imageProvider) => Container(
                          decoration: BoxDecoration(
                            image: DecorationImage(
                              image: imageProvider,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      )
                    else
                      Center(
                        child: Icon(
                          Icons.restaurant_rounded,
                          color: palette.textMuted,
                          size: 26,
                        ),
                      ),
                    Container(
                      // Soft scrim so the name and pill stay legible over a photo.
                      decoration: BoxDecoration(
                        color: palette.surface.withValues(alpha: 0.45),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.all(Dimens.spacing8),
                      padding: const EdgeInsets.fromLTRB(8.0, 4.0, 8.0, 4.0),
                      decoration: BoxDecoration(
                        color: palette.surfaceMuted.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(Dimens.radiusS),
                      ),
                      child: Text(
                        EnergyDisplay.formatWithUnit(context, intake.totalKcal),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: palette.textStrong,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(Dimens.spacing8),
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AutoSizeText(
                            intake.meal.name ?? "?",
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: palette.textStrong,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          MealValueUnitText(
                            value: intake.amount,
                            meal: intake.meal,
                            usesImperialUnits: usesImperialUnits,
                            textStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: palette.textMuted,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void onLongPressedItem(BuildContext context) {
    onItemLongPressed?.call(context, intake);
  }

  void onTappedItem(BuildContext context, bool usesImperialUnits) {
    onItemTapped?.call(context, intake, usesImperialUnits);
  }
}

/// Renders a user-attached meal photo behind the intake-card overlay.
/// Mirrors the `CachedNetworkImage` branch's BoxFit / decoration so the
/// card's gradient + kcal pill sit on top exactly as they did before.
class _LocalMealBackground extends StatelessWidget {
  final String relativePath;

  const _LocalMealBackground({required this.relativePath});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: UserImageStorage.absolutePath(relativePath),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final file = File(snapshot.data!);
        if (!file.existsSync()) return const SizedBox.shrink();
        return Container(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: FileImage(file),
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}
