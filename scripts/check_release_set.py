#!/usr/bin/env python3
"""Check release_set.txt, the list of books that a release publishes.

Fails (exit 1) when
- a line is not a config path under configs/, names a config that does not
  exist, or is listed twice;
- a book that release v0.10.0 published is missing from the set. Readers
  who follow releases/latest would lose that book without a word.

Prints the size of the set by folder. Stdlib only, so the release workflow
runs it in its first seconds, before anything is installed.

Usage:
    python scripts/check_release_set.py [release_set.txt]
"""

import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.release_set import (  # noqa: E402
    DEFAULT_NAME,
    published_before,
    read_release_set,
    release_set_problems,
)


def main() -> int:
    set_file = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / DEFAULT_NAME
    entries = read_release_set(set_file)
    problems = release_set_problems(entries, ROOT)

    try:
        before = published_before(ROOT)
    except ValueError as e:
        problems.append(str(e))
        before = {}
    listed = set(entries)
    lost = sorted(config for config in before if config not in listed)
    for config in lost:
        problems.append(
            f"published in v0.10.0 as {before[config][0]} but not in the set: {config}")

    by_folder = Counter(Path(e).parts[1] for e in entries if len(Path(e).parts) > 2)
    all_configs = sum(1 for _ in (ROOT / "configs").rglob("*.yaml"))
    print(f"{set_file.name}: {len(entries)} of {all_configs} configs")
    for folder, n in sorted(by_folder.items()):
        print(f"  {folder:22s} {n:4d}")
    print(f"  books of v0.10.0 still in the set: {len(before) - len(lost)} of {len(before)}")

    if problems:
        print(f"\nFAIL: {len(problems)} problem(s)")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
