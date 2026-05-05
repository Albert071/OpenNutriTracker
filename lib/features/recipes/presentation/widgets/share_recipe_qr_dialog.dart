import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opennutritracker/core/domain/entity/recipe_entity.dart';
import 'package:opennutritracker/features/recipes/domain/entity/shared_recipe_payload.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class ShareRecipeQrDialog extends StatefulWidget {
  final RecipeEntity recipe;

  const ShareRecipeQrDialog({super.key, required this.recipe});

  @override
  State<ShareRecipeQrDialog> createState() => _ShareRecipeQrDialogState();
}

class _ShareRecipeQrDialogState extends State<ShareRecipeQrDialog> {
  static const int _errorCorrectionLevel = QrErrorCorrectLevel.M;
  static const int _quietZoneModules = 3;

  late final String _code;

  @override
  void initState() {
    super.initState();
    _code = SharedRecipePayload.fromRecipe(widget.recipe).toJsonString();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).shareRecipeLabel),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 260,
              height: 260,
              child: QrImageView(
                data: _code,
                version: QrVersions.auto,
                errorCorrectionLevel: _errorCorrectionLevel,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.all(16.0),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(S.of(context).copyCodeLabel),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(S.of(context).codeCopiedLabel)),
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.share, size: 18),
                  label: Text(S.of(context).shareCodeLabel),
                  onPressed: () => _share(context),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.of(context).dialogOKLabel),
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context) async {
    try {
      final qrBytes = await _renderQrToImage(_code);
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/recipe_qr.png');
      await file.writeAsBytes(qrBytes);
      await Share.shareXFiles([XFile(file.path)], text: _code);
    } catch (_) {
      await Share.share(_code);
    }
  }

  Future<List<int>> _renderQrToImage(String data) async {
    const size = 512.0;
    final validation = QrValidator.validate(
      data: data,
      version: QrVersions.auto,
      errorCorrectionLevel: _errorCorrectionLevel,
    );
    final qrCode = validation.qrCode!;
    final margin = _quietZoneModules * size / qrCode.moduleCount;
    final contentSize = size - 2 * margin;
    final painter = QrPainter.withQr(
      qr: qrCode,
      eyeStyle: const QrEyeStyle(
          color: Color(0xFF000000), eyeShape: QrEyeShape.square),
      dataModuleStyle: const QrDataModuleStyle(
          color: Color(0xFF000000), dataModuleShape: QrDataModuleShape.square),
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, size, size),
      ui.Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.save();
    canvas.translate(margin, margin);
    painter.paint(canvas, Size(contentSize, contentSize));
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }
}
