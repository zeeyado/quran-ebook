"""Quran.com API v4 data loader.

Fetches Quran text from api.quran.com with support for multiple script
encodings including qpc_uthmani_hafs (the recommended script for use with
the KFGQPC Uthmanic Hafs font).

No authentication required for the v4 API.
"""

import html
import json
import re
import time
from pathlib import Path

import click
import httpx

from ..models import Ayah, Footnote, Mushaf, Surah
from .cache import cache_get, cache_set, get_cache_dir

BASE_URL = "https://api.quran.com/api/v4"

MAX_RETRIES = 3
RETRY_DELAY = 5  # seconds


def _api_get(client: httpx.Client, url: str, **kwargs) -> httpx.Response:
    """HTTP GET with retry on transient failures."""
    for attempt in range(MAX_RETRIES):
        try:
            resp = client.get(url, **kwargs)
            resp.raise_for_status()
            return resp
        except httpx.TimeoutException as e:
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_DELAY * (attempt + 1)
                click.echo(f"  Retry {attempt + 1}/{MAX_RETRIES} after timeout, waiting {wait}s...")
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

# Available script fields from the API
SCRIPT_FIELDS = {
    "qpc_uthmani_hafs",
    "text_qpc_hafs",
    "text_uthmani",
    "text_uthmani_simple",
    "text_uthmani_tajweed",
    "text_imlaei",
    "text_imlaei_simple",
    "text_indopak",
    "text_indopak_nastaleeq",
    "text_qpc_nastaleeq",
    "text_qpc_nastaleeq_hafs",
}

# QPC scripts append ayah numbers inline as NBSP + Arabic-Indic digits.
# We strip these since we render ayah numbers ourselves.
# Note: 2:72 uses a regular space (API data anomaly), so we accept either.
_QPC_TRAILING_NUMBER = re.compile(r"[\xa0 ][\u0660-\u0669]+$")

# QPC text embeds rub al-hizb marker (۞ U+06DE) at the start of hizb
# boundary ayahs, followed by NBSP. We strip this structural marker since
# it's not part of the Quran text and we handle hizb info via metadata.
_RUB_ALHIZB = re.compile(r"\u06DE\xa0?")

# Translation footnote pattern: <sup foot_note=NNNNNN>N</sup>
# Accept optional quotes around the attribute value and optional whitespace.
_FOOTNOTE_PATTERN = re.compile(r'<sup\s+foot_note=["\']?(\d+)["\']?\s*>(\d+)</sup>')


def _strip_qpc_markers(text: str) -> str:
    """Remove inline QPC markers (trailing ayah numbers, rub al-hizb).

    Note: sajdah sign (۩ U+06E9) is left in the text — the main font
    renders it correctly, so no stripping/re-adding needed.
    A hair space (U+200A) is added after ۩ to separate it from the ayah number marker.
    """
    text = _QPC_TRAILING_NUMBER.sub("", text)
    text = _RUB_ALHIZB.sub("", text)
    # Add hair space after sajdah sign for minimal separation from ayah marker
    text = text.replace("\u06E9", "\u06E9\u200A")
    return text


def _fetch_languages(client: httpx.Client) -> list[dict]:
    """Fetch all language metadata (iso_code, native_name, direction)."""
    cache_key = "quran_api_languages"
    cached = cache_get(cache_key)
    if cached:
        return cached

    resp = _api_get(client, f"{BASE_URL}/resources/languages")
    languages = resp.json()["languages"]
    cache_set(cache_key, languages)
    return languages


# API direction metadata is incorrect for some languages.
_DIRECTION_OVERRIDES: dict[str, str] = {
    "ku": "rtl",  # Sorani Kurdish uses Arabic script; API incorrectly says ltr
}


def get_language_direction(lang_code: str) -> str:
    """Look up text direction for a language from the API.

    Fetches and caches the languages list from Quran.com API.
    Returns "rtl" or "ltr". Defaults to "ltr" if language not found.
    """
    if lang_code in _DIRECTION_OVERRIDES:
        return _DIRECTION_OVERRIDES[lang_code]
    with httpx.Client(timeout=30) as client:
        languages = _fetch_languages(client)
    for lang in languages:
        if lang.get("iso_code") == lang_code:
            return lang.get("direction", "ltr")
    return "ltr"


