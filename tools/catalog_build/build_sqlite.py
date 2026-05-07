#!/usr/bin/env python3
"""
Build a single sqlite catalog file from a trimmed variant CSV.

Schema mirrors lib/features/offline_catalog/data/data_sources/
offline_catalog_data_source.dart so the file the workflow ships is
the same shape the app would produce locally.

  products(code PK, product_name, product_name_{en,de,fr}, brands,
           data TEXT, last_modified_t INT, fetched_at INT)
  idx_products_brands ON products(brands)
  products_fts (FTS5: code UNINDEXED, name fields, brands, unicode61
                with remove_diacritics 2)
  catalog_meta(key PK, value)

Usage:
  python3 build_sqlite.py <input.csv> <out.db> [--schema-version N]
"""
import argparse
import csv
import json
import os
import sqlite3
import sys
import time
from pathlib import Path


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

NUTRIMENT_KEYS = [
    "energy-kcal_100g", "carbohydrates_100g", "fat_100g",
    "proteins_100g", "sugars_100g", "saturated-fat_100g",
    "fiber_100g", "monounsaturated-fat_100g",
    "polyunsaturated-fat_100g", "trans-fat_100g",
    "cholesterol_100g", "sodium_100g", "potassium_100g",
    "magnesium_100g", "calcium_100g", "iron_100g", "zinc_100g",
    "phosphorus_100g", "vitamin-a_100g", "vitamin-c_100g",
    "vitamin-d_100g", "vitamin-b6_100g", "vitamin-b12_100g",
    "niacin_100g",
]


def to_double(v):
    if v is None or v == "":
        return None
    try:
        return float(v)
    except ValueError:
        return None


def to_int(v):
    if v is None or v == "":
        return None
    try:
        return int(v)
    except ValueError:
        try:
            return int(float(v))
        except ValueError:
            return None


def row_to_dto(row: dict) -> dict:
    nutriments = {}
    for key in NUTRIMENT_KEYS:
        v = to_double(row.get(key))
        if v is not None:
            nutriments[key] = v
    return {
        "code": row["code"],
        "product_name": row.get("product_name") or None,
        "product_name_en": None,
        "product_name_de": None,
        "product_name_fr": None,
        "brands": row.get("brands") or None,
        "image_front_thumb_url": (row.get("image_small_url")
                                   or row.get("image_url") or None),
        "image_front_url": row.get("image_url") or None,
        "image_ingredients_url": row.get("image_ingredients_url") or None,
        "image_nutrition_url": row.get("image_nutrition_url") or None,
        "image_url": row.get("image_url") or None,
        "url": row.get("url") or None,
        "quantity": row.get("quantity") or None,
        "product_quantity": to_double(row.get("product_quantity")),
        "serving_quantity": to_double(row.get("serving_quantity")),
        "serving_size": row.get("serving_size") or None,
        "nutriments": nutriments,
        "last_modified_t": to_int(row.get("last_modified_t")),
    }


def main() -> None:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("input")
    ap.add_argument("out")
    # Major schema version. Bump only when a change renames or removes
    # something a client query depends on — older clients refuse
    # higher majors at install time.
    ap.add_argument("--schema-version", type=int, default=1)
    # Minor schema version. Bump freely for additive changes (new
    # column on `products`, new auxiliary table). Older clients accept
    # any minor at the same major and silently ignore the additions.
    # See lib/features/offline_catalog/data/data_sources/
    # catalog_download_data_source.dart for the matching rule.
    ap.add_argument("--schema-version-minor", type=int, default=0)
    args = ap.parse_args()

    out = Path(args.out)
    if out.exists():
        out.unlink()
    db = sqlite3.connect(out)
    db.execute("PRAGMA journal_mode = MEMORY")
    db.execute("PRAGMA synchronous = OFF")
    db.execute("PRAGMA temp_store = MEMORY")
    db.execute("PRAGMA cache_size = -200000")

    db.executescript("""
        CREATE TABLE products (
            code TEXT PRIMARY KEY NOT NULL,
            product_name TEXT,
            product_name_en TEXT,
            product_name_de TEXT,
            product_name_fr TEXT,
            brands TEXT,
            data TEXT NOT NULL,
            last_modified_t INTEGER,
            fetched_at INTEGER NOT NULL
        );
        CREATE INDEX idx_products_brands ON products(brands);
        CREATE VIRTUAL TABLE products_fts USING fts5(
            code UNINDEXED,
            product_name, product_name_en, product_name_de,
            product_name_fr, brands,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TABLE catalog_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT
        );
    """)
    db.execute(
        "INSERT INTO catalog_meta (key, value) VALUES (?, ?)",
        ("schema_version", str(args.schema_version)),
    )
    db.execute(
        "INSERT INTO catalog_meta (key, value) VALUES (?, ?)",
        ("schema_version_minor", str(args.schema_version_minor)),
    )
    db.execute(
        "INSERT INTO catalog_meta (key, value) VALUES (?, ?)",
        ("built_at_ms", str(int(time.time() * 1000))),
    )

    fetched_at = int(time.time() * 1000)
    started = time.monotonic()
    inserted = 0
    skipped = 0
    batch = []

    with open(args.input, newline="", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            code = row.get("code")
            if not code:
                skipped += 1
                continue
            dto = row_to_dto(row)
            data_blob = json.dumps(dto, separators=(",", ":"), ensure_ascii=False)
            batch.append((
                code, dto["product_name"], None, None, None,
                dto["brands"], data_blob, dto["last_modified_t"], fetched_at,
            ))
            if len(batch) >= 5000:
                db.executemany(
                    "INSERT OR REPLACE INTO products "
                    "(code, product_name, product_name_en, product_name_de, "
                    "product_name_fr, brands, data, last_modified_t, fetched_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    batch,
                )
                inserted += len(batch)
                batch.clear()

    if batch:
        db.executemany(
            "INSERT OR REPLACE INTO products "
            "(code, product_name, product_name_en, product_name_de, "
            "product_name_fr, brands, data, last_modified_t, fetched_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            batch,
        )
        inserted += len(batch)
    db.commit()

    db.execute("""
        INSERT INTO products_fts(code, product_name, product_name_en,
            product_name_de, product_name_fr, brands)
        SELECT code, product_name, product_name_en, product_name_de,
            product_name_fr, brands
        FROM products
    """)
    db.commit()
    db.execute("VACUUM")
    db.close()

    size = out.stat().st_size
    elapsed = time.monotonic() - started
    print(
        f"  {out.name}: {inserted:,} rows, "
        f"{size:,} bytes ({size/1024/1024:.1f} MiB), "
        f"{elapsed:.1f}s",
        flush=True,
    )
    # Note: orchestrator passes the .db path before pigz runs, so the
    # size reported here is the *uncompressed* sqlite size. The final
    # gzipped size lands in the orchestrator-driven summary table that
    # upload_to_r2.py emits after the upload step.
    step_summary(f"| `{out.stem}` | {inserted:,} | {fmt_bytes(size)} (raw) |")


if __name__ == "__main__":
    main()
