import 'package:flutter/material.dart';

/// First page of the offline-catalog wizard. Plain explanation of
/// what the user is about to opt into, with the honest upfront notes
/// about Wi-Fi, screen-on time, and human-food-only scope.
class WelcomeWizardPage extends StatelessWidget {
  const WelcomeWizardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // l10n: offlineCatalogWelcomeTitle
          Text(
            'Build an offline food catalog',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          // l10n: offlineCatalogWelcomeBody1
          Text(
            'We can download a copy of the Open Food Facts database '
            'so search and barcode lookups work without an internet '
            'connection.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          // l10n: offlineCatalogWelcomeBody2
          Text(
            'You choose the countries on the next page; we keep just '
            'the columns the app actually uses (no images on disk, no '
            'unused metadata) so the download stays as small as we '
            'can make it.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          _Bullet(
            // l10n: offlineCatalogWelcomeBulletWifi
            text: 'We strongly recommend a Wi-Fi connection — the '
                'download can be hundreds of megabytes depending on '
                'how many countries you pick.',
            icon: Icons.wifi,
          ),
          _Bullet(
            // l10n: offlineCatalogWelcomeBulletScreen
            text: 'Please keep this screen open while the catalog '
                'builds. If the app is backgrounded for too long, the '
                'download will pause and you can resume it later.',
            icon: Icons.smartphone,
          ),
          _Bullet(
            // l10n: offlineCatalogWelcomeBulletHumanFood
            text: 'The catalog covers human food only — pet food, '
                'cosmetics, and other non-food entries are filtered '
                'out for you.',
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
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
