#!/usr/bin/env python3
"""Build Quran surah overview dictionary (StarDict format).

114 entries — one per surah — with introductory text from the Quran.com API.
Keyed by transliteration (e.g. "Al-Baqarah") to match plugin surah glyph
long-press candidates.

Source: Quran.com API v4 `/chapters/{id}/info?language={lang}`
Available in: English (all 114), Urdu, Indonesian, and a few others.
Falls back to English when a language isn't available.

Usage:
    python tools/build_surah_overview.py                  # English (default)
    python tools/build_surah_overview.py --language ur     # Urdu
    python tools/build_surah_overview.py --language id     # Indonesian
    python tools/build_surah_overview.py --all             # all available languages
"""

import argparse
import json
import re
import struct
import time
from pathlib import Path

import httpx

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / ".cache" / "surah_info"
OUTPUT_BASE = PROJECT_ROOT / "output" / "surah_overview"

BASE_URL = "https://api.quran.com/api/v4"
MAX_RETRIES = 3
RETRY_DELAY = 5

# Surah names (name_simple from Quran.com API) — dictionary keys
SURAH_NAMES = {
    1: "Al-Fatihah", 2: "Al-Baqarah", 3: "Ali 'Imran", 4: "An-Nisa",
    5: "Al-Ma'idah", 6: "Al-An'am", 7: "Al-A'raf", 8: "Al-Anfal",
    9: "At-Tawbah", 10: "Yunus", 11: "Hud", 12: "Yusuf", 13: "Ar-Ra'd",
    14: "Ibrahim", 15: "Al-Hijr", 16: "An-Nahl", 17: "Al-Isra",
    18: "Al-Kahf", 19: "Maryam", 20: "Taha", 21: "Al-Anbya",
    22: "Al-Hajj", 23: "Al-Mu'minun", 24: "An-Nur", 25: "Al-Furqan",
    26: "Ash-Shu'ara", 27: "An-Naml", 28: "Al-Qasas", 29: "Al-'Ankabut",
    30: "Ar-Rum", 31: "Luqman", 32: "As-Sajdah", 33: "Al-Ahzab",
    34: "Saba", 35: "Fatir", 36: "Ya-Sin", 37: "As-Saffat",
    38: "Sad", 39: "Az-Zumar", 40: "Ghafir", 41: "Fussilat",
    42: "Ash-Shuraa", 43: "Az-Zukhruf", 44: "Ad-Dukhan", 45: "Al-Jathiyah",
    46: "Al-Ahqaf", 47: "Muhammad", 48: "Al-Fath", 49: "Al-Hujurat",
    50: "Qaf", 51: "Adh-Dhariyat", 52: "At-Tur", 53: "An-Najm",
    54: "Al-Qamar", 55: "Ar-Rahman", 56: "Al-Waqi'ah", 57: "Al-Hadid",
    58: "Al-Mujadila", 59: "Al-Hashr", 60: "Al-Mumtahanah",
    61: "As-Saf", 62: "Al-Jumu'ah", 63: "Al-Munafiqun", 64: "At-Taghabun",
    65: "At-Talaq", 66: "At-Tahrim", 67: "Al-Mulk", 68: "Al-Qalam",
    69: "Al-Haqqah", 70: "Al-Ma'arij", 71: "Nuh", 72: "Al-Jinn",
    73: "Al-Muzzammil", 74: "Al-Muddaththir", 75: "Al-Qiyamah",
    76: "Al-Insan", 77: "Al-Mursalat", 78: "An-Naba", 79: "An-Nazi'at",
    80: "'Abasa", 81: "At-Takwir", 82: "Al-Infitar", 83: "Al-Mutaffifin",
    84: "Al-Inshiqaq", 85: "Al-Buruj", 86: "At-Tariq", 87: "Al-A'la",
    88: "Al-Ghashiyah", 89: "Al-Fajr", 90: "Al-Balad", 91: "Ash-Shams",
    92: "Al-Layl", 93: "Ad-Duhaa", 94: "Ash-Sharh", 95: "At-Tin",
    96: "Al-'Alaq", 97: "Al-Qadr", 98: "Al-Bayyinah", 99: "Az-Zalzalah",
    100: "Al-'Adiyat", 101: "Al-Qari'ah", 102: "At-Takathur",
    103: "Al-'Asr", 104: "Al-Humazah", 105: "Al-Fil", 106: "Quraysh",
    107: "Al-Ma'un", 108: "Al-Kawthar", 109: "Al-Kafirun",
    110: "An-Nasr", 111: "Al-Masad", 112: "Al-Ikhlas", 113: "Al-Falaq",
    114: "An-Nas",
}

