import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/env.dart';
import 'package:opennutritracker/features/offline_catalog/data/data_sources/catalog_download_data_source.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-process HTTP fixture serving the chunked-catalog layout —
/// `${variantId}.manifest.json` plus N `${partName}` chunks. Tests
/// reach in to swap the served bytes / etag / behaviour per case.
class _FakeCatalogServer {
  HttpServer? _server;
  String manifestJson = '';
  Map<String, List<int>> partsByName = {};

  /// Status to return for the next request to a given path. One-shot:
  /// after the response is served the override is cleared. Used to
  /// simulate Cloudflare's "Range request returns 200" quirk.
  final Map<String, int> nextStatusOverride = {};

  /// When true, every incoming request is answered with 403 before any
  /// other logic runs. Simulates the Cloudflare WAF Custom Rule
  /// rejecting a request whose `X-Catalog-Access` header is missing or
  /// stale (e.g. an APK pre-dating a token rotation).
  bool forbidAll = false;

  /// All `X-Catalog-Access` header values observed by the server,
  /// keyed by request path. Tests assert against this to confirm the
  /// data source attaches the bearer token to every catalog HTTP call
  /// — the HEAD probe, the manifest GET, and every chunk GET / send.
  final Map<String, List<String>> receivedAccessTokens = {};

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((HttpRequest req) async {
      final path = req.uri.path;
      // Path looks like /v1/<filename>; strip leading /v1/.
      final name = path.startsWith('/v1/') ? path.substring(4) : path;

      // Record the X-Catalog-Access header so tests can assert that
      // every catalog request carried it. Header names are
      // case-insensitive on the wire; `HttpHeaders.value` normalises.
      final token = req.headers.value('x-catalog-access') ?? '';
      receivedAccessTokens.putIfAbsent(path, () => []).add(token);

      if (forbidAll) {
        req.response.statusCode = 403;
        req.response.headers.set('content-type', 'text/plain');
        req.response.write('forbidden');
        await req.response.close();
        return;
      }

      if (req.method == 'HEAD') {
        if (name.endsWith('.manifest.json')) {
          req.response.statusCode = 200;
          req.response.headers
              .set('content-length', utf8.encode(manifestJson).length.toString());
          await req.response.close();
          return;
        }
        final bytes = partsByName[name];
        if (bytes != null) {
          req.response.statusCode = 200;
          req.response.headers
              .set('content-length', bytes.length.toString());
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }

      if (req.method == 'GET') {
        if (name.endsWith('.manifest.json')) {
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'application/json');
          req.response.write(manifestJson);
          await req.response.close();
          return;
        }
        final bytes = partsByName[name];
        if (bytes == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final overrideStatus = nextStatusOverride.remove(name);
        final range = req.headers.value('range');
        if (range != null && range.startsWith('bytes=')) {
          final spec = range.substring('bytes='.length);
          final parts = spec.split('-');
          final start = int.parse(parts[0]);
          final end = parts.length > 1 && parts[1].isNotEmpty
              ? int.parse(parts[1])
              : bytes.length - 1;
          // If a test wired a 200-with-full-body override for this
          // path, honour it: simulate Cloudflare ignoring the Range
          // header and returning the whole object.
          if (overrideStatus == 200) {
            req.response.statusCode = 200;
            req.response.headers
                .set('content-length', bytes.length.toString());
            req.response.add(bytes);
          } else {
            final slice = bytes.sublist(start, end + 1);
            req.response.statusCode = 206;
            req.response.headers
                .set('content-length', slice.length.toString());
            req.response.add(slice);
          }
        } else {
          req.response.statusCode = 200;
          req.response.headers
              .set('content-length', bytes.length.toString());
          req.response.add(bytes);
        }
        await req.response.close();
        return;
      }

      req.response.statusCode = 405;
      await req.response.close();
    });
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

/// Build a minimal sqlite file at [path] that the data source will
/// recognise as a valid catalog (catalog_meta.schema_version row).
/// Returns its raw bytes so the caller can gzip + split.
Future<List<int>> _buildFixtureDb(
  String path, {
  int schemaVersion = 1,
  int? schemaVersionMinor = 0,
  List<String> extraProductColumns = const [],
}) async {
  final db = await databaseFactoryFfi.openDatabase(path);
  await db.execute(
    'CREATE TABLE catalog_meta (key TEXT PRIMARY KEY, value TEXT)',
  );
  await db.insert('catalog_meta', {
    'key': 'schema_version',
    'value': schemaVersion.toString(),
  });
  if (schemaVersionMinor != null) {
    await db.insert('catalog_meta', {
      'key': 'schema_version_minor',
      'value': schemaVersionMinor.toString(),
    });
  }
  // Optional `products` table with extra columns — used by the
  // forward-compat tests to simulate a future build that added new
  // fields on top of what this client knows about.
  if (extraProductColumns.isNotEmpty) {
    final extras = extraProductColumns.map((c) => '$c TEXT').join(', ');
    await db.execute(
      'CREATE TABLE products (code TEXT PRIMARY KEY NOT NULL, $extras)',
    );
  }
  await db.close();
  return File(path).readAsBytes();
}

/// Split [bytes] into chunks of [chunkSize] each (last chunk may be
/// short). Returns the chunks AND a manifest JSON string referencing
/// them by `<variantId>.db.gz.part-NN`.
({String manifestJson, Map<String, List<int>> parts}) _buildChunkedLayout({
  required String variantId,
  required List<int> gzipped,
  required int chunkSize,
  int schemaVersionMajor = 1,
  int schemaVersionMinor = 0,
}) {
  final chunks = <List<int>>[];
  for (var i = 0; i < gzipped.length; i += chunkSize) {
    chunks.add(gzipped.sublist(
        i,
        (i + chunkSize > gzipped.length) ? gzipped.length : i + chunkSize));
  }
  final partsByName = <String, List<int>>{};
  final partsForManifest = <Map<String, dynamic>>[];
  for (var i = 0; i < chunks.length; i++) {
    final name = '$variantId.db.gz.part-${i.toString().padLeft(2, '0')}';
    partsByName[name] = chunks[i];
    partsForManifest.add({
      'name': name,
      'bytes': chunks[i].length,
      'sha256': sha256.convert(chunks[i]).toString(),
    });
  }
  final manifest = {
    'manifestVersion': 1,
    'variantId': variantId,
    'totalCompressedBytes': gzipped.length,
    'sha256': sha256.convert(gzipped).toString(),
    'schemaVersionMajor': schemaVersionMajor,
    'schemaVersionMinor': schemaVersionMinor,
    'parts': partsForManifest,
  };
  return (manifestJson: jsonEncode(manifest), parts: partsByName);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Disable flutter_test's default HttpOverrides so the data source
    // can actually reach the loopback server below.
    HttpOverrides.global = null;
  });