def _fetch_chapters(client: httpx.Client) -> list[dict]:
    """Fetch all 114 chapter metadata."""
    cache_key = "quran_api_chapters"
    cached = cache_get(cache_key)
    if cached:
        return cached

    resp = _api_get(client, f"{BASE_URL}/chapters")
    chapters = resp.json()["chapters"]
    cache_set(cache_key, chapters)
    return chapters


_SURAH_NAMES_DIR = Path(__file__).parent / "surah_names"


def _load_static_surah_names(language: str) -> dict[str, str] | None:
    """Load static surah names from bundled JSON if available.

    Returns a dict mapping chapter number (as string) -> translated name,
    or None if no static file exists for this language.
    """
    path = _SURAH_NAMES_DIR / f"{language}.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return None


def _fetch_translated_names(client: httpx.Client, language: str) -> dict[str, str]:
    """Fetch translated surah names (meanings) for a given language.

    Returns a dict mapping chapter number (as string) -> translated name
    (e.g. {"2": "The Cow", "3": "Family of Imran"}).
    Keys are strings because JSON serialization converts int keys to strings.

    Checks for bundled static names first (for languages not on the
    Quran.com API, e.g. Fulfulde from quranenc.com). Falls back to the
    API, but detects English fallback for non-English languages and
    returns an empty dict rather than leaking English names.
    """
    # Check for bundled static names first
    static = _load_static_surah_names(language)
    if static is not None:
        return static

    cache_key = f"quran_api_chapter_names_{language}"
    cached = cache_get(cache_key)
    if cached:
        return cached

    resp = _api_get(client, f"{BASE_URL}/chapters", params={"language": language})
    chapters = resp.json()["chapters"]

    # Detect English fallback: API returns English names for unsupported languages
    if language != "en" and chapters:
        returned_lang = (
            chapters[0].get("translated_name", {}).get("language_name", "").lower()
        )
        if returned_lang == "english":
            cache_set(cache_key, {})
            return {}

    names = {
        str(ch["id"]): ch.get("translated_name", {}).get("name", "")
        for ch in chapters
    }
    cache_set(cache_key, names)
    return names


