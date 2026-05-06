import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/cancellation_token.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_estimate_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_filter_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/catalog_stats_entity.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/download_progress.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/build_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/delete_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/estimate_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_catalog_stats_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/get_countries_taxonomy_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/domain/usecase/refresh_catalog_usecase.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';

/// Regression test for the lifecycle-vs-auxiliary phase confusion.
///
/// Background: when the wizard is reopened onto a paused build, it
/// fires both `LoadCatalogStatusEvent` (which sets phase=paused) and
/// `LoadCountriesEvent` (which used to set phase=loadingCountries
/// then countriesLoaded). The auxiliary country fetch was
/// overwriting the catalog's lifecycle phase, leaving the download
/// page stuck on a bare spinner because state.phase wasn't one of
/// the cases its switch handles.
///
/// The fix: country / estimate handlers preserve any "lifecycle"
/// phase already in flight. This test pins that contract down so
/// the regression can't sneak back in.
void main() {
  group('OfflineCatalogBloc — auxiliary events preserve lifecycle phase',
      () {
    late OfflineCatalogBloc bloc;
    late _StubGetCountriesUseCase getCountries;
    late _StubGetStatsUseCase getStats;
    late _StubBuildUseCase buildUseCase;

    setUp(() {
      getCountries = _StubGetCountriesUseCase();
      getStats = _StubGetStatsUseCase();
      buildUseCase = _StubBuildUseCase();
      bloc = OfflineCatalogBloc(
        getStats,
        getCountries,
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
        'LoadCountriesEvent does not overwrite a paused lifecycle '
        'phase set by LoadCatalogStatusEvent', () async {
      // Seed the data sources to land us on a paused build.
      getStats.next = const CatalogStatsEntity(
        productCount: 100,
        sizeBytes: 1024,
        lastSyncTime: null,
        filtersJson: null,
      );
      buildUseCase.hasResume = true;
      buildUseCase.persistedFilters = const CatalogFilterEntity(
        countries: {'en:united-kingdom'},
      );

      // Country fetch returns a normal list; the bug was about
      // LoadCountries overwriting phase, not about country results.
      getCountries.next = const [
        CountryTaxonomyEntry(
          code: 'en:united-kingdom',
          name: 'United Kingdom',
          productCount: 100000,
        ),
      ];

      bloc.add(const LoadCatalogStatusEvent());
      bloc.add(const LoadCountriesEvent());

      // Wait for both events to drain.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        bloc.state.phase,
        OfflineCatalogPhase.paused,
        reason: 'LoadCountries should not have overridden the paused '
            'lifecycle state',
      );
      expect(
        bloc.state.countries,
        isNotNull,
        reason: 'Countries should still have populated as a side '
            'effect of LoadCountries',
      );
    });

    test(
        'LoadCountriesEvent fired against an idle catalog still sets '
        'loadingCountries → countriesLoaded as it always did',
        () async {
      // No paused build, no products on disk.
      getStats.next = CatalogStatsEntity.empty;
      buildUseCase.hasResume = false;
      getCountries.next = const [
        CountryTaxonomyEntry(
          code: 'en:france',
          name: 'France',
          productCount: 1000000,
        ),
      ];

      bloc.add(const LoadCatalogStatusEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.phase, OfflineCatalogPhase.idle,
          reason: 'No catalog yet → idle');

      bloc.add(const LoadCountriesEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.phase, OfflineCatalogPhase.countriesLoaded,
          reason: 'Idle is NOT a lifecycle phase — country fetch may '
              'transition through its normal phases here');
      expect(bloc.state.countries, hasLength(1));
    });

    test(
        'EstimateCatalogEvent fired against a paused build is a '
        'no-op (preserves lifecycle phase)', () async {
      getStats.next = const CatalogStatsEntity(
        productCount: 100,
        sizeBytes: 1024,
        lastSyncTime: null,
        filtersJson: null,
      );
      buildUseCase.hasResume = true;
      buildUseCase.persistedFilters = const CatalogFilterEntity(
        countries: {'en:united-kingdom'},
      );

      bloc.add(const LoadCatalogStatusEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.phase, OfflineCatalogPhase.paused);

      bloc.add(EstimateCatalogEvent(const CatalogFilterEntity(
        countries: {'en:france'},
      )));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.phase, OfflineCatalogPhase.paused,
          reason: 'Estimate must not derail an in-flight lifecycle');
    });
  });
}

// ---------- Test stubs ---------- //

class _StubGetCountriesUseCase implements GetCountriesTaxonomyUseCase {
  List<CountryTaxonomyEntry> next = const [];

  @override
  Future<List<CountryTaxonomyEntry>> call({
    String? locale,
    bool forceRefresh = false,
  }) async => next;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: ${invocation.memberName}');
}

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
        rows: 0,
        estimatedBytes: 0,
        requests: 0,
        etaSeconds: 0,
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
