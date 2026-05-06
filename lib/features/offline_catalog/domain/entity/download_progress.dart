import 'package:equatable/equatable.dart';

/// Per-page progress snapshot emitted by the catalog builder. Consumed
/// by the bloc, throttled to ~1 emission per second before reaching
/// the UI so the LinearProgressIndicator doesn't thrash.
class DownloadProgress extends Equatable {
  final int rowsDownloaded;
  final int totalRows;
  final int currentPage;
  final int totalPages;
  final Duration elapsed;

  const DownloadProgress({
    required this.rowsDownloaded,
    required this.totalRows,
    required this.currentPage,
    required this.totalPages,
    required this.elapsed,
  });

  /// Fraction in 0.0..1.0. Returns 0 when [totalRows] is 0 so callers
  /// don't need a guard.
  double get fraction {
    if (totalRows <= 0) return 0;
    return (rowsDownloaded / totalRows).clamp(0.0, 1.0);
  }

  /// Naive estimate: assume the remaining rows arrive at the same
  /// average rate as the rows already fetched. Returns null when not
  /// enough data has flowed to compute a rate.
  Duration? get estimatedRemaining {
    if (rowsDownloaded <= 0 || totalRows <= rowsDownloaded) return Duration.zero;
    final perRowMillis = elapsed.inMilliseconds / rowsDownloaded;
    final remainingRows = totalRows - rowsDownloaded;
    return Duration(milliseconds: (perRowMillis * remainingRows).round());
  }

  @override
  List<Object?> get props =>
      [rowsDownloaded, totalRows, currentPage, totalPages, elapsed];
}
