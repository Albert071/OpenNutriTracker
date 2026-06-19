import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:opennutritracker/core/data/data_source/custom_meal_data_source.dart';
import 'package:opennutritracker/core/data/repository/custom_activity_template_repository.dart';
import 'package:opennutritracker/core/data/repository/intake_repository.dart';
import 'package:opennutritracker/core/data/repository/recipe_repository.dart';
import 'package:opennutritracker/core/data/repository/tracked_day_repository.dart';
import 'package:opennutritracker/core/data/repository/user_activity_repository.dart';
import 'package:opennutritracker/core/data/repository/weight_log_repository.dart';
import 'package:opennutritracker/core/utils/csv_data_exporter.dart';
import 'package:opennutritracker/core/utils/user_image_storage.dart';

const _defaultActivityJson = 'user_activity.json';
const _defaultIntakeJson = 'user_intake.json';
const _defaultTrackedDayJson = 'user_tracked_day.json';
const _defaultRecipeJson = 'user_recipes.json';
const _defaultWeightLogJson = 'weight_log.json';
const _defaultTemplatesJson = 'custom_activity_templates.json';

/// The two export shapes available from Settings → Export / Import App Data.
/// JSON is the canonical backup-and-restore format the app re-imports from;
/// CSV is a one-way spreadsheet-friendly view for analysis / sharing.
enum ExportFormat { json, csv }

class ExportDataUsecase {
  final UserActivityRepository _userActivityRepository;
  final IntakeRepository _intakeRepository;
  final TrackedDayRepository _trackedDayRepository;
  final RecipeRepository _recipeRepository;
  final CustomMealDataSource _customMealDataSource;
  final WeightLogRepository _weightLogRepository;
  final CustomActivityTemplateRepository _customActivityTemplateRepository;

  ExportDataUsecase(
    this._userActivityRepository,
    this._intakeRepository,
    this._trackedDayRepository,
    this._recipeRepository,
    this._customMealDataSource,
    this._weightLogRepository,
    this._customActivityTemplateRepository,
  );

  /// Exports all data to a zip at a user-specified location (interactive).
  Future<bool> exportData(
    String exportZipFileName,
    String userActivityJsonFileName,
    String userIntakeJsonFileName,
    String trackedDayJsonFileName,
    String recipeJsonFileName,
    String weightLogJsonFileName,
    String customActivityTemplateJsonFileName, {
    ExportFormat format = ExportFormat.json,
    String userActivityCsvFileName = 'user_activity.csv',
    String userIntakeCsvFileName = 'user_intake.csv',
    String trackedDayCsvFileName = 'user_tracked_day.csv',
  }) async {
    final zipBytes = await _buildArchiveBytes(
      userActivityJsonFileName: userActivityJsonFileName,
      userIntakeJsonFileName: userIntakeJsonFileName,
      trackedDayJsonFileName: trackedDayJsonFileName,
      recipeJsonFileName: recipeJsonFileName,
      weightLogJsonFileName: weightLogJsonFileName,
      customActivityTemplateJsonFileName: customActivityTemplateJsonFileName,
      format: format,
      userActivityCsvFileName: userActivityCsvFileName,
      userIntakeCsvFileName: userIntakeCsvFileName,
      trackedDayCsvFileName: trackedDayCsvFileName,
    );

    final result = await FilePicker.saveFile(
      fileName: exportZipFileName,
      type: FileType.custom,
      allowedExtensions: ['zip'],
      bytes: Uint8List.fromList(zipBytes),
    );

    return result != null && result.isNotEmpty;
  }

  /// Returns the JSON export zip as raw bytes — used by the background Drive
  /// upload job so no file picker dialog is shown.
  Future<Uint8List> exportDataAsBytes() async {
    final bytes = await _buildArchiveBytes(
      userActivityJsonFileName: _defaultActivityJson,
      userIntakeJsonFileName: _defaultIntakeJson,
      trackedDayJsonFileName: _defaultTrackedDayJson,
      recipeJsonFileName: _defaultRecipeJson,
      weightLogJsonFileName: _defaultWeightLogJson,
      customActivityTemplateJsonFileName: _defaultTemplatesJson,
    );
    return Uint8List.fromList(bytes);
  }

