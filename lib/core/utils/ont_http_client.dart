import 'package:http/http.dart' as http;

/// Thin wrapper around `http.BaseClient` that decorates every
/// outgoing request with a fixed `User-Agent`, plus any caller-
/// supplied extra headers (e.g. the `X-Catalog-Access` bearer token
/// the offline-catalog data source needs on every request to the
/// catalog CDN). The wrapper sits between the per-feature data
/// source and the underlying `http.Client` so a feature that needs
/// the same header on a manifest fetch, a HEAD probe, and a streamed
/// chunk download only has to declare it once at client-construction
/// time.
class ONTHttpClient extends http.BaseClient {
  final String userAgent;
  final http.Client _client;
  final Map<String, String>? _extraHeaders;

  ONTHttpClient(
    this.userAgent,
    this._client, {
    Map<String, String>? extraHeaders,
  }) : _extraHeaders = extraHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['User-Agent'] = userAgent;
    final extras = _extraHeaders;
    if (extras != null) {
      // `putIfAbsent` so a caller who set the header explicitly on a
      // specific request (e.g. an override for a one-off curl-style
      // call) wins. In practice this never collides — extra headers
      // are constants per data source — but the safer semantics are
      // free.
      for (final entry in extras.entries) {
        request.headers.putIfAbsent(entry.key, () => entry.value);
      }
    }
    return _client.send(request);
  }
}
