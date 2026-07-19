"""Data-snapshot layer — pin the exact upstream data a release is built from.

The reproducibility model (decided 2026-07-19): fetch-fresh-at-tag was the
hole, not the guarantee — upstream can drift between the local test build
and the tag push, so CI could ship content nobody ever proofed. Instead:

- ``snapshot make``   hashes every ``.cache/*.json`` entry's *value* (the
  ``_cached_at`` wrapper is excluded, so a re-fetch of identical data keeps
  an identical hash) into ``data/snapshot_manifest.json`` — committed to git,
  the trust root.
- ``snapshot pack``   tars ``.cache/`` into a tarball uploaded as an asset of
  the rolling ``data-snapshot`` PRE-release (never in git, never LFS).
- ``snapshot verify`` checks the local ``.cache`` against the committed
  manifest (CI runs it after unpacking the tarball; builds then run
  ``--offline`` so a miss is a hard failure, not a silent fetch).
- ``snapshot diff``   human-oriented drift report, grouped by data category.

Data refresh = deliberate event: ``build --fresh``, review ``snapshot diff``,
``snapshot make`` + commit, ``snapshot pack`` + re-upload.
"""

import hashlib
import json
import tarfile
import time
from pathlib import Path

from .cache import _cache_category, get_cache_dir

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
MANIFEST_PATH = _PROJECT_ROOT / "data" / "snapshot_manifest.json"
SNAPSHOT_NAME = "quran-data-snapshot.tar.gz"


def _hash_entry(cache_file: Path) -> dict | None:
    """Content hash of one cache entry's value; None if unparseable."""
    try:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    canonical = json.dumps(data.get("value"), ensure_ascii=False, sort_keys=True)
    return {
        "sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        "cached_at": int(data.get("_cached_at", 0)),
    }


def scan_cache(cache_dir: Path | None = None) -> tuple[dict[str, dict], list[str]]:
    """Hash every cache entry. Returns (entries, corrupt_keys)."""
    cache_dir = cache_dir or get_cache_dir()
    entries: dict[str, dict] = {}
    corrupt: list[str] = []
    for f in sorted(cache_dir.glob("*.json")):
        key = f.stem
        h = _hash_entry(f)
        if h is None:
            corrupt.append(key)
        else:
            entries[key] = h
    return entries, corrupt


def write_manifest(entries: dict[str, dict]) -> Path:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": int(time.time()),
        "count": len(entries),
        "entries": entries,
    }
    MANIFEST_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=0) + "\n",
        encoding="utf-8",
    )
    return MANIFEST_PATH


def load_manifest() -> dict[str, dict]:
    if not MANIFEST_PATH.exists():
        raise FileNotFoundError(
            f"no committed snapshot manifest at {MANIFEST_PATH} — run "
            f"`quran-ebook snapshot make` first"
        )
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))["entries"]


def compare(
    entries: dict[str, dict], manifest: dict[str, dict], only_cached: bool = False
) -> dict[str, list[str]]:
    """Compare local cache entries against the manifest.

    Returns {"changed": [...], "missing": [...], "extra": [...]} of keys.
    only_cached: restrict to keys present locally (drift-check fetches only
    a canary subset — absent keys are not drift there).
    """
    changed = [
        k for k, v in entries.items()
        if k in manifest and manifest[k]["sha256"] != v["sha256"]
    ]
    missing = [] if only_cached else [k for k in manifest if k not in entries]
    extra = [k for k in entries if k not in manifest]
    return {"changed": sorted(changed), "missing": sorted(missing), "extra": sorted(extra)}


def by_category(keys: list[str]) -> dict[str, int]:
    """Collapse a key list to {category: count} for readable reports."""
    counts: dict[str, int] = {}
    for k in keys:
        cat = _cache_category(k)
        counts[cat] = counts.get(cat, 0) + 1
    return counts


def pack(dest: Path, cache_dir: Path | None = None) -> Path:
    """Tar the cache (plus a manifest copy) into dest. Deterministic order."""
    cache_dir = cache_dir or get_cache_dir()
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(dest, "w:gz") as tar:
        for f in sorted(cache_dir.glob("*.json")):
            tar.add(f, arcname=f".cache/{f.name}")
        if MANIFEST_PATH.exists():
            tar.add(MANIFEST_PATH, arcname="snapshot_manifest.json")
    return dest
