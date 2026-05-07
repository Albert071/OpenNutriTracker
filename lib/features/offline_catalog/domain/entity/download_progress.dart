import 'package:equatable/equatable.dart';

/// What stage of the prebuilt-download flow a [DownloadProgress]
/// snapshot is from. The pivot to download-prebuilt collapsed the old
/// CSV parse phase into a smaller "installing" phase that gunzips the
/// database into place.
enum DownloadPhase {
  /// HTTP transfer of the prebuilt sqlite gzip from the catalog CDN
  /// to local cache. Supports HTTP `Range` so an interrupted download
  /// resumes from the byte it stopped at rather than starting over.
  downloading,

  /// Local stream-gunzip of the partial gzip into the catalog file
  /// path, followed by an atomic rename. Bytes-done here count
  /// uncompressed bytes already written.
  installing,
}

/// Progress snapshot emitted by the catalog downloader. Consumed by
/// the bloc, throttled to ~1 emission per second before reaching the
/// UI so the LinearProgressIndicator doesn't thrash.
///
/// Both phases carry a bytes pair:
///
/// * [phase] = downloading → [bytesDone] / [bytesTotal] are the
///   compressed bytes pulled from the CDN.
/// * [phase] = installing → [bytesDone] / [bytesTotal] are uncompressed
///   bytes written. [bytesTotal] is the expected unpacked size for the
///   variant; if the build script omitted that figure the field falls
///   back to zero (UI renders an indeterminate spinner).
class DownloadProgress extends Equatable {
  final DownloadPhase phase;

  /// Bytes done in the active phase. Compressed bytes during download,
  /// uncompressed bytes during install.
  final int bytesDone;

  /// Total bytes for the active phase, when known. Zero or negative
  /// means "indeterminate".
  final int bytesTotal;

  /// Wall-clock elapsed since the build (or build resume) started.
  /// Used for the ETA calculation.
  final Duration elapsed;

  const DownloadProgress({
    required this.phase,
    required this.bytesDone,
    required this.bytesTotal,
    required this.elapsed,
  });

  /// Fraction in 0.0..1.0. Falls back to 0 when [bytesTotal] is not
  /// known (callers can render an indeterminate spinner in that
  /// case rather than a 0% bar).
  double get fraction {
    if (bytesTotal <= 0) return 0;
    return (bytesDone / bytesTotal).clamp(0.0, 1.0);
  }

  /// Naive estimate: assume the remaining bytes arrive at the same
  /// average rate as the bytes already processed. Returns null when
  /// the total is unknown or no progress has been made yet.
  Duration? get estimatedRemaining {
    if (bytesDone <= 0 || bytesTotal <= 0 || bytesTotal <= bytesDone) {
      return Duration.zero;
    }
    final perByteMicros = elapsed.inMicroseconds / bytesDone;
    final remainingBytes = bytesTotal - bytesDone;
    return Duration(microseconds: (perByteMicros * remainingBytes).round());
  }

  @override
  List<Object?> get props => [phase, bytesDone, bytesTotal, elapsed];
}
