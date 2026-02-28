"""Simple file-based cache for downloaded data."""

import json
import time
from pathlib import Path

DEFAULT_CACHE_DIR = Path.home() / ".cache" / "quran-ebook"
DEFAULT_TTL_DAYS = 30


def get_cache_dir() -> Path:
    """Get or create the cache directory."""
    cache_dir = DEFAULT_CACHE_DIR
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def cache_get(key: str, ttl_days: int = DEFAULT_TTL_DAYS) -> dict | None:
    """Read a cached JSON value if it exists and hasn't expired."""
    cache_file = get_cache_dir() / f"{key}.json"
    if not cache_file.exists():
        return None

    data = json.loads(cache_file.read_text(encoding="utf-8"))
    cached_at = data.get("_cached_at", 0)
    if time.time() - cached_at > ttl_days * 86400:
        return None

    return data.get("value")


def cache_set(key: str, value: dict) -> None:
    """Write a value to the cache."""
    cache_file = get_cache_dir() / f"{key}.json"
    data = {"_cached_at": time.time(), "value": value}
    cache_file.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def cache_clear() -> int:
    """Remove all cached files. Returns count of files removed."""
    cache_dir = get_cache_dir()
    count = 0
    for f in cache_dir.glob("*.json"):
        f.unlink()
        count += 1
    return count