# Arabic surah names for display in entry headers
SURAH_NAMES_ARABIC = {
    1: "الفاتحة", 2: "البقرة", 3: "آل عمران", 4: "النساء",
    5: "المائدة", 6: "الأنعام", 7: "الأعراف", 8: "الأنفال",
    9: "التوبة", 10: "يونس", 11: "هود", 12: "يوسف", 13: "الرعد",
    14: "إبراهيم", 15: "الحجر", 16: "النحل", 17: "الإسراء",
    18: "الكهف", 19: "مريم", 20: "طه", 21: "الأنبياء",
    22: "الحج", 23: "المؤمنون", 24: "النور", 25: "الفرقان",
    26: "الشعراء", 27: "النمل", 28: "القصص", 29: "العنكبوت",
    30: "الروم", 31: "لقمان", 32: "السجدة", 33: "الأحزاب",
    34: "سبإ", 35: "فاطر", 36: "يس", 37: "الصافات",
    38: "ص", 39: "الزمر", 40: "غافر", 41: "فصلت",
    42: "الشورى", 43: "الزخرف", 44: "الدخان", 45: "الجاثية",
    46: "الأحقاف", 47: "محمد", 48: "الفتح", 49: "الحجرات",
    50: "ق", 51: "الذاريات", 52: "الطور", 53: "النجم",
    54: "القمر", 55: "الرحمن", 56: "الواقعة", 57: "الحديد",
    58: "المجادلة", 59: "الحشر", 60: "الممتحنة",
    61: "الصف", 62: "الجمعة", 63: "المنافقون", 64: "التغابن",
    65: "الطلاق", 66: "التحريم", 67: "الملك", 68: "القلم",
    69: "الحاقة", 70: "المعارج", 71: "نوح", 72: "الجن",
    73: "المزمل", 74: "المدثر", 75: "القيامة",
    76: "الإنسان", 77: "المرسلات", 78: "النبإ", 79: "النازعات",
    80: "عبس", 81: "التكوير", 82: "الانفطار", 83: "المطففين",
    84: "الانشقاق", 85: "البروج", 86: "الطارق", 87: "الأعلى",
    88: "الغاشية", 89: "الفجر", 90: "البلد", 91: "الشمس",
    92: "الليل", 93: "الضحى", 94: "الشرح", 95: "التين",
    96: "العلق", 97: "القدر", 98: "البينة", 99: "الزلزلة",
    100: "العاديات", 101: "القارعة", 102: "التكاثر",
    103: "العصر", 104: "الهمزة", 105: "الفيل", 106: "قريش",
    107: "الماعون", 108: "الكوثر", 109: "الكافرون",
    110: "النصر", 111: "المسد", 112: "الإخلاص", 113: "الفلق",
    114: "الناس",
}

# Languages known to have surah info content on the API.
# Others fall back to English — we detect that and skip.
KNOWN_LANGUAGES = {
    "en": "English",
    "ur": "Urdu",
    "id": "Indonesian",
    "ml": "Malayalam",
    "ta": "Tamil",
    "it": "Italian",
}


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

def _api_get(client: httpx.Client, url: str) -> httpx.Response:
    """HTTP GET with retry on transient failures."""
    for attempt in range(MAX_RETRIES):
        try:
            resp = client.get(url)
            resp.raise_for_status()
            return resp
        except (httpx.TimeoutException, httpx.HTTPStatusError) as e:
            is_server = isinstance(e, httpx.HTTPStatusError) and e.response.status_code < 500
            if is_server:
                raise
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_DELAY * (attempt + 1)
                print(f"  Retry {attempt + 1}/{MAX_RETRIES}, waiting {wait}s...")
                time.sleep(wait)
            else:
                raise


def fetch_surah_info(client: httpx.Client, chapter: int, language: str) -> dict | None:
    """Fetch surah info from API with file-based cache."""
    cache_file = CACHE_DIR / language / f"{chapter}.json"

    if cache_file.exists():
        return json.loads(cache_file.read_text(encoding="utf-8"))

    resp = _api_get(client, f"{BASE_URL}/chapters/{chapter}/info?language={language}")
    data = resp.json().get("chapter_info", {})

    # Detect English fallback — API returns language_name="english" when
    # the requested language isn't available.
    # Some languages (e.g. Italian) have language_name=null with real content — allow those.
    lang_name = data.get("language_name")
    if language != "en" and lang_name and lang_name.lower() == "english":
        return None

    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return data


# ---------------------------------------------------------------------------
# HTML processing
# ---------------------------------------------------------------------------

