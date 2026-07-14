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

from ..models import Ayah, Footnote, Mushaf, Surah, Word
from .cache import cache_get, cache_set, get_cache_dir
from .indopak_pages import load_indopak_page_map
from .qul_api import fetch_qul_tafsir, fetch_qul_translation

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

# IndoPak word-level text carries invisible control junk (ZWSP/FEFF/
# LRM/RLM, odd spaces) around pause-position words. Only THAT is removed —
# all visible orthography stays (waqf marks, sajdah, PUA glyph pieces:
# they render in the Nastaleeq font exactly as in the verse-text books;
# owner decision 2026-07-10: word stacks keep every symbol).
# KEEP IN SYNC with the copy in tools/build_dictionary.py (dict synonym
# headwords must match these rendered forms byte-for-byte).
_INDOPAK_WORD_JUNK_RE = re.compile(r"[\u200B-\u200F\uFEFF]+")
_INDOPAK_WORD_SPACE_RE = re.compile(r"[\s\u00A0]+")

# --- IndoPak WBW word derivation (2026-07-10 redesign) --------------------
# Word-level ``text_indopak`` is a DIFFERENT ENCODING from verse-level
# ``text_indopak_nastaleeq`` (Arabic yeh + E0xx PUA annotation pieces vs
# Farsi yeh + standard waqf codepoints + F5xx/F6xx PUA) -- mixing them gave
# duplicated waqf marks, unrenderable E0xx pieces and dead dictionary
# lookups (docs/indopak_wbw_study.md). The Hafs WBW reference model has
# word text identical to the verse-text tokens byte-for-byte, so IndoPak
# WBW mirrors that: word DISPLAY text is derived by tokenizing the verse
# body (after the ayah-marker split), and word-level data supplies only
# gloss + transliteration by position. Corpus-verified 6,236/6,236
# (scripts/dev_checks/check_indopak_wbw_zip.py).

# Any Arabic base letter -> the token is a real word.
_INDOPAK_LETTER_RE = re.compile(
    r"[\u0621-\u064A\u066E-\u066F\u0671-\u06D5\u06EE-\u06FF\u0750-\u077F]"
)
# Whole words rendered as single PUA ligature glyphs (printed red in
# IndoPak mushafs): U+F658 = walyatalattaf (18:19), U+F666 = thuluthay
# (73:20). The only two corpus-wide; other bare-PUA standalone tokens
# (U+F64A 2:10, U+F653 7:196) are waqf glyphs and must fold like marks.
_INDOPAK_WORD_GLYPHS = frozenset({"\uF658", "\uF666"})
# The 5 ayahs where the word-level API joins two verse tokens into one
# gloss word: {(surah, ayah): 1-based folded-token index} -- that token
# and its successor form one stack (Hafs precedent: one stack for
# "ba'da maa").
_INDOPAK_API_JOINS = {
    (2, 181): 3,   # ba'da maa
    (8, 6): 4,     # ba'da maa
    (13, 37): 8,   # ba'da maa
    (37, 130): 3,  # il yaseen
    (72, 16): 1,   # wa-an law
}


def _indopak_word_texts(
    body: str, n_words: int, surah: int, ayah: int
) -> list[str] | None:
    """Derive WBW word display texts from the IndoPak verse body.

    Tokenizes on spaces; standalone waqf-mark tokens fold onto the
    preceding word rebased on NBSP (same no-break glue the ayah-marker
    mechanism uses -- the marks are combining chars whose base in verse
    text is the preceding space). Returns None when the result doesn't
    align with the API word count, so callers can fall back safely.
    """
    words: list[str] = []
    for tok in body.split():
        if _INDOPAK_LETTER_RE.search(tok) or tok in _INDOPAK_WORD_GLYPHS:
            words.append(tok)
        elif words:
            words[-1] += "\u00A0" + tok
        else:
            return None  # leading mark token -- unexpected, bail out
    join_at = _INDOPAK_API_JOINS.get((surah, ayah))
    if join_at is not None and join_at < len(words):
        words[join_at - 1 : join_at + 1] = [
            words[join_at - 1] + " " + words[join_at]
        ]
    return words if len(words) == n_words else None


