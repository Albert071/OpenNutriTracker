# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenNutriTracker is a Flutter mobile app (iOS/Android) for nutritional tracking. It uses Open Food Facts and USDA Food Data Central (via Supabase) as food databases, with all user data stored locally in an AES-encrypted Hive database.

Flutter version: **3.41.7** (managed via FVM; see `.fvmrc`)

## Commands

All common tasks are in the `justfile`:

```sh
just install       # flutter pub get
just build         # dart run build_runner build --delete-conflicting-outputs
just format        # dart format ./lib/core ./lib/features ./lib/l10n ./test
just test          # flutter test
just check_intl    # verify generated intl files are up to date (used in CI)
just ci            # full CI: install, format check, intl check, build, analyze, test
```

Run a single test file:

```sh
flutter test test/unit_test/tdee_calc_test.dart
```

Run static analysis:

```sh
flutter analyze
```

## Environment Setup

Copy `.env` and fill in real values before running:

```
FDC_API_KEY="YOUR_KEY"        # USDA Food Data Central API key (direct FDC source, not actively used in UI)
SENTRY_DNS="DNS_URL"
SUPABASE_PROJECT_URL="PROJECT_URL"
SUPABASE_PROJECT_ANON_KEY="ANON_KEY"
```

After editing `.env`, run `just build` to regenerate `lib/core/utils/env.g.dart` (gitignored). The `envied` package obfuscates all secret values at compile time.

## Code Generation

Run `just build` (i.e. `dart run build_runner build`) whenever you add or modify any of the source files listed below. Every generated file starts with `// GENERATED CODE - DO NOT MODIFY BY HAND` or an equivalent header — never edit them directly.

If `build_runner` fails with `PackageNotFoundException: hive` after pulling from an older checkout, the build cache is stale from the pre-`hive_ce` days. Fix it with:

```sh
rm -rf .dart_tool/build
dart run build_runner build
```

### What gets generated and when

| Trigger                            | Generated file(s)                                                                                         | Tool                |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------- |
| Any `@HiveType` / `@HiveField` DBO | `<dbo_file>.g.dart` alongside the source                                                                  | `hive_ce_generator` |
| Any new DBO added anywhere         | `lib/hive_registrar.g.dart` — the `HiveRegistrar` extension that calls `registerAdapter()` for every type | `hive_ce_generator` |
| Any `@JsonSerializable` DTO        | `<dto_file>.g.dart` alongside the source                                                                  | `json_serializable` |
| `.env` file edited                 | `lib/core/utils/env.g.dart` (**gitignored** — must regenerate after every clone)                          | `envied_generator`  |

**DBO files** live in `lib/core/data/dbo/` and `lib/core/data/data_source/` (one `.g.dart` per file). Whenever you add a `@HiveField` or change a field's type, regenerate — otherwise the binary reader/writer will be out of sync.

**`lib/hive_registrar.g.dart`** is checked in to version control (it has no machine-specific content). Regenerate it any time you add or remove a DBO type. The `HiveDBProvider` registers adapters by calling `Hive.registerAdapters()` which delegates to this file.

**DTO files** live under `lib/features/add_meal/data/dto/` (OFF, FDC, and Supabase FDC subfolders). Regenerate when you add or change API response fields.

**`lib/core/utils/env.g.dart`** is the only generated file that is gitignored. After a fresh clone, run `just build` with a valid `.env` file before the app will compile.

## Localization

Source strings live in `lib/l10n/intl_en.arb` (and locale ARBs for `de`, `cs`, `it`, `pl`, `tr`, `uk`, `zh`). Generated Dart files live in `lib/generated/intl/` and `lib/generated/l10n.dart`.

The generated files in `lib/generated/` are **manually maintained** — do not regenerate them with `intl_translation:generate_from_arb`, as the generator output conflicts with the project's 120-char formatting. Edit them directly when adding strings, then run `just check_intl` to verify CI passes.

Note: `SupportedLanguage` enum (used internally for Supabase FDC column selection) only handles `en` and `de`; all other locales fall back to English.

## Code Style

The project uses a **120-character line width** (configured in `analysis_options.yaml`). The `just format` command targets only `./lib/core ./lib/features ./lib/l10n ./test` — it deliberately excludes `lib/generated/`. Do not run `dart format` on `lib/generated/` files.

## Architecture

The project follows **Clean Architecture** with a feature-based module structure.

### App startup sequence

