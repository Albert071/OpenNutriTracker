import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/services/drive_upload_service.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:workmanager/workmanager.dart';

const driveExportTaskName = 'driveExport';
const driveExportUniqueTaskName = 'ont-drive-export';

const _exportFileName = 'opennutritracker-export.zip';

final _log = Logger('BackgroundExportService');

// Must be a top-level function — WorkManager starts a fresh isolate.
@pragma('vm:entry-point')
void backgroundExportCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != driveExportTaskName) return Future.value(true);

    try {
      WidgetsFlutterBinding.ensureInitialized();
      // Re-init the GetIt locator — fresh isolate has no state.
      await initLocator();

      final folderId = await DriveUploadService.loadFolderId();
      if (folderId == null) {
        _log.warning('No Drive folder ID configured — skipping export');
        return Future.value(true);
      }

      final exportUsecase = locator<ExportDataUsecase>();
      final zipBytes = await exportUsecase.exportDataAsBytes();

      final uploadService = DriveUploadService();
      await uploadService.uploadFile(
        fileBytes: zipBytes,
        fileName: _exportFileName,
        driveFolderId: folderId,
      );

      _log.info('Background Drive export completed successfully');
      return Future.value(true);
    } catch (e, stack) {
      _log.severe('Background Drive export failed', e, stack);
      return Future.value(false);
    }
  });
}