def _fetch_verses(
    client: httpx.Client,
    chapter_number: int,
    script: str,
    total_verses: int,
) -> tuple[list[dict], bool]:
    """Fetch all verses for a chapter, handling pagination.

    Returns (verses, from_cache).
    """
    cache_key = f"quran_api_ch{chapter_number}_{script}"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    all_verses = []
    page = 1
    per_page = 50  # API maximum
    max_pages = (total_verses // per_page) + 2  # Safety limit

    while len(all_verses) < total_verses:
        if page > max_pages:
            raise RuntimeError(
                f"Chapter {chapter_number}: pagination exceeded {max_pages} pages "
                f"(got {len(all_verses)}/{total_verses} verses)"
            )
        resp = _api_get(
            client, f"{BASE_URL}/verses/by_chapter/{chapter_number}",
            params={
                "language": "en",
                "words": "false",
                "fields": script,
                "per_page": str(per_page),
                "page": str(page),
            },
        )
        data = resp.json()
        all_verses.extend(data["verses"])

        pagination = data.get("pagination", {})
        if pagination.get("next_page") is None:
            break
        page += 1

    cache_set(cache_key, all_verses)
    return all_verses, False


def _fetch_translation(
    client: httpx.Client,
    chapter_number: int,
    resource_id: int,
) -> tuple[list[dict], bool]:
    """Fetch translation with footnote text for a chapter.

    Uses the dedicated /quran/translations endpoint which returns footnote
    text inline, avoiding per-footnote API calls.

    Returns (verses, from_cache).
    """
    cache_key = f"quran_api_trans{resource_id}_ch{chapter_number}"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    resp = _api_get(
        client, f"{BASE_URL}/quran/translations/{resource_id}",
        params={"chapter_number": str(chapter_number), "foot_notes": "true"},
    )
    data = resp.json()
    translations = data.get("translations", [])

    result = []
    for t in translations:
        result.append({
            "text": t.get("text", ""),
            "foot_notes": t.get("foot_notes", {}),
        })

    cache_set(cache_key, result)
    return result, False


FAWAZAHMED0_CDN = "https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions"


def _fetch_fawazahmed0_translation(
    client: httpx.Client,
    chapter_number: int,
    edition: str,
) -> tuple[list[dict], bool]:
    """Fetch translation from fawazahmed0/quran-api CDN.

    Returns (verses, from_cache).
    """
    cache_key = f"fawazahmed0_{edition}_ch{chapter_number}"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    resp = _api_get(client, f"{FAWAZAHMED0_CDN}/{edition}/{chapter_number}.json")
    data = resp.json()

    result = []
    for verse in data.get("chapter", []):
        result.append({
            "text": verse.get("text", ""),
            "foot_notes": {},
        })

    cache_set(cache_key, result)
    return result, False


def _load_local_translation(chapter_number: int, edition: str) -> tuple[list[dict], bool]:
    """Load pre-extracted translation from bundled data or cache.

    Checks bundled data in data/{edition}/ first (committed to repo),
    then falls back to cache (written by tools/extract_clear_quran.py).
    Returns (verses, from_cache). Local/bundled data counts as cached.
    """
    # Check bundled data first
    bundled = Path(__file__).resolve().parent.parent.parent.parent / "data" / edition / f"{chapter_number}.json"
    if bundled.exists():
        return json.loads(bundled.read_text()), True

    # Fall back to cache
    cache_key = f"local_{edition}_ch{chapter_number}"
    cached = cache_get(cache_key, ttl_days=365000)
    if cached is None:
        raise FileNotFoundError(
            f"No local translation data for '{edition}' chapter {chapter_number}. "
            f"Run: python tools/extract_clear_quran.py"
        )
    return cached, True


def _sanitize_api_html(text: str) -> str:
    """Strip all HTML tags and escape for valid XHTML.

    The Quran.com API returns translation/footnote text with inconsistent HTML:
    <a class=f> wrappers, <p>, <br>, <div class="urdu">, bare & characters, etc.
    Some translations (e.g. Uyghur) also use <angle brackets> around non-Latin
    words as clarification markers.
    This function produces clean plain text safe for embedding in XHTML.
    """
    text = re.sub(r'</?[a-zA-Z][^>]*>', '', text)
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;').replace('>', '&gt;')
    return text


def _process_translation_text(
    text: str,
    foot_notes: dict[str, str],
    surah_number: int,
) -> tuple[str, list[Footnote]]:
    """Process translation text: replace footnote markers with EPUB3 noterefs.

    Args:
        text: Raw translation HTML with <sup foot_note=ID>N</sup> tags.
        foot_notes: Mapping of footnote_id -> footnote_text from the API.
        surah_number: Surah number (for generating unique footnote IDs).

    Returns:
        (processed_text, footnotes_list)
        - processed_text: Translation with <sup> replaced by EPUB3 noteref links
        - footnotes_list: List of Footnote objects for endnote rendering
    """
    footnotes = []

    def _replace_footnote(match):
        fn_id = match.group(1)
        fn_num = match.group(2)
        fn_text = foot_notes.get(fn_id, foot_notes.get(str(fn_id), ""))
        fn_text = _sanitize_api_html(fn_text)
        footnotes.append(Footnote(id=int(fn_id), number=int(fn_num), text=fn_text))
        return (
            f'<a epub:type="noteref" href="endnotes.xhtml#fn-{fn_id}" class="noteref">'
            f'{fn_num}</a>'
        )

    # Strip non-footnote HTML tags, keep <sup foot_note=...>...</sup> for replacement.
    text = re.sub(r'<(?!/?sup[\s>])/?[a-zA-Z][^>]*>', '', text)
    # Save footnote <sup> tags as placeholders before escaping.
    saved_sups: list[str] = []
    def _save_sup(m: re.Match) -> str:
        saved_sups.append(m.group(0))
        return f'\x00FN{len(saved_sups) - 1}\x00'
    text = _FOOTNOTE_PATTERN.sub(_save_sup, text)
    # Escape all XML special characters (bare &, stray < and >).
    # Some translations (e.g. Uyghur) use <angle brackets> around non-Latin words.
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;')
    text = text.replace('>', '&gt;')
    # Restore footnote <sup> tags and replace with EPUB3 noterefs.
    for i, sup in enumerate(saved_sups):
        text = text.replace(f'\x00FN{i}\x00', sup)
    processed = _FOOTNOTE_PATTERN.sub(_replace_footnote, text)
    return processed, footnotes


def load_quran(
    script: str = "qpc_uthmani_hafs",
    translation_id: int | None = None,
    translation_language: str | None = None,
    translation_source: str = "quran_api",
    translation_edition: str = "",
) -> Mushaf:
    """Load the complete Quran from the Quran.com API.

    Args:
        script: Which text encoding to fetch. Recommended: "qpc_uthmani_hafs"
            for use with the KFGQPC Uthmanic Hafs font.
        translation_id: Optional translation resource ID (e.g. 20 for
            Sahih International). When provided, each ayah includes
            translated text with footnotes.
        translation_language: Optional ISO language code (e.g. "en").
            When provided, fetches translated surah names (meanings)
            for use in bilingual headers and TOC.
        translation_source: Translation data source ("quran_api", "fawazahmed0",
            or "local" for pre-extracted translations from tools/).
        translation_edition: Edition key for fawazahmed0 CDN or local cache
            (e.g. "eng-mustafakhattaba" or "clearquran").

    Returns:
        A Mushaf containing all 114 surahs.
    """
    if script not in SCRIPT_FIELDS:
        raise ValueError(
            f"Unknown script '{script}'. Available: {', '.join(sorted(SCRIPT_FIELDS))}"
        )

    is_qpc = script.startswith("qpc_") or script.startswith("text_qpc_")

    with httpx.Client(timeout=30) as client:
        cache_dir = get_cache_dir()
        click.echo(f"Loading Quran data (cache: {cache_dir})")
        chapters = _fetch_chapters(client)

        translated_names: dict[str, str] = {}
        if translation_language:
            translated_names = _fetch_translated_names(client, translation_language)

        cached_count = 0
        fetched_count = 0
        trans_cached = 0
        trans_fetched = 0
        surahs = []
        for ch in chapters:
            ch_num = ch["id"]
            ch_name = ch["name_simple"]

            raw_verses, from_cache = _fetch_verses(client, ch_num, script, ch["verses_count"])
            if from_cache:
                cached_count += 1
            else:
                fetched_count += 1
                click.echo(f"  Fetched surah {ch_num}/114: {ch_name}")

            # Fetch translation if requested
            trans_data = None
            trans_from_cache = True
            if translation_source == "local" and translation_edition:
                trans_data, trans_from_cache = _load_local_translation(ch_num, translation_edition)
            elif translation_source == "fawazahmed0" and translation_edition:
                trans_data, trans_from_cache = _fetch_fawazahmed0_translation(
                    client, ch_num, translation_edition
                )
            elif translation_id is not None:
                trans_data, trans_from_cache = _fetch_translation(client, ch_num, translation_id)

            if trans_data is not None:
                if trans_from_cache:
                    trans_cached += 1
                else:
                    trans_fetched += 1

            ayahs = []
            for i, v in enumerate(raw_verses):
                text = v.get(script, "")
                has_hizb = "\u06DE" in text
                if is_qpc:
                    text = _strip_qpc_markers(text)

                translation = None
                footnotes = []
                if trans_data and i < len(trans_data):
                    td = trans_data[i]
                    translation, footnotes = _process_translation_text(
                        td["text"], td.get("foot_notes", {}), ch_num
                    )

                ayahs.append(Ayah(
                    surah_number=ch_num,
                    ayah_number=v["verse_number"],
                    text=text,
                    page_number=v.get("page_number"),  # V1 (1405 AH) page mapping
                    juz_number=v.get("juz_number"),
                    hizb_quarter=v.get("rub_el_hizb_number"),
                    sajdah=v.get("sajdah_number") is not None,
                    hizb_marker=has_hizb,
                    translation=translation,
                    footnotes=footnotes,
                ))

            surahs.append(Surah(
                number=ch_num,
                name_arabic=ch["name_arabic"],
                name_transliteration=ch["name_simple"],
                name_translation=_sanitize_api_html(translated_names.get(str(ch_num), "")),
                revelation_type=ch["revelation_place"],
                ayah_count=ch["verses_count"],
                ayahs=ayahs,
            ))

        if fetched_count:
            click.echo(f"  Arabic: {cached_count} cached, {fetched_count} fetched from API")
        else:
            click.echo(f"  Arabic: all {cached_count} surahs loaded from cache")
        if trans_fetched:
            click.echo(f"  Translation: {trans_cached} cached, {trans_fetched} fetched from API")
        elif trans_cached:
            click.echo(f"  Translation: all {trans_cached} surahs loaded from cache")

    # Al-Fatiha ayah 1 IS the basmala, in the correct script encoding.
    # Use it for all other surahs' bismillah to ensure font compatibility.
    bismillah = surahs[0].ayahs[0].text

    return Mushaf(
        surahs=surahs,
        script=script,
        bismillah_text=bismillah,
        metadata={
            "source": "quran.com",
            "api_version": "v4",
        },
    )
