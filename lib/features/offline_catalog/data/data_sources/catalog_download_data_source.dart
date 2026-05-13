import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/app_const.dart';
import 'package:opennutritracker/core/utils/env.dart';
import 'package:opennutritracker/core/utils/ont_http_client.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Raised when a freshly-fetched manifest disagrees with the one
/// stored alongside an in-flight partial download. The weekly rebuild
/// changes the sha256 of every variant; a partial from the old build
/// is no longer a prefix of the new chunks. The bloc surfaces this
/// recoverably so the user can discard + start fresh.
class CatalogVariantRotatedException implements Exception {
  const CatalogVariantRotatedException();

  @override
  String toString() =>
      'The catalog on the server has been rebuilt since you paused. '
      'Discard the partial download and start again to pick up the '
      'newest version.';
}

/// Raised when the downloaded sqlite advertises a `schema_version`
/// the client does not know how to read.
class CatalogSchemaVersionException implements Exception {
  final int downloaded;
  final int supported;

  const CatalogSchemaVersionException({
    required this.downloaded,
    required this.supported,
  });

  @override
  String toString() =>
      'The downloaded catalog reports schema version $downloaded, but '
      'this app only knows how to read up to version $supported. Update '
      'the app to use this catalog.';
}

/// Raised when the catalog CDN responds 403 to a request that
/// already carried the `X-Catalog-Access` header. In practice this
/// means the token compiled into the installed APK is no longer
/// accepted by the Cloudflare WAF Custom Rule — usually because an
/// emergency rotation happened on the server side and this build of
/// the app pre-dates it. The best recovery is to update the app, so
/// the bloc surfaces this as a non-recoverable error with that
/// guidance rather than offering a doomed retry.
class CatalogAccessDeniedException implements Exception {
  const CatalogAccessDeniedException();

  @override
  String toString() =>
      'The catalog server refused this request. Update OpenNutriTracker '
      'to pick up the latest catalog access credentials.';
}

/// Raised when a part's freshly-downloaded bytes do not hash to the
/// sha256 the manifest advertised. Either the bytes corrupted in
/// flight or the manifest is from a different build than the chunks.
class CatalogPartChecksumException implements Exception {
  final String partName;
  final String expected;
  final String actual;

  const CatalogPartChecksumException({
    required this.partName,
    required this.expected,
    required this.actual,
  });

  @override
  String toString() =>
      'Catalog part $partName has sha256 $actual but the manifest '
      'claimed $expected. The download is corrupt; start over.';
}

/// Highest manifest schema version this client understands. A newer
/// manifest signals a rebuild that drops compatibility, and we refuse
/// it cleanly rather than risking misparsing.
const int _kSupportedManifestVersion = 1;

class _CatalogPart {
  final String name;
  final int bytes;
  final String sha256Hex;

  const _CatalogPart({
    required this.name,
    required this.bytes,
    required this.sha256Hex,
  });

  factory _CatalogPart.fromJson(Map<String, dynamic> json) => _CatalogPart(
        name: json['name'] as String,
        bytes: json['bytes'] as int,
        sha256Hex: json['sha256'] as String,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'bytes': bytes,
        'sha256': sha256Hex,
      };
}

class _CatalogManifest {
  final int manifestVersion;
  final String variantId;
  final int totalCompressedBytes;
  final String sha256Hex;

  /// The catalog payload's major schema version, advertised here so
  /// older clients can refuse a breaking-change rebuild before they
  /// commit bandwidth to downloading any chunks.
  final int schemaVersionMajor;

  /// Minor schema version. Bumped freely for additive changes (new
  /// column / new aux table). Older clients accept any minor at the
  /// same major.
  final int schemaVersionMinor;
  final List<_CatalogPart> parts;

  const _CatalogManifest({
    required this.manifestVersion,
    required this.variantId,
    required this.totalCompressedBytes,
    required this.sha256Hex,
    required this.schemaVersionMajor,
    required this.schemaVersionMinor,
    required this.parts,
  });

