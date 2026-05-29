import 'package:flutter/material.dart';
import 'package:opennutritracker/core/domain/entity/user_activity_entity.dart';
import 'package:opennutritracker/core/presentation/widgets/app_card.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/styles/dimens.dart';
import 'package:opennutritracker/core/utils/energy_display.dart';

class ActivityCard extends StatelessWidget {
  final UserActivityEntity activityEntity;
  final Function(BuildContext, UserActivityEntity) onItemLongPressed;
  final Function(BuildContext, UserActivityEntity)? onItemTapped;
  final Function(bool isDragging)? onItemDragCallback;
  final bool firstListElement;

  const ActivityCard({
    super.key,
    required this.activityEntity,
    required this.onItemLongPressed,
    required this.firstListElement,
    this.onItemTapped,
    this.onItemDragCallback,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final radius = BorderRadius.circular(Dimens.radiusM);
    final card = Row(
      children: [
        SizedBox(
          width: firstListElement ? Dimens.spacing16 : 0,
        ),
        SizedBox(
          width: 120,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 120,
                child: AppCard(
                  padding: EdgeInsets.zero,
                  borderRadius: Dimens.radiusM,
                  child: ClipRRect(
                    borderRadius: radius,
                    child: InkWell(
                      onTap: onItemTapped != null
                          ? () => onItemTapped!(context, activityEntity)
                          : null,
                      onLongPress: onItemDragCallback == null
                          ? () => onItemLongPressed(context, activityEntity)
                          : null,
                      child: Stack(
                        children: [
                          Container(
                            margin: const EdgeInsets.all(Dimens.spacing8),
                            padding:
                                const EdgeInsets.fromLTRB(8.0, 4.0, 8.0, 4.0),
                            decoration: BoxDecoration(
                              color: palette.surfaceMuted,
                              borderRadius:
                                  BorderRadius.circular(Dimens.radiusS),
                            ),
                            child: Text(
                              "🔥${EnergyDisplay.formatWithUnit(context, activityEntity.burnedKcal)}",
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: palette.textStrong,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                          Center(
                            child: Icon(
                              activityEntity.physicalActivityEntity.displayIcon,
                              color: Theme.of(context).colorScheme.primary,
                              size: 26,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Dimens.spacing8),
              Padding(
                padding: const EdgeInsets.only(left: Dimens.spacing4),
                child: Text(
                  activityEntity.physicalActivityEntity.getName(context),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: palette.textStrong,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: Dimens.spacing4),
                child: Text(
                  '${activityEntity.duration.toInt()} min',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (onItemDragCallback == null) return card;

    return LongPressDraggable<UserActivityEntity>(
      data: activityEntity,
      onDragStarted: () => onItemDragCallback!.call(true),
      onDragEnd: (_) => onItemDragCallback!.call(false),
      onDraggableCanceled: (velocity, offset) => onItemDragCallback!.call(false),
      feedback: Material(
        color: Colors.transparent,
        child: AppCard(
          width: 80,
          height: 80,
          borderRadius: Dimens.radiusM,
          child: Center(
            child: Icon(
              activityEntity.physicalActivityEntity.displayIcon,
              size: 36,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }
}
