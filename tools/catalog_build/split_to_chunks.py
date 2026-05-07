#!/usr/bin/env python3
"""
Split each catalog `.db.gz` in a directory into chunks no larger than
[CHUNK_SIZE] bytes, emit a per-variant `manifest.json` describing the
parts and their sha256 hashes, and delete the original monolithic
`.db.gz`. After this step the directory contains
{16 manifests + N chunk files} ready for `upload_to_r2.py`.

Why we chunk: Cloudflare's edge cache treats Range requests against
objects above ~512 MB inconsistently — the first request that misses
the edge can trigger a full origin pull and the edge serves a 200
with the whole body, even though origin (R2) supports 206 cleanly.
Three of the loosest variants (`s0_n0_r{5,10,any}`) sit right at or
above that threshold. Splitting every variant into <=256 MiB pieces
keeps every chunk firmly under the threshold so the edge serves
Range requests reliably; the client reassembles the stream.

The client (CatalogDownloadDataSource) reads the manifest first, then
downloads each part with bounded parallelism, validates per-part
sha256, concatenates, validates the combined sha256, and proceeds
with gunzip + verify + atomic rename as before.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

# 256 MiB cap. Leaves comfortable headroom under Cloudflare's edge
# Range threshold and keeps individual chunks small enough for
# parallel workers on cellular connections.
CHUNK_SIZE = 256 * 1024 * 1024

# Streaming read block. 4 MiB balances memory use against syscall
# overhead; the whole chunk hash is built block-by-block.
READ_BLOCK = 4 * 1024 * 1024

# Bumped when the manifest schema changes shape in a way that older
# clients cannot read. The current client treats anything other than
# `1` as "manifest from a future build I don't understand" and refuses
# to install.
MANIFEST_VERSION = 1


def step_summary(line: str) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def fmt_bytes(n: int) -> str:
    if n >= 1024 ** 3:
        return f"{n / 1024 ** 3:.2f} GiB"
    if n >= 1024 ** 2:
        return f"{n / 1024 ** 2:.0f} MiB"
    if n >= 1024:
        return f"{n / 1024:.0f} KiB"
    return f"{n} B"


def split_one(
    gz_path: Path,
    *,
    schema_version_major: int,
    schema_version_minor: int,
) -> dict:
    """Split [gz_path] in place; return its manifest dict."""
    variant_id = gz_path.name
    if variant_id.endswith(".db.gz"):
        variant_id = variant_id[: -len(".db.gz")]

    full_hash = hashlib.sha256()
    parts: list[dict] = []
    total_bytes = 0

    with open(gz_path, "rb") as src:
        index = 0
        while True:
            chunk_name = f"{variant_id}.db.gz.part-{index:02d}"
            chunk_path = gz_path.parent / chunk_name
            chunk_hash = hashlib.sha256()
            written = 0
            with open(chunk_path, "wb") as dst:
                # Pull up to CHUNK_SIZE bytes from src in READ_BLOCK
                # increments. Stops short on EOF, which is also our
                # signal to break the outer loop.
                while written < CHUNK_SIZE:
                    want = min(READ_BLOCK, CHUNK_SIZE - written)
                    block = src.read(want)
                    if not block:
                        break
                    dst.write(block)
                    chunk_hash.update(block)
                    full_hash.update(block)
                    written += len(block)
            if written == 0:
                # Empty chunk = we hit EOF exactly on a chunk boundary.
                # Remove the empty file so the manifest doesn't
                # advertise a zero-byte part.
                chunk_path.unlink()
                break
            parts.append({
                "name": chunk_name,
                "bytes": written,
                "sha256": chunk_hash.hexdigest(),
            })
            total_bytes += written
            index += 1
            if written < CHUNK_SIZE:
                # Last chunk was partial — that's the tail of the file.
                break

    # Embed the catalog payload's schema version inline so older
    # clients can refuse a major-version bump *before* downloading any
    # chunks. The values come from CLI flags rather than being read
    # back out of the gzipped sqlite, so the build orchestrator and
    # the rechunking-in-place tool can both pass the same constants
    # they pass to build_sqlite.py.
    manifest = {
        "manifestVersion": MANIFEST_VERSION,
        "variantId": variant_id,
        "totalCompressedBytes": total_bytes,
        "sha256": full_hash.hexdigest(),
        "schemaVersionMajor": schema_version_major,
        "schemaVersionMinor": schema_version_minor,
        "parts": parts,
    }
    manifest_path = gz_path.parent / f"{variant_id}.manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    gz_path.unlink()
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("local_dir")
    # The schema version embedded in each manifest. Must match what
    # build_sqlite.py wrote into catalog_meta.schema_version /
    # schema_version_minor for the artefacts in [local_dir]; the
    # orchestrator passes the same defaults to both.
    ap.add_argument("--schema-version-major", type=int, default=1)
    ap.add_argument("--schema-version-minor", type=int, default=0)
    args = ap.parse_args()

    src = Path(args.local_dir)
    files = sorted(src.glob("*.db.gz"))
    if not files:
        print(f"no .db.gz files in {src}", file=sys.stderr)
        return 2

    print(f"\nsplitting {len(files)} variant(s) into chunks of "
          f"{fmt_bytes(CHUNK_SIZE)} max")

    step_summary("### Splitting variants into chunks")
    step_summary("")
    step_summary(f"Chunk cap: **{fmt_bytes(CHUNK_SIZE)}** "
                 "(under Cloudflare's edge-cache Range threshold).")
    step_summary("")
    step_summary("| variant | parts | total | largest part |")
    step_summary("|---|---:|---:|---:|")

    for gz_path in files:
        manifest = split_one(
            gz_path,
            schema_version_major=args.schema_version_major,
            schema_version_minor=args.schema_version_minor,
        )
        n_parts = len(manifest["parts"])
        total = manifest["totalCompressedBytes"]
        largest = max(p["bytes"] for p in manifest["parts"])
        print(f"  {manifest['variantId']}: {n_parts} part(s), "
              f"{total:,} bytes total, largest {largest:,}",
              flush=True)
        step_summary(
            f"| `{manifest['variantId']}` | {n_parts} | "
            f"{fmt_bytes(total)} | {fmt_bytes(largest)} |"
        )

    step_summary("")
    return 0


if __name__ == "__main__":
    sys.exit(main())