def clean_html(text: str) -> str:
    """Clean API HTML for StarDict display.

    KOReader's MuPDF dictionary renderer supports basic HTML.
    Keep structure (paragraphs, lists) but strip links, and convert
    headings to compact bold paragraphs (MuPDF renders h1-h3 with
    browser-default sizing which is disproportionately large in popups).
    """
    # Remove <a> tags but keep their text
    text = re.sub(r'<a\b[^>]*>(.*?)</a>', r'\1', text, flags=re.DOTALL)
    # Convert h1-h6 to compact bold paragraphs
    text = re.sub(
        r'<h[1-6][^>]*>(.*?)</h[1-6]>',
        r'<p style="margin:0.3em 0 0.1em"><b>\1</b></p>',
        text, flags=re.DOTALL | re.IGNORECASE,
    )
    # Normalize whitespace
    text = re.sub(r'\n\s*\n', '\n', text)
    return text.strip()


# ---------------------------------------------------------------------------
# StarDict output
# ---------------------------------------------------------------------------

def write_stardict(entries: list[tuple[str, str]], output_dir: Path,
                   name: str, bookname: str):
    """Write StarDict dictionary files (.ifo, .idx, .dict)."""
    output_dir.mkdir(parents=True, exist_ok=True)
    entries_sorted = sorted(entries, key=lambda e: e[0].encode("utf-8"))

    dict_data = bytearray()
    idx_data = bytearray()
    for key, definition in entries_sorted:
        key_bytes = key.encode("utf-8")
        def_bytes = definition.encode("utf-8")
        offset = len(dict_data)
        size = len(def_bytes)
        dict_data.extend(def_bytes)
        idx_data.extend(key_bytes + b"\x00")
        idx_data.extend(struct.pack(">II", offset, size))

    dict_path = output_dir / f"{name}.dict"
    idx_path = output_dir / f"{name}.idx"
    ifo_path = output_dir / f"{name}.ifo"

    dict_path.write_bytes(dict_data)
    idx_path.write_bytes(idx_data)
    ifo_path.write_text(
        f"StarDict's dict ifo file\n"
        f"version=2.4.2\n"
        f"wordcount={len(entries_sorted)}\n"
        f"idxfilesize={len(idx_data)}\n"
        f"bookname={bookname}\n"
        f"sametypesequence=h\n",
        encoding="utf-8",
    )

    print(f"\nBuilt {len(entries_sorted)} entries ({bookname}):")
    print(f"  {ifo_path}")
    print(f"  {idx_path} ({len(idx_data):,} bytes)")
    print(f"  {dict_path} ({len(dict_data):,} bytes)")


# ---------------------------------------------------------------------------
# Entry building
# ---------------------------------------------------------------------------

def build_entry_html(chapter: int, info: dict) -> str:
    """Build HTML content for a surah overview dictionary entry."""
    name_ar = SURAH_NAMES_ARABIC.get(chapter, "")
    name_en = SURAH_NAMES.get(chapter, f"Surah {chapter}")
    source = info.get("source", "")
    text = info.get("text", "")

    parts = []

    # Header: surah number + Arabic name + transliteration
    parts.append(
        f'<p style="text-align:center;font-size:130%">'
        f'<b>{chapter}. {name_ar} — {name_en}</b></p>'
    )

    # Full content (short_text omitted — always duplicated in text body)
    if text:
        parts.append(clean_html(text))

    # Source attribution
    if source:
        parts.append(f'<p style="color:#888;font-size:80%">— {source}</p>')

    return "\n".join(parts)


def build_entries(client: httpx.Client, language: str) -> list[tuple[str, str]]:
    """Fetch all 114 surahs and build dictionary entries."""
    entries = []
    skipped = []

    for ch in range(1, 115):
        info = fetch_surah_info(client, ch, language)
        if not info:
            skipped.append(ch)
            continue

        name = SURAH_NAMES.get(ch, f"Surah {ch}")
        html = build_entry_html(ch, info)
        entries.append((name, html))

    if skipped:
        print(f"  Skipped {len(skipped)} chapters (no data for language): {skipped}")

    return entries


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Build Quran surah overview dictionary")
    parser.add_argument("--language", "-l", default="en",
                        help="Language code (default: en). Use --all for all known languages.")
    parser.add_argument("--all", action="store_true",
                        help="Build for all known languages")
    args = parser.parse_args()

    languages = list(KNOWN_LANGUAGES.keys()) if args.all else [args.language]

    with httpx.Client(timeout=30.0) as client:
        for lang in languages:
            lang_name = KNOWN_LANGUAGES.get(lang, lang)
            print(f"\n{'='*60}")
            print(f"Building surah overview: {lang_name} ({lang})")
            print(f"{'='*60}")

            entries = build_entries(client, lang)
            print(f"Total entries: {len(entries)}")

            if not entries:
                print(f"  No entries — skipping {lang}")
                continue

            dict_name = f"quran_surah_overview_{lang}"
            bookname = f"Quran Surah Overview ({lang_name})"
            output_dir = OUTPUT_BASE / lang
            write_stardict(entries, output_dir, dict_name, bookname)


if __name__ == "__main__":
    main()
