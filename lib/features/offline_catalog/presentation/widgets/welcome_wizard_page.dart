import 'package:flutter/material.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// First page of the offline-catalog wizard. Plain explanation of
/// what the user is about to opt into, with the honest upfront notes
/// about Wi-Fi, screen-on time, and human-food-only scope.
class WelcomeWizardPage extends StatelessWidget {
  const WelcomeWizardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.offlineCatalogWelcomeTitle,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(s.offlineCatalogWelcomeBody1, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          Text(s.offlineCatalogWelcomeBody2, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 24),
          _Bullet(text: s.offlineCatalogWelcomeBulletWifi, icon: Icons.wifi),
          _Bullet(
            text: s.offlineCatalogWelcomeBulletScreen,
            icon: Icons.smartphone,
          ),
          _Bullet(
            text: s.offlineCatalogWelcomeBulletHumanFood,
            icon: Icons.restaurant,
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  final IconData icon;

  const _Bullet({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
