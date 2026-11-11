#!/usr/bin/env python3
"""Write renamed-files.csv: old file name, new file name, one row per book.

Since v0.11.0 every book has a new, permanent file name. Release v0.10.0
published 152 books under the old names; this list says what each of them
is called now. It is attached to the release, so that a reader whose old
link or old file no longer matches finds the new name.

Columns: old_filename, new_filename, book (the book's English label).
Only books that were really published under an old name are listed.

Usage:
    python scripts/gen_renamed_files.py [-o output/renamed-files.csv]
                                        [--set release_set.txt]
"""

import argparse
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from gen_catalog import build_catalog, config_paths_for  # noqa: E402


def renamed_rows(catalog: dict) -> list[tuple[str, str, str]]:
    return sorted(
        (v["old_filename"], v["filename"], v["title_en"])
        for v in catalog["variants"] if v["old_filename"]
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", default="output/renamed-files.csv")
    ap.add_argument("--set", dest="set_file", default="release_set.txt",
                    help="the release set file (default: release_set.txt)")
    args = ap.parse_args()

    catalog, _missing = build_catalog(config_paths_for(args.set_file))
    rows = renamed_rows(catalog)
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["old_filename", "new_filename", "book"])
        writer.writerows(rows)
    print(f"{out.name}: {len(rows)} renamed books -> {out}")


if __name__ == "__main__":
    main()