  Future<List<int>> _buildArchiveBytes({
    required String userActivityJsonFileName,
    required String userIntakeJsonFileName,
    required String trackedDayJsonFileName,
    required String recipeJsonFileName,
    required String weightLogJsonFileName,
    required String customActivityTemplateJsonFileName,
    ExportFormat format = ExportFormat.json,
    String userActivityCsvFileName = 'user_activity.csv',
    String userIntakeCsvFileName = 'user_intake.csv',
    String trackedDayCsvFileName = 'user_tracked_day.csv',
  }) async {
    final archive = Archive();

    // Activity dataset
    final fullUserActivity =
        await _userActivityRepository.getAllUserActivityDBO();
    if (format == ExportFormat.json) {
      final bytes = utf8.encode(jsonEncode(
        fullUserActivity.map((a) => a.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(userActivityJsonFileName, bytes.length, bytes),
      );
    } else {
      final bytes = utf8.encode(
        CsvDataExporter.userActivitiesToCsv(fullUserActivity),
      );
      archive.addFile(
        ArchiveFile(userActivityCsvFileName, bytes.length, bytes),
      );
    }

    // Intake dataset
    final fullIntake = await _intakeRepository.getAllIntakesDBO();
    if (format == ExportFormat.json) {
      final bytes = utf8.encode(jsonEncode(
        fullIntake.map((i) => i.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(userIntakeJsonFileName, bytes.length, bytes),
      );
    } else {
      final bytes = utf8.encode(CsvDataExporter.intakesToCsv(fullIntake));
      archive.addFile(
        ArchiveFile(userIntakeCsvFileName, bytes.length, bytes),
      );
    }

    // Tracked day dataset
    final fullTrackedDay = await _trackedDayRepository.getAllTrackedDaysDBO();
    if (format == ExportFormat.json) {
      final bytes = utf8.encode(jsonEncode(
        fullTrackedDay.map((d) => d.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(trackedDayJsonFileName, bytes.length, bytes),
      );
    } else {
      final bytes = utf8.encode(
        CsvDataExporter.trackedDaysToCsv(fullTrackedDay),
      );
      archive.addFile(
        ArchiveFile(trackedDayCsvFileName, bytes.length, bytes),
      );
    }

    // Recipes, photos, weight log and Custom activity templates — JSON only.
    if (format == ExportFormat.json) {
      final fullRecipes = _recipeRepository.getAllRecipesDBO();
      final recipeBytes = utf8.encode(jsonEncode(
        fullRecipes.map((r) => r.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(recipeJsonFileName, recipeBytes.length, recipeBytes),
      );

      for (final recipe in fullRecipes) {
        await _addUserImageIfPresent(archive, recipe.imagePath);
      }

      final customMeals = _customMealDataSource.getAllCustomMeals();
      for (final meal in customMeals) {
        await _addUserImageIfPresent(archive, meal.localImagePath);
      }

      final fullWeightLog = await _weightLogRepository.getAllEntriesDBO();
      final weightLogBytes = utf8.encode(jsonEncode(
        fullWeightLog.map((entry) => entry.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(
          weightLogJsonFileName,
          weightLogBytes.length,
          weightLogBytes,
        ),
      );

      final fullTemplates =
          await _customActivityTemplateRepository.allTemplateDBOs();
      final templatesBytes = utf8.encode(jsonEncode(
        fullTemplates.map((template) => template.toJson()).toList(),
      ));
      archive.addFile(
        ArchiveFile(
          customActivityTemplateJsonFileName,
          templatesBytes.length,
          templatesBytes,
        ),
      );
    }

    return ZipEncoder().encode(archive);
  }

  Future<void> _addUserImageIfPresent(
    Archive archive,
    String? relativePath,
  ) async {
    if (relativePath == null) return;
    final sanitized = UserImageStorage.sanitizeRelative(relativePath);
    if (sanitized == null) return;
    final absolute = await UserImageStorage.absolutePath(sanitized);
    final file = File(absolute);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    archive.addFile(ArchiveFile(sanitized, bytes.length, bytes));
  }
}
