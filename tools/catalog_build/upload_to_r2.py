#!/usr/bin/env python3
"""
Upload a directory of catalog artefacts to R2 using the S3-compatible
API. The expected layout (produced by `split_to_chunks.py`) is per-
variant:

  s1_n1_r5.manifest.json
  s1_n1_r5.db.gz.part-00
  s1_n1_r5.db.gz.part-01    (only if the variant exceeded the chunk cap)
  ...

Manifests upload as `application/json`; chunks upload as
`application/octet-stream` (they are fragments of a gzip stream and
not individually decompressible — only the concatenation is). The
client (CatalogDownloadDataSource) reads the manifest first and
fetches each chunk in parallel.

Pre-flight: refuses to upload if the total size of the directory
exceeds the configured ceiling (default 9.7 GiB).

Credentials are read from environment variables:
  R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
  R2_ENDPOINT, R2_BUCKET, R2_PREFIX (optional, default 'v1/')

Usage:
  python3 upload_to_r2.py <local_dir>
"""
import argparse
import os
import sys
import time
from pathlib import Path

import json
import urllib.request
import urllib.error

import boto3
from botocore.config import Config

CEILING_BYTES = int(9.7 * 1024 * 1024 * 1024)


def step_summary(text: str) -> None:
    """Append markdown to the GH Actions step summary, no-op locally."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write(text)
        if not text.endswith("\n"):
            f.write("\n")


def fmt_bytes(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def gh_error(msg: str) -> None:
    """Emit a GH Actions error annotation (becomes a red banner on the run page)."""
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error::{msg}", flush=True)
    print(msg, file=sys.stderr, flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("local_dir")
    args = ap.parse_args()

    src = Path(args.local_dir)
    # Per-variant `.manifest.json` plus N `.db.gz.part-NN` chunks.
    # `split_to_chunks.py` runs upstream of this script and rewrites
    # the directory from monolithic `.db.gz` into the chunked layout.
    manifests = sorted(src.glob("*.manifest.json"))
    parts = sorted(src.glob("*.db.gz.part-*"))
    files = manifests + parts
    if not files:
        print(
            f"no .manifest.json / .db.gz.part-NN files in {src} — "
            f"did split_to_chunks.py run?",
            file=sys.stderr,
        )
        sys.exit(2)

    total = sum(f.stat().st_size for f in files)
    print(f"\n{len(files)} files, {total:,} bytes "
          f"({total/1024/1024/1024:.2f} GiB) total")
    if total > CEILING_BYTES:
        msg = (
            f"REFUSING to upload: total {total:,} bytes exceeds the "
            f"{CEILING_BYTES/1024/1024/1024:.2f} GiB ceiling. Trim the "
            f"variant set, drop columns from the projection, or raise "
            f"the ceiling deliberately."
        )
        gh_error(msg)
        step_summary(f"### Upload refused\n\n:no_entry: {msg}")
        sys.exit(3)

    endpoint = os.environ["R2_ENDPOINT"]
    bucket = os.environ["R2_BUCKET"]
    prefix = os.environ.get("R2_PREFIX", "v1/")
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
        config=Config(
            retries={"max_attempts": 5, "mode": "adaptive"},
            s3={
                "multipart_chunksize": 64 * 1024 * 1024,
                "multipart_threshold": 64 * 1024 * 1024,
                "max_concurrency": 8,
            },
        ),
    )

    step_summary("### Upload to R2")
    step_summary("")
    step_summary(f"Bucket: `{bucket}`, prefix: `{prefix}`, "
                 f"endpoint: `{endpoint}`")
    step_summary("")
    step_summary("| object | size | speed |")
    step_summary("|---|---:|---:|")

    for f in files:
        key = prefix + f.name
        size = f.stat().st_size
        # Manifests are JSON; chunks are fragments of a gzip stream
        # and not individually decompressible (only the concatenation
        # is) so octet-stream is the honest content-type. Either way
        # Cloudflare's cache rule overrides the cache TTL on the way
        # out so this only affects what a curling user sees.
        if f.name.endswith(".manifest.json"):
            content_type = "application/json"
        else:
            content_type = "application/octet-stream"
        started = time.monotonic()
        s3.upload_file(
            str(f), bucket, key,
            ExtraArgs={"ContentType": content_type},
        )
        elapsed = time.monotonic() - started
        mbps = size / elapsed / 1024 / 1024 if elapsed > 0 else 0
        print(f"  uploaded {key}  ({size:,} bytes, {mbps:.1f} MiB/s)",
              flush=True)
        step_summary(f"| `{key}` | {fmt_bytes(size)} | {mbps:.1f} MiB/s |")

    step_summary("")
    step_summary(f"**Total uploaded:** {len(files)} files, "
                 f"{fmt_bytes(total)}")
    print(f"\nuploaded {len(files)} files to s3://{bucket}/{prefix}")

    # Sweep: delete anything under the prefix that wasn't part of this
    # upload set. Protects against drift when a variant is renamed
    # or removed in code without anyone manually cleaning the bucket.
    uploaded_keys = {prefix + f.name for f in files}
    stale: list[str] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []) or []:
            if obj["Key"] not in uploaded_keys:
                stale.append(obj["Key"])

    if stale:
        print(f"\nsweeping {len(stale)} stale object(s) under {prefix}")
        # delete_objects accepts up to 1000 keys per call.
        for i in range(0, len(stale), 1000):
            batch = [{"Key": k} for k in stale[i:i + 1000]]
            s3.delete_objects(Bucket=bucket, Delete={"Objects": batch, "Quiet": True})
        for k in stale:
            print(f"  swept {k}", flush=True)
        step_summary("")
        step_summary(f"### Sweep")
        step_summary("")
        step_summary(f"Removed **{len(stale)}** stale object(s) "
                     f"no longer in the variant set:")
        for k in stale:
            step_summary(f"- `{k}`")
    else:
        print("\nsweep: nothing to remove")

    # Cache purge — invalidate the just-uploaded URLs at the edge so
    # users see the new files immediately rather than waiting up to
    # the 7-day cache TTL. Optional: skipped silently if the purge
    # token / zone / host env vars aren't set (e.g. local dev runs).
    purge_token = os.environ.get("CLOUDFLARE_PURGE_TOKEN")
    zone_id = os.environ.get("CLOUDFLARE_ZONE_ID")
    cdn_host = os.environ.get("CDN_HOST")
    if purge_token and zone_id and cdn_host:
        urls = [f"https://{cdn_host}/{key}" for key in sorted(uploaded_keys)]
        # CF free plan accepts up to 30 URLs per purge call.
        for i in range(0, len(urls), 30):
            chunk = urls[i:i + 30]
            req = urllib.request.Request(
                f"https://api.cloudflare.com/client/v4/zones/{zone_id}/purge_cache",
                data=json.dumps({"files": chunk}).encode("utf-8"),
                headers={
                    "Authorization": f"Bearer {purge_token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    body = json.loads(resp.read())
                    if not body.get("success"):
                        gh_error(f"cache purge reported failure: {body.get('errors')}")
                        sys.exit(4)
            except urllib.error.HTTPError as e:
                gh_error(f"cache purge HTTP {e.code}: {e.read().decode('utf-8', 'replace')}")
                sys.exit(4)
        print(f"\npurged {len(urls)} URL(s) from the edge cache")
        step_summary("")
        step_summary(f"### Cache purge")
        step_summary("")
        step_summary(f"Invalidated **{len(urls)}** URL(s) at the Cloudflare edge "
                     f"so users see the fresh files immediately.")
    else:
        print("\ncache purge: skipped (CLOUDFLARE_PURGE_TOKEN / "
              "CLOUDFLARE_ZONE_ID / CDN_HOST not all set)")


if __name__ == "__main__":
    main()
