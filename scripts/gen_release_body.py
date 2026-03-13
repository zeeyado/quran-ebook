#!/usr/bin/env python3
"""Generate GitHub release body from README download tables.

Extracts the EPUBs section from README.md (release assets) and appends
a compact reference to KOReader addons (which live on main branch, not
as release assets). EPUB links are rewritten to point at the specific
tag's release assets.
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

    # Extract EPUBs section only (release assets built by CI)
    readme_path = repo_root / "README.md"
    readme = readme_path.read_text()

    match = re.search(
        r"(^## EPUBs\n.+?)(?=^## Dictionary|^## KOReader Plugin|^## Build Your Own|^## Data Sources|\Z)",
        readme,
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

    # Expand bare anchor links (#something) to full README links
    epubs = re.sub(
        r"\]\(#([a-z-]+)\)",
        r"](../../blob/main/README.md#\1)",
        epubs,
    )

    readme = "../../blob/main/README.md"

    print(epubs)
    print()
    print("---")
    print()
    print(f"Latest KOReader addons: [plugin]({readme}#install) · [word dictionary]({readme}#dictionary) · [grammar & i'rab]({readme}#grammar-dictionary-lookup) · [tafsir]({readme}#tafsir-commentary-lookup) · [surah overview]({readme}#surah-overview-lookup) · [setup tips]({readme}#koreader-settings)")


if __name__ == "__main__":
    main()