# Translation footnote pattern: <sup foot_note=NNNNNN>N</sup>
# Accept optional quotes around the attribute value and optional whitespace.
_FOOTNOTE_PATTERN = re.compile(r'<sup\s+foot_note=["\']?(\d+)["\']?\s*>(\d+)</sup>')


# IndoPak trailing ayah-marker cluster: the source ends each ayah with
# " <waqf marks><PUA glyph(s)>" -- the small-high waqf marks (U+06DF, U+06D9,
# ...) are COMBINING marks whose base character is that space, and the final
# PUA codepoint (U+F500 + n - 1) is the Nastaleeq font's built-in ornate ayah
# number. The cluster is heterogeneous (byte-verified against cached
# text_indopak_nastaleeq for all 6,236 ayahs, 2026-07-06; 213 ayahs failed
# the original narrow class): many ayahs encode
# waqf marks as PUA codepoints (2:8 ends U+06DF U+06D8 U+F652 U+F507), odd
# singletons carry vowel signs or small letters (18:1 has U+065A, 88:17-20
# U+06E5), and 22:77 places a combining mark AFTER the last PUA. Hence:
# generous mark classes on both sides of a required PUA char, anchored to
# "space ... end". Still safe: no standard Arabic letter is in any class, so
# the match can never eat into a real word, and PUA only occurs in clusters.
_INDOPAK_MARKER_RE = re.compile(
    r" ([\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED\uE000-\uF8FF]*"
    r"[\uE000-\uF8FF]"
    r"[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED]*)$"
)


def _split_indopak_marker(text: str) -> tuple[str, str]:
    """Split the trailing ayah-marker cluster off IndoPak ayah text.

    Returns (body, marker). The marker's combining waqf marks are re-based
    onto a NO-BREAK SPACE so they render identically inside their own
    element (<a>/<span>): the NBSP simultaneously provides the visual gap
    after the last word AND forbids a line break between word and marker
    (invariants 1/2/4/5 in docs/production_push_2026-07.md Wave 5 -- a
    marker may never start a line; the gap must not stretch under justify).
    Falls back to (text, "") when the tail doesn't match, so unexpected
    input renders exactly as before rather than corrupting.
    """
    m = _INDOPAK_MARKER_RE.search(text)
    if not m:
        return text, ""
    # Gap tuning (single point): NBSP on BOTH sides for symmetric gaps
    # (device-verified 2026-07-05: thin space after rendered visibly
    # narrower than the NBSP before). NBSP before = combining-mark base +
    # no-break glue; NBSP after stays inside the anchor, and the break
    # AFTER the marker survives because the template's trailing ZWSP
    # allows a break after itself (UAX14 LB8) even though NBSP-ZWSP
    # itself can't break (LB12).
    return text[: m.start()], "\u00A0" + m.group(1) + "\u00A0"


# PUA codepoints have DEFAULT bidi class L (left-to-right): in the RTL flow
# any two PUA glyphs separated only by weak/neutral characters (space, NBSP,
# combining marks, ZWSP/WJ) fuse into a single LTR run and visually reorder
# (UAX#9). Reported by AzIAmDev in issue #15: 53:27 rendered with the ayah
# medallion INSIDE al-untha, whose final letters are the PUA ligature U+F664.
# Corpus scan 2026-07-14: 9 ayahs flip their own medallion into their last
# word (4:157, 37:45, 53:21/27/37/45, 75:39, 80:3, 92:3); 20 more fuse with
# the PREVIOUS ayah's medallion across the boundary in continuous flow
# (verse-initial U+F61F etc.). Fix: isolate each MAXIMAL RUN of PUA glyphs
# in one dir="rtl" span. Markup-only on purpose -- the text bytes stay
# identical, preserving StarDict headword / selection-lookup byte-matching
# (the RLM alternative would break that contract).
#
# Run granularity matters (regression caught by AzIAmDev, 2026-07-14):
# ADJACENT PUA glyphs must stay together in ONE span = one text node = one
# shaping run. 224 runs corpus-wide hold pairs like annotation-stack +
# medallion (32:27: U+F64E ruku/quarter stack + U+F51A medallion) or
# invisible-spacer + waqf glyph inside words (80:3): the font positions
# the first glyph onto/around the second during shaping, and splitting
# them into separate spans detaches the zero-width annotation, leaving it
# floating over unrelated following text. Their byte order inside one
# LTR-resolving run is exactly what the font expects -- do NOT "fix" the
# apparent reordering inside a run. The span also carries the run's
# TRAILING combining marks so mark+base stay in one text node (22:77
# places marks after the last PUA; no run has marks BETWEEN PUA glyphs,
# corpus-verified). Mechanism A/B-tested in the emulator against 53:27,
# 104:1-2, 2:8 and 32:27 (2026-07-14): dir="rtl" spans fix the fusion
# classes; RLM also works but mutates bytes; display:inline-block on the
# marker still breaks gap symmetry, so the plain-inline .ayah-mark ruling
# stands.
_INDOPAK_PUA_RUN_RE = re.compile(
    r"[\uE000-\uF8FF]+"
    r"[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED]*"
)


