import 'package:flutter/material.dart';
import 'package:opennutritracker/core/services/background_export_service.dart';
import 'package:opennutritracker/core/services/drive_upload_service.dart';
import 'package:workmanager/workmanager.dart';

class AutoExportDialog extends StatefulWidget {
  const AutoExportDialog({super.key});

  @override
  State<AutoExportDialog> createState() => _AutoExportDialogState();
}

class _AutoExportDialogState extends State<AutoExportDialog> {
  final _keyController = TextEditingController();
  bool _hasKey = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DriveUploadService.hasServiceAccountKey().then((v) {
      if (mounted) setState(() => _hasKey = v);
    });
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final json = _keyController.text.trim();
    if (json.isEmpty) {
      setState(() => _error = 'Paste the service account JSON key first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await DriveUploadService.saveServiceAccountKey(json);
      await Workmanager().registerPeriodicTask(
        driveExportUniqueTaskName,
        driveExportTaskName,
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(minutes: 5),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
      if (mounted) setState(() => _hasKey = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to save key: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disable() async {
    await Workmanager().cancelByUniqueName(driveExportUniqueTaskName);
    await DriveUploadService.deleteServiceAccountKey();
    if (mounted) setState(() => _hasKey = false);
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
                  const Expanded(
                    child: Text(
                      'Daily export enabled. Your nutrition data is uploaded to '
                      'Google Drive each night automatically.',
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Text(
                'Paste the service account JSON key below. The key is stored '
                'securely on this device and used to upload your daily export '
                'to Google Drive.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '{ "type": "service_account", ... }',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_hasKey)
          TextButton(
            onPressed: _disable,
            child: Text(
              'Disable',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          )
        else
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
