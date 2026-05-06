import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

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
    final s = S.of(context);
    final p = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.offlineCatalogDownloadingTitle,
            style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(s.offlineCatalogDownloadingBody,
            style: theme.textTheme.bodyMedium),
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
              label: Text(s.offlineCatalogPause),
            ),
            OutlinedButton.icon(
              onPressed: () => _confirmCancel(context),
              icon: const Icon(Icons.cancel_outlined),
              label: Text(s.offlineCatalogCancel),
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
    final s = S.of(context);
    final isDownloading = p.phase == DownloadPhase.downloading;
    final headline = isDownloading
        // "Downloaded X MB of Y MB"
        ? s.offlineCatalogDownloadingProgress(
            _formatBytes(p.bytesDone),
            _formatBytes(p.bytesTotal),
          )
        // "X products kept (Y rows scanned)"
        : s.offlineCatalogDownloadingProgress(
            _n(p.rowsKept),
            _n(p.rowsScanned),
          );
    final phaseLabel = isDownloading
        ? s.offlineCatalogTileBuilding
        : s.offlineCatalogTileRefreshing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: p.fraction, minHeight: 8),
        const SizedBox(height: 16),
        Text(headline, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(phaseLabel, style: theme.textTheme.bodySmall),
        if (p.estimatedRemaining != null && p.bytesTotal > 0) ...[
          const SizedBox(height: 4),
          Text(
            s.offlineCatalogDownloadingEta(
              _formatDuration(p.estimatedRemaining!),
            ),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  void _confirmCancel(BuildContext context) {
    final s = S.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.offlineCatalogCancelConfirmTitle),
        content: Text(s.offlineCatalogCancelConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(s.offlineCatalogCancelConfirmKeep),
          ),
          TextButton(
            onPressed: () {
              context
                  .read<OfflineCatalogBloc>()
                  .add(const CancelCatalogBuildEvent());
              Navigator.of(dialogContext).pop();
            },
            child: Text(s.offlineCatalogDiscard),
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

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
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

class _PausedView extends StatelessWidget {
  final DownloadProgress? progress;

  const _PausedView({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.offlineCatalogPausedTitle, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(s.offlineCatalogPausedBody, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        if (progress != null) ...[
          LinearProgressIndicator(value: progress!.fraction, minHeight: 8),
          const SizedBox(height: 12),
          Text(
            progress!.phase == DownloadPhase.downloading
                ? s.offlineCatalogPausedProgress(
                    _formatBytes(progress!.bytesDone),
                    _formatBytes(progress!.bytesTotal),
                  )
                : s.offlineCatalogPausedProgress(
                    _n(progress!.rowsKept),
                    _n(progress!.rowsScanned),
                  ),
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
              label: Text(s.offlineCatalogResume),
            ),
            OutlinedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const CancelCatalogBuildEvent());
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(s.offlineCatalogDiscard),
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

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }
}

class _DoneView extends StatelessWidget {
  final CatalogStatsEntity? stats;
  final VoidCallback onDone;

  const _DoneView({required this.stats, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
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
          Text(s.offlineCatalogDoneTitle, style: theme.textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (stats != null)
            Text(
              s.offlineCatalogDoneSummary(
                _n(stats!.productCount),
                _formatBytes(stats!.sizeBytes),
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          const SizedBox(height: 8),
          Text(
            s.offlineCatalogDoneBody,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check),
            label: Text(s.offlineCatalogDoneAction),
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
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              size: 64, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(s.offlineCatalogErrorTitle,
              style: theme.textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(
            recoverable
                ? s.offlineCatalogErrorBodyRecoverable
                : s.offlineCatalogErrorBodyFatal,
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
              label: Text(s.offlineCatalogErrorRetry),
            ),
        ],
      ),
    );
  }
}
