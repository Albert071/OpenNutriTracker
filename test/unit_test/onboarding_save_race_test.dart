import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/data/repository/user_repository.dart';
import 'package:opennutritracker/core/domain/entity/user_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_pal_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_weight_goal_entity.dart';
import 'package:opennutritracker/core/domain/usecase/add_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/add_user_usecase.dart';
import 'package:opennutritracker/features/onboarding/presentation/bloc/onboarding_bloc.dart';

/// Fake repository whose every write returns a Future controlled by an
/// external Completer. Lets us assert that `OnboardingBloc.saveOnboardingData`
/// only resolves when the inner Hive writes have actually finished.
class _FakeUserRepository implements UserRepository {
  final Completer<void> writeCompleter = Completer<void>();
  bool writeStarted = false;

  @override
  Future<void> updateUserData(userEntity) async {
    writeStarted = true;
    await writeCompleter.future;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeConfigRepository implements ConfigRepository {
  final Completer<void> anonCompleter = Completer<void>();
  final Completer<void> imperialCompleter = Completer<void>();

  @override
  Future<void> setConfigHasAcceptedAnonymousData(bool _) async {
    await anonCompleter.future;
  }

  @override
  Future<void> setConfigUsesImperialUnits(bool _) async {
    await imperialCompleter.future;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  group('OnboardingBloc.saveOnboardingData await chain', () {
    late _FakeUserRepository userRepo;
    late _FakeConfigRepository configRepo;
    late OnboardingBloc bloc;

    setUp(() {
      userRepo = _FakeUserRepository();
      configRepo = _FakeConfigRepository();
      bloc = OnboardingBloc(
        AddUserUsecase(userRepo),
        AddConfigUsecase(configRepo),
      );
    });

    tearDown(() {
      bloc.close();
    });

    UserEntity makeUser() => UserEntity(
          birthday: DateTime(1990, 6, 15),
          heightCM: 165,
          weightKG: 70,
          gender: UserGenderEntity.female,
          goal: UserWeightGoalEntity.loseWeight,
          pal: UserPALEntity.sedentary,
        );

    test(
        'saveOnboardingData does not resolve until the user write completes',
        () async {
      // Regression: saveOnboardingData was `void ... async` and did not
      // await `_addUserUsecase.addUser(...)`. The onboarding screen then
      // navigated away before the user had been written to Hive, and the
      // home screen recomputed kcal against the dummy default user.

      final saveFuture =
          bloc.saveOnboardingData(makeUser(), false, false);

      // Yield once so the bloc has a chance to start the inner write.
      await Future<void>.delayed(Duration.zero);
      expect(userRepo.writeStarted, isTrue,
          reason: 'bloc must start the user write immediately');

      bool resolved = false;
      // ignore: unawaited_futures
      saveFuture.then((_) => resolved = true);

      // Without completing the user write, saveOnboardingData must not be
      // done — proves the bloc actually awaits the write.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolved, isFalse,
          reason: 'saveOnboardingData must await the user write');

      // Complete the writes in order; saveOnboardingData should now resolve.
      userRepo.writeCompleter.complete();
      configRepo.anonCompleter.complete();
      configRepo.imperialCompleter.complete();
      await saveFuture;
      expect(resolved, isTrue);
    });
  });
}
