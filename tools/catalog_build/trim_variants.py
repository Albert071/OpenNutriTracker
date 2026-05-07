#!/usr/bin/env python3
"""
Read the OFF CSV dump and emit 16 trimmed CSVs — one per
combination of the wizard's three filter axes:

  s — well-scanned (unique_scans_n >= 2)
  n — has nutrition grade (nutriscore_grade in a-e)
  r — recency (3 / 5 / 10 years, or any)

Each trimmed CSV carries only the ~43 columns the catalog reads,
plus the few columns the wizard's client-side filters consult.

Always-on filters (obsolete, pet-food/cosmetics/non-food, completeness
< 0.3) are applied before any variant assignment, so every output file
shares the same baseline. A row is written to every variant whose
filter accepts it.

Usage:
  python3 trim_variants.py <input.csv.gz> <out_dir>
"""
import argparse
import os
import subprocess
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

KEEP_COLUMNS = [
    "code", "url", "product_name", "brands", "quantity",
    "product_quantity", "serving_quantity", "serving_size",
    "categories_tags", "countries_tags", "nutriscore_grade",
    "nutrition_grades", "completeness", "obsolete",
    "last_modified_t", "unique_scans_n",
    "image_url", "image_small_url",
    "image_ingredients_url", "image_nutrition_url",
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
EXCLUDED_CATEGORY_TAGS = {
    b"en:pet-food", b"pet-food",
    b"en:cosmetics", b"cosmetics",
    b"en:non-food-products", b"non-food-products",
}
GRADES = {b"a", b"b", b"c", b"d", b"e"}
SECS_PER_YEAR = 365 * 24 * 3600
RECENCY_OPTIONS = [
    ("3", 3 * SECS_PER_YEAR),
    ("5", 5 * SECS_PER_YEAR),
    ("10", 10 * SECS_PER_YEAR),
    ("any", None),
]
FLUSH_BYTES = 1 << 20


def main() -> None:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("input")
    ap.add_argument("out_dir")
    args = ap.parse_args()

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    proc = subprocess.Popen(
        ["pigz", "-dc", args.input],
        stdout=subprocess.PIPE,
        bufsize=8 * 1024 * 1024,
    )

    header_line = proc.stdout.readline()
    header_fields = header_line.rstrip(b"\r\n").split(b"\t")
    lookup = {h.decode("utf-8", "replace"): i for i, h in enumerate(header_fields)}

    picks = [lookup[c] for c in KEEP_COLUMNS if c in lookup]
    obsolete_i = lookup.get("obsolete", -1)
    completeness_i = lookup.get("completeness", -1)
    categories_i = lookup.get("categories_tags", -1)
    grade_i = lookup.get("nutriscore_grade", -1)
    scans_i = lookup.get("unique_scans_n", -1)
    last_mod_i = lookup.get("last_modified_t", -1)

    now_s = int(time.time())
    trimmed_header = b"\t".join(header_fields[i] for i in picks) + b"\n"

    variants = []
    for s in (0, 1):
        for n in (0, 1):
            for r_label, r_secs in RECENCY_OPTIONS:
                f = open(out / f"s{s}_n{n}_r{r_label}.csv", "wb")
                f.write(trimmed_header)
                cutoff = now_s - r_secs if r_secs is not None else None
                variants.append((s, n, cutoff, f, bytearray()))

    scanned = 0
    drops = 0
    started = time.monotonic()

    try:
        for line in proc.stdout:
            scanned += 1
            fields = line.rstrip(b"\r\n").split(b"\t")

            if obsolete_i < len(fields) and fields[obsolete_i] in (b"1", b"true", b"on"):
                drops += 1
                continue
            if completeness_i < len(fields):
                c = fields[completeness_i]
                try:
                    if not c or float(c) < 0.3:
                        drops += 1
                        continue
                except ValueError:
                    drops += 1
                    continue
            if categories_i < len(fields):
                cats = fields[categories_i]
                bad = False
                if cats:
                    for tag in cats.split(b","):
                        if tag.strip() in EXCLUDED_CATEGORY_TAGS:
                            bad = True
                            break
                if bad:
                    drops += 1
                    continue

            has_scans = False
            if scans_i < len(fields):
                s = fields[scans_i]
                try:
                    has_scans = bool(s) and int(s) >= 2
                except ValueError:
                    pass
            has_grade = (
                grade_i < len(fields)
                and fields[grade_i].lower() in GRADES
            )
            last_mod = 0
            if last_mod_i < len(fields):
                lm = fields[last_mod_i]
                try:
                    last_mod = int(lm) if lm else 0
                except ValueError:
                    pass

            trimmed = b"\t".join(
                fields[i] if i < len(fields) else b"" for i in picks
            ) + b"\n"

            for s_flag, n_flag, cutoff, f, buf in variants:
                if s_flag and not has_scans:
                    continue
                if n_flag and not has_grade:
                    continue
                if cutoff is not None and last_mod < cutoff:
                    continue
                buf.extend(trimmed)
                if len(buf) >= FLUSH_BYTES:
                    f.write(buf)
                    buf.clear()

            if scanned % 200000 == 0:
                now = time.monotonic()
                rate = scanned / (now - started)
                print(f"  scanned {scanned:,} ({rate:,.0f}/sec), dropped {drops:,}",
                      flush=True)
    finally:
        for s_flag, n_flag, cutoff, f, buf in variants:
            if buf:
                f.write(buf)
            f.close()
        proc.wait()

    elapsed = time.monotonic() - started
    print(f"trim complete: {scanned:,} rows in {elapsed:.1f}s, "
          f"always-on drops {drops:,}", flush=True)

    step_summary("### Trim phase")
    step_summary("")
    step_summary(f"- Rows scanned: **{scanned:,}**")
    step_summary(f"- Always-on drops (obsolete / pet-food / cosmetics / "
                 f"non-food / completeness < 0.3): **{drops:,}** "
                 f"({drops * 100 / scanned:.1f}%)")
    step_summary(f"- Wallclock: **{elapsed:.1f}s**")
    step_summary("")


if __name__ == "__main__":
    main()
