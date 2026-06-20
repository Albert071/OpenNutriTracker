import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis/storage/v1.dart' as gcs;

const _saKeyStorageKey = 'drive_service_account_key';
const _bucketStorageKey = 'gcs_bucket_name';

const _androidOptions = AndroidOptions(
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_CBC_PKCS7Padding,
  sharedPreferencesName: 'SharedPrefs',
);

class GcsUploadService {
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

  static Future<void> saveBucketName(String bucket) async {
    await _storage.write(key: _bucketStorageKey, value: bucket);
  }

  static Future<String?> loadBucketName() async {
    return await _storage.read(key: _bucketStorageKey);
  }

  static Future<void> deleteBucketName() async {
    await _storage.delete(key: _bucketStorageKey);
  }

  /// Uploads [fileBytes] to GCS [bucketName] as [objectName], replacing any
  /// existing object with the same name.
  Future<void> uploadFile({
    required List<int> fileBytes,
    required String objectName,
    required String bucketName,
  }) async {
    final keyJson = await _storage.read(key: _saKeyStorageKey);
    if (keyJson == null) throw StateError('No service account key stored');

    final credentials = ServiceAccountCredentials.fromJson(jsonDecode(keyJson));
    final authClient = await clientViaServiceAccount(
      credentials,
      [gcs.StorageApi.devstorageReadWriteScope],
    );

    try {
      final storageApi = gcs.StorageApi(authClient);
      final media = gcs.Media(
        Stream.value(fileBytes),
        fileBytes.length,
        contentType: 'application/zip',
      );
      await storageApi.objects.insert(
        gcs.Object()..name = objectName,
        bucketName,
        uploadMedia: media,
      );
    } finally {
      authClient.close();
    }
  }
}