def _bidi_armor_indopak(text: str) -> str:
    """Isolate each maximal PUA glyph run (+ trailing marks) in one span."""
    return _INDOPAK_PUA_RUN_RE.sub(
        lambda m: f'<span dir="rtl">{m.group(0)}</span>', text
    )


# IndoPak mushaf convention overlines the word(s) of prostration in the 15
# sajdah loci (14 recitation sajdahs + the Shafi'i sajdah at 22:77). The
# overlined WORDS sometimes sit an ayah before the QUL sajdah_number flag
# (16:49 vs 16:50, 17:107 vs 109, 27:25 vs 26, 41:37 vs 38): the flag marks
# the recitation stop, the overline marks the prostration phrase. The
# Nastaleeq font does not embed overlines, so the phrases are styled via
# .sajdah spans (base.css.j2). Phrase selection contributed by AzIAmDev
# (issue #15); substrings below are byte-exact slices of our verse bodies
# (their EPUB was NFC-normalized, so their bytes differ -- do not copy).
_INDOPAK_SAJDAH_PHRASES = {
    (7, 206): "\u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0646\u064E",
    (13, 15): "\u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F",
    (16, 49): "\u0648\u064E\u0644\u0650\u0644\u0651\u0670\u0647\u0650 \u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F",
    (17, 107): "\u06CC\u064E\u062E\u0650\u0631\u0651\u064F\u0648\u0652\u0646\u064E \u0644\u0650\u0644\u0652\u0627\u064E\u0630\u0652\u0642\u064E\u0627\u0646\u0650 \u0633\u064F\u062C\u0651\u064E\u062F\u064B\u0627",
    (19, 58): "\u0633\u064F\u062C\u0651\u064E\u062F\u064B\u0627 \u0648\u0651\u064E\u0628\u064F\u0643\u0650\u06CC\u0651\u064B\u0627",
    (22, 18): "\u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F",
    (22, 77): "\u0648\u064E\u0627\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0627",
    (25, 60): "\u0627\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0627",
    (27, 25): "\u0627\u064E\u0644\u0651\u064E\u0627 \u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0627 \u0644\u0650\u0644\u0651\u0670\u0647\u0650",
    (32, 15): "\u062E\u064E\u0631\u0651\u064F\u0648\u0652\u0627 \u0633\u064F\u062C\u0651\u064E\u062F\u064B\u0627",
    (38, 24): "\u0648\u064E\u062E\u064E\u0631\u0651\u064E \u0631\u064E\u0627\u0643\u0650\u0639\u064B\u0627",
    (41, 37): "\u0648\u064E\u0627\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0627 \u0644\u0650\u0644\u0651\u0670\u0647\u0650",
    (53, 62): "\u0641\u064E\u0627\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0627",
    (84, 21): "\u0644\u064E\u0627 \u06CC\u064E\u0633\u0652\u062C\u064F\u062F\u064F\u0648\u0652\u0646\u064E",
    (96, 19): "\u0648\u064E\u0627\u0633\u0652\u062C\u064F\u062F\u0652",
}


