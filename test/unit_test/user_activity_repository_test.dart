import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/core/data/data_source/user_activity_data_source.dart';
import 'package:opennutritracker/core/data/data_source/user_activity_dbo.dart';
import 'package:opennutritracker/core/data/dbo/physical_activity_dbo.dart';
import 'package:opennutritracker/core/data/repository/user_activity_repository.dart';
import 'package:opennutritracker/core/domain/entity/user_activity_entity.dart';

void main() {
  group('UserActivityRepository', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      Hive.registerAdapter(UserActivityDBOAdapter());
      Hive.registerAdapter(PhysicalActivityDBOAdapter());
      Hive.registerAdapter(PhysicalActivityTypeDBOAdapter());
    });

    setUp(() {
      Hive.init('.');
    });

    tearDown(() async {
      await Hive.close();
      Hive.deleteFromDisk();
    });

    test('updateUserActivity updates duration and recalculates burnedKcal',
        () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'running_general',
        'running, general',
        'running, general',
        8.0, // MET value
        [],
        PhysicalActivityTypeDBO.running,
      );

      final activity = UserActivityDBO(
        'test-id-1',
        30.0, // 30 minutes
        50.0, // original burnedKcal (placeholder)
        DateTime.utc(2024, 6, 1),
        physicalActivity,
      );
      await box.add(activity);

      final updated = await repo.updateUserActivity('test-id-1', 60.0, 99.5);

      expect(updated, isNotNull);
      expect(updated!.id, equals('test-id-1'));
      expect(updated.duration, equals(60.0));
      expect(updated.burnedKcal, equals(99.5));
      expect(updated.physicalActivityEntity.code, equals('running_general'));
    });

    test('updateUserActivity returns null for unknown id', () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final result =
          await repo.updateUserActivity('nonexistent', 60.0, 100.0);
      expect(result, isNull);
    });

    test('updateUserActivity preserves the original date', () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final originalDate = DateTime.utc(2026, 3, 14, 9, 26, 53);
      final physicalActivity = PhysicalActivityDBO(
        'cycling_general',
        'cycling, general',
        'cycling, general',
        7.5,
        [],
        PhysicalActivityTypeDBO.bicycling,
      );
      await box.add(UserActivityDBO(
        'date-test',
        45.0,
        300.0,
        originalDate,
        physicalActivity,
      ));

      final updated = await repo.updateUserActivity('date-test', 30.0, 200.0);
      expect(updated, isNotNull);
      expect(updated!.date, equals(originalDate));
    });

    test('updateUserActivity preserves the underlying physical activity',
        () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'walking_brisk',
        'walking, brisk',
        'walking, brisk',
        4.3,
        ['walking'],
        PhysicalActivityTypeDBO.sport,
      );
      await box.add(UserActivityDBO(
        'phys-test',
        20.0,
        100.0,
        DateTime.utc(2026, 1, 1),
        physicalActivity,
      ));

      final updated = await repo.updateUserActivity('phys-test', 25.0, 130.0);
      expect(updated!.physicalActivityEntity.code, equals('walking_brisk'));
      expect(updated.physicalActivityEntity.mets, equals(4.3));
    });

    test('updateUserActivity accepts a zero duration without crashing',
        () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'running_general',
        'running, general',
        'running, general',
        8.0,
        [],
        PhysicalActivityTypeDBO.running,
      );
      await box.add(UserActivityDBO(
        'zero-test',
        30.0,
        50.0,
        DateTime.utc(2024, 6, 1),
        physicalActivity,
      ));

      final updated = await repo.updateUserActivity('zero-test', 0.0, 0.0);
      expect(updated, isNotNull);
      expect(updated!.duration, equals(0.0));
      expect(updated.burnedKcal, equals(0.0));
    });

    test('two consecutive updates both work and the last one wins', () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      await box.clear();
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'running_general',
        'running, general',
        'running, general',
        8.0,
        [],
        PhysicalActivityTypeDBO.running,
      );
      await box.add(UserActivityDBO(
        'multi-test',
        30.0,
        50.0,
        DateTime.utc(2024, 6, 1),
        physicalActivity,
      ));

      await repo.updateUserActivity('multi-test', 45.0, 75.0);
      final second = await repo.updateUserActivity('multi-test', 60.0, 100.0);

      expect(second, isNotNull);
      expect(second!.duration, equals(60.0));
      expect(second.burnedKcal, equals(100.0));

      // The store should still hold exactly one row for that id.
      final all = await repo.getAllUserActivityDBO();
      final matches = all.where((a) => a.id == 'multi-test').toList();
      expect(matches, hasLength(1));
    });

    test('deleteUserActivity removes the activity by id', () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'running_general',
        'running, general',
        'running, general',
        8.0,
        [],
        PhysicalActivityTypeDBO.running,
      );
      final activity = UserActivityDBO(
        'delete-test',
        30.0,
        50.0,
        DateTime.utc(2024, 6, 1),
        physicalActivity,
      );
      await box.add(activity);

      await repo.deleteUserActivity(
        UserActivityEntity.fromUserActivityDBO(activity),
      );

      final all = await repo.getAllUserActivityDBO();
      expect(all.where((a) => a.id == 'delete-test'), isEmpty);
    });

    test('getAllUserActivityByDate returns only same-day activities',
        () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      await box.clear();
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final physicalActivity = PhysicalActivityDBO(
        'walking_brisk',
        'walking, brisk',
        'walking, brisk',
        4.3,
        [],
        PhysicalActivityTypeDBO.sport,
      );

      await box.addAll([
        UserActivityDBO('a', 30, 50, DateTime.utc(2024, 6, 1, 8, 0),
            physicalActivity),
        UserActivityDBO('b', 30, 50, DateTime.utc(2024, 6, 1, 18, 0),
            physicalActivity),
        UserActivityDBO('c', 30, 50, DateTime.utc(2024, 6, 2, 8, 0),
            physicalActivity),
      ]);

      final june1 =
          await repo.getAllUserActivityByDate(DateTime.utc(2024, 6, 1, 12));
      expect(june1.map((a) => a.id).toSet(), equals({'a', 'b'}));

      final june2 =
          await repo.getAllUserActivityByDate(DateTime.utc(2024, 6, 2));
      expect(june2.map((a) => a.id).toList(), equals(['c']));
    });

    test('getRecentUserActivity dedups by physical activity code, '
        'most recent first', () async {
      final box = await Hive.openBox<UserActivityDBO>('activity_test');
      await box.clear();
      final repo = UserActivityRepository(UserActivityDataSource(box));

      final running = PhysicalActivityDBO(
        'running_general',
        'running, general',
        'running, general',
        8.0,
        [],
        PhysicalActivityTypeDBO.running,
      );
      final cycling = PhysicalActivityDBO(
        'cycling_general',
        'cycling, general',
        'cycling, general',
        7.5,
        [],
        PhysicalActivityTypeDBO.bicycling,
      );

      await box.addAll([
        UserActivityDBO('r1', 30, 50, DateTime.utc(2024, 6, 1), running),
        UserActivityDBO('r2', 30, 50, DateTime.utc(2024, 6, 5), running),
        UserActivityDBO('c1', 30, 50, DateTime.utc(2024, 6, 3), cycling),
      ]);

      final recent = await repo.getRecentUserActivity();
      // r1 deduped because r2 is newer with same code.
      expect(recent.map((a) => a.physicalActivityEntity.code).toList(),
          equals(['running_general', 'cycling_general']));
    });
  });
}
