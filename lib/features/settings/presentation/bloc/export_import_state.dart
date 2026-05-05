part of 'export_import_bloc.dart';

abstract class ExportImportState extends Equatable {
  const ExportImportState();
}

class ExportImportInitial extends ExportImportState {
  @override
  List<Object?> get props => [];
}

class ExportImportLoadingState extends ExportImportState {
  @override
  List<Object?> get props => [];
}

class ExportImportSuccess extends ExportImportState {
  @override
  List<Object?> get props => [];
}

class ExportImportError extends ExportImportState {
  @override
  List<Object?> get props => [];
}

/// CSV import finished. [imported] is the number of meals saved;
/// [skipped] is the number of rows that failed validation;
/// [anyHadBarcode] is true when at least one imported meal had a barcode
/// (used to nudge the user to contribute back to Open Food Facts).
class CsvImportResultState extends ExportImportState {
  final int imported;
  final int skipped;
  final bool anyHadBarcode;

  const CsvImportResultState({
    required this.imported,
    required this.skipped,
    required this.anyHadBarcode,
  });

  @override
  List<Object?> get props => [imported, skipped, anyHadBarcode];
}

class CsvImportErrorState extends ExportImportState {
  final String message;

  const CsvImportErrorState(this.message);

  @override
  List<Object?> get props => [message];
}

/// Result of a recipe CSV import. [imported] is the number of recipes saved;
/// [skipped] is the number of rows that failed validation.
class RecipeCsvImportResultState extends ExportImportState {
  final int imported;
  final int skipped;

  const RecipeCsvImportResultState({
    required this.imported,
    required this.skipped,
  });

  @override
  List<Object?> get props => [imported, skipped];
}
