import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/dbo/user_dbo.dart';

class UserDataSource {
  static const _userKey = "UserKey";
  final log = Logger('UserDataSource');
  final Box<UserDBO> _userBox;

  UserDataSource(this._userBox);

  Future<void> saveUserData(UserDBO userDBO) async {
    log.fine('Updating user in db');
    await _userBox.put(_userKey, userDBO);
  }

  Future<bool> hasUserData() async => _userBox.containsKey(_userKey);

  Future<UserDBO> getUserData() async {
    final user = _userBox.get(_userKey);
    if (user == null) {
      throw StateError(
        'UserDataSource.getUserData() called before user was saved — '
        'check hasUserData() first or ensure onboarding has completed.',
      );
    }
    return user;
  }
}
