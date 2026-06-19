import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_auth_io/google_auth_io.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

const _saKeyStorageKey = 'drive_service_account_key';

// drive.file scope: access only to files created by this app and files
// explicitly shared with the service account. Does not touch the user's
// other Drive files.
const _driveScope = drive.DriveApi.driveFileScope;

const _androidOptions = AndroidOptions(
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_CBC_PKCS7Padding,
  sharedPreferencesName: 'SharedPrefs',
);

class DriveUploadService {
  static const _storage = FlutterSecureStorage(aOptions: _androidOptions);

  static Future<void> saveServiceAccountKey(String keyJson) async {
    await _storage.write(key: _saKeyStorageKey, value: keyJson);
  }

  static Future<bool> hasServiceAccountKey() async {
    return await _storage.containsKey(key: _saKeyStorageKey);
  }

  static Future<void> deleteServiceAccountKey() async {
    await _storage.delete(key: _saKeyStorageKey);
  }

  /// Uploads [fileBytes] to [driveFolderId] as [fileName], replacing any
  /// existing file with the same name in that folder (update in place).
  /// Returns the Drive file ID on success.
  Future<String> uploadFile({
    required List<int> fileBytes,
    required String fileName,
    required String driveFolderId,
  }) async {
    final keyJson = await _storage.read(key: _saKeyStorageKey);
    if (keyJson == null) throw StateError('No service account key stored');

    final credentials = ServiceAccountCredentials.fromJson(jsonDecode(keyJson));
    final authClient = await clientViaServiceAccount(credentials, [_driveScope]);

    try {
      final driveApi = drive.DriveApi(authClient);
      final media = drive.Media(
        Stream.value(fileBytes),
        fileBytes.length,
        contentType: 'application/zip',
      );

      // Check if a file with the same name already exists in the folder so
      // we can update it in place rather than accumulating duplicates.
      final existing = await driveApi.files.list(
        q: "name = '$fileName' and '$driveFolderId' in parents and trashed = false",
        spaces: 'drive',
        $fields: 'files(id)',
      );

      if (existing.files != null && existing.files!.isNotEmpty) {
        final existingId = existing.files!.first.id!;
        await driveApi.files.update(
          drive.File(),
          existingId,
          uploadMedia: media,
        );
        return existingId;
      } else {
        final newFile = drive.File()
          ..name = fileName
          ..parents = [driveFolderId];
        final created = await driveApi.files.create(
          newFile,
          uploadMedia: media,
        );
        return created.id!;
      }
    } finally {
      authClient.close();
    }
  }
}
