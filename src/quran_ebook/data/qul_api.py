"""QUL (Quranic Universal Library) API data loader.

Fetches translations and tafsirs from qul.tarteel.ai. The QUL API
provides 193 translations and 114 tafsirs — a superset of Quran.com's
catalog, including Al-Mukhtasar (31 languages) and 94 QUL-exclusive
tafsirs.

No authentication required. Response format is similar to Quran.com v4.

See docs/qul_integration_plan.md for API details and resource IDs.
"""

import click
import httpx

from .cache import cache_get, cache_set

QUL_BASE_URL = "https://qul.tarteel.ai/api/v1"

MAX_RETRIES = 3
RETRY_DELAY = 5  # seconds


def _api_get(client: httpx.Client, url: str, **kwargs) -> httpx.Response:
    """HTTP GET with retry on transient failures."""
    import time

    for attempt in range(MAX_RETRIES):
        try:
            resp = client.get(url, **kwargs)
            resp.raise_for_status()
            return resp
        except httpx.TransportError:
            # TimeoutException subclasses TransportError; this also covers
            # connection resets, DNS failures, TLS hiccups (Wave 2 gap).
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_DELAY * (attempt + 1)
                click.echo(f"  Retry {attempt + 1}/{MAX_RETRIES} after network error, waiting {wait}s...")
                time.sleep(wait)
            else:
                raise
        except httpx.HTTPStatusError as e:
            if e.response.status_code >= 500 and attempt < MAX_RETRIES - 1:
                wait = RETRY_DELAY * (attempt + 1)
                click.echo(f"  Retry {attempt + 1}/{MAX_RETRIES} after HTTP {e.response.status_code}, waiting {wait}s...")
                time.sleep(wait)
            else:
                raise


def fetch_qul_translation(
    client: httpx.Client,
    chapter_number: int,
    resource_id: int,
    total_verses: int,
) -> tuple[list[dict], bool]:
    """Fetch translation from QUL API for a chapter.

    Uses /translations/{id}/by_range endpoint.
    Returns (verses, from_cache) matching the quran_api convention:
    each verse is {"text": "...", "foot_notes": {}}.
    """
    cache_key = f"qul_trans{resource_id}_ch{chapter_number}"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    resp = _api_get(
        client,
        f"{QUL_BASE_URL}/translations/{resource_id}/by_range",
        params={"from": f"{chapter_number}:1", "to": f"{chapter_number}:{total_verses}"},
    )
    data = resp.json()

    result = _parse_qul_response(data, total_verses)
    cache_set(cache_key, result)
    return result, False


def fetch_qul_tafsir(
    client: httpx.Client,
    chapter_number: int,
    resource_id: int,
    total_verses: int,
) -> tuple[list[dict], bool]:
    """Fetch tafsir from QUL API for a chapter.

    Uses /tafsirs/{id}/by_range endpoint. Handles grouped ayahs
    (some tafsir entries span multiple verses).
    Returns (verses, from_cache) matching the quran_api convention:
    each verse is {"text": "...", "foot_notes": {}, "group_start": int|None,
    "group_end": int|None} — group span present on every covered ayah so
    builders can emit one endnote per grouped entry.
    """
    # _g2: cache-key generation bump — older cached entries predate the
    # group_start/group_end fields and would silently rebuild ungrouped.
    cache_key = f"qul_tafsir{resource_id}_ch{chapter_number}_g2"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    resp = _api_get(
        client,
        f"{QUL_BASE_URL}/tafsirs/{resource_id}/by_range",
        params={"from": f"{chapter_number}:1", "to": f"{chapter_number}:{total_verses}"},
    )
    data = resp.json()

    result = _parse_qul_response(data, total_verses)
    cache_set(cache_key, result)
    return result, False


def _parse_qul_response(data: dict, total_verses: int) -> list[dict]:
    """Parse QUL API response into per-ayah list.

    QUL returns translations/tafsirs keyed by verse. Some entries
    (especially tafsirs) may span multiple ayahs via a 'verses' array.
    We expand grouped entries so every ayah has content, and keep the
    group span (group_start/group_end) on each covered ayah so builders
    can emit ONE endnote per grouped entry instead of duplicating it.

    Returns list of {"text": str, "foot_notes": dict, "group_start":
    int|None, "group_end": int|None} in ayah order.
    """
    # Build a dict mapping ayah_number -> entry
    ayah_entries: dict[int, dict] = {}

    # QUL response varies: may have "translations", "tafsirs", or top-level array
    items = (
        data.get("translations")
        or data.get("tafsirs")
        or data.get("results")
        or (data if isinstance(data, list) else [])
    )

    for item in items:
        text = item.get("text", "")

        # Determine which ayahs this entry covers
        verse_key = item.get("verse_key", "")  # e.g. "2:255"
        verses = item.get("verses", [])  # grouped ayahs

        if verses:
            covered = [a for a in (_ayah_from_key(vk) for vk in verses) if a]
        elif verse_key:
            a = _ayah_from_key(verse_key)
            covered = [a] if a else []
        else:
            covered = []
        if not covered:
            continue
        start, end = min(covered), max(covered)
        for ayah_num in covered:
            ayah_entries[ayah_num] = {
                "text": text,
                "foot_notes": {},
                "group_start": start,
                "group_end": end,
            }

    # Build ordered result list (one entry per ayah)
    result = []
    for i in range(1, total_verses + 1):
        result.append(ayah_entries.get(i) or {
            "text": "",
            "foot_notes": {},
            "group_start": None,
            "group_end": None,
        })

    return result


def _ayah_from_key(verse_key: str) -> int | None:
    """Extract ayah number from a verse key like '2:255'."""
    parts = verse_key.split(":")
    if len(parts) == 2:
        try:
            return int(parts[1])
        except ValueError:
            pass
    return None
