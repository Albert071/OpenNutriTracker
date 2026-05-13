import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ont_http_client.dart';

/// A tiny `http.BaseClient` stand-in that records every outgoing
/// request so the test can assert on the merged headers. We do this
/// at the BaseClient seam rather than via a real socket because the
/// only thing we care about here is header merging behaviour — no
/// network and no body wrangling.
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final bytes = utf8.encode('ok');
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
      request: request,
    );
  }
}

void main() {
  // Disable flutter_test's default HttpOverrides so any real HTTP that
  // accidentally happens would surface — but the recording client
  // intercepts before that anyway.
  HttpOverrides.global = null;

  test('attaches the User-Agent header on every request', () async {
    final inner = _RecordingClient();
    final client = ONTHttpClient('OpenNutriTracker-test', inner);

    await client.get(Uri.parse('http://example.invalid/x'));
    await client.head(Uri.parse('http://example.invalid/y'));

    expect(inner.requests, hasLength(2));
    for (final req in inner.requests) {
      expect(req.headers['User-Agent'], 'OpenNutriTracker-test');
    }
  });

  test(
    'with extraHeaders, merges the extras into every outgoing request',
    () async {
      final inner = _RecordingClient();
      final client = ONTHttpClient(
        'OpenNutriTracker-test',
        inner,
        extraHeaders: const {
          'X-Catalog-Access': 'sekret-token-value',
        },
      );

      await client.get(Uri.parse('http://example.invalid/manifest.json'));
      await client.head(Uri.parse('http://example.invalid/part-00'));
      // Send a StreamedRequest the same shape as a Range chunk fetch
      // — the catalog data source uses this path for every chunk GET,
      // so it's the one most likely to regress if a future change
      // bypasses the header merge.
      final streamed = http.Request('GET', Uri.parse('http://example.invalid/part-01'));
      streamed.headers['Range'] = 'bytes=128-';
      await client.send(streamed);

      expect(inner.requests, hasLength(3));
      for (final req in inner.requests) {
        expect(req.headers['X-Catalog-Access'], 'sekret-token-value');
        expect(req.headers['User-Agent'], 'OpenNutriTracker-test');
      }
      // The third request also kept its caller-set Range header — the
      // merge must not clobber pre-existing values.
      expect(inner.requests[2].headers['Range'], 'bytes=128-');
    },
  );

  test(
    'without extraHeaders, behaves exactly as the wrapper has historically '
    'behaved (only User-Agent is added)',
    () async {
      final inner = _RecordingClient();
      final client = ONTHttpClient('OpenNutriTracker-test', inner);

      await client.get(Uri.parse('http://example.invalid/whatever'));

      expect(inner.requests, hasLength(1));
      final req = inner.requests.single;
      expect(req.headers['User-Agent'], 'OpenNutriTracker-test');
      expect(req.headers.containsKey('X-Catalog-Access'), isFalse);
    },
  );

  test(
    'a caller-set header on the request wins over the wrapper extras '
    '(extras are a default, not an override)',
    () async {
      final inner = _RecordingClient();
      final client = ONTHttpClient(
        'OpenNutriTracker-test',
        inner,
        extraHeaders: const {
          'X-Catalog-Access': 'from-wrapper',
        },
      );

      final req = http.Request('GET', Uri.parse('http://example.invalid/x'));
      req.headers['X-Catalog-Access'] = 'from-caller';
      await client.send(req);

      expect(inner.requests.single.headers['X-Catalog-Access'], 'from-caller');
    },
  );
}
