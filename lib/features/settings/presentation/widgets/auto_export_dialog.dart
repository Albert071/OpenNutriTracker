import 'package:flutter/material.dart';
import 'package:opennutritracker/core/services/background_export_service.dart';
import 'package:opennutritracker/core/services/drive_upload_service.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:workmanager/workmanager.dart';

const _exportFileName = 'opennutritracker-export.zip';

class AutoExportDialog extends StatefulWidget {
  const AutoExportDialog({super.key});

  @override
  State<AutoExportDialog> createState() => _AutoExportDialogState();
}

class _AutoExportDialogState extends State<AutoExportDialog> {
  final _keyController = TextEditingController();
  final _folderController = TextEditingController();
  bool _hasKey = false;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _testResult;
  String? _currentFolderId;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final hasKey = await DriveUploadService.hasServiceAccountKey();
    final folderId = await DriveUploadService.loadFolderId();
    if (mounted) {
      setState(() {
        _hasKey = hasKey;
        _currentFolderId = folderId;
      });
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final json = _keyController.text.trim();
    final folderId = _folderController.text.trim();
    if (json.isEmpty) {
      setState(() => _error = 'Paste the service account JSON key first.');
      return;
    }
    if (folderId.isEmpty) {
      setState(() => _error = 'Enter the Shared Drive folder ID.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await DriveUploadService.saveServiceAccountKey(json);
      await DriveUploadService.saveFolderId(folderId);
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
          _currentFolderId = folderId;
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
    await DriveUploadService.deleteServiceAccountKey();
    await DriveUploadService.deleteFolderId();
    if (mounted) setState(() => _hasKey = false);
  }

  Future<void> _testNow() async {
    final folderId = _currentFolderId;
    if (folderId == null) {
      setState(() => _error = 'No folder ID saved.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _error = null;
    });
    try {
      final zipBytes = await locator<ExportDataUsecase>().exportDataAsBytes();
      await DriveUploadService().uploadFile(
        fileBytes: zipBytes,
        fileName: _exportFileName,
        driveFolderId: folderId,
      );
      if (mounted) {
        setState(() => _testResult = 'Upload successful! Check your Drive folder.');
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
      title: const Text('Auto-export to Drive'),
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
                      'Daily export enabled.\nFolder: ${_currentFolderId ?? "—"}',
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
                'Paste the service account JSON key and your Shared Drive '
                'folder ID below.',
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
                controller: _folderController,
                maxLines: 1,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Shared Drive folder ID',
                  hintText: 'e.g. 1ABC123xyz...',
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