  factory _CatalogManifest.fromJson(Map<String, dynamic> json) =>
      _CatalogManifest(
        manifestVersion: json['manifestVersion'] as int,
        variantId: json['variantId'] as String,
        totalCompressedBytes: json['totalCompressedBytes'] as int,
        sha256Hex: json['sha256'] as String,
        schemaVersionMajor: json['schemaVersionMajor'] as int,
        schemaVersionMinor: json['schemaVersionMinor'] as int,
        parts: (json['parts'] as List<dynamic>)
            .map((e) => _CatalogPart.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'manifestVersion': manifestVersion,
        'variantId': variantId,
        'totalCompressedBytes': totalCompressedBytes,
        'sha256': sha256Hex,
        'schemaVersionMajor': schemaVersionMajor,
        'schemaVersionMinor': schemaVersionMinor,
        'parts': parts.map((e) => e.toJson()).toList(growable: false),
      };
}

/// Downloads a prebuilt sqlite catalog from the catalog CDN as a
/// stream of <=256 MiB chunks described by a per-variant manifest,
/// reassembles them, gunzips the result into place, and verifies its
/// schema version before the atomic rename.
///
/// The chunked layout exists because Cloudflare's edge cache treats
/// Range requests against very large objects inconsistently — the
/// first request that misses the edge can return 200 with the whole
/// body instead of 206. Splitting every variant under the threshold
/// keeps Range requests honest, lets us run a small worker pool of
/// concurrent downloads (more throughput on fast connections,
/// graceful behaviour on slow ones), and gives finer-grained
/// pause/resume.
///
/// **Pause semantics:** the bloc cancels the [CancellationToken];
/// each in-flight worker breaks on its next chunk-loop iteration and
/// closes its file. Every part already on disk stays. A subsequent
/// `downloadAndInstall` call for the same variant resumes by
/// finishing whatever parts are partial (Range request) or queued.
class CatalogDownloadDataSource {
  static final _log = Logger('CatalogDownloadDataSource');

  /// CDN base URL. Manifest is `${variantId}.manifest.json`; chunks
  /// are `${partName}` (each manifest part already carries the full
  /// filename including the variant prefix).
  static const String defaultBaseUrl =
      'https://catalog.opennutritracker.org/v1';

  /// Highest sqlite schema version this client knows how to read.
  /// Bumping the on-device schema requires bumping this in lockstep.
  static const int supportedSchemaVersion = 1;

  /// Number of chunks downloaded in parallel. Matches the prior
  /// parallel-CSV downloader's worker count for the same reasons —
  /// good throughput on fast links, doesn't saturate cellular.
  static const int _workerConcurrency = 4;

  /// Filenames for partial-download artefacts. They live next to the
  /// final catalog file in the documents directory so cleanup is a
  /// single glob.
  static const _tmpPartPrefix = 'offline_catalog.db.tmp.part-';
  static const _tmpManifestFilename = 'offline_catalog.db.tmp.manifest.json';
  static const _tmpGzFilename = 'offline_catalog.db.tmp.gz';
  static const _tmpDbFilename = 'offline_catalog.db.tmp';

  /// Throttle for the install-phase progress emissions.
  static const _installEmitInterval = Duration(milliseconds: 200);

  /// Throttle for the download-phase progress emissions. Workers
  /// report into a shared counter; this is the rate at which the
  /// counter is emitted to the bloc.
  static const _downloadEmitInterval = Duration(milliseconds: 250);

  final String _baseUrl;
  final http.Client Function() _httpClientFactory;
  final Future<Directory> Function() _docsDirResolver;
  final Future<String> Function() _userAgentResolver;

