import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/build_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/delete_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/estimate_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_catalog_stats_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/refresh_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';

/// Regression test for the lifecycle-vs-auxiliary phase confusion.
///
/// Background: when the wizard is reopened onto a paused download, it
/// fires both `LoadCatalogStatusEvent` (which sets phase=paused) and,
/// the moment the user steps onto the Estimate page, an
/// `EstimateCatalogEvent`. The auxiliary estimate fetch could
/// otherwise overwrite the catalog's lifecycle phase, leaving the
/// download page stuck on a bare spinner because state.phase was
/// briefly `estimating`.
///
/// The fix: the estimate handler preserves any "lifecycle" phase
/// already in flight. This test pins that contract down so the
/// regression can't sneak back in.
void main() {
  group('OfflineCatalogBloc — auxiliary events preserve lifecycle phase',
      () {
    late OfflineCatalogBloc bloc;
    late _StubGetStatsUseCase getStats;
    late _StubBuildUseCase buildUseCase;

    setUp(() {
      getStats = _StubGetStatsUseCase();
      buildUseCase = _StubBuildUseCase();
      bloc = OfflineCatalogBloc(
        getStats,
        _StubEstimateUseCase(),
        buildUseCase,
        _StubRefreshUseCase(),
        _StubDeleteUseCase(),
        _StubConfigRepository(),
      );
    });

    tearDown(() async {
      await bloc.close();
    });

    test(
        'EstimateCatalogEvent does not overwrite a paused lifecycle '
        'phase set by LoadCatalogStatusEvent', () async {
      // Seed the data sources to land us on a paused build.
      getStats.next = const CatalogStatsEntity(
        productCount: 100,
        sizeBytes: 1024,
        lastSyncTime: null,
        filtersJson: null,
      );
      buildUseCase.hasResume = true;
      buildUseCase.persistedFilters = const CatalogFilterEntity();

      bloc.add(const LoadCatalogStatusEvent());
      // The wizard fires an estimate the moment the user lands on
      // the Estimate page; the bug was that this could derail an
      // in-flight pause.
      bloc.add(const EstimateCatalogEvent(CatalogFilterEntity()));

      // Wait for both events to drain.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        bloc.state.phase,
        OfflineCatalogPhase.paused,
        reason: 'Estimate should not have overridden the paused '
            'lifecycle state',
      );
    });

    test(
        'EstimateCatalogEvent fired against an idle catalog still '
        'transitions through estimating → estimated as it always did',
        () async {
      // No paused build, no products on disk.
      getStats.next = CatalogStatsEntity.empty;
      buildUseCase.hasResume = false;

      bloc.add(const LoadCatalogStatusEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.phase, OfflineCatalogPhase.idle,
          reason: 'No catalog yet → idle');

      bloc.add(const EstimateCatalogEvent(CatalogFilterEntity()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.phase, OfflineCatalogPhase.estimated,
          reason: 'Idle is NOT a lifecycle phase — estimate may '
              'transition through its normal phases here');
      expect(bloc.state.estimate, isNotNull);
    });

    test(
        'EstimateCatalogEvent fired against a ready catalog is a '
        'no-op (preserves lifecycle phase)', () async {
      getStats.next = const CatalogStatsEntity(
        productCount: 100,
        sizeBytes: 1024,
        lastSyncTime: null,
        filtersJson: null,
      );
      buildUseCase.hasResume = false;

      bloc.add(const LoadCatalogStatusEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.phase, OfflineCatalogPhase.ready);

      bloc.add(const EstimateCatalogEvent(CatalogFilterEntity()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.phase, OfflineCatalogPhase.ready,
          reason: 'Estimate must not derail an in-flight lifecycle');
    });
  });

  group('CatalogFilterEntity — variant id round trip', () {
    test('toVariantId() produces the canonical s/n/r form', () {
      expect(
        const CatalogFilterEntity().toVariantId(),
        equals('s1_n1_r5'),
      );
      expect(
        const CatalogFilterEntity(
          requireMinPopularity: false,
          requireNutritionGrade: false,
          maxAge: null,
        ).toVariantId(),
        equals('s0_n0_rany'),
      );
      expect(
        const CatalogFilterEntity(
          maxAge: Duration(days: 365 * 3),
        ).toVariantId(),
        equals('s1_n1_r3'),
      );
      expect(
        const CatalogFilterEntity(
          requireMinPopularity: false,
          maxAge: Duration(days: 365 * 10),
        ).toVariantId(),
        equals('s0_n1_r10'),
      );
    });

    test('fromVariantId() inverts toVariantId() across all 16 combos',
        () {
      const all = [
        's0_n0_r3', 's0_n0_r5', 's0_n0_r10', 's0_n0_rany',
        's0_n1_r3', 's0_n1_r5', 's0_n1_r10', 's0_n1_rany',
        's1_n0_r3', 's1_n0_r5', 's1_n0_r10', 's1_n0_rany',
        's1_n1_r3', 's1_n1_r5', 's1_n1_r10', 's1_n1_rany',
      ];
      for (final variant in all) {
        final entity = CatalogFilterEntity.fromVariantId(variant);
        expect(entity, isNotNull, reason: 'fromVariantId($variant)');
        expect(entity!.toVariantId(), equals(variant));
      }
    });

    test('fromVariantId() returns null for malformed input', () {
      expect(CatalogFilterEntity.fromVariantId(''), isNull);
      expect(CatalogFilterEntity.fromVariantId('s2_n0_r5'), isNull);
      expect(CatalogFilterEntity.fromVariantId('s1_n1_r7'), isNull);
      expect(CatalogFilterEntity.fromVariantId('not-a-variant'), isNull);
    });
  });
}

// ---------- Test stubs ---------- //

class _StubGetStatsUseCase implements GetCatalogStatsUseCase {
  CatalogStatsEntity next = CatalogStatsEntity.empty;

  @override
  Future<CatalogStatsEntity> call() async => next;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

class _StubBuildUseCase implements BuildCatalogUseCase {
  bool hasResume = false;
  CatalogFilterEntity? persistedFilters;

  @override
  Future<bool> hasResumeableBuild() async => hasResume;

  @override
  Future<CatalogFilterEntity?> getPersistedFilters() async =>
      persistedFilters;

  @override
  Stream<DownloadProgress> call({
    required CatalogFilterEntity filters,
    required CancellationToken cancellation,
  }) async* {
    // Empty — these tests don't run the build path.
  }
}

class _StubEstimateUseCase implements EstimateCatalogUseCase {
  @override
  Future<CatalogEstimateEntity> call(CatalogFilterEntity filters) async =>
      const CatalogEstimateEntity(
        rows: 351000,
        estimatedBytes: 537 * 1024 * 1024,
        requests: 73 * 1024 * 1024,
        etaSeconds: 8,
      );
}

class _StubRefreshUseCase implements RefreshCatalogUseCase {
  @override
  Stream<DownloadProgress> call({required CancellationToken cancellation}) =>
      const Stream.empty();
}

class _StubDeleteUseCase implements DeleteCatalogUseCase {
  @override
  Future<void> call() async {}
}

class _StubConfigRepository implements ConfigRepository {
  @override
  Future<void> setOfflineCatalogEnabled(bool enabled) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}
