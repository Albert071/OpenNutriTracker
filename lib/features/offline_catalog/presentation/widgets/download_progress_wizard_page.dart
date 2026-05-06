import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Combined download + done page. While the bloc is in
/// [OfflineCatalogPhase.building] we show progress, pause, and cancel.
/// On [OfflineCatalogPhase.paused] we show a Resume CTA. On
/// [OfflineCatalogPhase.ready] we show the success summary and a
/// Done button.
///
/// While the bloc is actively working (downloading or parsing) we
/// also hold a screen wakelock so a long build isn't interrupted by
/// the OS dimming the display — particularly important on iOS,
/// where backgrounding a wakelock-less app suspends it within ~30s
/// and kills the in-flight download. The wakelock is released the
/// moment the page leaves an active phase OR the page itself is
/// unmounted (the user navigated away from the wizard).
class DownloadProgressWizardPage extends StatefulWidget {
  final VoidCallback onDone;

  const DownloadProgressWizardPage({super.key, required this.onDone});

  @override
  State<DownloadProgressWizardPage> createState() =>
      _DownloadProgressWizardPageState();
}

class _DownloadProgressWizardPageState
    extends State<DownloadProgressWizardPage> {
  static final _log = Logger('DownloadProgressWizardPage');

  /// Track the current wakelock state so we don't issue redundant
  /// enable / disable calls per bloc emission. The plugin handles
  /// repeats fine, but it surfaces noisy logs on some platforms.
  bool _wakelockHeld = false;

  @override
  void dispose() {
    // Belt-and-braces: always release on unmount, even if the bloc
    // listener didn't get a chance to.
    if (_wakelockHeld) {
      WakelockPlus.disable().catchError((Object e) {
        _log.warning('Failed to release wakelock on dispose: $e');
      });
      _wakelockHeld = false;
    }
    super.dispose();
  }

  bool _shouldHoldWakelock(OfflineCatalogPhase phase) {
    // The bloc folds the CSV download AND the subsequent parse
    // into a single `building` phase (the [DownloadProgress.phase]
    // enum tracks the sub-phase, but the wakelock decision doesn't
    // care which sub-phase is active — both are long-running and
    // both need the screen alive).
    return phase == OfflineCatalogPhase.building ||
        phase == OfflineCatalogPhase.refreshing;
  }

  Future<void> _syncWakelock(OfflineCatalogPhase phase) async {
    final wantHold = _shouldHoldWakelock(phase);
    if (wantHold == _wakelockHeld) return;
    try {
      if (wantHold) {
        await WakelockPlus.enable();
        _wakelockHeld = true;
      } else {
        await WakelockPlus.disable();
        _wakelockHeld = false;
      }
    } catch (e) {
      // Wakelock failures are never fatal — worst case the screen
      // sleeps and the user has to come back and resume. We log
      // and move on.
      _log.warning('Failed to ${wantHold ? "enable" : "disable"} '
          'wakelock: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<OfflineCatalogBloc, OfflineCatalogState>(
      listenWhen: (previous, current) => previous.phase != current.phase,
      listener: (context, state) => _syncWakelock(state.phase),
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
        return _DoneView(stats: state.stats, onDone: widget.onDone);
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
    // Title + body switch with the underlying phase so the user
    // isn't told "Downloading your catalog" while we're actually
    // chewing through the gzip and writing rows to sqlite.
    final isParsing = p != null && p.phase == DownloadPhase.parsing;
    final title = isParsing
        // l10n: offlineCatalogParsingTitle
        ? 'Building your database'
        : s.offlineCatalogDownloadingTitle;
    final body = isParsing
        // l10n: offlineCatalogParsingBody
        ? 'We\'re reading the file you just downloaded, picking out '
            'the products that match your filters, and saving them '
            'to your device. This usually takes about a minute.'
        : s.offlineCatalogDownloadingBody;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(body, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        if (p != null) _buildProgressBlock(context, p) else _buildSpinner(),
        const SizedBox(height: 32),
        // Wrap rather than Row so the Pause / Cancel buttons reflow
        // gracefully on narrow widths instead of clipping. The 2 px
        // overflow we used to see at intrinsic sizing is gone now
        // because Wrap measures its children honestly.
        Wrap(
          alignment: WrapAlignment.spaceEvenly,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                context
                    .read<OfflineCatalogBloc>()
                    .add(const PauseCatalogBuildEvent());
                // Pop back to settings so the user gets a clear
                // "the action took effect" signal — the settings
                // tile updates its subtitle to "Download paused —
                // tap to resume", and resume is one tap away from
                // there. Staying on the wizard with a near-
                // identical body would feel like Pause did
                // nothing.
                Navigator.of(context).maybePop();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: p.fraction, minHeight: 8),
        const SizedBox(height: 16),
        if (isDownloading) ...[
          // Download phase: bytes downloaded vs total — both
          // numbers describe the same thing (download progress).
          Text(
            s.offlineCatalogDownloadingProgress(
              _formatBytes(p.bytesDone),
              _formatBytes(p.bytesTotal),
            ),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(s.offlineCatalogTileBuilding,
              style: theme.textTheme.bodySmall),
        ] else ...[
          // Parse phase: the two numbers are independent — kept is
          // what survives the filter, scanned is everything we've
          // read so far. Show them on separate lines so the user
          // doesn't read them as a fraction.
          // l10n: offlineCatalogParsingKept
          Text(
            '${_n(p.rowsKept)} products kept',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          // l10n: offlineCatalogParsingScanned
          Text(
            '${_n(p.rowsScanned)} rows scanned from the OFF dump',
            style: theme.textTheme.bodySmall,
          ),
        ],
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
              // Close the dialog and the wizard. The user is back
              // at settings with the catalog cleanly reset to
              // "Not built — tap to set up".
              Navigator.of(dialogContext).pop();
              Navigator.of(context).maybePop();
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