  CatalogDownloadDataSource({
    String baseUrl = defaultBaseUrl,
    http.Client Function()? httpClientFactory,
    Future<Directory> Function()? docsDirResolver,
    Future<String> Function()? userAgentResolver,
  })  : _baseUrl = baseUrl,
        _httpClientFactory = httpClientFactory ?? http.Client.new,
        _docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory,
        _userAgentResolver =
            userAgentResolver ?? AppConst.getUserAgentString;

  /// Manifest URL for [variantId] (e.g. `s1_n1_r5`).
  Uri manifestUrlFor(String variantId) =>
      Uri.parse('$_baseUrl/$variantId.manifest.json');

  /// URL for a single chunk by its part name. Part names from the
  /// manifest already include the variant prefix.
  Uri partUrlFor(String partName) => Uri.parse('$_baseUrl/$partName');

  /// Headers every catalog HTTP request carries. The bearer token
  /// gates `catalog.opennutritracker.org` at the Cloudflare edge —
  /// the WAF Custom Rule 403s any request whose `X-Catalog-Access`
  /// header does not match the value baked into the APK. Declaring
  /// the headers once here means every code path that constructs an
  /// `ONTHttpClient` for catalog traffic picks them up automatically.
  Map<String, String> get _catalogRequestHeaders => {
        'X-Catalog-Access': Env.catalogAccessToken,
      };