`main()` → `initLocator()` → Hive DB init (AES key from `flutter_secure_storage`) → Supabase init → check `UserDataSource.hasUserData()` → route to `onboarding` (first run) or `main` (returning user). Sentry is only enabled in **release mode** and only if the user consented to anonymous data collection during onboarding.

### Directory structure

```
lib/
  core/           # Shared across all features
    data/
      data_source/  # Hive box wrappers (local DB access)
      dbo/          # Hive-annotated database objects (suffixed DBO)
      repository/   # Core repositories (user, intake, config, etc.)
    domain/
      entity/       # Plain domain models (suffixed Entity)
      usecase/      # Business logic operations
    presentation/
      main_screen.dart  # Bottom nav shell (Home / Diary / Profile)
      widgets/          # Shared UI components
    styles/       # Color schemes, typography
    utils/        # locator.dart (DI), hive_db_provider.dart, env.dart, calc/, etc.
  features/       # One folder per screen/flow
    home/         # Dashboard with daily kcal/macro summary
    diary/        # Calendar-based food diary
    profile/      # User stats, BMI, goals
    add_meal/     # Food search (text + barcode) and meal logging
    meal_detail/  # Nutritional detail view for a food item
    edit_meal/    # Edit a logged intake entry
    scanner/      # Barcode camera scanner
    add_activity/ # Log physical activity
    activity_detail/ # View logged activity
    settings/     # App settings, data export/import
    onboarding/   # First-run user setup flow
  generated/      # Intl files — maintained manually (see Localization above)
  l10n/           # Source ARB translation files
```

Each feature follows the same three-layer structure:

- `data/` — DTOs and remote/local data sources
- `domain/` — feature-specific entities and use cases
- `presentation/` — BLoC + screen widgets

### Navigation

Named routes are defined in `NavigationOptions` and registered in `main.dart`. The three main tabs (Home / Diary / Profile) share a single `MainScreen` shell with `NavigationBar`; all other screens are pushed onto the route stack.

### State management

**flutter_bloc** is used throughout. Every screen has a corresponding `*Bloc` with `*Event` and `*State` files.

### Dependency injection

**GetIt** is the service locator. All registrations happen in `lib/core/utils/locator.dart` (`initLocator()`), called once at startup. Registration order matters — data sources first, then repositories, then use cases, then BLoCs.

- **`registerLazySingleton`** — screen-persistent BLoCs (Home, Diary, CalendarDay, Profile, Settings, Onboarding). `HomeBloc` and `DiaryBloc` cross-reference each other via the locator at runtime.
- **`registerFactory`** — per-navigation BLoCs (MealDetail, Scanner, EditMeal, AddMeal, Products, Food, Activities, ActivityDetail, ExportImport). A fresh instance is created each navigation.

### Local database

**hive_ce** (the actively maintained community fork of Hive) is used for all persistent local storage, AES-256 encrypted. The five boxes opened by `HiveDBProvider`:

| Box               | DBO type          | Purpose                                                         |
| ----------------- | ----------------- | --------------------------------------------------------------- |
| `ConfigBox`       | `ConfigDBO`       | App settings: theme, units, kcal adjustment, per-macro % goals  |
| `IntakeBox`       | `IntakeDBO`       | Meal log entries (links to `MealDBO`, typed by `IntakeTypeDBO`) |
| `UserActivityBox` | `UserActivityDBO` | Logged physical activities                                      |
| `UserBox`         | `UserDBO`         | User profile: height, weight, birthday, gender, PAL, goal       |
| `TrackedDayBox`   | `TrackedDayDBO`   | Per-day calorie/macro running totals for diary calendar         |

When adding a new `@HiveType`, assign a unique `typeId`. Check all existing DBOs to avoid collisions — IDs are currently scattered across 0–15+.

### Food data sources

`ProductsRepository` aggregates three sources via `SearchProductsUseCase`:

| Source          | Class             | Notes                                                            |
| --------------- | ----------------- | ---------------------------------------------------------------- |
| Open Food Facts | `OFFDataSource`   | REST API — text search + barcode lookup                          |
| Supabase FDC    | `SpFdcDataSource` | Full-text search on `fdc_food` table; `en`/`de` column selection |
| USDA FDC direct | `FDCDataSource`   | Requires `FDC_API_KEY`; not actively surfaced in the UI          |

`SearchProductsUseCase.searchFDCFoodByString` uses the **Supabase** source, not the direct FDC API.

### Calorie and macro calculations

