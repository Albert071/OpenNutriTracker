import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:stream_transform/stream_transform.dart';

/// Shared tuning for search-as-you-type across the product and food blocs.
const searchDebounceDuration = Duration(milliseconds: 500);

/// Minimum trimmed query length before a debounced search hits the remote
/// source. Shorter queries still surface local matches (custom meals,
/// recipes, recent intake, cached results).
const minRemoteQueryLength = 3;

/// Debounce keystrokes, then run the latest one as a restartable handler so an
/// in-flight search is cancelled the moment a newer query arrives. Keeps the
/// remote source to roughly one request per typing pause.
EventTransformer<E> debounceRestartable<E>(Duration duration) {
  return (events, mapper) =>
      restartable<E>().call(events.debounce(duration), mapper);
}
