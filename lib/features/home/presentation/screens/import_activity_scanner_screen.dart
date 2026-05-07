import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:opennutritracker/core/domain/usecase/get_physical_activity_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_user_usecase.dart';
import 'package:opennutritracker/core/utils/calc/met_calc.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/activity_detail/presentation/bloc/activity_detail_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/calendar_day_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/diary_bloc.dart';
import 'package:opennutritracker/features/home/domain/entity/shared_activity_payload.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

class ImportActivityScannerScreen extends StatefulWidget {
  const ImportActivityScannerScreen({super.key});

  @override
  State<ImportActivityScannerScreen> createState() =>
      _ImportActivityScannerScreenState();
}

class _ImportActivityScannerScreenState
    extends State<ImportActivityScannerScreen> {
  late ActivityDetailBloc _activityDetailBloc;
  late GetPhysicalActivityUsecase _getPhysicalActivityUsecase;
  late GetUserUsecase _getUserUsecase;
  bool _isProcessing = false;

  @override
  void initState() {
    _activityDetailBloc = locator<ActivityDetailBloc>();
    _getPhysicalActivityUsecase = locator<GetPhysicalActivityUsecase>();
    _getUserUsecase = locator<GetUserUsecase>();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).importActivityLabel),
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard_outlined),
            tooltip: S.of(context).pasteCodeLabel,
            onPressed: _showPasteCodeDialog,
          ),
        ],
      ),
      body: MobileScanner(
        controller: MobileScannerController(
          formats: const [BarcodeFormat.qrCode],
        ),
        onDetect: _onDetect,
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    // Flip the flag synchronously, before any await, so a second
    // onDetect call that mobile_scanner queues up while the camera
    // still has the QR in frame can't pass the gate. The flag was
    // previously only flipped inside _processCode, leaving a brief
    // microtask window where two detections could both reach the
    // dialog.
    _isProcessing = true;
    await _processCode(raw);
  }

  Future<void> _showPasteCodeDialog() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of(ctx).pasteCodeLabel),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: S.of(ctx).pasteCodeHint,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.of(ctx).dialogCancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(S.of(ctx).importActivityLabel),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) {
      await _processCode(code);
    }
  }

  Future<void> _processCode(String raw) async {
    // Idempotent set — _onDetect flips the flag synchronously
    // before calling here, but the paste-code dialog path doesn't,
    // so this still needs to set it. The previous early-return
    // guard would short-circuit the camera path now that _onDetect
    // sets the flag, leaving the finally block unreached and the
    // flag stuck at true.
    setState(() => _isProcessing = true);

    try {
      final payload = SharedActivityPayload.fromJsonString(raw);
      if (!mounted) return;
      final confirmed = await _showConfirmDialog(payload);
      if (confirmed == true && mounted) {
        await _importItems(payload);
        _refreshPages();
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(S.of(context).importActivitySuccessLabel)),
          );
        }
      }
    } on SharedActivityParseException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).importMealErrorLabel)),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<bool?> _showConfirmDialog(SharedActivityPayload payload) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          S.of(ctx).importActivityConfirmTitle(payload.totalCount),
        ),
        content: Text(S.of(ctx).importActivityConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of(ctx).dialogCancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of(ctx).dialogOKLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _importItems(SharedActivityPayload payload) async {
    final messenger = ScaffoldMessenger.of(context);
    final user = await _getUserUsecase.getUserData();
    final allActivities =
        await _getPhysicalActivityUsecase.getAllPhysicalActivities();

    var skipped = 0;
    final today = DateTime.now();

    for (final item in payload.items) {
      final activity =
          allActivities.firstWhereOrNull((a) => a.code == item.code);
      if (activity == null) {
        skipped++;
        continue;
      }
      final burnedKcal =
          METCalc.getTotalBurnedKcal(user, activity, item.duration);
      _activityDetailBloc.persistActivity(
        item.duration.toString(),
        burnedKcal,
        activity,
        today,
      );
    }

    if (skipped > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('$skipped activity/activities could not be imported.'),
        ),
      );
    }
  }

  void _refreshPages() {
    locator<HomeBloc>().add(const LoadItemsEvent());
    locator<DiaryBloc>().add(const LoadDiaryYearEvent());
    locator<CalendarDayBloc>().add(RefreshCalendarDayEvent());
  }
}
