import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/core/data/data_source/config_data_source.dart';
import 'package:opennutritracker/core/data/data_source/health_connect_service.dart';
import 'package:opennutritracker/core/data/data_source/intake_data_source.dart';
import 'package:opennutritracker/core/data/dbo/config_dbo.dart';
import 'package:opennutritracker/core/data/dbo/intake_dbo.dart';
import 'package:opennutritracker/core/data/repository/intake_repository.dart';
import 'package:opennutritracker/core/domain/usecase/import_from_health_connect_usecase.dart';
import 'package:opennutritracker/features/settings/data/dto/health_connect_nutrition_record.dart';

import '../helpers/hive_test_setup.dart';

/// #295: The Health Connect import use case is the only piece in this
/// feature that has interesting branching — the rest is platform glue.
/// These tests cover the three branches a user actually hits:
///   * happy path: three records come back, three intakes land.
///   * re-running the same import: dedup catches the existing rows so
///     the user can't accidentally double their day.
///   * permission denial: we don't append anything and we report it
///     back to the UI so the snackbar can be honest.
class _FakeHealthConnectService implements HealthConnectService {
  bool grantsPermission;
  List<HealthConnectNutritionRecord> nextFetch;
  int fetchCalls = 0;
  int permissionCalls = 0;

  _FakeHealthConnectService({
    this.grantsPermission = true,
    this.nextFetch = const [],
  });

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<bool> requestPermissions() async {
    permissionCalls++;
    return grantsPermission;
  }

  @override
  Future<List<HealthConnectNutritionRecord>> fetchNutritionSince(
      DateTime since) async {
    fetchCalls++;
    return nextFetch;
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerHiveAdaptersOnce();
  });

  late Box<IntakeDBO> intakeBox;
  late Box<ConfigDBO> configBox;
  late IntakeRepository intakeRepository;
  late ConfigDataSource configDataSource;

  setUp(() async {
    Hive.init('.');
    final suffix = DateTime.now().microsecondsSinceEpoch;
    intakeBox = await Hive.openBox<IntakeDBO>('hc_intake_test_$suffix');
    configBox = await Hive.openBox<ConfigDBO>('hc_config_test_$suffix');
    await configBox.put('ConfigKey', ConfigDBO.empty());
    intakeRepository = IntakeRepository(IntakeDataSource(intakeBox));
    configDataSource = ConfigDataSource(configBox);
  });

  tearDown(() async {
    await intakeBox.deleteFromDisk();
    await configBox.deleteFromDisk();
  });

  HealthConnectNutritionRecord r(
    String name,
    DateTime when, {
    double kcal = 200,
    double carbs = 10,
    double protein = 8,
    double fat = 5,
  }) =>
      HealthConnectNutritionRecord(
        mealName: name,
        loggedAt: when,
        kcal: kcal,
        carbs: carbs,
        protein: protein,
        fat: fat,
      );

  test('appends three intakes when the service returns three records',
      () async {
    final base = DateTime(2026, 5, 16, 8, 30);
    final fake = _FakeHealthConnectService(
      nextFetch: [
        r('Porridge', base),
        r('Sandwich', base.add(const Duration(hours: 4))),
        r('Stir fry', base.add(const Duration(hours: 10))),
      ],
    );
    final usecase = ImportFromHealthConnectUseCase(
      fake,
      intakeRepository,
      configDataSource,
    );

    final result = await usecase.run();

    expect(result.imported, 3);
    expect(result.skipped, 0);
    expect(result.permissionDenied, isFalse);
    expect(fake.permissionCalls, 1);
    expect(fake.fetchCalls, 1);

    final stored = await intakeRepository.getAllIntakesDBO();
    expect(stored.length, 3);
    expect(
      stored.every(
        (dbo) => dbo.importSource ==
            ImportFromHealthConnectUseCase.sourceTag,
      ),
      isTrue,
    );
    expect(
      stored.map((dbo) => dbo.meal.name).toSet(),
      {'Porridge', 'Sandwich', 'Stir fry'},
    );

    // The high-water mark should now be set so the next run only looks
    // forward, not back to a hard-coded 30 days.
    final lastImport =
        await configDataSource.getLastHealthConnectImportAt();
    expect(lastImport, isNotNull);
  });

  test('re-running over the same window skips already-imported records',
      () async {
    final base = DateTime(2026, 5, 16, 8, 30);
    final records = [
      r('Porridge', base),
      r('Sandwich', base.add(const Duration(hours: 4))),
      r('Stir fry', base.add(const Duration(hours: 10))),
    ];
    final fake = _FakeHealthConnectService(nextFetch: records);
    final usecase = ImportFromHealthConnectUseCase(
      fake,
      intakeRepository,
      configDataSource,
    );

    final first = await usecase.run();
    expect(first.imported, 3);

    // Same payload comes back from Health Connect — the dedup index
    // should catch every row.
    final second = await usecase.run();
    expect(second.imported, 0);
    expect(second.skipped, 3);
    expect(second.permissionDenied, isFalse);

    final stored = await intakeRepository.getAllIntakesDBO();
    expect(stored.length, 3, reason: 'no duplicate intakes added');
  });

  test('permission denial returns ImportResult.permissionDenied with no writes',
      () async {
    final fake = _FakeHealthConnectService(
      grantsPermission: false,
      nextFetch: [r('Lunch', DateTime(2026, 5, 16, 12, 0))],
    );
    final usecase = ImportFromHealthConnectUseCase(
      fake,
      intakeRepository,
      configDataSource,
    );

    final result = await usecase.run();

    expect(result.permissionDenied, isTrue);
    expect(result.imported, 0);
    expect(result.skipped, 0);
    expect(fake.fetchCalls, 0,
        reason: 'fetch is skipped when permission is denied');

    final stored = await intakeRepository.getAllIntakesDBO();
    expect(stored, isEmpty);
  });
}
