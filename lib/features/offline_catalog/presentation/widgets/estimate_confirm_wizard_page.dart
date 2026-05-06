import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Page 4 of the wizard. Reads the live count for the user's filter
/// set from the bloc and shows estimated rows, on-disk size, request
/// count, and time. Above-cap estimates require typed confirmation
/// before the build can start.
class EstimateConfirmWizardPage extends StatefulWidget {
  final ValueChanged<bool> onConfirmedChanged;

  const EstimateConfirmWizardPage({
    super.key,
    required this.onConfirmedChanged,
  });

  @override
  State<EstimateConfirmWizardPage> createState() =>
      _EstimateConfirmWizardPageState();
}

class _EstimateConfirmWizardPageState extends State<EstimateConfirmWizardPage> {
  final _typedConfirmController = TextEditingController();

  @override
  void dispose() {
    _typedConfirmController.dispose();
    super.dispose();
  }

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
        // Roughly how many products we expect to keep on disk after
        // the wizard's filter set runs over the CSV stream.
        _SummaryRow(
          icon: Icons.storage,
          label: s.offlineCatalogEstimateRowsLabel,
          value: '~${_formatRows(estimate.rows)}',
        ),
        // On-disk size of the resulting sqlite catalog.
        _SummaryRow(
          icon: Icons.sd_storage,
          label: s.offlineCatalogEstimateSizeLabel,
          value: _formatBytes(estimate.estimatedBytes),
        ),
        // [requests] now carries the total *download* bytes (the
        // CSV gzip from OFF). The legacy "network requests" label
        // is recycled as a "download" line; the icon hints at it.
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
        if (estimate.isAboveHardCap) ...[
          const SizedBox(height: 16),
          _buildHardCapWarning(context),
        ],
      ],
    );
  }

  Widget _buildHardCapWarning(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    final phrase = s.offlineCatalogEstimateHardCapPhrase;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  s.offlineCatalogEstimateHardCapTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.offlineCatalogEstimateHardCapBody(phrase)),
          const SizedBox(height: 12),
          TextField(
            controller: _typedConfirmController,
            decoration: InputDecoration(
              hintText: phrase,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onChanged: (value) {
              widget.onConfirmedChanged(value.trim() == phrase);
            },
          ),
        ],
      ),
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