  /// Quick "is the catalog CDN reachable?" probe. Issues a HEAD
  /// against the recommended default variant's manifest with a tight
  /// timeout, and folds every failure mode (timeout, DNS error, TLS
  /// error, non-2xx response) into a simple `false`. Used by the
  /// settings tile and the wizard to decide whether to even let the
  /// user start a download — if the bucket is down we surface a
  /// "try again later" message instead of marching into a flow that
  /// is going to fail at the manifest fetch anyway.
  ///
  /// The recommended default variant `s1_n1_r5` is always present
  /// when the catalog pipeline is healthy, so reaching it
  /// successfully proves the whole chain (DNS, edge, R2, cache
  /// rule) is working end to end.
  Future<bool> probeAvailability({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final userAgent = await _userAgentResolver();
    final client = ONTHttpClient(
      userAgent,
      _httpClientFactory(),
      extraHeaders: _catalogRequestHeaders,
    );
    try {
      final response = await client
          .head(manifestUrlFor('s1_n1_r5'))
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      _log.fine('Catalog availability probe failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// HEAD probe of [variantId]'s manifest URL. Returns the manifest's
  /// `Content-Length` in bytes — useful as a cheap connectivity
  /// check before committing to the full download.
  Future<int?> probeContentLength(String variantId) async {
    final userAgent = await _userAgentResolver();
    final client = ONTHttpClient(
      userAgent,
      _httpClientFactory(),
      extraHeaders: _catalogRequestHeaders,
    );
    try {
      final response = await client
          .head(manifestUrlFor(variantId))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 403) {
        throw const CatalogAccessDeniedException();
      }
      if (response.statusCode != 200) return null;
      final raw = response.headers['content-length'];
      if (raw == null) return null;
      return int.tryParse(raw);
    } finally {
      client.close();
    }
  }

  /// True when there is a partial download on disk for [variantId]
  /// that a resume could pick up. We require the stored manifest
  /// sidecar to match the expected variant.
  Future<bool> hasResumeablePartial(String variantId) async {
    final dir = await _docsDirResolver();
    final manifestFile = File(p.join(dir.path, _tmpManifestFilename));
    if (!await manifestFile.exists()) return false;
    try {
      final manifest = _CatalogManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
      );
      if (manifest.variantId != variantId) return false;
      // At least one part file must exist, otherwise the user
      // cancelled before any bytes landed.
      for (final part in manifest.parts) {
        final partFile = File(p.join(dir.path, _localNameFor(part.name)));
        if (await partFile.exists() && await partFile.length() > 0) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Wipe every partial-download artefact. Called on cancel and on
  /// catalog delete.
  Future<void> cleanupPartials() async {
    final dir = await _docsDirResolver();
    // Sweep every file under the temp-download family. Done as a
    // directory listing rather than known-name list because part
    // names depend on the manifest, which we may no longer trust.
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (name == _tmpManifestFilename ||
          name == _tmpGzFilename ||
          name == _tmpDbFilename ||
          name.startsWith(_tmpPartPrefix)) {
        try {
          if (entity is File) {
            await entity.delete();
          }
        } catch (e) {
          _log.warning('Failed to delete ${entity.path}: $e');
        }
      }
    }
  }

  /// Full pipeline: fetch manifest → download all chunks in parallel
  /// → concatenate → verify combined sha256 → gunzip → verify schema
  /// version → atomic rename.
  ///
  /// * [variantId] is the catalog variant (e.g. `s1_n1_r5`).
  /// * [catalogDbPath] is where the final on-device catalog lives.
  /// * [expectedUncompressedBytes] is used as the install-phase
  ///   progress total. Pass `0` to render an indeterminate spinner.
  /// * [beforeInstall] is invoked just before the atomic rename so
  ///   the caller can close any open sqflite handle.
  /// * [cancellation] short-circuits each worker between chunks and
  ///   between the loop and install phases. Partial files stay on
  ///   disk; a future call resumes from there.
  Stream<DownloadProgress> downloadAndInstall({
    required String variantId,
    required String catalogDbPath,
    required int expectedUncompressedBytes,
    required Future<void> Function() beforeInstall,
    required CancellationToken cancellation,
  }) {
    final controller = StreamController<DownloadProgress>();
    // Run the work as a fire-and-forget Future and route both
    // progress events and terminal errors through the controller.
    // The async-generator shape is awkward to compose with the worker
    // pool's parallel emissions, so we drop down to an explicit
    // controller here.
    Future<void> drive() async {
      try {
        await _drive(
          controller: controller,
          variantId: variantId,
          catalogDbPath: catalogDbPath,
          expectedUncompressedBytes: expectedUncompressedBytes,
          beforeInstall: beforeInstall,
          cancellation: cancellation,
        );
      } catch (e, st) {
        controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }

    unawaited(drive());
    return controller.stream;
  }

  Future<void> _drive({
    required StreamController<DownloadProgress> controller,
    required String variantId,
    required String catalogDbPath,
    required int expectedUncompressedBytes,
    required Future<void> Function() beforeInstall,
    required CancellationToken cancellation,
  }) async {
    final stopwatch = Stopwatch()..start();
    final dir = await _docsDirResolver();
    final tmpManifestPath = p.join(dir.path, _tmpManifestFilename);
    final tmpGzPath = p.join(dir.path, _tmpGzFilename);
    final tmpDbPath = p.join(dir.path, _tmpDbFilename);
    final userAgent = await _userAgentResolver();

    final client = ONTHttpClient(
      userAgent,
      _httpClientFactory(),
      extraHeaders: _catalogRequestHeaders,
    );
    final _CatalogManifest manifest;
    try {
      manifest = await _resolveManifest(
        client: client,
        variantId: variantId,
        tmpManifestPath: tmpManifestPath,
        dir: dir,
      );
    } finally {
      client.close();
    }

    // Phase 1: chunked download. Workers share a bytes-done counter
    // and a queue of pending parts.
    final bytesDoneByPart = <String, int>{};
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

    int totalBytesDone() {
      var total = 0;
      for (final v in bytesDoneByPart.values) {
        total += v;
      }
      return total;
    }

    void maybeEmit({bool force = false}) {
      final now = DateTime.now();
      if (!force && now.difference(lastEmit) < _downloadEmitInterval) {
        return;
      }
      lastEmit = now;
      controller.add(DownloadProgress(
        phase: DownloadPhase.downloading,
        bytesDone: totalBytesDone(),
        bytesTotal: manifest.totalCompressedBytes,
        elapsed: stopwatch.elapsed,
      ));
    }

    // Pre-populate the counter with bytes already on disk so the
    // first emission reflects how far a resumed download has come.
    final pending = <_CatalogPart>[];
    for (final part in manifest.parts) {
      final partFile =
          File(p.join(dir.path, _localNameFor(part.name)));
      final existing = await partFile.exists() ? await partFile.length() : 0;
      if (existing >= part.bytes) {
        // Optimistic: trust the size. We'll verify the sha256 before
        // concat regardless, and a hash mismatch will rewipe.
        bytesDoneByPart[part.name] = part.bytes;
      } else {
        bytesDoneByPart[part.name] = existing;
        pending.add(part);
      }
    }
    maybeEmit(force: true);

    if (pending.isNotEmpty) {
      await _runWorkers(
        pending: pending,
        manifest: manifest,
        userAgent: userAgent,
        dir: dir,
        bytesDoneByPart: bytesDoneByPart,
        cancellation: cancellation,
        onProgress: () => maybeEmit(),
      );
      maybeEmit(force: true);
    }

    cancellation.throwIfCancelled();

    // Phase 2: verify, concatenate, gunzip, rename.
    await _verifyAndConcatenate(
      manifest: manifest,
      dir: dir,
      tmpGzPath: tmpGzPath,
    );

    cancellation.throwIfCancelled();

    final out = File(tmpDbPath).openWrite();
    var uncompressedBytes = 0;
    var lastInstallEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      // The decompressed output for the largest variant is ~3.7 GB.
      // We MUST go through `addStream` rather than the looped
      // `out.add(chunk)` pattern: `IOSink.add` does not await the
      // underlying file write, so chunks accumulate in a native
      // buffer and the process gets killed by the kernel for
      // exceeding its memory budget. `addStream` respects
      // backpressure — it pauses the source stream while the sink
      // is busy, keeping peak memory bounded by the gzip decoder's
      // internal buffer rather than the full output size.
      final gzipStream = File(tmpGzPath).openRead().transform(gzip.decoder);
      final tracked = gzipStream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            if (cancellation.isCancelled) {
              sink.addError(const CancellationException());
              sink.close();
              return;
            }
            uncompressedBytes += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastInstallEmit) >= _installEmitInterval) {
              lastInstallEmit = now;
              controller.add(DownloadProgress(
                phase: DownloadPhase.installing,
                bytesDone: uncompressedBytes,
                bytesTotal: expectedUncompressedBytes,
                elapsed: stopwatch.elapsed,
              ));
            }
            sink.add(chunk);
          },
        ),
      );
      await out.addStream(tracked);
      await out.flush();
    } finally {
      await out.close();
    }
    cancellation.throwIfCancelled();

