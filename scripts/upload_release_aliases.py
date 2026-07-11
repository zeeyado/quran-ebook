#!/usr/bin/env python3
"""One-cycle alias uploads for the rename release (decision N1).

Uploads each renamed EPUB to the release a SECOND time under its OLD
filename, so floating `releases/latest/download/<oldname>` links (README
bookmarks, forum posts) survive exactly one cycle. REMOVE THIS STEP from
release.yml at the NEXT release.

Aliases are derived from catalog.json's old_filename fields INTERSECTED
with the previous release's actual asset list — variants that never
shipped under an old name get no alias. Everything skipped is logged
(no silent caps).

Requires: gh CLI authenticated (GITHUB_TOKEN in CI), catalog.json built,
EPUBs in output/.

Usage:
    python scripts/upload_release_aliases.py <tag>
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def gh_json(args: list[str]):
    out = subprocess.run(
        ["gh"] + args, check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: upload_release_aliases.py <tag>")
    tag = sys.argv[1]

    # Previous release = most recent release that isn't this tag
    # (--paginate: the asset-listing pagination rule, grammar doc §4b).
    releases = gh_json(["api", "--paginate", "repos/{owner}/{repo}/releases"])
    prev = next((r for r in releases if r["tag_name"] != tag and not r["draft"]), None)
    if prev is None:
        print("No previous release found — nothing to alias.")
        return
    prev_assets = {a["name"] for a in prev["assets"]}
    print(f"Previous release: {prev['tag_name']} ({len(prev_assets)} assets)")

    catalog = json.loads((ROOT / "output" / "catalog.json").read_text())
    to_alias, skipped_unreleased, missing_new = [], [], []
    for v in catalog["variants"]:
        old = v.get("old_filename")
        if not old or old == v["filename"]:
            continue
        if old not in prev_assets:
            skipped_unreleased.append(old)
            continue
        if not (ROOT / "output" / v["filename"]).exists():
            missing_new.append(v["filename"])
            continue
        to_alias.append((v["filename"], old))

    if missing_new:
        sys.exit(f"ERROR: built EPUBs missing for {len(missing_new)} aliased "
                 f"variants: {missing_new[:5]}")
    print(f"Aliasing {len(to_alias)} previously-released names; "
          f"skipping {len(skipped_unreleased)} never-released old names.")
    for name in skipped_unreleased:
        print(f"  skip (not in {prev['tag_name']}): {name}")

    with tempfile.TemporaryDirectory() as td:
        for new, old in to_alias:
            staged = Path(td) / old
            shutil.copyfile(ROOT / "output" / new, staged)
            subprocess.run(
                ["gh", "release", "upload", tag, str(staged), "--clobber"],
                check=True)
            print(f"  aliased: {old} <- {new}")
    print(f"Done: {len(to_alias)} aliases uploaded to {tag}.")


if __name__ == "__main__":
    main()
