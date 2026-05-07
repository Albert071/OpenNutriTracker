import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Page 3 of the wizard. Reads the static estimate for the user's
/// filter set from the bloc and shows expected products, on-disk
/// size, download size, and a rough ETA.
///
/// The pivot to download-prebuilt removed the typed-confirmation
/// footgun the old above-hard-cap path used — every variant is now a
/// well-bounded prebuilt artefact, the largest is ~520 MB compressed,
/// and the user makes an informed choice from the summary alone.
class EstimateConfirmWizardPage extends StatelessWidget {
  const EstimateConfirmWizardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OfflineCatalogBloc, OfflineCatalogState>(
      builder: (context, state) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _buildBody(context, state),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, OfflineCatalogState state) {
    // Error first — when the estimate call fails, [state.estimate]
    // stays null but the phase moves to error. If we let the
    // null-estimate branch run before checking the phase the user
    // sees an indefinite spinner instead of the recovery message.
    if (state.phase == OfflineCatalogPhase.error) {
      return _ErrorView(
        message: state.errorMessage,
        activeFilters: state.activeFilters,
      );
    }
    if (state.phase == OfflineCatalogPhase.estimating ||
        state.estimate == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final estimate = state.estimate!;
    final theme = Theme.of(context);
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.offlineCatalogEstimateTitle,
            style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(s.offlineCatalogEstimateBody, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        // Roughly how many products this variant carries.
        _SummaryRow(
          icon: Icons.storage,
          label: s.offlineCatalogEstimateRowsLabel,
          value: '~${_formatRows(estimate.rows)}',
        ),
        // On-disk size of the resulting sqlite catalog (uncompressed).
        _SummaryRow(
          icon: Icons.sd_storage,
          label: s.offlineCatalogEstimateSizeLabel,
          value: _formatBytes(estimate.estimatedBytes),
        ),
        // Download bytes (compressed gzip from the catalog CDN).
        _SummaryRow(
          icon: Icons.cloud_download,
          label: s.offlineCatalogEstimateRequestsLabel,
          value: _formatBytes(estimate.requests),
        ),
        _SummaryRow(
          icon: Icons.timer_outlined,
          label: s.offlineCatalogEstimateTimeLabel,
          value: _formatDuration(Duration(seconds: estimate.etaSeconds)),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.wifi, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(s.offlineCatalogEstimateWifiHint)),
            ],
          ),
        ),
      ],
    );
  }

  String _formatRows(int rows) {
    if (rows >= 1000000) {
      return '${(rows / 1000000).toStringAsFixed(2)} million';
    }
    if (rows >= 1000) {
      return '${(rows / 1000).round()},000';
    }
    return '$rows';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes B';
  }

  String _formatDuration(Duration d) {
    if (d.inHours >= 1) {
      final mins = d.inMinutes - d.inHours * 60;
      return '${d.inHours}h ${mins}m';
    }
    if (d.inMinutes >= 1) return '${d.inMinutes} min';
    return '${d.inSeconds}s';
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 16),
          Text(label, style: theme.textTheme.titleMedium),
          const Spacer(),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String? message;
  final CatalogFilterEntity? activeFilters;

  const _ErrorView({required this.message, required this.activeFilters});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              s.offlineCatalogEstimateError,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            if (activeFilters != null)
              ElevatedButton.icon(
                onPressed: () {
                  context
                      .read<OfflineCatalogBloc>()
                      .add(EstimateCatalogEvent(activeFilters!));
                },
                icon: const Icon(Icons.refresh),
                label: Text(s.offlineCatalogErrorRetry),
              ),
          ],
        ),
      ),
    );
  }
}