def _wrap_indopak_sajdah(text: str, surah: int, ayah: int) -> str:
    """Wrap the prostration phrase in a .sajdah span (overline styling).

    Must run on the CLEAN verse body, before _bidi_armor_indopak (the
    phrases are stored as byte-exact body substrings). Falls back to the
    unchanged text with a warning if the source bytes ever drift.
    """
    phrase = _INDOPAK_SAJDAH_PHRASES.get((surah, ayah))
    if phrase is None:
        return text
    if text.count(phrase) != 1:
        click.echo(
            f"  WARNING: sajdah phrase not found (or ambiguous) in "
            f"{surah}:{ayah}; overline skipped"
        )
        return text
    return text.replace(phrase, f'<span class="sajdah">{phrase}</span>')


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


def _fetch_words(
    client: httpx.Client,
    chapter_number: int,
    language: str,
    total_verses: int,
    script: str = "qpc_uthmani_hafs",
) -> tuple[dict[int, list[dict]], bool]:
    """Fetch word-level data (WBW glosses + transliteration) for a chapter.

    Returns ({verse_number: [word_dicts]}, from_cache).
    Each word_dict has: position, text, translation, transliteration.

    The word text field is chosen to match the configured script encoding:
    QPC scripts use ``text_qpc_hafs``; IndoPak scripts use ``text_indopak``
    (the only word-level IndoPak field — no word-level ``_nastaleeq``
    exists; the Nastaleeq font covers its codepoints incl. the QPC-style
    U+06E1 sukun, cmap-verified 2026-07-10); others use ``text_uthmani``.
    """
    # QPC scripts need text_qpc_hafs at word level (different codepoints for
    # sukun, maddah etc. that the KFGQPC font expects).
    is_qpc = script.startswith("qpc_") or script.startswith("text_qpc_")
    if script.startswith("text_indopak"):
        word_text_field = "text_indopak"
    elif is_qpc:
        word_text_field = "text_qpc_hafs"
    else:
        word_text_field = "text_uthmani"

    cache_key = f"quran_api_words_{word_text_field}_{language}_ch{chapter_number}"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    all_verses = []
    page = 1
    per_page = 50
    max_pages = (total_verses // per_page) + 2

    while len(all_verses) < total_verses:
        if page > max_pages:
            break
        resp = _api_get(
            client, f"{BASE_URL}/verses/by_chapter/{chapter_number}",
            params={
                "language": language,
                "words": "true",
                "word_fields": word_text_field,
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

    # Group words by verse number
    result = {}
    for v in all_verses:
        verse_num = v["verse_number"]
        words = []
        for w in v.get("words", []):
            if w.get("char_type_name") == "word":
                wtext = w.get(word_text_field, w.get("text", ""))
                if word_text_field == "text_indopak":
                    wtext = _INDOPAK_WORD_JUNK_RE.sub("", wtext)
                    wtext = _INDOPAK_WORD_SPACE_RE.sub(" ", wtext).strip()
                # QPC embeds rub al-hizb (۞) in the first word of hizb
                # boundary ayahs — strip it since we render hizb markers
                # separately with a different font.
                if is_qpc:
                    wtext = _RUB_ALHIZB.sub("", wtext)
                trans_obj = w.get("translation") or {}
                trans_text = trans_obj.get("text", "") if isinstance(trans_obj, dict) else ""
                translit_obj = w.get("transliteration") or {}
                translit_text = translit_obj.get("text", "") if isinstance(translit_obj, dict) else ""
                # Quran.com API returns literal "<null>" for missing glosses
                # in some languages (e.g. Dari/Farsi).
                if not trans_text or trans_text == "<null>":
                    trans_text = ""
                if not translit_text or translit_text == "<null>":
                    translit_text = ""
                words.append({
                    "position": w["position"],
                    "text": wtext,
                    "translation": trans_text,
                    "transliteration": translit_text,
                })
        result[verse_num] = words

    cache_set(cache_key, result)
    return result, False


def _fetch_qcf_words(
    client: httpx.Client,
    chapter_number: int,
    total_verses: int,
    code_field: str = "code_v2",
) -> tuple[dict[int, list[dict]], bool]:
    """Fetch QCF glyph word data for a chapter.

    Returns ({verse_number: [word_dicts]}, from_cache).
    Each word_dict has: position, code (glyph string), page_number, text_uthmani.
    """
    cache_key = f"quran_api_qcf_{code_field}_ch{chapter_number}_v2"
    cached = cache_get(cache_key)
    if cached:
        return cached, True

    all_verses = []
    page = 1
    per_page = 50
    max_pages = (total_verses // per_page) + 2

    while len(all_verses) < total_verses:
        if page > max_pages:
            break
        resp = _api_get(
            client, f"{BASE_URL}/verses/by_chapter/{chapter_number}",
            params={
                "language": "en",
                "words": "true",
                "word_fields": f"{code_field},page_number,line_number,text_uthmani",
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

    result = {}
    for v in all_verses:
        verse_num = v["verse_number"]
        words = []
        for w in v.get("words", []):
            char_type = w.get("char_type_name", "word")
            if char_type in ("word", "end"):
                words.append({
                    "position": w["position"],
                    "code": w.get(code_field, w.get("text", "")),
                    "page_number": w.get("page_number", 1),
                    "line_number": w.get("line_number"),
                    "text_uthmani": w.get("text_uthmani", ""),
                    "char_type": char_type,
                })
        result[verse_num] = words

    cache_set(cache_key, result)
    return result, False


def load_quran_qcf(
    script: str = "qcf_v4_tajweed",
    translation_id: int | None = None,
    translation_language: str | None = None,
    translation_source: str = "quran_api",
    translation_edition: str = "",
) -> Mushaf:
    """Load Quran with QCF glyph word data for per-page font rendering.

    Each ayah contains Word objects with code_v2 (glyph string) and
    page_number (for font-family selection). The ayah text field contains
    the concatenated glyph codes for the full ayah.
    """
    code_field = "code_v1" if "v1" in script else "code_v2"

    with httpx.Client(timeout=30) as client:
        cache_dir = get_cache_dir()
        click.echo(f"Loading QCF Quran data (cache: {cache_dir})")
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

            qcf_data, from_cache = _fetch_qcf_words(
                client, ch_num, ch["verses_count"], code_field=code_field
            )
            if from_cache:
                cached_count += 1
            else:
                fetched_count += 1
                click.echo(f"  Fetched QCF surah {ch_num}/114: {ch_name}")

            # Fetch verse-level data for page_number/juz/hizb metadata
            raw_verses, _ = _fetch_verses(client, ch_num, "qpc_uthmani_hafs", ch["verses_count"])

            # Fetch translation if requested
            trans_data = None
            trans_from_cache = True
            if translation_source == "local" and translation_edition:
                trans_data, trans_from_cache = _load_local_translation(ch_num, translation_edition)
            elif translation_source == "fawazahmed0" and translation_edition:
                trans_data, trans_from_cache = _fetch_fawazahmed0_translation(
                    client, ch_num, translation_edition
                )
            elif translation_source == "qul" and translation_id is not None:
                trans_data, trans_from_cache = fetch_qul_translation(
                    client, ch_num, translation_id, ch["verses_count"]
                )
            elif translation_source == "qul_tafsir" and translation_id is not None:
                trans_data, trans_from_cache = fetch_qul_tafsir(
                    client, ch_num, translation_id, ch["verses_count"]
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
                verse_num = v["verse_number"]
                has_hizb = "\u06DE" in v.get("qpc_uthmani_hafs", "")

                translation = None
                footnotes = []
                if trans_data and i < len(trans_data):
                    td = trans_data[i]
                    translation, footnotes = _process_translation_text(
                        td["text"], td.get("foot_notes", {}), ch_num
                    )

                # Build Word objects from QCF data
                words = []
                verse_words = qcf_data.get(verse_num, qcf_data.get(str(verse_num), []))
                for wd in verse_words:
                    code = wd["code"]
                    text = wd["text_uthmani"]
                    # Strip font's rub al-hizb glyph from position 1 of hizb-boundary ayahs.
                    # The API bakes it as an extra glyph: "ﱨ ﱩ" (rub + space + word).
                    # We render our own hizb marker from Scheherazade instead.
                    if has_hizb and wd["position"] == 1 and " " in code:
                        code = code.split(" ", 1)[1]
                        text = text.lstrip("\u06DE").lstrip()
                    words.append(Word(
                        position=wd["position"],
                        text=text,
                        code_v2=code,
                        page_number=wd["page_number"],
                        line_number=wd.get("line_number"),
                        char_type=wd.get("char_type", "word"),
                    ))

                # Ayah text = concatenated glyph codes (for fallback display)
                ayah_text = " ".join(wd["code"] for wd in verse_words)

                ayahs.append(Ayah(
                    surah_number=ch_num,
                    ayah_number=verse_num,
                    text=ayah_text,
                    page_number=v.get("page_number"),
                    juz_number=v.get("juz_number"),
                    hizb_quarter=v.get("rub_el_hizb_number"),
                    sajdah=v.get("sajdah_number") is not None,
                    hizb_marker=has_hizb,
                    translation=translation,
                    footnotes=footnotes,
                    words=words,
                ))

            surahs.append(Surah(
                number=ch_num,
                name_arabic=ch["name_arabic"],
                name_transliteration=ch["name_simple"],
                name_translation=_dedup_translated_name(
                    _sanitize_api_html(translated_names.get(str(ch_num), "")),
                    ch["name_simple"],
                ),
                revelation_type=ch["revelation_place"],
                ayah_count=ch["verses_count"],
                ayahs=ayahs,
            ))

        if fetched_count:
            click.echo(f"  QCF: {cached_count} cached, {fetched_count} fetched from API")
        else:
            click.echo(f"  QCF: all {cached_count} surahs loaded from cache")
        if trans_fetched:
            click.echo(f"  Translation: {trans_cached} cached, {trans_fetched} fetched from API")
        elif trans_cached:
            click.echo(f"  Translation: all {trans_cached} surahs loaded from cache")

    # QCF doesn't have a simple bismillah text — it's composed of glyph codes
    # from the first ayah's words. Store the uthmani bismillah for metadata.
    bismillah = surahs[0].ayahs[0].text

    return Mushaf(
        surahs=surahs,
        script=script,
        bismillah_text=bismillah,
        metadata={
            "source": "quran.com",
            "api_version": "v4",
            "qcf_version": code_field,
        },
    )


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


def _dedup_translated_name(translation: str, transliteration: str) -> str:
    """Return empty string if the translated name is redundant with the transliteration."""
    def _norm(s: str) -> str:
        return s.lower().replace("-", "").replace("'", "").replace("\u2019", "")
    if _norm(translation) == _norm(transliteration):
        return ""
    return translation


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

    # Fix upstream data corruption: some translations (e.g. Maududi en)
    # have U+FFFD replacement characters where em-dashes should be.
    text = text.replace('\ufffd', '\u2014')
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
    wbw_language: str | None = None,
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
            "local", "qul", or "qul_tafsir"). "qul" fetches translations from
            QUL API, "qul_tafsir" fetches tafsirs (e.g. Al-Mukhtasar).
        translation_edition: Edition key for fawazahmed0 CDN or local cache
            (e.g. "eng-mustafakhattaba" or "clearquran").
        wbw_language: Optional ISO language code for word-by-word glosses
            (e.g. "en"). When provided, fetches per-word translation and
            transliteration for each ayah.

    Returns:
        A Mushaf containing all 114 surahs.
    """
    if script not in SCRIPT_FIELDS:
        raise ValueError(
            f"Unknown script '{script}'. Available: {', '.join(sorted(SCRIPT_FIELDS))}"
        )

    is_qpc = script.startswith("qpc_") or script.startswith("text_qpc_")

    # The API's page_number is always the Madinah-604 grid (its `mushaf`
    # param is ignored) — wrong for IndoPak books. Override from the QUL
    # 15-line layout map (fails loud if the tracked map is missing).
    indopak_pages = None
    if script.startswith("text_indopak"):
        indopak_pages = load_indopak_page_map()

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
            elif translation_source == "qul" and translation_id is not None:
                trans_data, trans_from_cache = fetch_qul_translation(
                    client, ch_num, translation_id, ch["verses_count"]
                )
            elif translation_source == "qul_tafsir" and translation_id is not None:
                trans_data, trans_from_cache = fetch_qul_tafsir(
                    client, ch_num, translation_id, ch["verses_count"]
                )
            elif translation_id is not None:
                trans_data, trans_from_cache = _fetch_translation(client, ch_num, translation_id)

            if trans_data is not None:
                if trans_from_cache:
                    trans_cached += 1
                else:
                    trans_fetched += 1

            # Fetch word-by-word data if requested
            words_data: dict[int, list[dict]] | None = None
            if wbw_language:
                words_data, wbw_from_cache = _fetch_words(
                    client, ch_num, wbw_language, ch["verses_count"],
                    script=script,
                )
                if not wbw_from_cache:
                    click.echo(f"  Fetched WBW words for surah {ch_num}/114: {ch_name}")

            ayahs = []
            for i, v in enumerate(raw_verses):
                text = v.get(script, "")
                has_hizb = "\u06DE" in text
                if is_qpc:
                    text = _strip_qpc_markers(text)
                ayah_marker = ""
                if script.startswith("text_indopak"):
                    text, ayah_marker = _split_indopak_marker(text)

                translation = None
                footnotes = []
                if trans_data and i < len(trans_data):
                    td = trans_data[i]
                    translation, footnotes = _process_translation_text(
                        td["text"], td.get("foot_notes", {}), ch_num
                    )

                # Build Word objects from WBW data
                # Cache stores keys as strings (JSON serialization)
                words = []
                if words_data:
                    verse_num = v["verse_number"]
                    wlist = words_data.get(verse_num, words_data.get(str(verse_num), []))
                    # IndoPak: word DISPLAY text comes from the verse body
                    # tokens (identical rendering/selection/lookup to the
                    # verse-text books); word-level data only supplies the
                    # gloss + transliteration. See _indopak_word_texts.
                    verse_texts = None
                    if script.startswith("text_indopak") and wlist:
                        verse_texts = _indopak_word_texts(
                            text, len(wlist), ch_num, verse_num
                        )
                        if verse_texts is None:
                            click.echo(
                                f"  WARNING: {ch_num}:{verse_num} verse-token"
                                " alignment failed; using word-level text"
                            )
                    for j, wd in enumerate(wlist):
                        word_text = (
                            verse_texts[j] if verse_texts
                            else wd.get("text", wd.get("text_uthmani", ""))
                        )
                        if script.startswith("text_indopak"):
                            # display-only markup; dict headwords are
                            # derived separately from the clean tokens
                            word_text = _bidi_armor_indopak(word_text)
                        words.append(Word(
                            position=wd["position"],
                            text=word_text,
                            translation=wd.get("translation", ""),
                            transliteration=wd.get("transliteration", ""),
                        ))

                if script.startswith("text_indopak"):
                    # order matters: sajdah phrases are byte-exact CLEAN-body
                    # substrings, so wrap them first, then bidi-armor the
                    # PUA glyphs (armor only touches PUA runs, never markup)
                    text = _wrap_indopak_sajdah(
                        text, ch_num, v["verse_number"]
                    )
                    text = _bidi_armor_indopak(text)
                    ayah_marker = _bidi_armor_indopak(ayah_marker)

                ayahs.append(Ayah(
                    surah_number=ch_num,
                    ayah_number=v["verse_number"],
                    text=text,
                    # Madinah 1405 AH grid, except IndoPak scripts which get
                    # the 15-line Qudratullah pages (see indopak_pages).
                    page_number=(
                        indopak_pages[(ch_num, v["verse_number"])]
                        if indopak_pages else v.get("page_number")
                    ),
                    juz_number=v.get("juz_number"),
                    hizb_quarter=v.get("rub_el_hizb_number"),
                    sajdah=v.get("sajdah_number") is not None,
                    hizb_marker=has_hizb,
                    ayah_marker=ayah_marker,
                    translation=translation,
                    footnotes=footnotes,
                    words=words,
                ))

            surahs.append(Surah(
                number=ch_num,
                name_arabic=ch["name_arabic"],
                name_transliteration=ch["name_simple"],
                name_translation=_dedup_translated_name(
                    _sanitize_api_html(translated_names.get(str(ch_num), "")),
                    ch["name_simple"],
                ),
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
