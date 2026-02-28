"""Quran.com API v4 data loader.

Fetches Quran text from api.quran.com with support for multiple script
encodings including qpc_uthmani_hafs (the recommended script for use with
the KFGQPC Uthmanic Hafs font).

No authentication required for the v4 API.
"""

import re

import click
import httpx

from ..models import Ayah, Footnote, Mushaf, Surah
from .cache import cache_get, cache_set

BASE_URL = "https://api.quran.com/api/v4"

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

    resp = client.get(f"{BASE_URL}/resources/languages")
    resp.raise_for_status()
    languages = resp.json()["languages"]
    cache_set(cache_key, languages)
    return languages


def get_language_direction(lang_code: str) -> str:
    """Look up text direction for a language from the API.

    Fetches and caches the languages list from Quran.com API.
    Returns "rtl" or "ltr". Defaults to "ltr" if language not found.
    """
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

    resp = client.get(f"{BASE_URL}/chapters")
    resp.raise_for_status()
    chapters = resp.json()["chapters"]
    cache_set(cache_key, chapters)
    return chapters


def _fetch_translated_names(client: httpx.Client, language: str) -> dict[str, str]:
    """Fetch translated surah names (meanings) for a given language.

    Returns a dict mapping chapter number (as string) -> translated name
    (e.g. {"2": "The Cow", "3": "Family of Imran"}).
    Keys are strings because JSON serialization converts int keys to strings.
    """
    cache_key = f"quran_api_chapter_names_{language}"
    cached = cache_get(cache_key)
    if cached:
        return cached

    resp = client.get(f"{BASE_URL}/chapters", params={"language": language})
    resp.raise_for_status()
    chapters = resp.json()["chapters"]
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
) -> list[dict]:
    """Fetch all verses for a chapter, handling pagination."""
    cache_key = f"quran_api_ch{chapter_number}_{script}"
    cached = cache_get(cache_key)
    if cached:
        return cached

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
        resp = client.get(
            f"{BASE_URL}/verses/by_chapter/{chapter_number}",
            params={
                "language": "en",
                "words": "false",
                "fields": script,
                "per_page": str(per_page),
                "page": str(page),
            },
        )
        resp.raise_for_status()
        data = resp.json()
        all_verses.extend(data["verses"])

        pagination = data.get("pagination", {})
        if pagination.get("next_page") is None:
            break
        page += 1

    cache_set(cache_key, all_verses)
    return all_verses


def _fetch_translation(
    client: httpx.Client,
    chapter_number: int,
    resource_id: int,
) -> list[dict]:
    """Fetch translation with footnote text for a chapter.

    Uses the dedicated /quran/translations endpoint which returns footnote
    text inline, avoiding per-footnote API calls.

    Returns a list of dicts, one per verse in order, each with:
        - text: translation text with <sup foot_note=...> tags
        - foot_notes: dict mapping footnote_id -> footnote_text
    """
    cache_key = f"quran_api_trans{resource_id}_ch{chapter_number}"
    cached = cache_get(cache_key)
    if cached:
        return cached

    resp = client.get(
        f"{BASE_URL}/quran/translations/{resource_id}",
        params={"chapter_number": str(chapter_number), "foot_notes": "true"},
    )
    resp.raise_for_status()
    data = resp.json()
    translations = data.get("translations", [])

    result = []
    for t in translations:
        result.append({
            "text": t.get("text", ""),
            "foot_notes": t.get("foot_notes", {}),
        })

    cache_set(cache_key, result)
    return result


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
        footnotes.append(Footnote(id=int(fn_id), number=int(fn_num), text=fn_text))
        return (
            f'<a epub:type="noteref" href="endnotes.xhtml#fn-{fn_id}" class="noteref">'
            f'{fn_num}</a>'
        )

    processed = _FOOTNOTE_PATTERN.sub(_replace_footnote, text)
    return processed, footnotes


def load_quran(
    script: str = "qpc_uthmani_hafs",
    translation_id: int | None = None,
    translation_language: str | None = None,
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

    Returns:
        A Mushaf containing all 114 surahs.
    """
    if script not in SCRIPT_FIELDS:
        raise ValueError(
            f"Unknown script '{script}'. Available: {', '.join(sorted(SCRIPT_FIELDS))}"
        )

    is_qpc = script.startswith("qpc_") or script.startswith("text_qpc_")

    with httpx.Client(timeout=30) as client:
        click.echo("Fetching chapter metadata from quran.com...")
        chapters = _fetch_chapters(client)

        translated_names: dict[str, str] = {}
        if translation_language:
            translated_names = _fetch_translated_names(client, translation_language)

        surahs = []
        for ch in chapters:
            ch_num = ch["id"]
            ch_name = ch["name_simple"]
            click.echo(f"  Fetching surah {ch_num}/114: {ch_name}...")

            raw_verses = _fetch_verses(client, ch_num, script, ch["verses_count"])

            # Fetch translation if requested
            trans_data = None
            if translation_id is not None:
                trans_data = _fetch_translation(client, ch_num, translation_id)

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
                name_translation=translated_names.get(str(ch_num), ""),
                revelation_type=ch["revelation_place"],
                ayah_count=ch["verses_count"],
                ayahs=ayahs,
            ))

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