  group('CatalogDownloadDataSource', () {
    late Directory tmp;
    late _FakeCatalogServer server;
    late int port;
    late CatalogDownloadDataSource ds;
    late List<int> fixtureGzip;
    late Map<String, List<int>> fixtureParts;
    late String fixtureManifestJson;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('catalog-download-test-');
      final fixturePath = p.join(tmp.path, 'fixture.db');
      final fixtureRaw = await _buildFixtureDb(fixturePath);
      fixtureGzip = gzip.encode(fixtureRaw);
      // Small chunk size so the tiny fixture splits into multiple
      // parts — exercises the multi-part assembly path even though
      // the real CDN cap is 256 MiB. The fixture sqlite gzips to
      // roughly 1 KiB, so 128-byte chunks reliably produce ≥6 parts.
      const chunkSize = 128;
      final layout = _buildChunkedLayout(
        variantId: 's1_n1_r5',
        gzipped: fixtureGzip,
        chunkSize: chunkSize,
      );
      fixtureParts = layout.parts;
      fixtureManifestJson = layout.manifestJson;

      server = _FakeCatalogServer()
        ..manifestJson = fixtureManifestJson
        ..partsByName = fixtureParts;
      port = await server.start();
      ds = CatalogDownloadDataSource(
        baseUrl: 'http://127.0.0.1:$port/v1',
        httpClientFactory: http.Client.new,
        docsDirResolver: () async => tmp,
        userAgentResolver: () async => 'OpenNutriTracker-test',
      );
    });

