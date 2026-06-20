import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/services/gcs_upload_service.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/settings/domain/usecase/export_data_usecase.dart';
import 'package:workmanager/workmanager.dart';

const driveExportTaskName = 'driveExport';
const driveExportUniqueTaskName = 'ont-drive-export';

const _exportObjectName = 'opennutritracker-export.zip';

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

      final bucket = await GcsUploadService.loadBucketName();
      if (bucket == null) {
        _log.warning('No GCS bucket configured — skipping export');
        return Future.value(true);
      }

      final exportUsecase = locator<ExportDataUsecase>();
      final zipBytes = await exportUsecase.exportDataAsBytes();

      await GcsUploadService().uploadFile(
        fileBytes: zipBytes,
        objectName: _exportObjectName,
        bucketName: bucket,
      );

      _log.info('Background GCS export completed successfully');
      return Future.value(true);
    } catch (e, stack) {
      _log.severe('Background GCS export failed', e, stack);
      return Future.value(false);
    }
  });
}
