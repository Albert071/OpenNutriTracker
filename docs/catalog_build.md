# Catalog build

Long-form reference for the weekly pipeline that turns the OpenFoodFacts CSV dump into the chunked sqlite catalog the Flutter client downloads. The scripts live in `tools/catalog_build/`, the orchestrating workflow lives at `.github/workflows/build_catalog.yml`, and the Cloudflare side it uploads into is documented separately in [`docs/opentofu.md`](opentofu.md). This file is the one to read when you want to understand what the pipeline does, why it makes the choices it does, and how to extend or change it.

## Contents

- [Overview](#overview)
- [The variant matrix](#the-variant-matrix)
- [Pipeline stages](#pipeline-stages)
  - [1. Download the OFF CSV dump](#1-download-the-off-csv-dump)
  - [2. Trim into 16 variants](#2-trim-into-16-variants)
    - [What's dropped from OFF, including in the loosest tier](#whats-dropped-from-off-including-in-the-loosest-tier)
  - [3. Build sqlite](#3-build-sqlite)
  - [4. Split into chunks and write the manifest](#4-split-into-chunks-and-write-the-manifest)
  - [5. Upload, sweep, purge](#5-upload-sweep-purge)
- [The chunked layout](#the-chunked-layout)
- [Schema versioning](#schema-versioning)
- [Disk and upload ceilings](#disk-and-upload-ceilings)
- [The CI workflow](#the-ci-workflow)
- [Running it locally](#running-it-locally)
- [Adding things](#adding-things)
  - [Bringing a dropped OFF field into the catalog](#bringing-a-dropped-off-field-into-the-catalog)
  - [A new variant axis](#a-new-variant-axis)
- [Common gotchas](#common-gotchas)
- [Re-chunking what's already on R2](#re-chunking-whats-already-on-r2)
- [Files](#files)

## Overview

Every Saturday evening (and on demand via `workflow_dispatch`) a chained workflow rebuilds the offline catalog from scratch. The pipeline pulls the latest OFF dump, applies the always-on filters, slices the result into the 16 wizard-filter variants, builds a sqlite + FTS5 file for each, splits each compressed file into chunks under a 256 MiB cap, and uploads the chunks plus a per-variant manifest to a public-read Cloudflare R2 bucket served through `catalog.opennutritracker.org`. Once everything is up, it asks the Cloudflare edge to invalidate the new URLs so users start hitting the fresh catalog right away.

```text
  OFF CSV dump (1.2 GB gzipped)
            │
            ▼
  trim_variants.py   ──► 16 trimmed CSVs    (one per s × n × r combo)
            │
            ▼  (per variant, sequential to keep peak disk down)
  build_sqlite.py    ──► variant.db        (sqlite + FTS5 + catalog_meta)
            │
       pigz -6 ──► variant.db.gz
            │
            ▼
  split_to_chunks.py ──► variant.db.gz.part-NN
                        variant.manifest.json
            │
            ▼
  upload_to_r2.py    ──► R2 bucket (chunks + manifests)
                       ──► sweep stale objects
                       ──► purge edge cache for new URLs
```

A successful tofu apply is the gate for this workflow: the catalog only gets rebuilt and uploaded into infrastructure that has just been reconciled with the OpenTofu config.

## The variant matrix

The wizard exposes three filter axes to the user, and the build pipeline pre-computes one catalog file per combination so the client can pick a tier based on how much storage and how strict a quality bar the user wants. The axes are:

- `s` ∈ {0, 1}, the well-scanned filter. `1` requires `unique_scans_n >= 2` on the row, which throws away one-off submissions; `0` keeps everything that passes the always-on filters.
- `n` ∈ {0, 1}, the nutrition-grade filter. `1` requires `nutriscore_grade` to be one of `a..e`; `0` keeps rows that have no grade at all.
- `r` ∈ {3, 5, 10, any}, the recency cutoff in years on `last_modified_t`. `any` is "no recency filter".

Two by two by four gives 16 variants, each named `s{0|1}_n{0|1}_r{3|5|10|any}` and each represented as one `.manifest.json` plus N chunk files in R2. The smallest tier (`s1_n1_r5`, the recommended default) is around 350 thousand rows and 73 MiB compressed. The loosest (`s0_n0_rany`) is around 3.2 million rows and 520 MiB compressed; that one splits into three chunks.

The always-on filters apply to every variant before any axis is consulted: rows marked `obsolete`, rows with `completeness < 0.3`, and rows tagged with `en:pet-food`, `en:cosmetics`, or `en:non-food-products` are dropped at the trim step. Those filters codify what "the offline catalog is human food the user might actually scan" means for this app.

## Pipeline stages

The orchestrator is `tools/catalog_build/build_catalog.sh`, which wraps each stage in a GitHub Actions `::group::` block so the workflow log collapses cleanly, and has each Python helper append markdown to `$GITHUB_STEP_SUMMARY` so the run page surfaces row counts and sizes at a glance.

### 1. Download the OFF CSV dump

The orchestrator pulls `https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz` (around 1.2 GB compressed) into `$WORK/openfoodfacts.csv.gz`, skipping the download if the file is already present and non-empty. There is no checksum gate here; OFF does not publish one for the dump, and a partial download would surface as a CSV parse error in the next stage.

### 2. Trim into 16 variants

`trim_variants.py` opens the CSV through `pigz -dc`, reads the header to look up column indices, and walks every row exactly once. For each row it does the always-on filters first; if the row survives, it is written to every variant whose axis filters accept it. A row that passes `s1_n1_r3` (the strictest combination) gets written to all sixteen variant files, since every more permissive combination would also accept it. A row that passes only `s0_n0_rany` (the loosest) gets written only there.

The trim step keeps 44 columns out of OFF's ~200, dropping fields the catalog doesn't need (image set extras, expanded category trees, the long-form ingredients text, source-tag metadata). Each variant file gets the same set of columns plus a header row, so build_sqlite can read them with a uniform projection.

Output is one `.csv` per variant in `$WORK/trimmed/`. Total size on disk for all 16 sits around 1.8 GB.

#### What's dropped from OFF, including in the loosest tier

It is worth being explicit about this, because the question "is this field in the catalog?" comes up often and the answer is no for most of OFF's surface area. Even `s0_n0_rany`, the most expansive variant, has three layers of trimming applied to it.

The first layer is the row-level always-on filters described above. They typically drop somewhere between a third and half of the input rows, mostly to obsolete entries and stubs with too little data to be useful. Pet food, cosmetics, and other non-food categories also disappear here. None of these rows reach any variant.

The second layer is the column-level pruning of `KEEP_COLUMNS`. The 44 surviving columns cover identifiers, name and brand, sizing, the two grade fields, completeness and obsolete (used for filtering), recency and scan-count (also for filtering), four image URLs, and 24 per-100g nutriment columns. The whole rest of OFF's CSV is dropped at this stage, which means the catalog at any tier carries none of the following families:

- **Ingredients data** in any form: `ingredients_text` and its localised variants, `ingredients_tags`, `ingredients_analysis_tags`, `additives_tags`, `additives_n`. These are the largest single source of bytes in the OFF dump and the most consequential omission; the app does not use ingredient lists today, but bringing them back would noticeably grow every variant's footprint.
- **Allergens and traces**: `allergens`, `allergens_tags`, `traces`, `traces_tags`. The most user-facing absence, and a reasonable thing to revisit if the wizard ever grows allergen filtering.
- **Eco-Score and NOVA group**: `ecoscore_grade`, `ecoscore_score`, `nova_group`, `pnns_groups_1`, `pnns_groups_2`. The Nutri-Score is kept (it drives the `n` axis); the others are not.
- **Packaging, labels, origins, manufacturing places, stores**: the supply-chain metadata that OFF accumulates is dropped wholesale.
- **Per-serving nutriment columns**: only the per-100g values are kept. The client computes per-serving values on the fly from `serving_quantity` when it needs them.
- **Per-row provenance**: `creator`, `created_t`, `last_modifier`, `last_editor`, `editors_tags`, `states_tags`. None of it is needed for searching or scanning.

The third layer is field-level: of the 44 columns that survive the trim, a few are read by `trim_variants.py` to do their filtering work and then discarded by `build_sqlite.py` rather than written into the per-row JSON blob the client reads. Those discarded-after-filtering columns include `completeness`, `obsolete`, `unique_scans_n`, `nutriscore_grade` itself, and the legacy `nutrition_grades` field. The two tag lists `categories_tags` and `countries_tags` survive the trim but are also not stored on the rows, which is a small leftover from the pre-pivot model where the wizard offered a country picker; the catalog is now global, so those columns could be dropped from `KEEP_COLUMNS` to clean up the trim slightly.

The net effect is meaningful. The full OFF dump is around 1.2 GB compressed and uncompresses to roughly 9 GB of TSV. The most expansive variant after all three layers is around 3.8 GB uncompressed and 520 MB gzipped, which is roughly an order of magnitude smaller than the source. The strictest is closer to two orders of magnitude smaller. If you ever need to extend the catalog to carry one of the dropped families, see [Bringing a dropped OFF field into the catalog](#bringing-a-dropped-off-field-into-the-catalog) below.

### 3. Build sqlite

`build_sqlite.py` takes one trimmed CSV and produces one `.db`. It opens sqlite with relaxed pragmas (memory journal, `synchronous = OFF`, large cache) because peak insert speed matters more than crash durability for a build artefact, and creates four objects:

- `products` holds the rows themselves, with the full DTO serialised into a JSON blob in the `data` column. Forward-compatible field additions on the OFF side (a new nutrient, a new metadata field) flow into the JSON without a schema migration, and only fields that need to be queried, sorted, or full-text searched warrant their own column.
- `idx_products_brands` is a single index on `products.brands`, which the client uses for brand-prefix lookups.
- `products_fts` is an FTS5 virtual table over the four name columns plus `brands`, tokenised with `unicode61` and `remove_diacritics 2` so a search for "creme brulee" matches "crème brûlée".
- `catalog_meta` is a key-value table holding `schema_version`, `schema_version_minor`, and `built_at_ms`.

Rows go into `products` first, in batches of 5000, then `INSERT INTO products_fts SELECT ... FROM products` rebuilds the index in a single statement (much faster than per-row FTS work during the row loop). The orchestrator runs `pigz -6` on the resulting `.db` immediately after build_sqlite completes, so peak disk on the runner only ever holds one uncompressed sqlite file at a time. The trimmed CSV is removed too, once its `.db.gz` exists.

### 4. Split into chunks and write the manifest

`split_to_chunks.py` walks the directory of `.db.gz` files and, for each one, streams it into chunks of at most 256 MiB. Streaming keeps memory bounded to a 4 MiB read block; the per-chunk and combined sha256 hashes are accumulated as bytes flow through. Each variant produces between one chunk (most of them) and three chunks (`s0_n0_r{5,10,any}`, the only variants larger than 256 MiB), and a small JSON manifest describing them.

The original `.db.gz` is removed once the chunks are written; the directory at the end of this stage holds only manifests and chunk files. See [The chunked layout](#the-chunked-layout) for the manifest shape and the reasoning behind the 256 MiB cap.

### 5. Upload, sweep, purge

`upload_to_r2.py` is the last stage. It globs `*.manifest.json` and `*.db.gz.part-*` from the work directory, refuses the run if the total exceeds the 9.7 GiB ceiling (see [Disk and upload ceilings](#disk-and-upload-ceilings)), and uploads each file with the appropriate content type: `application/json` for manifests, `application/octet-stream` for chunks. boto3's adaptive retry mode and 64 MiB multipart threshold do the rest.

After the upload finishes, two cleanup steps follow. The sweep step lists every object under the bucket prefix and deletes anything not in this upload set; that catches stale objects from a previous build whose variant set has changed (a renamed variant, a removed one, a chunk-size change that produced a different number of parts). The cache-purge step posts the just-uploaded URLs to Cloudflare's `/zones/{zone}/purge_cache` endpoint in batches of 30, so users see the new catalog immediately rather than waiting up to a week for the 7-day edge TTL to expire on the old one.

Both cleanup steps require their own credentials. The sweep uses the same R2 token as the upload. The purge uses `CLOUDFLARE_PURGE_TOKEN`, a separate zone-scoped, purge-only token managed by OpenTofu (see `opentofu/cloudflare/tokens.tf`). If the purge env vars are not all set, the step is skipped silently with a log line, which is the right behaviour for local runs.

## The chunked layout

Each variant lives in R2 as a small JSON manifest plus N chunk files. The manifest looks like this:

```json
{
  "manifestVersion": 1,
  "variantId": "s0_n0_rany",
  "totalCompressedBytes": 544732369,
  "sha256": "066e8afa4e194bd9a5ae3747978ef70f1aea12b7cd1a59794cab8200d3976488",
  "schemaVersionMajor": 1,
  "schemaVersionMinor": 0,
  "parts": [
    { "name": "s0_n0_rany.db.gz.part-00", "bytes": 268435456, "sha256": "32a8..." },
    { "name": "s0_n0_rany.db.gz.part-01", "bytes": 268435456, "sha256": "7cb1..." },
    { "name": "s0_n0_rany.db.gz.part-02", "bytes":   7861457, "sha256": "24e7..." }
  ]
}
```

The client downloads the manifest first (a sub-1 KiB request that fits in a single TCP round-trip), validates `manifestVersion` and `variantId`, refuses early on a `schemaVersionMajor` it does not understand, and then fetches each chunk in parallel with up to four workers. As each chunk lands it gets verified against its per-part sha256, and once all parts are concatenated the combined sha256 is checked against the manifest's top-level value. The schema version inside the resulting sqlite is then checked one more time before the file is renamed into place, so there are three independent integrity gates between an upstream artefact and an installed catalog.

The 256 MiB chunk cap is not arbitrary. Cloudflare's edge cache treats Range requests against very large objects inconsistently; the first request that misses the edge can trigger a full origin pull and the edge serves a 200 with the whole body even though the origin (R2) supports 206 cleanly. Three of the loosest variants would sit right at or above the threshold where this happens, so chunking keeps every piece firmly under it. The client side has a defensive fallback for the 200-on-Range case anyway, but with the chunked layout it should rarely if ever trigger.

## Schema versioning

`build_sqlite.py` writes both `schema_version` (the major version) and `schema_version_minor` into `catalog_meta`, and `split_to_chunks.py` mirrors them into each manifest. The major version is bumped when a change renames or removes something a client query depends on; older clients refuse such a catalog at the manifest stage, before any chunks are downloaded, and keep using whatever they already have on disk. The minor version is bumped freely for additive changes (a new column on `products`, a new auxiliary table); older clients accept any minor at the same major, since their column-named queries simply ignore fields they do not know about.

The current values are `schema_version = 1` and `schema_version_minor = 0`. To bump the minor (because you have added a new column), pass `--schema-version-minor 1` (or whatever the next number is) to both `build_sqlite.py` and `split_to_chunks.py` from the orchestrator. To bump the major, pass `--schema-version 2 --schema-version-minor 0` to both, and accept that every client below the new major will refuse the new catalog until the app is updated.

## Disk and upload ceilings

The pipeline is sized to fit inside a GitHub-hosted ubuntu-latest runner's roughly 14 GB of free disk. The peak holds the OFF CSV (1.2 GB), the trimmed CSVs (around 1.8 GB total), and one variant's uncompressed `.db` (up to 3.8 GB for `s0_n0_rany`) at once, with the build_catalog workflow stripping out the pre-installed Android SDK, .NET, Haskell, and CodeQL trees first to give itself headroom. Each `.db` is gzipped and its trimmed CSV deleted as soon as build_sqlite finishes, so the runner only ever holds one uncompressed sqlite file at peak.

`upload_to_r2.py` carries a 9.7 GiB total-upload ceiling as a hard refusal: if the directory's total size exceeds it, the script logs a GitHub Actions error annotation and exits non-zero rather than committing the bandwidth. The current 16 variants come to about 3.51 GiB, so there is plenty of headroom, but the ceiling exists so a future schema mistake (an unintended column, a runaway variant matrix) cannot quietly multiply the CDN bill. Raising it should always be a deliberate code change rather than a rubber-stamp.

## The CI workflow

`.github/workflows/build_catalog.yml` is wired to start via `workflow_run` only after `Tofu apply` completes successfully on the same branch. There is no `push` or `cron` trigger directly on this workflow; the catalog build is always downstream of an apply, which means the build only happens against infrastructure that has just been reconciled with the OpenTofu config. The first guard on the job is `if: github.event.workflow_run.conclusion == 'success'`, so a failed apply does not propagate a half-broken upload.

The job runs on `ubuntu-latest` and walks through these steps:

1. Check out the repo at the commit the upstream apply ran against.
2. Free disk space by removing `/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, and `/opt/hostedtoolcache/CodeQL`. Together those buy enough room for the peak-disk profile described above.
3. Install `pigz`, which the orchestrator uses for both the OFF download decompression and the per-variant `.db` compression.
4. Set up Python 3.12 with `pip` cache keyed off `tools/catalog_build/requirements.txt`.
5. Install Python deps (just `boto3` at the moment).
6. Run `bash tools/catalog_build/build_catalog.sh`, with the seven Tofu-managed secrets piped in as environment variables.
7. Print final disk usage in `if: always()`, so failed runs still leave a usable diagnostic.

There is no explicit job timeout. GitHub's per-job 6-hour ceiling is the right backstop for the data volume here; a real run takes around 10 to 20 minutes wallclock, dominated by the OFF download and the per-variant sqlite VACUUM steps.

## Running it locally

The pipeline is just bash and Python, so it runs anywhere with `pigz` and Python 3.12 installed. The R2 upload step needs the same seven environment variables the workflow consumes; the simplest way to run a local build end-to-end is to source the gitignored `.env` from the cloudflare Tofu directory, since it carries the same values for the operator's own use:

```bash
cd /tmp && mkdir -p catalog-build-work && export WORK=$PWD/catalog-build-work
set -a && source ~/git/OpenNutriTracker/opentofu/cloudflare/.env && set +a
# Pull the catalog upload creds out of the encrypted Tofu state
# (see docs/opentofu.md for the helper script that does this).
~/git/OpenNutriTracker/tools/catalog_build/build_catalog.sh
```

If you only want the build artefacts and not the upload, run the stages by hand and stop after `split_to_chunks.py`. The `$WORK/dbs` directory will hold the manifests and chunks ready to inspect, and skipping `upload_to_r2.py` skips the sweep and the cache purge along with it.

## Adding things

### Bringing a dropped OFF field into the catalog

This is by far the most common kind of catalog extension: deciding to carry a piece of OFF data that the pipeline currently throws away. Allergens, ingredients, eco-score, NOVA group, packaging tags, anything in [What's dropped from OFF, including in the loosest tier](#whats-dropped-from-off-including-in-the-loosest-tier) is a candidate for this kind of work.

Before you start, two questions are worth answering up front, because they shape what the change looks like.

The first is what the client wants to do with the field. If the app needs to **filter, sort, or full-text search** by it, the field belongs in its own column on `products` (and possibly in the FTS5 index too). If the app just needs to **read** it for display once a row has been looked up by code or by name, the field can live inside the JSON `data` blob alongside the rest of the per-row payload. The JSON path is cheaper and simpler; reach for the column path only when a query genuinely needs it.

The second is the size impact. Some OFF fields are large enough to dominate every variant they are added to. `ingredients_text` is the most extreme example: it carries the full ingredient list as free text, which is comparable in size to all the other kept columns combined. A naive "let's also keep ingredients" change can roughly double every variant's compressed size, which would push the loosest tier over the 9.7 GiB upload ceiling on its own. Look at a sampled row from the OFF dump and estimate the contribution before committing.

Once you have those two answers, the change is mechanical.

If the field stays in the JSON `data` blob (the lightweight path):

1. Add the OFF source column to `KEEP_COLUMNS` in `tools/catalog_build/trim_variants.py` so it survives the trim. If it is not currently being read at trim time, no other trim-stage change is needed.
2. Extend `row_to_dto` in `tools/catalog_build/build_sqlite.py` to include the new key.
3. On the client side, extend `OFFProductDTO` to deserialise the new key, and (if needed) extend `MealEntity.fromOFFProduct` to surface it on the entity the rest of the app sees.
4. No schema bump is needed. Older clients silently ignore the new key; newer ones read it.

If the field becomes a real column on `products` (the queryable path):

1. Add the OFF source column to `KEEP_COLUMNS` in `tools/catalog_build/trim_variants.py`, the same as above.
2. In `tools/catalog_build/build_sqlite.py` add the column to the `products` `CREATE TABLE`, extend the `INSERT INTO products` columns and bind list, and (if the field should be searchable) add it to the FTS5 column list and the FTS rebuild `INSERT ... SELECT`. Decide whether the field goes in the JSON blob too; usually you want both, so the client's existing JSON-read path keeps working without a query.
3. Pass `--schema-version-minor N` to `build_sqlite.py` and `split_to_chunks.py` from the orchestrator, where `N` is the next minor number, since this is an additive change. Major bump only if the change renames or removes something existing clients depend on.
4. On the client side, add the matching `CREATE TABLE` (or `ALTER TABLE`) statement to `_ensureSchema` in `lib/features/offline_catalog/data/data_sources/offline_catalog_data_source.dart` so a fresh local install creates the right shape, and add whichever query method consumes the new column.
5. If the field also belongs in the JSON blob, extend `row_to_dto` and the client DTO as in the lightweight path.

After either path, run the pipeline once and watch the manifest sizes. If the loosest variant's compressed size has grown materially, recheck the 9.7 GiB ceiling and the runner's disk-headroom margin before pushing the change to main.

### A new variant axis

Adding a fourth axis (something like a country filter, or a quality tier above the current `n`) means changing the variant matrix from `2 × 2 × 4 = 16` to whatever the new shape is. The trim step in `trim_variants.py` is where the variants are enumerated and where the per-row dispatch decides which output files a row belongs to. The wizard on the client side has to expose the new axis in `CatalogFilterEntity.toVariantId`, the variant sizing table in `OfflineCatalogRepository`, and the wizard UI page.

The per-variant disk and bandwidth costs add up multiplicatively. Doubling the axes count without removing existing axes would push past the 9.7 GiB upload ceiling; budget the change carefully and probably trim some columns from `KEEP_COLUMNS` to compensate.

## Common gotchas

- **The OFF dump is republished daily, not weekly.** Re-running the workflow more than once a week is fine and gives users fresher data, but the cron only fires Saturday evening because the chained tofu apply on the same schedule rotates the catalog upload token at the same time, and rotating that token more often than weekly is more churn than the project needs.
- **`build_sqlite.py` runs with `synchronous = OFF` and `journal_mode = MEMORY`.** A power loss on the runner during a build would corrupt the in-progress `.db`, but the pipeline is restartable from the orchestrator anyway, and durability mid-build buys nothing here.
- **The trim step processes rows in a single pass.** Adding a new variant that is not strictly more or less restrictive than an existing one is fine, but it widens the per-row dispatch loop. The hot-path conditional inside `trim_variants.py` is worth reviewing if you ever add more than a couple of new axes.
- **Cache-purge errors fail the workflow.** A failed purge leaves the new catalog uploaded but invisible to most users until the 7-day TTL expires. The script returns a non-zero exit code, which surfaces as a red workflow run on the repo so the issue gets noticed rather than waiting it out silently.
- **The upload step's sweep is unforgiving.** Anything under the bucket prefix that is not in the upload set gets deleted, including any manual experiments you might have left there. If you ever want to keep a debug copy of an old catalog, put it under a different prefix.

## Re-chunking what's already on R2

`tools/catalog_build/rechunk_existing.sh` is a one-off helper that downloads the chunks currently in R2, reassembles them into monolithic `.db.gz` files, runs the chunker again, and re-uploads. The script exists to migrate the layout in place when the chunker's output shape changes (when `schemaVersionMajor` or `schemaVersionMinor` is added to the manifest, when the chunk size cap is adjusted, when a new manifest field is introduced) without paying the cost of a full rebuild from the OFF CSV.

The script needs the same R2 credentials as the upload step. Once the next weekly rebuild has run with the new chunker, the rechunk script becomes dead code and is safe to delete; it is migration scaffolding, not a tool the project needs long-term.

## Files

```text
tools/catalog_build/
  build_catalog.sh         ← orchestrator: download → trim → build → split → upload
  trim_variants.py         ← single-pass OFF CSV → 16 trimmed CSVs
  build_sqlite.py          ← one trimmed CSV → one .db (products + FTS5)
  split_to_chunks.py       ← .db.gz → chunks + manifest, ≤256 MiB cap
  upload_to_r2.py          ← upload + sweep + cache-purge, 9.7 GiB ceiling
  rechunk_existing.sh      ← one-off in-place migration helper
  requirements.txt         ← pinned Python deps (boto3)
```

```text
.github/workflows/
  build_catalog.yml        ← workflow_run-chained from tofu_apply.yml
```
