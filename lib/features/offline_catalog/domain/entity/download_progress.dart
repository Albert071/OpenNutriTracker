import 'package:equatable/equatable.dart';

/// What stage of the build a [DownloadProgress] snapshot is from.
/// The CSV-dump build runs through three of these in sequence:
/// downloading the gzip from OFF, then streaming + filtering the
/// decoded CSV, then a brief commit to seal the catalog.
enum DownloadPhase {
  /// HTTP transfer of the OFF CSV gzip to local cache, with HTTP
  /// Range support so an interrupted download resumes from the byte
  /// it stopped at rather than starting over.
  downloading,

  /// Local stream-parse of the gzip: decompress, split lines, apply
  /// the wizard's filter set, write survivors to sqlite.
  parsing,
}

/// Per-page progress snapshot emitted by the catalog builder. Consumed
/// by the bloc, throttled to ~1 emission per second before reaching
/// the UI so the LinearProgressIndicator doesn't thrash.
///
/// The fields carry different meanings depending on [phase]:
///
/// * [phase] = downloading → [bytesDone] / [bytesTotal] are the
///   meaningful pair. [rowsKept] / [rowsScanned] stay zero.
/// * [phase] = parsing → [rowsKept] is what's been written to
///   sqlite so far, [rowsScanned] is what's been read from the
///   csv (kept and dropped together), [bytesDone]/[bytesTotal]
///   reflect bytes-into-decompressed-stream when known.
class DownloadProgress extends Equatable {
  final DownloadPhase phase;

  /// Bytes consumed in the active phase. For download this is bytes
  /// pulled from OFF; for parsing it is bytes read from the local
  /// gzip file (decoded csv stream length is not known up-front).
  final int bytesDone;

  /// Total bytes for the active phase, when known. Zero or negative
  /// means "indeterminate" (rare — only when the parser stage is
  /// running and the decoded stream length is not known).
  final int bytesTotal;

  /// Rows that survived the wizard's filter and were written to
  /// sqlite. Non-zero only during and after the parsing phase.
  final int rowsKept;

  /// Rows read from the csv (regardless of whether they were kept).
  /// Useful for "filtering rate" UX during a long parse.
  final int rowsScanned;

  /// Wall-clock elapsed since the build (or build resume) started.
  /// Used for the ETA calculation.
  final Duration elapsed;

  const DownloadProgress({
    required this.phase,
    required this.bytesDone,
    required this.bytesTotal,
    required this.rowsKept,
    required this.rowsScanned,
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
  List<Object?> get props =>
      [phase, bytesDone, bytesTotal, rowsKept, rowsScanned, elapsed];
}
