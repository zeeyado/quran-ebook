"""Simple file-based cache for downloaded data.

Cache lives in .cache/ at the project root (gitignored).

TTL is only enforced locally — when a cache entry expires, the user is
prompted interactively (once per data category) to re-fetch or keep using
the existing data.  In non-interactive contexts the stale data is reused
silently, and ``quran-ebook build --cached`` / ``--fresh`` preset the
decision process-wide (reuse / refetch) so full-matrix builds run
unattended.  Production CI builds run without a pre-populated cache, so
they always fetch fresh data on the first call and reuse it within the run.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

import click

# Project root: src/quran_ebook/data/cache.py → 4 levels up
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
DEFAULT_CACHE_DIR = _PROJECT_ROOT / ".cache"
DEFAULT_TTL_DAYS = 30


class OfflineCacheMiss(RuntimeError):
    """Raised in offline mode when a required cache entry is absent."""

# Strip the _chNN chapter component (anywhere in the key) to group cache
# keys into categories for prompting — keys carry the chapter both at the
# end ("quran_api_trans234_ch5") and mid-key ("quran_api_ch1_text_indopak"),
# and per-chapter categories meant 114 prompts per build.
_CATEGORY_RE = re.compile(r"_ch\d+(?=_|$)")

# Tracks user decisions per category within a single process.
# True = re-fetch (return None for stale), False = use stale data.
_stale_decisions: dict[str, bool] = {}

# Process-wide stale policy: "ask" (interactive prompt per category),
# "reuse" (keep stale data, never prompt — unattended builds),
# "refetch" (re-fetch every stale entry, never prompt — drift refresh),
# "offline" (reuse regardless of age; a cache MISS raises OfflineCacheMiss —
# snapshot-pinned builds must never silently reach the network).
_stale_policy: str = "ask"


def set_stale_policy(policy: str) -> None:
    """Set the process-wide stale-cache policy (CLI --cached / --fresh / --offline)."""
    if policy not in ("ask", "reuse", "refetch", "offline"):
        raise ValueError(f"unknown stale policy: {policy!r}")
    global _stale_policy
    _stale_policy = policy


def get_stale_policy() -> str:
    """Current process-wide stale-cache policy."""
    return _stale_policy


def get_cache_dir() -> Path:
    """Get or create the cache directory (QURAN_EBOOK_CACHE_DIR overrides)."""
    cache_dir = Path(os.environ.get("QURAN_EBOOK_CACHE_DIR") or DEFAULT_CACHE_DIR)
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def _cache_category(key: str) -> str:
    """Derive a category from a cache key for grouped staleness prompts."""
    return _CATEGORY_RE.sub("", key)


def _is_interactive() -> bool:
    """Check if stdin is a TTY (not piped or in CI)."""
    return hasattr(sys.stdin, "isatty") and sys.stdin.isatty()


def _prompt_stale(key: str, age_days: int) -> bool:
    """Prompt user about stale cache. Returns True to re-fetch, False to reuse.

    Only prompts once per category. Non-interactive defaults to reuse.
    """
    if _stale_policy != "ask":
        return _stale_policy == "refetch"

    category = _cache_category(key)
    if category in _stale_decisions:
        return _stale_decisions[category]

    if not _is_interactive():
        _stale_decisions[category] = False
        return False

    label = category.replace("_", " ").replace("quran api", "Quran API")
    answer = click.prompt(
        f"  {label} cache is {age_days} days old. Re-fetch?",
        type=click.Choice(["y", "N"], case_sensitive=False),
        default="N",
        show_default=True,
    )
    refetch = answer.lower() == "y"
    _stale_decisions[category] = refetch
    return refetch


def cache_get(key: str, ttl_days: int = DEFAULT_TTL_DAYS) -> dict | None:
    """Read a cached JSON value if it exists and hasn't expired.

    When the TTL has elapsed, prompts the user (once per data category)
    to re-fetch or reuse the stale data.  Old cache files are never
    deleted — they are only overwritten by a successful ``cache_set``.
    """
    cache_file = get_cache_dir() / f"{key}.json"
    if not cache_file.exists():
        if _stale_policy == "offline":
            raise OfflineCacheMiss(
                f"offline build: no cache entry for '{key}' — the data snapshot "
                f"is incomplete (refresh it, or build without --offline)"
            )
        return None

    try:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        if _stale_policy == "offline":
            raise OfflineCacheMiss(
                f"offline build: cache entry for '{key}' is corrupt — re-unpack "
                f"the data snapshot"
            )
        cache_file.unlink(missing_ok=True)
        return None

    cached_at = data.get("_cached_at", 0)
    age_seconds = time.time() - cached_at
    if age_seconds > ttl_days * 86400:
        age_days = int(age_seconds / 86400)
        if _prompt_stale(key, age_days):
            return None  # caller will re-fetch; old file stays until cache_set
        # user chose to keep stale data
        return data.get("value")

    return data.get("value")


def cache_set(key: str, value: dict) -> None:
    """Write a value to the cache.

    Writes to a temporary file first, then renames — so a failed fetch
    never corrupts the existing cache entry.
    """
    cache_dir = get_cache_dir()
    cache_file = cache_dir / f"{key}.json"
    tmp_file = cache_dir / f"{key}.json.tmp"
    payload = json.dumps({"_cached_at": time.time(), "value": value}, ensure_ascii=False)
    tmp_file.write_text(payload, encoding="utf-8")
    tmp_file.rename(cache_file)


def cache_clear() -> int:
    """Remove all cached files. Returns count of files removed."""
    cache_dir = get_cache_dir()
    count = 0
    for f in cache_dir.glob("*.json"):
        f.unlink()
        count += 1
    return count
