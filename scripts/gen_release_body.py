#!/usr/bin/env python3
"""Write the text of a GitHub release: short, with links to the rest.

The text is RELEASE_NOTES.md, then a few direct links ("Pick a book"),
then where to find everything else: BOOKS.md (the table of every book),
renamed-files.csv (old file name, new file name) and the OPDS catalog.
The full tables are no longer copied in here: with a few hundred books
they made a text longer than GitHub accepts.

Guards (each fails with exit 1, and all of them run in the first seconds
of the release workflow, before anything is built):
- the first line of RELEASE_NOTES.md must name the tag, and must not say
  DRAFT (the previous release's notes, or unfinished ones, never ship);
- every picked book must be in the release set;
- the text must stay under MAX_CHARS. GitHub cuts a release text at
  125,000 characters without a word.

A late run (after the catalog exists) also checks every picked file name
against the catalog.

Usage:
    python scripts/gen_release_body.py v0.11.0 > release_body.md
    python scripts/gen_release_body.py v0.11.0-rc1 --rehearsal > release_body.md

--rehearsal is for release candidates: the notes may still say DRAFT, and
their first line needs to name only the version the candidate is for.

Stdlib only: the workflow runs this before anything is installed.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.release_set import DEFAULT_NAME, read_release_set  # noqa: E402

REPO_URL = "https://github.com/zeeyado/quran-ebook"
OPDS_URL = "https://zeeyado.github.io/quran-ebook/opds/root.xml"
# GitHub's own limit is 125,000 characters; stay well under it.
MAX_CHARS = 100_000
# Above this the text is no longer "short": say so, but do not fail.
SHORT_CHARS = 15_000

# The direct links of "Pick a book": config, file name, label.
PICKS = [
    ("configs/arabic/hafs_ayah.yaml",
     "quran_hafs-uthmani_kfgqpc_ayah_ar.epub",
     "Arabic, one ayah per paragraph"),
    ("configs/arabic/hafs_inline.yaml",
     "quran_hafs-uthmani_kfgqpc_flow_ar.epub",
     "Arabic, flowing text"),
    ("configs/bilingual/en_sahih.yaml",
     "quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih.epub",
     "Arabic with English under each ayah (Sahih International)"),
    ("configs/wbw/en_sahih.yaml",
     "quran_hafs-uthmani_kfgqpc_word-inline_ar-en-sahih.epub",
     "Word by word, English"),
    ("configs/bilingual-interactive/en_sahih_mukhtasar.yaml",
     "quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih_tafsir-mukhtasar.epub",
     "English under each ayah, with the Al-Mukhtasar tafsir in a popup"),
    ("configs/bilingual/en_mukhtasar.yaml",
     "quran_hafs-uthmani_kfgqpc_ayah-inline_ar_tafsir-mukhtasar-en.epub",
     "Arabic with Al-Mukhtasar in English under each ayah"),
    ("configs/arabic/indopak_ayah.yaml",
     "quran_hafs-indopak_nastaleeq_ayah_ar.epub",
     "IndoPak script, Arabic (beta)"),
    ("configs/wbw/en_indopak.yaml",
     "quran_hafs-indopak_nastaleeq_word-inline_ar-en-sahih.epub",
     "IndoPak script, word by word, English (beta)"),
    ("configs/arabic/warsh_ayah.yaml",
     "quran_warsh-uthmani_kfgqpc_ayah_ar.epub",
     "Warsh, Arabic (beta)"),
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def read_notes(tag: str, rehearsal: bool) -> str:
    path = ROOT / "RELEASE_NOTES.md"
    if not path.exists():
        fail("RELEASE_NOTES.md is missing")
    notes = path.read_text(encoding="utf-8").strip()
    first_line = notes.splitlines()[0] if notes else ""
    # A release candidate (v1.2.3-rc1) rehearses the notes of v1.2.3.
    wanted = re.sub(r"-rc\d*$", "", tag) if rehearsal else tag
    if not re.search(rf"(?<![\w.]){re.escape(wanted)}(?![\w.-])", first_line):
        fail(f"RELEASE_NOTES.md first line does not name '{wanted}': the notes "
             f"are stale. Update them before tagging.\n  first line: {first_line!r}")
    if "DRAFT" in first_line and not rehearsal:
        fail(f"RELEASE_NOTES.md is still marked DRAFT. Finish it before tagging {tag}.")
    return notes


def check_picks() -> None:
    listed = set(read_release_set(ROOT / DEFAULT_NAME))
    missing = [config for config, _file, _label in PICKS if config not in listed]
    if missing:
        fail(f"picked books are not in {DEFAULT_NAME}: {missing}")
    catalog_path = ROOT / "output" / "catalog.json"
    if catalog_path.exists():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        files = {v["filename"] for v in catalog["variants"]}
        unknown = [file for _config, file, _label in PICKS if file not in files]
        if unknown:
            fail(f"picked files are not in the catalog: {unknown}")


def render(tag: str, notes: str) -> str:
    assets = f"{REPO_URL}/releases/download/{tag}"
    n_books = len(read_release_set(ROOT / DEFAULT_NAME))
    lines = [notes, "", "## Pick a book", ""]
    lines += [f"- [{label}]({assets}/{file})" for _config, file, label in PICKS]
    lines += [
        "",
        f"**All {n_books} books**, by language and layout: "
        f"[BOOKS.md]({REPO_URL}/blob/{tag}/BOOKS.md). "
        "Every file is also in the list of assets below.",
        "",
        "**In KOReader** you can browse and download the books on the device: "
        f"add `{OPDS_URL}` to its OPDS catalogs.",
        "",
        "**Old file names.** The books that v0.10.0 published have new names. "
        f"[renamed-files.csv]({assets}/renamed-files.csv) lists the old and "
        "the new name of each one.",
        "",
        f"Dictionaries, the KOReader plugin and reader settings: see the "
        f"[README]({REPO_URL}/blob/{tag}/README.md).",
    ]
    return "\n".join(lines) + "\n"


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 1 or flags - {"--rehearsal"}:
        print("Usage: gen_release_body.py <tag> [--rehearsal]", file=sys.stderr)
        sys.exit(1)
    tag = args[0]

    notes = read_notes(tag, "--rehearsal" in flags)
    check_picks()
    body = render(tag, notes)
    size = len(body)
    print(f"release text: {size:,} characters (limit {MAX_CHARS:,})", file=sys.stderr)
    if size > MAX_CHARS:
        fail(f"the release text has {size:,} characters; the limit is {MAX_CHARS:,} "
             f"(GitHub cuts at 125,000). Shorten RELEASE_NOTES.md.")
    if size > SHORT_CHARS:
        print(f"note: over {SHORT_CHARS:,} characters. The release page should be "
              "short; long lists belong in BOOKS.md.", file=sys.stderr)
    sys.stdout.write(body)


if __name__ == "__main__":
    main()
