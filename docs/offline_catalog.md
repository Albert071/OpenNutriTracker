# Offline catalog (client side)

Long-form reference for how the offline catalog feature lives inside the Flutter app. The pipeline that produces what the catalog downloads is documented in [`docs/catalog_build.md`](catalog_build.md), and the Cloudflare-side infrastructure that hosts it is documented in [`docs/opentofu.md`](opentofu.md). This file covers what happens once a user opens the wizard, downloads a catalog, and then uses it for searches and barcode scans.

## Contents

- [What the feature gives the user](#what-the-feature-gives-the-user)
- [Architecture](#architecture)
- [The wizard](#the-wizard)
  - [Welcome](#welcome)
  - [Quality](#quality)
  - [Estimate](#estimate)
  - [Download](#download)
- [Bloc lifecycle](#bloc-lifecycle)
- [The download path](#the-download-path)
- [Using the catalog at runtime](#using-the-catalog-at-runtime)
  - [Barcode scans](#barcode-scans)
  - [Name and brand search](#name-and-brand-search)
  - [How the catalog and the live API interact](#how-the-catalog-and-the-live-api-interact)
- [Crash-safety auto-disable](#crash-safety-auto-disable)
- [Forward compatibility](#forward-compatibility)
- [The settings tile](#the-settings-tile)
- [Adding things](#adding-things)
  - [A new wizard page](#a-new-wizard-page)
  - [A new bloc state](#a-new-bloc-state)
- [Common gotchas](#common-gotchas)
- [Files](#files)

## What the feature gives the user

Open Food Facts is a fantastic dataset, but it lives behind a network call. A user standing in a supermarket with patchy reception, or on a flight, or in a rural cafe, gets no benefit from any of that data unless the app can serve it locally. The offline catalog feature exists to let the app do exactly that: download a prebuilt sqlite database of the OFF dataset (or a filtered subset of it, sized for the user's storage and patience), keep it on disk, and query it directly when a barcode scan or a name search comes in.

The user's entry point is a tile on the settings screen titled "Offline food catalog". Tapping it opens a four-page wizard that walks through choosing a quality tier, previewing the size and download time, and committing to a download. Once the catalog is on disk, every barcode scan and every search consults it before reaching for the network. Nothing else about the app's flow changes: a hit in the catalog produces the same `MealEntity` shape as a live OFF API hit, so the consumer code path downstream of the search use cases never knows the difference.

## Architecture

The feature follows the same Clean Architecture layout as the rest of the app, with one wrinkle: it is the only feature that owns its own sqlite file (everything else lives in the encrypted Hive store). The reasoning is that the catalog is public OFF data the user has already paid the bandwidth for, and there is no privacy benefit to encrypting it; the user's intake history, profile, and recipes stay in the Hive boxes, untouched.

The pieces, top to bottom:

- **`OfflineCatalogDataSource`** owns the sqlite + FTS5 file. It exposes a thin query surface (`getByCode`, `searchByText`, `count`, `sizeBytes`, `getMeta`, `setMeta`, `clear`, `close`) and an idempotent `_ensureSchema` that runs after every open. The schema-creation step uses `CREATE TABLE IF NOT EXISTS` for every table, which is the bridge that lets the same code path open both a freshly-installed prebuilt catalog (where the tables already exist) and a fresh-launch empty file (where they need to be materialised so `count()` returns zero cleanly).
- **`CatalogDownloadDataSource`** owns the network and disk-staging side: fetching manifests, parallel-chunked HTTP downloads with Range-resume, per-part and combined sha256 verification, gunzip, schema-version verification, and the atomic rename into place. See [The download path](#the-download-path) for the details.
- **`OfflineCatalogRepository`** is the orchestrator that the use cases talk to. It owns the static variant-sizing table that drives the estimate page, threads the cancellation token through the download stream, writes the post-install meta entries, and exposes search/lookup pass-throughs to the data source.
- **Six use cases** wrap the repository: `BuildCatalogUseCase`, `RefreshCatalogUseCase`, `EstimateCatalogUseCase`, `DeleteCatalogUseCase`, `GetCatalogStatsUseCase`, and `SearchOfflineCatalogUseCase`. Each one is a single-responsibility surface so the bloc can compose them without leaking repository internals.
- **`OfflineCatalogBloc`** owns the wizard's lifecycle state, the in-flight `CancellationToken`, and the throttling that keeps download progress emissions to about one per second on the UI side. The bloc is a lazy singleton: an in-flight download survives the wizard screen being popped, which means a user can navigate away to scan a barcode mid-download and come back without losing their place.
- **The wizard screen and pages** live under `presentation/`, with one widget per wizard page plus the `IntroductionScreen`-based orchestrator.

The feature plugs into the rest of the app in three places: the settings screen owns the tile that opens the wizard, `SearchProductsUseCase` and `SearchProductByBarcodeUseCase` consult the catalog when it's enabled, and the boot-time crash-safety switch in `main.dart` lives outside the feature's own files because it has to run before anything else.

The locator registers everything as lazy singletons except the bloc itself, which has the full feature dependency graph injected through its constructor:

```dart
locator.registerLazySingleton<OfflineCatalogDataSource>(...);
locator.registerLazySingleton<CatalogDownloadDataSource>(...);
locator.registerLazySingleton<OfflineCatalogRepository>(...);
// six use cases registered the same way
locator.registerLazySingleton<OfflineCatalogBloc>(() => OfflineCatalogBloc(
  // get_stats, estimate, build, refresh, delete, config_repo
));
```

## The wizard

`OfflineCatalogWizardScreen` is built on the `introduction_screen` package, the same one onboarding uses, so the visual rhythm matches the first-launch experience the user already saw. The state lives partly on the orchestrator widget (the user's filter selection, the current page index) and partly on the bloc (estimate, build progress, catalog readiness), and the orchestrator forwards filter changes into the next page through callback props.

There are four pages.

### Welcome

`WelcomeWizardPage` is a plain explanation screen. It sets the expectations the user needs to make a sensible choice on the next page: that the download takes Wi-Fi, that the screen needs to stay on for the duration, and that the catalog covers human food only (pet food, cosmetics, and other non-food categories are filtered out at the upstream pipeline level, so there is no toggle here for them). The footer is a single "Get started" button.

### Quality

`QualityWizardPage` exposes the three filter axes the user actually decides on: the well-scanned toggle, the nutrition-grade toggle, and a four-chip recency picker (3 / 5 / 10 / Any years). The defaults are `s1_n1_r5`, which is the recommended tier and the one that lands at roughly 73 MB compressed and 351 thousand rows. A user who taps Next without thinking about it gets a sensible catalog; a user who relaxes the toggles understands they are committing to a larger download.

### Estimate

`EstimateConfirmWizardPage` reads the static estimate for the user's current filter triple from the bloc and surfaces four numbers: the approximate row count, the on-disk size after install, the compressed download size, and a rough wall-clock ETA at 10 MB/s. The numbers come from a hard-coded variant-sizing table in `OfflineCatalogRepository`, populated from a real end-to-end build run, so the estimate is honest within a small drift week to week.

A Wi-Fi hint sits at the bottom of the page reminding the user that the download is paid for in cellular data otherwise. The hard-cap typed-confirmation footgun the old design used has been removed; with the new prebuilt model the largest variant is roughly 520 MB compressed, which is large but no longer the kind of "are you really sure" decision that warrants typing a confirmation phrase.

### Download

`DownloadProgressWizardPage` is the only page that mutates state. It renders one of four layouts based on the bloc's current phase: `_ActiveView` while downloading or installing, `_PausedView` when paused, `_DoneView` when ready, and `_ErrorView` when something has gone wrong. The active view shows a progress bar tied to either the download bytes or the install bytes (the bar is the same, the title and body change), with Pause and Cancel buttons during download and a Cancel button during install.

The page also holds a `wakelock_plus` lock for the duration of the active phase. Without it the OS would dim the screen and, on iOS in particular, eventually background-suspend the app while the download was in flight. The lock is released the moment the bloc leaves the active phase or the page itself is unmounted.

## Bloc lifecycle

`OfflineCatalogBloc` runs through a short list of phases that the wizard pages and the settings tile both key off:

- **`initial`** — no state has been loaded yet. The bloc emits this exactly once, before the first `LoadCatalogStatusEvent`.
- **`idle`** — no catalog on disk, no partial download. Fresh state.
- **`estimating` → `estimated`** — the user has landed on the estimate page and the bloc is computing the static estimate (or has just computed it). These transition fast; they exist mostly so the UI can render a spinner while the work happens.
- **`downloading`** — chunks are flowing from the CDN onto disk. Progress is throttled to roughly one emission per second.
- **`installing`** — chunks have all landed and are being concatenated, gunzipped, schema-checked, and atomic-renamed into place. Same progress shape, different label, no Pause button (the install phase is short and pause-mid-gunzip would not give the user a meaningful resume point).
- **`paused`** — the user tapped Pause during a download. Partial chunks stay on disk; resume picks up from where the streams left off.
- **`ready`** — a catalog is installed and `offlineCatalogEnabled` is true. Search and scanner now consult it.
- **`error`** — something failed. The state's `errorRecoverable` flag tells the UI whether to show a retry button: most errors are recoverable, but `CatalogSchemaVersionException` is not (retrying against the same major-bumped catalog would hit the same error again, so the user has to update the app to use the new version).

Pause and cancel both flip the `CancellationToken` the bloc holds for the in-flight build. The download stream completes naturally on the next chunk-loop iteration; the file system state is left in place for pause and wiped for cancel.

A subtle property of the bloc that's worth knowing about: the auxiliary handlers (`_onEstimate`, `_onLoadStatus`) check whether a lifecycle phase is already in flight before they overwrite state. Without that guard, a wizard re-entry that fires both `LoadCatalogStatusEvent` and `EstimateCatalogEvent` could clobber a paused-download state with a transient `estimating` phase, which would leave the download page showing a spinner instead of the resume CTA. The bloc test pins this contract down so the regression cannot return.

## The download path

The download is owned by `CatalogDownloadDataSource` and is documented from the build pipeline's perspective in [`docs/catalog_build.md`](catalog_build.md). The client-side shape of it, summarised: fetch the manifest first (a sub-1 KiB request that fits in a single TCP round-trip), validate `manifestVersion` and `variantId`, refuse early on a `schemaVersionMajor` higher than this client supports, and then run up to four parallel workers each fetching one chunk at a time. Per-chunk Range support lets pause and resume work at finer than whole-chunk granularity. Each chunk is verified against its sha256 from the manifest, and the combined concatenation is verified against the manifest's top-level sha256 before the gunzip step starts.

A defensive fallback handles the Cloudflare quirk where the edge can return 200-with-full-body to a Range request against an object the cache has not fully prepared. When this happens the data source detects the 200 status, truncates the partial chunk on disk, and rewrites it from byte zero. With every chunk now under 256 MiB this should rarely if ever trigger, but the fallback is in place because we found it the hard way during the original loosest-tier testing.

The schema version is checked twice: once at the manifest stage (so an unsupported major refuses the install before any chunks are downloaded, which keeps the existing on-disk catalog intact and saves the user the bandwidth) and once again on the staged sqlite right before the atomic rename (defence in depth, in case the manifest and the sqlite ever disagree).

## Using the catalog at runtime

Once a catalog is installed and `offlineCatalogEnabled` is true, every barcode scan and every name-search query reaches for it before reaching for the network. The integration sits in two use cases on the consumer side of the offline-catalog feature.

### Barcode scans

`SearchProductByBarcodeUseCase` walks through a four-step fallback chain:

1. Custom meals (user-created templates) — instant, always available, never falls through.
2. The 90-day remote-search cache (`RemoteSearchCacheDataSource`) — instant, populated by previous network hits.
3. The offline catalog (`SearchOfflineCatalogUseCase.getByBarcode`) — only consulted when `offlineCatalogEnabled` is true. A hit here is also written into the 90-day cache, so a future scan of the same product is a step-2 hit that doesn't need to open the sqlite at all.
4. The live OFF API — the network fallback that catches anything not in the catalog or the cache.

The chain is deliberate: each step is faster than the next and runs first. A user with a fresh catalog installed sees a near-instant local hit on every supermarket-staple barcode, plus a slightly-slower-but-still-no-network hit on anything they have scanned before, plus the safety net of the live API for everything else.

### Name and brand search

`SearchProductsUseCase` consults `SearchOfflineCatalogUseCase.searchByText` when the catalog is enabled, before the live OFF API is asked. The query goes to FTS5 over the four name columns plus brands, with `unicode61` and `remove_diacritics 2` so a search for "creme brulee" matches the canonical "crème brûlée" rows; results are ranked by FTS5's BM25-like scoring and limited to 50 per query. The results merge into the consumer's view in the same `MealEntity` shape as live API results.

### How the catalog and the live API interact

The two are complementary, not substitutes. The catalog covers the bulk of supermarket-staple products at the chosen quality tier, refreshed weekly; the live API covers the long tail of newer or stricter-quality products that the user's variant chose to drop. A user with a strict catalog (`s1_n1_r5`, the default) will hit the catalog for the well-known stuff and fall through to the live API for the recently-added or edge-case items. A user with the loosest catalog (`s0_n0_rany`) will hit the catalog for almost everything.

The settings toggle to enable or disable the catalog is independent of whether one is downloaded: a user can install a catalog, decide they prefer the live-API-only experience, and switch the toggle off without deleting the data. The next toggle-on resumes serving from the same on-disk file.

## Crash-safety auto-disable

The catalog code path is large, the data shape it reads is generated upstream rather than written on-device, and the cost of a malformed row crashing the app on every launch is high. To keep that cost bounded, the app implements a two-step crash-safety switch around the catalog.

The first half lives at boot in `main.dart`. Before the app starts rendering anything the boot sequence increments a `consecutive_crashes` counter persisted in the config Hive box, presuming the launch is going to crash until proven otherwise. If the counter was already two or more before this increment, the boot disables the catalog (`offlineCatalogEnabled = false`, `catalogAutoDisabled = true`) and arms a one-shot home-screen notice. Two crashes specifically catches the typical iOS "killed during init" pattern: a single crash is usually transient (an OOM during a background coalesce, a flaky platform channel), but a second consecutive one is a strong signal that something persistent is breaking us.

The second half lives on the home screen. `MainScreen`, after its first frame has rendered for a few seconds, calls `setCatalogConsecutiveCrashes(0)` to reset the counter. The app has clearly survived the launch, so the counter goes back to zero and the next boot starts the cycle fresh. We deliberately leave `catalogAutoDisabled` alone here: clearing it would silently flip the catalog back on for the user, and that is exactly the kind of decision the user should make themselves once they have read the banner.

The settings screen surfaces the auto-disabled state with a short banner above the catalog tile and a "Re-enable" button, and the home screen renders a one-shot notice the first time the user lands on it after the auto-disable trips. The notice is acknowledged via `setCatalogAutoDisableNoticeAcknowledged(true)` so it does not nag on every subsequent launch. The user's downloaded data is never deleted by this path; it stays on disk and is available again the moment the user re-enables.

## Forward compatibility

The catalog is forward-compatible with additive schema changes by design. The build pipeline writes both `schema_version` (major) and `schema_version_minor` into `catalog_meta` and into each manifest. The client refuses installs where the major is higher than what it understands (`CatalogDownloadDataSource.supportedSchemaVersion`, currently `1`); it accepts any minor at the same major. Since the client's queries name specific columns, additive changes (a new column on `products`, a new auxiliary table) appear in the file but are simply ignored.

This matters when an app version lags behind. A user who has not updated the app for a month, when the build pipeline has been bumping the minor weekly with new fields, can still download whatever the CDN currently serves and use it; their app does not understand the new fields, but neither does it crash on them. A major bump, by contrast, is a signal that the schema has genuinely changed shape and the client must update before it can read what's on the CDN. The app refuses the install, surfaces a non-recoverable error in the wizard, and leaves the existing on-disk catalog (if any) untouched so the user keeps using yesterday's data on their old app version until they update.

## The settings tile

`_OfflineCatalogTile` in `settings_screen.dart` is the user-facing entry point. Its subtitle reflects the bloc's current phase: "Not built — tap to set up" when idle, "Building NN%" while downloading or installing, "Download paused — tap to resume" when paused, or "X products, Y MB · last refreshed Z" when ready. Tapping the tile opens the wizard regardless of state, so a user who notices the tile is paused can resume from there rather than having to know about the wizard route.

When a catalog is ready, a popup-menu trailing button surfaces two actions: Refresh, which re-runs the download for the persisted variant (a fresh weekly build picks up new products), and Delete, which wipes the catalog file and flips `offlineCatalogEnabled` off. Both actions go through the bloc and use the same progress UI as a first-time install.

The auto-disabled banner sits above the tile when `catalogAutoDisabled` is true, with a Re-enable button that clears the flag, sets `offlineCatalogEnabled = true`, and resets the consecutive-crash counter. The user's data stays on disk through all of this; auto-disable is a soft pause, not a wipe.

## Adding things

### A new wizard page

The wizard lives on `OfflineCatalogWizardScreen`, which builds an `IntroductionScreen` from a list of `PageViewModel`s. To add a page, append a new `PageViewModel` to the list at the right index, give it a body widget (under `presentation/widgets/` to match the rest), and decide what page-changed event the orchestrator should fire when the user lands on it. Pages currently fire `EstimateCatalogEvent` on the estimate page and `StartCatalogBuildEvent` on the download page; new pages can add to the same `_onPageChanged` handler.

Watch the auto-jump logic: when the bloc is in a lifecycle phase (paused, downloading, installing, ready), `_onPageChanged` deliberately keeps the user on the download page rather than letting them back-navigate into the estimate page mid-flight, since a re-fired `EstimateCatalogEvent` would clobber lifecycle state. New pages need to be similarly considered.

### A new bloc state

The bloc's `OfflineCatalogPhase` enum is the source of truth for what the wizard pages and the settings tile render. Add the new phase to the enum, decide whether `_isLifecyclePhase` should treat it as a protected state (which prevents auxiliary events from overwriting it), update the wizard's `_buildBody` and the settings tile's `_subtitleFor` and `_trailingFor` to render the new phase, and update the bloc's transitions to actually emit it. The bloc test pins down a few invariants worth respecting; extend it with a case covering the new phase.

## Common gotchas

- **The catalog file is at `${ApplicationDocumentsDirectory}/offline_catalog.db`**, not in the app's encrypted Hive store. The `clear()` method removes the `.db`, the `-wal`, and the `-shm` sidecars; do not assume there is only one file to clean up. On Windows the close-then-rename ordering matters because Windows refuses to rename over an open file handle; the data source closes its handle inside `beforeInstall` for that reason.
- **`offlineCatalogEnabled` and `catalogAutoDisabled` are independent flags** on `ConfigEntity`. The auto-disable path flips both; the user re-enabling from settings flips both back. Code that reads only one of them risks a subtle wrong state during the auto-disable transition.
- **The bloc's `_isLifecyclePhase` is not `isActive`.** It includes `paused`, `ready`, and `error` because those are the states whose UI must not be disturbed by an auxiliary `LoadStatus` or `Estimate` event. Adding a new phase without thinking about whether it belongs in this set is the most likely way to break the wizard's resume-from-paused experience.
- **Search use cases gate on `getOfflineCatalogEnabled`, not on whether a catalog file exists.** A user who has downloaded a catalog and then disabled the toggle keeps the file on disk but skips the local lookup entirely. The data source's `count()` is the right check for "is there a catalog at all".
- **The wizard's lazy-singleton bloc means an in-flight download survives a screen pop.** If you ever need to add code that creates a fresh bloc (for testing, for a different entry point), be aware that the existing singleton holds the live `CancellationToken` and will keep emitting progress to anything listening.

## Files

```text
lib/features/offline_catalog/
  data/
    data_sources/
      catalog_download_data_source.dart   ← manifest + chunked download + verify + rename
      offline_catalog_data_source.dart    ← sqflite + FTS5 query surface, _ensureSchema
    repository/
      offline_catalog_repository.dart     ← orchestrator over downloader + data source
  domain/
    entity/
      cancellation_token.dart             ← cooperative cancel/pause primitive
      catalog_estimate_entity.dart        ← rows / size / requests / etaSeconds
      catalog_filter_entity.dart          ← s/n/r axes + toVariantId / fromVariantId
      catalog_stats_entity.dart           ← productCount / sizeBytes / lastSyncTime
      download_progress.dart              ← phase + bytesDone / bytesTotal / elapsed
    usecase/
      build_catalog_usecase.dart
      delete_catalog_usecase.dart
      estimate_catalog_usecase.dart
      get_catalog_stats_usecase.dart
      refresh_catalog_usecase.dart
      search_offline_catalog_usecase.dart ← consumed by add_meal + scanner search
  presentation/
    bloc/                                 ← lifecycle + cancellation + progress throttling
    widgets/
      welcome_wizard_page.dart            ← page 1
      quality_wizard_page.dart            ← page 2
      estimate_confirm_wizard_page.dart   ← page 3
      download_progress_wizard_page.dart  ← page 4 + wakelock + Pause/Cancel/Resume
    offline_catalog_wizard_screen.dart    ← IntroductionScreen orchestrator
```

```text
Integration points outside the feature:

lib/core/utils/locator.dart                                  ← DI wiring
lib/main.dart                                                ← boot-time crash-safety increment
lib/core/presentation/main_screen.dart                       ← post-launch crash counter reset
lib/core/data/repository/config_repository.dart              ← offline_catalog_enabled flag
lib/features/add_meal/domain/usecase/search_products_usecase.dart        ← name search fallback chain
lib/features/scanner/domain/usecase/search_product_by_barcode_usecase.dart ← barcode fallback chain
lib/features/settings/settings_screen.dart                   ← _OfflineCatalogTile
```
