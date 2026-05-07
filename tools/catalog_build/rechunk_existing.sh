#!/usr/bin/env bash
# Re-shard the catalog already in R2 into the chunked layout, without
# re-running the full OFF CSV parse. One-off used during the
# chunked-layout migration: downloads each monolithic .db.gz from the
# public CDN, runs split_to_chunks.py, then re-uploads via
# upload_to_r2.py. upload_to_r2's sweep step automatically deletes the
# 16 old .db.gz objects in the same pass, since they will no longer
# be in the upload set.
#
# Why this exists rather than a fresh build: a full rebuild walks the
# 1.2 GB OFF CSV plus 10+ minutes of sqlite + FTS5 work; this skips
# straight to the artefacts that already exist. Bandwidth: about
# 3.51 GB down (the existing 16 .db.gz files) plus a similar amount
# back up (chunks). On a 2 Gbps link the down phase takes ~15 s.
#
# Requires the same R2 credentials as upload_to_r2.py:
#   R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
#   R2_PREFIX (optional, default 'v1/')
# Optional, for invalidating the new URLs at the edge so users see
# them right away rather than waiting on the 7-day CDN TTL:
#   CLOUDFLARE_PURGE_TOKEN, CLOUDFLARE_ZONE_ID, CDN_HOST
#
# Delete this script after the first weekly rebuild produces the
# chunked layout natively. It is migration scaffolding, not a tool we
# need long-term.
set -euo pipefail

WORK="${WORK:-/tmp/rechunking}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CDN_BASE="${CDN_BASE:-https://catalog.opennutritracker.org/v1}"

VARIANTS=(
  s0_n0_r3   s0_n0_r5   s0_n0_r10   s0_n0_rany
  s0_n1_r3   s0_n1_r5   s0_n1_r10   s0_n1_rany
  s1_n0_r3   s1_n0_r5   s1_n0_r10   s1_n0_rany
  s1_n1_r3   s1_n1_r5   s1_n1_r10   s1_n1_rany
)

# Pre-flight the env so we fail before downloading 3.5 GB.
: "${R2_ENDPOINT:?R2_ENDPOINT must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID must be set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY must be set}"

mkdir -p "$WORK"
cd "$WORK"

echo "==> downloading 16 .db.gz files in parallel from $CDN_BASE"
echo "    into $WORK"
URLS=()
for v in "${VARIANTS[@]}"; do
  URLS+=("$CDN_BASE/${v}.db.gz")
done
# -Z enables parallel transfers; --parallel-max 16 lets all 16 go at
# once on Jordan's 2 Gbps line. --remote-name-all applies -O to every
# URL so each lands at $WORK/<basename>. --fail turns any 4xx/5xx into
# a non-zero exit.
START_TS=$(date +%s)
curl --fail --parallel --parallel-max 16 --remote-name-all "${URLS[@]}"
ELAPSED=$(( $(date +%s) - START_TS ))
TOTAL_BYTES=$(du -sb "$WORK" | awk '{print $1}')
TOTAL_GB=$(awk "BEGIN { printf \"%.2f\", $TOTAL_BYTES/1024/1024/1024 }")
echo "    downloaded ${TOTAL_GB} GiB in ${ELAPSED}s"
ls -lh "$WORK"/*.db.gz

echo
echo "==> splitting into chunks + manifests (256 MiB cap)"
python3 "$HERE/split_to_chunks.py" "$WORK"

echo
echo "==> after split:"
ls -lh "$WORK" | head -60

echo
echo "==> uploading chunked layout to R2"
echo "    (upload_to_r2 sweep will remove the old .db.gz objects in"
echo "    the same pass, since they're no longer in the upload set)"
python3 "$HERE/upload_to_r2.py" "$WORK"

echo
echo "==> done in $(( $(date +%s) - START_TS ))s"
echo "    consider deleting this script and \$WORK now that the"
echo "    chunked layout is live."
