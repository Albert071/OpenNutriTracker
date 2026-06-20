import 'package:flutter/material.dart';
import 'package:opennutritracker/core/services/background_export_service.dart';
import 'package:opennutritracker/core/services/gcs_upload_service.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:workmanager/workmanager.dart';

const _exportObjectName = 'opennutritracker-export.zip';

class AutoExportDialog extends StatefulWidget {
  const AutoExportDialog({super.key});

  @override
  State<AutoExportDialog> createState() => _AutoExportDialogState();
}

class _AutoExportDialogState extends State<AutoExportDialog> {
  final _keyController = TextEditingController();
  final _bucketController = TextEditingController();
  bool _hasKey = false;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _testResult;
  String? _currentBucket;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final hasKey = await GcsUploadService.hasServiceAccountKey();
    final bucket = await GcsUploadService.loadBucketName();
    if (mounted) {
      setState(() {
        _hasKey = hasKey;
        _currentBucket = bucket;
      });
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _bucketController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final json = _keyController.text.trim();
    final bucket = _bucketController.text.trim();
    if (json.isEmpty) {
      setState(() => _error = 'Paste the service account JSON key first.');
      return;
    }
    if (bucket.isEmpty) {
      setState(() => _error = 'Enter the GCS bucket name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await GcsUploadService.saveServiceAccountKey(json);
      await GcsUploadService.saveBucketName(bucket);
      await Workmanager().registerPeriodicTask(
        driveExportUniqueTaskName,
        driveExportTaskName,
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(minutes: 5),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
      if (mounted) {
        setState(() {
          _hasKey = true;
          _currentBucket = bucket;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disable() async {
    await Workmanager().cancelByUniqueName(driveExportUniqueTaskName);
    await GcsUploadService.deleteServiceAccountKey();
    await GcsUploadService.deleteBucketName();
    if (mounted) setState(() => _hasKey = false);
  }

  Future<void> _testNow() async {
    final bucket = _currentBucket;
    if (bucket == null) {
      setState(() => _error = 'No bucket name saved.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _error = null;
    });
    try {
      final zipBytes = await locator<ExportDataUsecase>().exportDataAsBytes();
      await GcsUploadService().uploadFile(
        fileBytes: zipBytes,
        objectName: _exportObjectName,
        bucketName: bucket,
      );
      if (mounted) {
        setState(() => _testResult = 'Upload successful! Check your GCS bucket.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Auto-export to Cloud Storage'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hasKey) ...[
              Row(
                children: [
                  Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Daily export enabled.\nBucket: ${_currentBucket ?? "—"}',
                    ),
                  ),
                ],
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 8),
                Text(
                  _testResult!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 12),
                ),
              ],
            ] else ...[
              const Text(
                'Paste the service account JSON key and the GCS bucket name '
                'where exports should be uploaded.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Service account JSON key',
                  hintText: '{ "type": "service_account", ... }',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bucketController,
                maxLines: 1,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'GCS bucket name',
                  hintText: 'icarus-nutrition-exports',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_hasKey) ...[
          TextButton(
            onPressed: _testing ? null : _testNow,
            child: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Export now'),
          ),
          TextButton(
            onPressed: _disable,
            child: Text(
              'Disable',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ] else
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Enable'),
          ),
      ],
    );
  }
}