Calculation utilities live in `lib/core/utils/calc/`:

- **TDEE** — `TDEECalc.getTDEEKcalIOM2005()` (IOM 2005 gender-specific equation). A WHO 2001 formula exists but is unused.
- **Calorie goal** — TDEE + weight-goal adjustment (±500 kcal) + optional user kcal offset + today's burned activity kcal.
- **Macro defaults** — 60% carbs / 25% fat / 15% protein of total kcal goal. Per-macro overrides stored in `ConfigEntity`.
- **MET** — `MetCalc` converts MET × weight × hours to burned kcal for activities.

### Data export / import

Settings screen exports to a `.zip` containing three JSON files (user activities, intakes, tracked days). Import merges from a user-selected zip. User profile data is **not** included in the export.

## Catalog infrastructure

The offline catalog feature is backed by Cloudflare-side infrastructure managed in code at `opentofu/infrastructure/`. A weekly GitHub Actions workflow builds 16 prebuilt sqlite databases from the OpenFoodFacts CSV dump, splits each into ≤256 MiB chunks, and uploads them to a public-read R2 bucket served through `catalog.opennutritracker.org`. The Flutter client (`lib/features/offline_catalog/data/data_sources/catalog_download_data_source.dart`) downloads from that domain.

What OpenTofu manages:

- The catalog R2 bucket and its custom-domain mapping.
- A zone-level cache rule that overrides R2's missing `Cache-Control` header so responses can actually hit the edge.
- Two downstream Cloudflare API tokens (object-write on the bucket; cache-purge on the zone).
- Seven GitHub Actions secrets sealed against the repo's libsodium public key, consumed by the catalog-build workflow.

State lives in a separate private R2 bucket (`opennutritracker-tf-state`) and is encrypted at rest at the OpenTofu layer using PBKDF2 (SHA-512, 600k iterations) into AES-256-GCM. The passphrase comes from `TF_VAR_state_passphrase`, which is mirrored to the `TF_VAR_STATE_PASSPHRASE` GitHub Actions secret and to the gitignored `opentofu/infrastructure/.env`.

The CI pipeline lives in a single workflow at `.github/workflows/build_catalog.yml`. Jobs run as `build → plan → apply_gated | apply_unattended`, with artefact passing inside the run. `apply_gated` requires the `tofu-apply` environment's reviewer and only fires for push-to-main or main-branch `workflow_dispatch`; `apply_unattended` fires for the Saturday 19:00 UTC cron on main and for any push or dispatch on `feature/offline-off-catalog` while that branch is in active development. Triggers are restricted to the two named branches, the cron, and manual dispatch — no PR runs and no other-branch runs. OpenTofu manages the catalog chunks as `aws_s3_object` resources, so a chunk whose content has not changed produces no diff and no API call.

For the full reference on the OpenTofu side (resource list, secrets matrix, bootstrap-from-scratch procedure, recovery story if the passphrase is lost, common gotchas), see [`docs/opentofu.md`](docs/opentofu.md). For the build pipeline that produces what gets uploaded into all this infrastructure (variant matrix, the chunked layout, schema versioning, the CI workflow that orchestrates it), see [`docs/catalog_build.md`](docs/catalog_build.md). For the client-side feature itself (the wizard, the bloc lifecycle, the search and scanner fallback chain, the auto-disable crash safety, forward compatibility from the client's perspective), see [`docs/offline_catalog.md`](docs/offline_catalog.md).

Local OpenTofu apply, when needed:

```sh
cd opentofu/infrastructure
set -a && source .env && set +a
~/.tenv/OpenTofu/1.11.6/tofu init
~/.tenv/OpenTofu/1.11.6/tofu apply
```

The `.env` file is gitignored and lives next to the rest of the OpenTofu config. Per-project `tenv` already pins the matching binary version on the dev box.

## Naming Conventions

| Suffix                     | Meaning                                                       |
| -------------------------- | ------------------------------------------------------------- |
| `DBO`                      | Database Object — Hive-annotated local storage model          |
| `DTO`                      | Data Transfer Object — JSON-deserialized API response model   |
| `Entity`                   | Domain model — plain Dart class used in business logic and UI |
| `Bloc` / `Event` / `State` | BLoC pattern state management files                           |
| `Usecase`                  | Single-responsibility business logic class                    |
| `Repository`               | Mediates between data sources and use cases                   |
| `DataSource`               | Direct access to one data store (Hive box or HTTP API)        |
