/// Cooperative cancellation primitive for long-running catalog work.
///
/// Cancellation is checked between pages of the bulk loader, never
/// mid-page, so we never half-write a batch. The token is also used to
/// signal a "pause" — the wizard re-uses the same machinery as cancel
/// but persists the cursor instead of clearing it.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  /// Reset the token so the same instance can be re-armed for a
  /// resume. Use sparingly — most call sites should construct a fresh
  /// token on each new operation.
  void reset() {
    _cancelled = false;
  }

  void throwIfCancelled() {
    if (_cancelled) throw CancellationException();
  }
}

class CancellationException implements Exception {
  const CancellationException();

  @override
  String toString() => 'CancellationException';
}
