#!/usr/bin/env bash
# Orchestrates the weekly catalog build:
#   1. Download the OFF CSV dump
#   2. Trim it into 16 wizard-filter variants (one CSV per variant)
#   3. For each variant, build the sqlite + FTS5 database, gzip it,
#      then delete the .db so peak disk on a GitHub runner stays low
#   4. Hand the final .db.gz directory to upload_to_r2.py
#
# Designed to fit inside a GitHub-hosted ubuntu-latest runner's
# ~14 GB free disk: peak usage is the OFF CSV (1.2 GB) + the trimmed
# CSVs (~1.8 GB total) + the current variant's .db (max 3.8 GB).
#
# When run inside a GitHub Actions job, each phase is wrapped in a
# `::group::` block so the workflow log collapses cleanly, and a
# markdown summary is appended to $GITHUB_STEP_SUMMARY by the
# Python helpers so the run page shows row counts + sizes at a
# glance without anyone having to read the raw log.
set -euo pipefail

WORK="${WORK:-$(pwd)/work}"
OFF_URL="https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START_TS=$(date +%s)

mkdir -p "$WORK/trimmed" "$WORK/dbs"

# Helper: GitHub Actions ::group:: wrapper that no-ops outside CI.
gh_group_start() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::group::$1"
  else
    echo "==> $1"
  fi
}
gh_group_end() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::endgroup::"
  fi
}

# Append a single line to the GH step summary if we're in CI.
gh_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

gh_summary "## Catalog build"
gh_summary ""
gh_summary "Started at \`$(date --utc +%Y-%m-%dT%H:%M:%SZ)\`."
gh_summary ""

gh_group_start "downloading OFF CSV"
if [[ ! -s "$WORK/openfoodfacts.csv.gz" ]]; then
  curl -L --fail --output "$WORK/openfoodfacts.csv.gz" "$OFF_URL"
fi
ls -lh "$WORK/openfoodfacts.csv.gz"
OFF_BYTES=$(stat -c '%s' "$WORK/openfoodfacts.csv.gz")
gh_summary "**OFF CSV dump:** $(numfmt --to=iec --suffix=B "$OFF_BYTES")"
gh_summary ""
gh_group_end

gh_group_start "trimming into 16 variants"
python3 "$HERE/trim_variants.py" "$WORK/openfoodfacts.csv.gz" "$WORK/trimmed"
ls -lh "$WORK/trimmed/" | head -20
gh_group_end

gh_group_start "building 16 sqlite databases (sequential, gzip + delete .db each)"
gh_summary "### Per-variant sqlite databases"
gh_summary ""
gh_summary "| variant | rows | gzipped size |"
gh_summary "|---|---:|---:|"
for csv in "$WORK"/trimmed/*.csv; do
  name="$(basename "$csv" .csv)"
  db_path="$WORK/dbs/${name}.db"
  python3 "$HERE/build_sqlite.py" "$csv" "$db_path"
  pigz -6 "$db_path"
  rm -f "$csv"  # frees the trimmed CSV once the .db.gz is on disk
done
gh_summary ""
gh_group_end

gh_group_start "sizes (monolithic, pre-chunk)"
ls -lh "$WORK/dbs/" | head -20
TOTAL=$(du -sb "$WORK/dbs/" | awk '{print $1}')
echo "total: $TOTAL bytes"
gh_summary "**Total .db.gz on disk:** $(numfmt --to=iec --suffix=B "$TOTAL")"
gh_summary ""
gh_group_end

# Split each .db.gz into <=256 MiB chunks + a manifest. After this
# step the directory contains {16 manifests + N chunk files} and the
# original monolithic .db.gz files are gone. Keeps every chunk under
# Cloudflare's edge-cache Range threshold so Range requests work
# reliably from the client.
gh_group_start "splitting variants into chunks (<=256 MiB each)"
python3 "$HERE/split_to_chunks.py" "$WORK/dbs/"
ls -lh "$WORK/dbs/" | head -40
gh_group_end

gh_group_start "uploading to R2 (with 9.7 GiB pre-flight)"
python3 "$HERE/upload_to_r2.py" "$WORK/dbs/"
gh_group_end

ELAPSED=$(( $(date +%s) - START_TS ))
gh_summary "**Total wallclock:** ${ELAPSED}s ($(printf '%dm %ds' $((ELAPSED/60)) $((ELAPSED%60))))"
echo "==> done in ${ELAPSED}s"
