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


if __name__ == "__main__":
    main()
