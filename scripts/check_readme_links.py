#!/usr/bin/env python3
"""Check that download links follow the release that is about to go out.

A link of the form  releases/latest/download/<file>  follows the latest
release. From the moment a release is public, every such link must name a
file of that release, or it is dead. The files of a release are the books
of the release set, the word dictionary, catalog.json and
renamed-files.csv.

Checked: README.md and RELEASE_NOTES.md (or the files given). For the
README it also checks that BOOKS.md, the table of every book, is linked.

The release workflow runs this on a release tag. It does not run on a
release candidate: the README changes over to the new books together with
the release itself.

Usage:
    python scripts/check_readme_links.py [--set release_set.txt] [FILE ...]
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "src"))

from gen_catalog import build_catalog, config_paths_for  # noqa: E402
from quran_ebook.release_set import DEFAULT_NAME, word_dictionary  # noqa: E402

THIS_REPO = "zeeyado/quran-ebook"
DEFAULT_FILES = ["README.md", "RELEASE_NOTES.md"]
# An absolute link names its repo; a relative one (../../releases/...) is ours.
LINK = re.compile(
    r"(?:https://github\.com/([\w.-]+/[\w.-]+)/)?"
    r"releases/latest/download/([^\s)\"'<>#?]+)")


def release_files(set_file: str) -> set[str]:
    catalog, _missing = build_catalog(config_paths_for(set_file))
    names = {v["filename"] for v in catalog["variants"]}
    names |= {"catalog.json", "renamed-files.csv", word_dictionary(ROOT).name}
    return names


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", default=DEFAULT_FILES)
    ap.add_argument("--set", dest="set_file", default=DEFAULT_NAME)
    args = ap.parse_args()

    try:
        published = release_files(args.set_file)
    except ValueError as e:
        sys.exit(f"ERROR: {e}")

    failed = False
    for name in args.files:
        text = (ROOT / name).read_text(encoding="utf-8")
        links = [m.group(2) for m in LINK.finditer(text)
                 if m.group(1) in (None, THIS_REPO)]
        dead = sorted({link for link in links if link not in published})
        print(f"{name}: {len(links)} links to files of the latest release, "
              f"{len(dead)} of them to files this release does not publish")
        for link in dead[:10]:
            print(f"  - {link}")
        if len(dead) > 10:
            print(f"  ... and {len(dead) - 10} more")
        failed = failed or bool(dead)
        if name == "README.md" and not re.search(r"\]\((?:\./)?BOOKS\.md[)#]", text):
            print("  - README.md does not link BOOKS.md, the table of every book")
            failed = True
    if failed:
        print("FAIL: change these links (or the release set) before the release tag")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
