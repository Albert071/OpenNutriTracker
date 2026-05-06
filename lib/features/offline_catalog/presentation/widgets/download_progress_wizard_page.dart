import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';

/// Combined download + done page. While the bloc is in
/// [OfflineCatalogPhase.building] we show progress, pause, and cancel.
/// On [OfflineCatalogPhase.paused] we show a Resume CTA. On
/// [OfflineCatalogPhase.ready] we show the success summary and a
/// Done button.
class DownloadProgressWizardPage extends StatelessWidget {
  final VoidCallback onDone;

  const DownloadProgressWizardPage({super.key, required this.onDone});

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
    switch (state.phase) {
      case OfflineCatalogPhase.building:
        return _BuildingView(progress: state.progress);
      case OfflineCatalogPhase.paused:
        return _PausedView(progress: state.progress);
      case OfflineCatalogPhase.ready:
        return _DoneView(stats: state.stats, onDone: onDone);
      case OfflineCatalogPhase.error:
        return _ErrorView(
          message: state.errorMessage,
          recoverable: state.errorRecoverable,
        );
      default:
        return const Center(child: CircularProgressIndicator());
    }
  }
}

class _BuildingView extends StatelessWidget {
  final DownloadProgress? progress;

  const _BuildingView({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = progress;
    return ListView(
      children: [
        // l10n: offlineCatalogDownloadingTitle
        Text(
          'Downloading your catalog',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        // l10n: offlineCatalogDownloadingBody
        Text(
          'You can leave this screen open and the download will keep '
          'going. We will save what we have downloaded so far if you '
          'pause or cancel.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        if (p != null) _buildProgressBlock(context, p) else _buildSpinner(),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const PauseCatalogBuildEvent());
              },
              icon: const Icon(Icons.pause),
              // l10n: offlineCatalogPause
              label: const Text('Pause'),
            ),
            OutlinedButton.icon(
              onPressed: () => _confirmCancel(context),
              icon: const Icon(Icons.cancel_outlined),
              // l10n: offlineCatalogCancel
              label: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSpinner() {
    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildProgressBlock(BuildContext context, DownloadProgress p) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: p.fraction,
          minHeight: 8,
        ),
        const SizedBox(height: 16),
        // l10n: offlineCatalogDownloadingProgress (formatter)
        Text(
          'Downloaded ${_n(p.rowsDownloaded)} of ${_n(p.totalRows)} '
          'products',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        // l10n: offlineCatalogDownloadingPage
        Text(
          'Page ${p.currentPage} of ${p.totalPages}',
          style: theme.textTheme.bodySmall,
        ),
        if (p.estimatedRemaining != null) ...[
          const SizedBox(height: 4),
          // l10n: offlineCatalogDownloadingEta
          Text(
            'About ${_formatDuration(p.estimatedRemaining!)} left',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  void _confirmCancel(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // l10n: offlineCatalogCancelConfirmTitle
        title: const Text('Cancel and discard?'),
        content: const Text(
          // l10n: offlineCatalogCancelConfirmBody
          'This will throw away the products you have already '
          'downloaded. If you would like to come back to it later, '
          'use Pause instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            // l10n: offlineCatalogCancelConfirmKeep
            child: const Text('Keep downloading'),
          ),
          TextButton(
            onPressed: () {
              context
                  .read<OfflineCatalogBloc>()
                  .add(const CancelCatalogBuildEvent());
              Navigator.of(dialogContext).pop();
            },
            // l10n: offlineCatalogCancelConfirmDiscard
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  String _n(int v) {
    if (v >= 1000) {
      return v.toString().replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          );
    }
    return v.toString();
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

class _PausedView extends StatelessWidget {
  final DownloadProgress? progress;

  const _PausedView({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        // l10n: offlineCatalogPausedTitle
        Text(
          'Download paused',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        // l10n: offlineCatalogPausedBody
        Text(
          'We saved your progress. Pick up where you left off whenever '
          'you have a Wi-Fi connection.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        if (progress != null) ...[
          LinearProgressIndicator(value: progress!.fraction, minHeight: 8),
          const SizedBox(height: 12),
          Text(
            // l10n: offlineCatalogPausedProgress
            '${_n(progress!.rowsDownloaded)} of '
            '${_n(progress!.totalRows)} products downloaded',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const ResumeCatalogBuildEvent());
              },
              icon: const Icon(Icons.play_arrow),
              // l10n: offlineCatalogResume
              label: const Text('Resume'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const CancelCatalogBuildEvent());
              },
              icon: const Icon(Icons.delete_outline),
              // l10n: offlineCatalogDiscard
              label: const Text('Discard'),
            ),
          ],
        ),
      ],
    );
  }

  String _n(int v) => v.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );
}

class _DoneView extends StatelessWidget {
  final CatalogStatsEntity? stats;
  final VoidCallback onDone;

  const _DoneView({required this.stats, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          // l10n: offlineCatalogDoneTitle
          Text(
            'Catalog ready',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          if (stats != null)
            Text(
              // l10n: offlineCatalogDoneSummary
              '${_n(stats!.productCount)} products available offline. '
              '${_formatBytes(stats!.sizeBytes)} on disk.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          const SizedBox(height: 8),
          // l10n: offlineCatalogDoneBody
          Text(
            'Searches and barcode scans will now work offline. We '
            'will still check the live database for products that are '
            'not in your catalog yet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check),
            // l10n: offlineCatalogDoneAction
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }

  String _n(int v) => v.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }
}

class _ErrorView extends StatelessWidget {
  final String? message;
  final bool recoverable;

  const _ErrorView({required this.message, required this.recoverable});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              size: 64, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          // l10n: offlineCatalogErrorTitle
          Text(
            'Something went wrong',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          // l10n: offlineCatalogErrorBody
          Text(
            recoverable
                ? 'We saved everything we downloaded so far. Try '
                    'again from the Resume button when you have a '
                    'better connection.'
                : 'We could not finish this download.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 32),
          if (recoverable)
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const ResumeCatalogBuildEvent());
              },
              icon: const Icon(Icons.refresh),
              // l10n: offlineCatalogRetry
              label: const Text('Try again'),
            ),
        ],
      ),
    );
  }
}