    await _verifyStagedSchema(tmpDbPath);
    await beforeInstall();

    await File(tmpDbPath).rename(catalogDbPath);

    // Cleanup partials. Best-effort.
    await cleanupPartials();

    controller.add(DownloadProgress(
      phase: DownloadPhase.installing,
      bytesDone: uncompressedBytes,
      bytesTotal: expectedUncompressedBytes > 0
          ? expectedUncompressedBytes
          : uncompressedBytes,
      elapsed: stopwatch.elapsed,
    ));
  }

  /// Read the cached manifest if we have one, fetch a fresh one
  /// otherwise. On a resume, validate the cached vs fresh sha256 to
  /// detect a CDN rebuild that has rotated the chunks under us.
  Future<_CatalogManifest> _resolveManifest({
    required ONTHttpClient client,
    required String variantId,
    required String tmpManifestPath,
    required Directory dir,
  }) async {
    final manifestFile = File(tmpManifestPath);
    final hasCached = await manifestFile.exists();
    final freshResponse = await client
        .get(manifestUrlFor(variantId))
        .timeout(const Duration(seconds: 30));
    if (freshResponse.statusCode == 403) {
      throw const CatalogAccessDeniedException();
    }
    if (freshResponse.statusCode != 200) {
      throw HttpException(
        'GET ${manifestUrlFor(variantId)} returned '
        '${freshResponse.statusCode}',
      );
    }
    final fresh = _CatalogManifest.fromJson(
      jsonDecode(freshResponse.body) as Map<String, dynamic>,
    );
    if (fresh.manifestVersion != _kSupportedManifestVersion) {
      throw FormatException(
        'Catalog manifest version ${fresh.manifestVersion} is not '
        'supported by this client (max $_kSupportedManifestVersion). '
        'Update the app to use this catalog.',
      );
    }
    if (fresh.variantId != variantId) {
      throw FormatException(
        'Manifest variantId ${fresh.variantId} does not match '
        'requested $variantId',
      );
    }

    // Early refusal on a major-version mismatch. The CDN only ever
    // hosts a single catalog version at a time (we don't have the
    // budget to keep multiple major versions live), so when the build
    // pipeline ships v2 the v1 client must not download what it can't
    // read. Any existing on-device catalog is left in place — the
    // user keeps using yesterday's data on their old app version
    // until they update.
    if (fresh.schemaVersionMajor > supportedSchemaVersion) {
      throw CatalogSchemaVersionException(
        downloaded: fresh.schemaVersionMajor,
        supported: supportedSchemaVersion,
      );
    }

    if (hasCached) {
      try {
        final cached = _CatalogManifest.fromJson(
          jsonDecode(await manifestFile.readAsString())
              as Map<String, dynamic>,
        );
        if (cached.sha256Hex != fresh.sha256Hex) {
          // CDN rebuild while we were paused. Wipe everything and
          // surface a recoverable error so the user picks "discard
          // and start over" from the wizard.
          _log.info(
            'Cached manifest sha256 ${cached.sha256Hex} differs from '
            'fresh ${fresh.sha256Hex}; the catalog has been rebuilt '
            'since the partial download started. Wiping partials.',
          );
          await cleanupPartials();
          throw const CatalogVariantRotatedException();
        }
      } on FormatException {
        // Malformed cached manifest — just overwrite it.
        await cleanupPartials();
      }
    }

    await manifestFile.writeAsString(
      jsonEncode(fresh.toJson()),
      flush: true,
    );
    return fresh;
  }

