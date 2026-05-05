import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:opennutritracker/core/domain/usecase/save_recipe_usecase.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/recipes/domain/entity/shared_recipe_payload.dart';
import 'package:opennutritracker/features/recipes/presentation/bloc/recipes_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

class ImportRecipeScannerScreen extends StatefulWidget {
  const ImportRecipeScannerScreen({super.key});

  @override
  State<ImportRecipeScannerScreen> createState() =>
      _ImportRecipeScannerScreenState();
}

class _ImportRecipeScannerScreenState extends State<ImportRecipeScannerScreen> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).importRecipeLabel),
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
            child: Text(S.of(ctx).importRecipeLabel),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) {
      await _processCode(code);
    }
  }

  Future<void> _processCode(String raw) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final payload = SharedRecipePayload.fromJsonString(raw);
      if (!mounted) return;
      final confirmed = await _showConfirmDialog(payload);
      if (confirmed == true && mounted) {
        await locator<SaveRecipeUseCase>().save(payload.toRecipeEntity());
        locator<RecipesBloc>().add(const LoadRecipesEvent());
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).importRecipeSuccessLabel)),
          );
        }
      }
    } on SharedRecipeParseException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).importRecipeErrorLabel)),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<bool?> _showConfirmDialog(SharedRecipePayload payload) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(payload.name),
        content: Text(
          S.of(ctx).importRecipeConfirmContent(payload.ingredients.length),
        ),
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
}
