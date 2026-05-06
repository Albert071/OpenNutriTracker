import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';

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
  static const _confirmPhrase = 'I understand';

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
    if (state.phase == OfflineCatalogPhase.estimating ||
        state.estimate == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.phase == OfflineCatalogPhase.error) {
      return _ErrorView(message: state.errorMessage);
    }
    final estimate = state.estimate!;
    final theme = Theme.of(context);
    return ListView(
      children: [
        // l10n: offlineCatalogEstimateTitle
        Text(
          'Ready to download',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        // l10n: offlineCatalogEstimateBody
        Text(
          'Here is what we will download for you.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        _SummaryRow(
          icon: Icons.storage,
          // l10n: offlineCatalogEstimateRows
          label: 'Products',
          value: _formatRows(estimate.rows),
        ),
        _SummaryRow(
          icon: Icons.sd_storage,
          // l10n: offlineCatalogEstimateSize
          label: 'Estimated size',
          value: _formatBytes(estimate.estimatedBytes),
        ),
        _SummaryRow(
          icon: Icons.cloud_download,
          // l10n: offlineCatalogEstimateRequests
          label: 'Network requests',
          value: '${estimate.requests}',
        ),
        _SummaryRow(
          icon: Icons.timer_outlined,
          // l10n: offlineCatalogEstimateTime
          label: 'Estimated time',
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
              const Expanded(
                // l10n: offlineCatalogEstimateWifiHint
                child: Text(
                  'Connect to Wi-Fi if you can. The download is paid '
                  'for in cellular data otherwise.',
                ),
              ),
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
              // l10n: offlineCatalogEstimateHardCapTitle
              const Expanded(
                child: Text(
                  'This is a very large download',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // l10n: offlineCatalogEstimateHardCapBody
          Text(
            'Your filter set covers more than a million products. '
            'That is a lot of bandwidth and a lot of time. To '
            'continue, type "$_confirmPhrase" in the box below — '
            'we want you to actively choose this rather than tap '
            'through it by accident.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typedConfirmController,
            decoration: InputDecoration(
              hintText: _confirmPhrase,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onChanged: (value) {
              widget.onConfirmedChanged(value.trim() == _confirmPhrase);
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

  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            // l10n: offlineCatalogEstimateError
            const Text(
              'We could not reach Open Food Facts to get an estimate. '
              'Check your internet connection and try again.',
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
          ],
        ),
      ),
    );
  }
}
