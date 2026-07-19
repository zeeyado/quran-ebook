#!/usr/bin/env python3
"""Generate GitHub release body from README download tables.

Extracts the EPUBs section from README.md (release assets) and appends
a compact reference to KOReader addons (which live on main branch, not
as release assets). EPUB links are rewritten to point at the specific
tag's release assets.

Filename-rename policy = HARD BREAK (owner decision 2026-07-19, replaces
the N1 one-cycle alias uploads): old explicit-tag links never die, README
updates atomically with the tag, so renamed variants ship under the new
name only — with a rename table appended here (from catalog.json's
old_filename fields) so anyone hitting a 404 on a floating link finds the
new name.
"""

import json
import re
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_release_body.py <tag>", file=sys.stderr)
        sys.exit(1)

    tag = sys.argv[1]
    repo_root = Path(__file__).resolve().parent.parent

    # Prepend release notes if present — but refuse stale notes: the first
    # line must name the tag being released (guards against shipping the
    # previous version's notes verbatim; see docs/production_push_2026-07.md).
    release_notes_path = repo_root / "RELEASE_NOTES.md"
    if release_notes_path.exists():
        notes = release_notes_path.read_text().strip()
        first_line = notes.splitlines()[0] if notes else ""
        if tag not in first_line:
            print(
                f"ERROR: RELEASE_NOTES.md first line does not mention tag "
                f"'{tag}' — notes are stale. Update them before tagging.\n"
                f"  first line: {first_line!r}",
                file=sys.stderr,
            )
            sys.exit(1)
        if "DRAFT" in first_line:
            print(
                f"ERROR: RELEASE_NOTES.md is still marked DRAFT — finish it "
                f"before tagging {tag}.",
                file=sys.stderr,
            )
            sys.exit(1)
        print(notes)
        print()

    # Extract EPUBs section only (release assets built by CI)
    readme_path = repo_root / "README.md"
    readme_text = readme_path.read_text()

    match = re.search(
        r"(^## EPUBs\n.+?)(?=^## Dictionary|^## KOReader Plugin|^## Build Your Own|^## Data Sources|\Z)",
        readme_text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        print("ERROR: Could not find EPUBs section in README.md", file=sys.stderr)
        sys.exit(1)

    epubs = match.group(1).rstrip()

    # Rewrite EPUB link targets:
    # ../../releases/latest/download/X  →  ../../releases/download/{tag}/X
    epubs = epubs.replace(
        "../../releases/latest/download/",
        f"../../releases/download/{tag}/",
    )

    # Expand bare anchor links (#something) to repo root (rendered README)
    epubs = re.sub(
        r"\]\(#([a-z-]+)\)",
        r"](../../#\1)",
        epubs,
    )

    # Extract "Updating EPUBs" section from README
    update_match = re.search(
        r"(^### Updating EPUBs\n.+?)(?=^###|\Z)",
        readme_text,
        re.MULTILINE | re.DOTALL,
    )

    print(epubs)
    print()
    if update_match:
        print(update_match.group(1).rstrip())

    # Rename table (hard break): catalog.json exists only at real body-gen
    # time — the early notes-freshness guard runs before the build, so a
    # missing catalog is simply skipped.
    catalog_path = repo_root / "output" / "catalog.json"
    if catalog_path.exists():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        renames = [
            (v["old_filename"], v["filename"])
            for v in catalog["variants"]
            if v.get("old_filename") and v["old_filename"] != v["filename"]
        ]
        if renames:
            print()
            print("<details><summary>Renamed files — old name → new name "
                  f"({len(renames)} renames; old links from previous releases "
                  "keep working at their own tags)</summary>\n")
            print("| Old filename | New filename |")
            print("| --- | --- |")
            for old, new in sorted(renames):
                print(f"| `{old}` | [`{new}`](../../releases/download/{tag}/{new}) |")
            print("\n</details>")


if __name__ == "__main__":
    main()