    tearDown(() async {
      await server.stop();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('manifestUrlFor produces the canonical manifest URL', () {
      expect(
        ds.manifestUrlFor('s1_n1_r5'),
        equals(
          Uri.parse('http://127.0.0.1:$port/v1/s1_n1_r5.manifest.json'),
        ),
      );
    });

    test('probeContentLength returns the manifest length', () async {
      final length = await ds.probeContentLength('s1_n1_r5');
      expect(length, equals(utf8.encode(fixtureManifestJson).length));
    });

    test('hasResumeablePartial is false when no partial exists',
        () async {
      expect(await ds.hasResumeablePartial('s1_n1_r5'), isFalse);
    });

    test('downloadAndInstall assembles all chunks into a valid catalog',
        () async {
      // Sanity: fixture must actually have multiple parts to exercise
      // the multi-part code path.
      expect(fixtureParts.length, greaterThan(1));

      final dbPath = p.join(tmp.path, 'offline_catalog.db');
      final progressEvents = <DownloadProgress>[];
      var installCallbackInvocations = 0;

      await for (final event in ds.downloadAndInstall(
        variantId: 's1_n1_r5',
        catalogDbPath: dbPath,
        expectedUncompressedBytes: 0,
        beforeInstall: () async => installCallbackInvocations++,
        cancellation: CancellationToken(),
      )) {
        progressEvents.add(event);
      }

      expect(installCallbackInvocations, equals(1),
          reason: 'beforeInstall should be invoked exactly once');
      expect(File(dbPath).existsSync(), isTrue);
      expect(progressEvents.any((e) => e.phase == DownloadPhase.downloading),
          isTrue);
      expect(progressEvents.any((e) => e.phase == DownloadPhase.installing),
          isTrue);
      expect(progressEvents.last.phase, DownloadPhase.installing);

      final produced = await databaseFactoryFfi.openDatabase(dbPath);
      try {
        final rows = await produced.rawQuery(
          "SELECT value FROM catalog_meta WHERE key = 'schema_version'",
        );
        expect(rows.first['value'], equals('1'));
      } finally {
        await produced.close();
      }

      // All staging artefacts must be cleaned up after success.
      expect(File(p.join(tmp.path, 'offline_catalog.db.tmp.gz')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'offline_catalog.db.tmp')).existsSync(),
          isFalse);
      expect(
          File(p.join(tmp.path, 'offline_catalog.db.tmp.manifest.json'))
              .existsSync(),
          isFalse);
      // No leftover part files either.
      final leftoverParts = await tmp
          .list()
          .where((e) =>
              p.basename(e.path).startsWith('offline_catalog.db.tmp.part-'))
          .toList();
      expect(leftoverParts, isEmpty);
    });

    test(
      'recovers when the CDN returns 200-with-full-body to a Range '
      'request (Cloudflare quirk)',
      () async {
        // Pre-populate a partial copy of part-00 on disk so the
        // download path issues a Range request.
        final part0Name = fixtureParts.keys.first;
        final part0Bytes = fixtureParts[part0Name]!;
        final partialBytes = part0Bytes.sublist(0, part0Bytes.length ~/ 2);
        await File(p.join(tmp.path, 'offline_catalog.db.tmp.part-00'))
            .writeAsBytes(partialBytes);
        // Pre-write a manifest sidecar that matches the upstream
        // manifest, so the data source treats the partial as a real
        // resume rather than wiping it on the sha256-changed branch.
        await File(p.join(tmp.path, 'offline_catalog.db.tmp.manifest.json'))
            .writeAsString(fixtureManifestJson);
        // Wire the server to ignore the next Range request and serve
        // the whole body with a 200 instead.
        server.nextStatusOverride[part0Name] = 200;

        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        await for (final _ in ds.downloadAndInstall(
          variantId: 's1_n1_r5',
          catalogDbPath: dbPath,
          expectedUncompressedBytes: 0,
          beforeInstall: () async {},
          cancellation: CancellationToken(),
        )) {}

        // Despite the simulated quirk, the install must still succeed.
        expect(File(dbPath).existsSync(), isTrue);
      },
    );

    test('refuses to install a catalog whose schema_version is too new',
        () async {
      // Replace the fixture with one advertising a future schema.
      final futurePath = p.join(tmp.path, 'future.db');
      final futureBytes = await _buildFixtureDb(futurePath,
          schemaVersion: CatalogDownloadDataSource.supportedSchemaVersion + 1);
      final futureGzip = gzip.encode(futureBytes);
      final layout = _buildChunkedLayout(
        variantId: 's1_n1_r5',
        gzipped: futureGzip,
        chunkSize: 128,
      );
      server
        ..manifestJson = layout.manifestJson
        ..partsByName = layout.parts;

      final dbPath = p.join(tmp.path, 'offline_catalog.db');
      Object? caught;
      try {
        await for (final _ in ds.downloadAndInstall(
          variantId: 's1_n1_r5',
          catalogDbPath: dbPath,
          expectedUncompressedBytes: 0,
          beforeInstall: () async {},
          cancellation: CancellationToken(),
        )) {}
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<CatalogSchemaVersionException>());
      expect(File(dbPath).existsSync(), isFalse);
    });

    test(
      'accepts a higher schema_version_minor at the same major '
      '(forward-compatible additive bump)',
      () async {
        // Build a fixture that advertises minor 99 — well above
        // anything the client has seen — but stays at the supported
        // major. Also tack on unknown columns to `products` to
        // simulate the kind of additive change a minor bump would
        // typically carry. Both the manifest's stated minor and the
        // SQLite's catalog_meta.schema_version_minor are 99 so the
        // test exercises both layers of the version check.
        final futurePath = p.join(tmp.path, 'future-minor.db');
        final futureBytes = await _buildFixtureDb(
          futurePath,
          schemaVersion: CatalogDownloadDataSource.supportedSchemaVersion,
          schemaVersionMinor: 99,
          extraProductColumns: const ['nutriscore_grade', 'eco_score'],
        );
        final futureGzip = gzip.encode(futureBytes);
        final layout = _buildChunkedLayout(
          variantId: 's1_n1_r5',
          gzipped: futureGzip,
          chunkSize: 128,
          schemaVersionMajor:
              CatalogDownloadDataSource.supportedSchemaVersion,
          schemaVersionMinor: 99,
        );
        server
          ..manifestJson = layout.manifestJson
          ..partsByName = layout.parts;

        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        await for (final _ in ds.downloadAndInstall(
          variantId: 's1_n1_r5',
          catalogDbPath: dbPath,
          expectedUncompressedBytes: 0,
          beforeInstall: () async {},
          cancellation: CancellationToken(),
        )) {}

        // Install must succeed.
        expect(File(dbPath).existsSync(), isTrue);

        // The unknown columns should be left in place — sqlite has
        // no notion of "drop columns the client didn't define" and
        // our queries name specific columns, so the future fields
        // sit harmlessly alongside what we read.
        final produced = await databaseFactoryFfi.openDatabase(dbPath);
        try {
          final cols = await produced.rawQuery(
            'PRAGMA table_info(products)',
          );
          final names = cols.map((r) => r['name'] as String).toSet();
          expect(names.contains('nutriscore_grade'), isTrue,
              reason: 'extra columns from a future minor must persist');
          expect(names.contains('eco_score'), isTrue);
        } finally {
          await produced.close();
        }
      },
    );

    test(
      'refuses early when the manifest declares a higher major than '
      'this client supports, without downloading any chunks, and '
      'leaves the existing on-disk catalog untouched',
      () async {
        // Pre-seed an existing on-disk catalog so we can assert the
        // refusal does not touch it. The contents do not matter for
        // this assertion — just the file's identity.
        final existingDbPath = p.join(tmp.path, 'offline_catalog.db');
        await File(existingDbPath).writeAsBytes(const [0xCA, 0xFE]);
        final existingBytesBefore =
            await File(existingDbPath).readAsBytes();

        // The fixture itself can stay at the supported major (we
        // never reach the post-download verifier for this test); the
        // manifest is what flips to the breaking-change major.
        final fixtureBytes = fixtureGzip;
        final layout = _buildChunkedLayout(
          variantId: 's1_n1_r5',
          gzipped: fixtureBytes,
          chunkSize: 128,
          schemaVersionMajor:
              CatalogDownloadDataSource.supportedSchemaVersion + 1,
          schemaVersionMinor: 0,
        );
        server
          ..manifestJson = layout.manifestJson
          ..partsByName = layout.parts;

        Object? caught;
        try {
          await for (final _ in ds.downloadAndInstall(
            variantId: 's1_n1_r5',
            catalogDbPath: existingDbPath,
            expectedUncompressedBytes: 0,
            beforeInstall: () async {},
            cancellation: CancellationToken(),
          )) {}
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<CatalogSchemaVersionException>());

        // No part files should have been written — the refusal
        // happens at the manifest stage, before any chunks are
        // requested.
        final stagingFiles = await tmp
            .list()
            .where((e) =>
                p.basename(e.path).startsWith('offline_catalog.db.tmp'))
            .toList();
        expect(stagingFiles, isEmpty,
            reason: 'no chunks should have been downloaded');

        // The existing on-device catalog must be byte-identical —
        // the user's data is preserved while they update the app.
        final existingBytesAfter =
            await File(existingDbPath).readAsBytes();
        expect(existingBytesAfter, equals(existingBytesBefore));
      },
    );

    test(
      'refuses to install when a part sha256 disagrees with the manifest',
      () async {
        // Mutate one chunk's bytes server-side so the manifest's
        // recorded sha256 no longer matches what the client downloads.
        final part0Name = fixtureParts.keys.first;
        final tampered = List<int>.from(fixtureParts[part0Name]!);
        tampered[0] = (tampered[0] + 1) % 256;
        server.partsByName = {...fixtureParts, part0Name: tampered};

        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        Object? caught;
        try {
          await for (final _ in ds.downloadAndInstall(
            variantId: 's1_n1_r5',
            catalogDbPath: dbPath,
            expectedUncompressedBytes: 0,
            beforeInstall: () async {},
            cancellation: CancellationToken(),
          )) {}
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<CatalogPartChecksumException>());
        expect(File(dbPath).existsSync(), isFalse);
      },
    );

    test(
      'cached manifest with mismatched sha256 triggers rotated-variant '
      'exception and wipes partials',
      () async {
        // Pre-write a manifest sidecar with a different combined sha256
        // than what the server now serves. Simulates the user pausing
        // mid-download, the weekly rebuild firing, then the user
        // resuming against an upstream that has rotated.
        final staleManifest = {
          'manifestVersion': 1,
          'variantId': 's1_n1_r5',
          'totalCompressedBytes': fixtureGzip.length,
          'sha256': 'deadbeef' * 8,
          'schemaVersionMajor':
              CatalogDownloadDataSource.supportedSchemaVersion,
          'schemaVersionMinor': 0,
          'parts': const <Map<String, dynamic>>[],
        };
        await File(p.join(tmp.path, 'offline_catalog.db.tmp.manifest.json'))
            .writeAsString(jsonEncode(staleManifest));
        await File(p.join(tmp.path, 'offline_catalog.db.tmp.part-00'))
            .writeAsBytes([1, 2, 3]);

        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        Object? caught;
        try {
          await for (final _ in ds.downloadAndInstall(
            variantId: 's1_n1_r5',
            catalogDbPath: dbPath,
            expectedUncompressedBytes: 0,
            beforeInstall: () async {},
            cancellation: CancellationToken(),
          )) {}
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<CatalogVariantRotatedException>());
        expect(File(dbPath).existsSync(), isFalse);
      },
    );

    test(
      'every catalog HTTP request carries the X-Catalog-Access header '
      'with the envied token',
      () async {
        // Drive the full download-and-install flow, plus the lighter
        // HEAD probe paths, so the fake server sees a representative
        // mix of catalog HTTP calls: HEAD on the manifest (probe),
        // GET on the manifest, GETs on every chunk.
        await ds.probeAvailability();
        await ds.probeContentLength('s1_n1_r5');

        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        await for (final _ in ds.downloadAndInstall(
          variantId: 's1_n1_r5',
          catalogDbPath: dbPath,
          expectedUncompressedBytes: 0,
          beforeInstall: () async {},
          cancellation: CancellationToken(),
        )) {}

        // At least the probe (HEAD on s1_n1_r5.manifest.json), the
        // manifest GET, and a GET per chunk should all be present.
        expect(server.receivedAccessTokens, isNotEmpty);
        expect(
          server.receivedAccessTokens.keys,
          contains('/v1/s1_n1_r5.manifest.json'),
        );
        for (final partName in fixtureParts.keys) {
          expect(
            server.receivedAccessTokens.keys,
            contains('/v1/$partName'),
            reason: 'no request observed for chunk $partName',
          );
        }
        // Every observed value must equal the envied token. There
        // must be no empty values — that would mean a code path
        // somewhere constructed a client without the headers.
        final expectedToken = Env.catalogAccessToken;
        for (final entry in server.receivedAccessTokens.entries) {
          for (final observed in entry.value) {
            expect(observed, equals(expectedToken),
                reason:
                    'request to ${entry.key} did not carry the catalog '
                    'access token');
          }
        }
      },
    );

    test(
      'downloadAndInstall throws CatalogAccessDeniedException when the '
      'CDN returns 403 (WAF gate rejected the bearer token)',
      () async {
        server.forbidAll = true;
        final dbPath = p.join(tmp.path, 'offline_catalog.db');
        Object? caught;
        try {
          await for (final _ in ds.downloadAndInstall(
            variantId: 's1_n1_r5',
            catalogDbPath: dbPath,
            expectedUncompressedBytes: 0,
            beforeInstall: () async {},
            cancellation: CancellationToken(),
          )) {}
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<CatalogAccessDeniedException>());
        // No catalog should have landed at the final path.
        expect(File(dbPath).existsSync(), isFalse);
      },
    );

    test(
      'probeContentLength throws CatalogAccessDeniedException on a 403',
      () async {
        server.forbidAll = true;
        Object? caught;
        try {
          await ds.probeContentLength('s1_n1_r5');
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<CatalogAccessDeniedException>());
      },
    );

    test('cleanupPartials removes leftover staging files', () async {
      // Seed a representative spread of the staging filenames.
      await File(p.join(tmp.path, 'offline_catalog.db.tmp.gz'))
          .writeAsBytes([1]);
      await File(p.join(tmp.path, 'offline_catalog.db.tmp.part-00'))
          .writeAsBytes([2]);
      await File(p.join(tmp.path, 'offline_catalog.db.tmp.part-01'))
          .writeAsBytes([3]);
      await File(p.join(tmp.path, 'offline_catalog.db.tmp.manifest.json'))
          .writeAsString('{}');

      await ds.cleanupPartials();

      for (final n in const [
        'offline_catalog.db.tmp.gz',
        'offline_catalog.db.tmp.part-00',
        'offline_catalog.db.tmp.part-01',
        'offline_catalog.db.tmp.manifest.json',
      ]) {
        expect(File(p.join(tmp.path, n)).existsSync(), isFalse,
            reason: '$n should have been deleted');
      }
    });
  });
}
