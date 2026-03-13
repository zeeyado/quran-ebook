#!/usr/bin/env python3
"""Generate GitHub release body from README download tables.

Extracts the Downloads section from README.md and rewrites links to point
at the specific tag's release assets instead of "latest".
"""

import re
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_release_body.py <tag>", file=sys.stderr)
        sys.exit(1)

    tag = sys.argv[1]
    repo_root = Path(__file__).resolve().parent.parent

    # Prepend release notes if present
    release_notes_path = repo_root / "RELEASE_NOTES.md"
    if release_notes_path.exists():
        print(release_notes_path.read_text().strip())
        print()

    # Extract download sections from README (EPUBs + Dictionary + KOReader Plugin)
    readme_path = repo_root / "README.md"
    readme = readme_path.read_text()

    # Extract from "## EPUBs" through end of "## KOReader Plugin" (up to "## Build")
    match = re.search(
        r"(^## EPUBs\n.+?^## Dictionary\n.+?^## KOReader Plugin\n.+?)(?=^## Build Your Own|^## Data Sources|\Z)",
        readme,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        print("ERROR: Could not find EPUBs/Dictionary/Plugin sections in README.md", file=sys.stderr)
        sys.exit(1)

    downloads = match.group(1).rstrip()

    # Rewrite link targets:
    # ../../releases/latest/download/X  →  ../../releases/download/{tag}/X
    # ../../raw/main/release/X           →  ../../releases/download/{tag}/X
    downloads = downloads.replace(
        "../../releases/latest/download/",
        f"../../releases/download/{tag}/",
    )
    downloads = re.sub(
        r"\.\./\.\./raw/main/release/([^)]+)",
        rf"../../releases/download/{tag}/\1",
        downloads,
    )

    # Rewrite README anchor links to point at tagged README
    # ../../raw/main/release/) (bare directory link) → remove or skip
    downloads = downloads.replace(
        "](../../blob/main/README.md#",
        f"](../../blob/{tag}/README.md#",
    )
    # Also fix #anchor links that are just (#something) — make them point to tagged README
    downloads = re.sub(
        r"\]\(#([a-z-]+)\)",
        rf"](../../blob/{tag}/README.md#\1)",
        downloads,
    )

    print(downloads)
    print()
    print(f"See [README](../../blob/{tag}/README.md#koreader-settings) for KOReader setup tips (footnote popups, RTL page turns, mushaf page numbers).")


if __name__ == "__main__":
    main()