  /// Run up to [_workerConcurrency] download workers in parallel,
  /// each pulling parts off the shared [pending] list until empty.
  Future<void> _runWorkers({
    required List<_CatalogPart> pending,
    required _CatalogManifest manifest,
    required String userAgent,
    required Directory dir,
    required Map<String, int> bytesDoneByPart,
    required CancellationToken cancellation,
    required void Function() onProgress,
  }) async {
    final queue = List<_CatalogPart>.from(pending);
    final workerCount = math.min(_workerConcurrency, queue.length);

    Future<void> worker() async {
      final client = ONTHttpClient(
        userAgent,
        _httpClientFactory(),
        extraHeaders: _catalogRequestHeaders,
      );
      try {
        while (queue.isNotEmpty) {
          if (cancellation.isCancelled) return;
          final part = queue.removeAt(0);
          await _downloadOnePart(
            part: part,
            client: client,
            dir: dir,
            bytesDoneByPart: bytesDoneByPart,
            cancellation: cancellation,
            onProgress: onProgress,
          );
        }
      } finally {
        client.close();
      }
    }

    await Future.wait(
      List.generate(workerCount, (_) => worker()),
      eagerError: true,
    );
    cancellation.throwIfCancelled();
  }

  /// Pull a single part to disk. Resume-aware: if the file already
  /// has bytes from a previous attempt we issue a `Range:` request
  /// and append the rest. Handles the Cloudflare quirk where the
  /// edge sometimes returns 200-with-full-body to a Range request by
  /// truncating the partial and rewriting from byte 0.
  Future<void> _downloadOnePart({
    required _CatalogPart part,
    required ONTHttpClient client,
    required Directory dir,
    required Map<String, int> bytesDoneByPart,
    required CancellationToken cancellation,
    required void Function() onProgress,
  }) async {
    final partFile = File(p.join(dir.path, _localNameFor(part.name)));
    var resumeFrom =
        await partFile.exists() ? await partFile.length() : 0;

    if (resumeFrom >= part.bytes) {
      // Already on disk; defer hash check to the verify phase.
      bytesDoneByPart[part.name] = part.bytes;
      return;
    }

    final request = http.Request('GET', partUrlFor(part.name));
    if (resumeFrom > 0) {
      request.headers['Range'] = 'bytes=$resumeFrom-';
    }

    final response = await client.send(request);
    if (response.statusCode == 403) {
      throw const CatalogAccessDeniedException();
    }
    if (resumeFrom > 0 && response.statusCode == 200) {
      // Cloudflare ignored the Range header. Truncate and start over.
      _log.info(
        'Server ignored Range header on part ${part.name} '
        '(returned 200 to a Range request); restarting from byte 0',
      );
      await partFile.writeAsBytes(const <int>[]);
      resumeFrom = 0;
      bytesDoneByPart[part.name] = 0;
      onProgress();
    }
    final ok = (resumeFrom == 0 && response.statusCode == 200) ||
        (resumeFrom > 0 && response.statusCode == 206);
    if (!ok) {
      throw HttpException(
        'GET ${partUrlFor(part.name)} returned '
        '${response.statusCode} (resumeFrom=$resumeFrom)',
      );
    }

    final sink = partFile.openWrite(mode: FileMode.append);
    var bytesDone = resumeFrom;
    try {
      await for (final chunk in response.stream) {
        if (cancellation.isCancelled) break;
        sink.add(chunk);
        bytesDone += chunk.length;
        bytesDoneByPart[part.name] = bytesDone;
        onProgress();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Validate per-part sha256 and combined sha256 while concatenating
  /// every part into the single tmp `.gz`. Single streaming pass per
  /// part: bytes flow simultaneously into the per-part hasher, the
  /// combined hasher, and the output sink, so peak memory is the
  /// underlying file-read buffer rather than a whole part in RAM.
  ///
  /// Backpressure note: we route bytes through `IOSink.addStream`
  /// rather than the looped `sink.add(chunk)` pattern. Without the
  /// stream's natural pause/resume, the largest variant's 520 MB of
  /// concatenated output piles up in the sink's native buffer and
  /// the process gets killed for exceeding its memory budget. With
  /// `addStream`, the source pauses whenever the sink is busy, so
  /// peak memory stays bounded by the in-flight chunk plus the
  /// hasher state.
  Future<void> _verifyAndConcatenate({
    required _CatalogManifest manifest,
    required Directory dir,
    required String tmpGzPath,
  }) async {
    final out = File(tmpGzPath);
    if (await out.exists()) await out.delete();
    final sink = out.openWrite();
    final combinedSink = _DigestSink();
    final combinedHasher = sha256.startChunkedConversion(combinedSink);
    try {
      for (final part in manifest.parts) {
        final partFile =
            File(p.join(dir.path, _localNameFor(part.name)));
        final size = await partFile.length();
        if (size != part.bytes) {
          throw CatalogPartChecksumException(
            partName: part.name,
            expected: 'size ${part.bytes}',
            actual: 'size $size',
          );
        }
        final partSink = _DigestSink();
        final partHasher = sha256.startChunkedConversion(partSink);
        // Tee the read stream into the two hashers while letting
        // `addStream` push the bytes into the sink under proper
        // backpressure. The transformer doesn't buffer — each
        // chunk lands in both hashers and then re-emerges into the
        // sink in the same call.
        final teed = partFile.openRead().transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, downstream) {
              partHasher.add(chunk);
              combinedHasher.add(chunk);
              downstream.add(chunk);
            },
          ),
        );
        await sink.addStream(teed);
        partHasher.close();
        final partActual = partSink.digest!.toString();
        if (partActual != part.sha256Hex) {
          throw CatalogPartChecksumException(
            partName: part.name,
            expected: part.sha256Hex,
            actual: partActual,
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    combinedHasher.close();
    final combinedActual = combinedSink.digest!.toString();
    if (combinedActual != manifest.sha256Hex) {
      throw CatalogPartChecksumException(
        partName: '<combined>',
        expected: manifest.sha256Hex,
        actual: combinedActual,
      );
    }
  }

  /// Open the freshly-staged sqlite at [path] read-only and confirm
  /// its `catalog_meta.schema_version` (the major version) is one we
  /// can read.
  ///
  /// **Compatibility model.** The build script writes two values:
  ///
  /// * `schema_version` — the **major** version. Bumped only when a
  ///   schema change renames or removes something the client depends
  ///   on. Refuse if `major > supportedSchemaVersion`.
  /// * `schema_version_minor` (optional, defaults to 0 when absent) —
  ///   bumped freely for additive changes (new columns, new tables).
  ///   We accept any minor at the same major: extra columns and
  ///   tables sit harmlessly alongside what we query, and our SELECTs
  ///   name specific columns so they ignore the unknowns.
  ///
  /// This lets a stale client install whatever the CDN currently
  /// serves as long as the major hasn't moved, so users on lagging
  /// app versions still get fresh data. When a major bump genuinely
  /// breaks compatibility, refusing here is the right call —
  /// installing a v2 catalog into a v1 client could produce silently
  /// wrong query results.
  Future<void> _verifyStagedSchema(String path) async {
    Database? db;
    try {
      db = await openReadOnlyDatabase(path);
      final majorRaw = await _readMetaValue(db, 'schema_version');
      if (majorRaw == null) {
        throw const FormatException(
          'Downloaded catalog has no schema_version entry in catalog_meta',
        );
      }
      final major = int.tryParse(majorRaw);
      if (major == null) {
        throw FormatException(
          'Downloaded catalog has an unparseable schema_version: '
          '$majorRaw',
        );
      }
      if (major > supportedSchemaVersion) {
        throw CatalogSchemaVersionException(
          downloaded: major,
          supported: supportedSchemaVersion,
        );
      }
      // Minor is informational. A missing entry (older artefact built
      // before the minor field existed) is treated as 0.
      final minorRaw = await _readMetaValue(db, 'schema_version_minor');
      final minor = minorRaw == null ? 0 : (int.tryParse(minorRaw) ?? 0);
      _log.info(
        'Catalog schema accepted: major=$major minor=$minor '
        '(this client supports up to major $supportedSchemaVersion, '
        'any minor)',
      );
    } finally {
      await db?.close();
    }
  }

  Future<String?> _readMetaValue(Database db, String key) async {
    final rows = await db.rawQuery(
      'SELECT value FROM catalog_meta WHERE key = ? LIMIT 1',
      [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value']?.toString();
  }

  /// Map a manifest part name (e.g. `s1_n1_r5.db.gz.part-00`) to the
  /// local filename we use for its on-disk staging copy
  /// (`offline_catalog.db.tmp.part-00`). This way every variant's
  /// partials live under the same filename family, so
  /// `cleanupPartials()` can wipe them with one prefix glob and the
  /// final catalog file path is independent of which variant the
  /// user picked.
  static String _localNameFor(String partName) {
    final dashIdx = partName.lastIndexOf('-');
    final suffix = dashIdx >= 0 ? partName.substring(dashIdx + 1) : '00';
    return '$_tmpPartPrefix$suffix';
  }
}

/// Tiny `Sink<Digest>` for `Hash.startChunkedConversion`. Stores the
/// finalised digest so we can read it back after `close()`.
class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest event) {
    digest = event;
  }

  @override
  void close() {}
}
