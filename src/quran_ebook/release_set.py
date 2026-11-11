"""The release set: the configs that a release builds and publishes.

``release_set.txt`` at the repo root holds one config path per line,
relative to the repo root, with forward slashes. Blank lines and lines
that start with ``#`` are ignored. Every other config under ``configs/``
still builds on request; it is just not published.

Stdlib only: the release scripts import this module before any dependency
is installed.
"""

import csv
from pathlib import Path

DEFAULT_NAME = "release_set.txt"
# Old name -> new name for every config that existed when the file names
# changed (one row per config: config, old_filename, new_filename).
RENAME_TABLE = Path("data") / "filename_map_v1.csv"
# The files that the previous release (v0.10.0) published, by their old names.
RELEASED_BEFORE = Path("data") / "released_v0.10.0.txt"


def read_release_set(path: str | Path) -> list[str]:
    """The config paths listed in ``path``, in file order, as written."""
    entries = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    return entries


def release_set_problems(entries: list[str], root: str | Path) -> list[str]:
    """What is wrong with a release set: one line per problem, empty if fine."""
    root = Path(root)
    problems = []
    if not entries:
        problems.append("the release set is empty")
    seen = set()
    for entry in entries:
        if entry in seen:
            problems.append(f"listed twice: {entry}")
            continue
        seen.add(entry)
        path = Path(entry)
        if (path.is_absolute() or ".." in path.parts or "\\" in entry
                or path.parts[:1] != ("configs",) or path.suffix != ".yaml"):
            problems.append(f"not a config path under configs/: {entry}")
        elif not (root / path).is_file():
            problems.append(f"no such config: {entry}")
    return problems


def load_release_set(path: str | Path, root: str | Path) -> list[Path]:
    """Read and check a release set; return the config files, sorted.

    Raises ValueError that lists every problem.
    """
    entries = read_release_set(path)
    problems = release_set_problems(entries, root)
    if problems:
        raise ValueError(f"{path}: " + "; ".join(problems))
    return sorted(Path(root) / entry for entry in entries)


def published_before(root: str | Path) -> dict[str, tuple[str, str]]:
    """config path -> (old file name, new file name), for every book that
    the previous release published.

    The frozen rename table knows the old name of every config that existed
    when the names changed; the list of the previous release's files says
    which of those were really published. Only such a book has an old name.

    Raises ValueError when a published name is missing from the table or
    belongs to two configs.
    """
    root = Path(root)
    released = set(read_release_set(root / RELEASED_BEFORE))
    table: dict[str, tuple[str, str]] = {}
    with open(root / RENAME_TABLE, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            old = row["old_filename"].strip() + ".epub"
            if old in released:
                table[row["config"].strip()] = (old, row["new_filename"].strip() + ".epub")
    found = [old for old, _ in table.values()]
    missing = sorted(released - set(found))
    twice = sorted({old for old in found if found.count(old) > 1})
    if missing or twice:
        raise ValueError(
            f"{RENAME_TABLE}: {len(missing)} published names missing {missing[:3]}, "
            f"{len(twice)} listed for two configs {twice[:3]}"
        )
    return table
