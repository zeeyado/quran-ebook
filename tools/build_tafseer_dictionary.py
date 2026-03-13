#!/usr/bin/env python3
"""Build Quran tafseer dictionaries (StarDict format).

Per-ayah entries with tafseer commentary from the Quran.com API.
Each tafsir becomes a separate StarDict dictionary.

Keyed by "Surah_Name N" (e.g. "Al-Baqarah 255") — same as grammar dictionary,
so the existing KOReader plugin picks these up automatically.

Some tafsirs (e.g. Ibn Kathir) group multiple ayahs under one commentary entry.
For grouped ayahs, all keys in the group point to the same content, with the
title showing the ayah range (e.g. "Al-Baqarah 6–7").

Source: Quran.com API v4 `/tafsirs/{id}/by_chapter/{chapter}`

Usage:
    python tools/build_tafseer_dictionary.py --tafsir muyassar
    python tools/build_tafseer_dictionary.py --tafsir ibn-kathir-en
    python tools/build_tafseer_dictionary.py --all
    python tools/build_tafseer_dictionary.py --list
"""

import argparse
import json
import re
import struct
import time
from pathlib import Path

import httpx

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / ".cache" / "tafseer"
OUTPUT_BASE = PROJECT_ROOT / "output" / "tafseer_dictionary"

BASE_URL = "https://api.quran.com/api/v4"
MAX_RETRIES = 3
RETRY_DELAY = 5
PER_PAGE = 50

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

# Quran ayah counts per surah (1-indexed)
SURAH_AYAH_COUNTS = [
    0,  # placeholder for 0-index
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,  # 1-10
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,   # 11-20
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,      # 21-30
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,        # 31-40
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,         # 41-50
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,         # 51-60
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,         # 61-70
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,         # 71-80
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,         # 81-90
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,              # 91-100
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,                  # 101-110
    5, 4, 5, 6,                                       # 111-114
]

# ---------------------------------------------------------------------------
# Tafsir registry
# ---------------------------------------------------------------------------

TAFSIR_REGISTRY = {
    # Arabic
    "muyassar": {
        "id": 16,
        "slug": "ar-tafsir-muyassar",
        "name": "Tafsir al-Muyassar",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_muyassar",
        "bookname": "Tafsir al-Muyassar (المیسر)",
    },
    "ibn-kathir-ar": {
        "id": 14,
        "slug": "ar-tafsir-ibn-kathir",
        "name": "Tafsir Ibn Kathir",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_ibn_kathir_ar",
        "bookname": "Tafsir Ibn Kathir (Arabic)",
    },
    "tabari": {
        "id": 15,
        "slug": "ar-tafsir-al-tabari",
        "name": "Tafsir al-Tabari",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_tabari",
        "bookname": "Tafsir al-Tabari (الطبري)",
    },
    "qurtubi": {
        "id": 90,
        "slug": "ar-tafseer-al-qurtubi",
        "name": "Tafsir al-Qurtubi",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_qurtubi",
        "bookname": "Tafsir al-Qurtubi (القرطبي)",
    },
    "saddi": {
        "id": 91,
        "slug": "ar-tafseer-al-saddi",
        "name": "Tafsir al-Sa'di",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_saddi",
        "bookname": "Tafsir al-Sa'di (السعدي)",
    },
    "baghawi": {
        "id": 94,
        "slug": "ar-tafsir-al-baghawi",
        "name": "Tafsir al-Baghawi",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_baghawi",
        "bookname": "Tafsir al-Baghawi (البغوي)",
    },
    "wasit": {
        "id": 93,
        "slug": "ar-tafsir-al-wasit",
        "name": "al-Tafsir al-Wasit",
        "language": "ar",
        "direction": "rtl",
        "dict_name": "quran_tafsir_wasit",
        "bookname": "al-Tafsir al-Wasit (Tantawi)",
    },
    # English
    "ibn-kathir-en": {
        "id": 169,
        "slug": "en-tafisr-ibn-kathir",
        "name": "Tafsir Ibn Kathir",
        "language": "en",
        "direction": "ltr",
        "dict_name": "quran_tafsir_ibn_kathir_en",
        "bookname": "Tafsir Ibn Kathir (English)",
    },
    "maariful-quran": {
        "id": 168,
        "slug": "en-tafsir-maarif-ul-quran",
        "name": "Ma'ariful Qur'an",
        "language": "en",
        "direction": "ltr",
        "dict_name": "quran_tafsir_maariful_quran",
        "bookname": "Ma'ariful Qur'an (Mufti Shafi)",
    },
    "tazkirul-quran-en": {
        "id": 817,
        "slug": "tazkirul-quran-en",
        "name": "Tazkirul Quran",
        "language": "en",
        "direction": "ltr",
        "dict_name": "quran_tafsir_tazkirul_quran_en",
        "bookname": "Tazkirul Quran (Wahiduddin Khan, English)",
    },
    # Urdu
    "ibn-kathir-ur": {
        "id": 160,
        "slug": "tafseer-ibn-e-kaseer-urdu",
        "name": "Tafsir Ibn Kathir",
        "language": "ur",
        "direction": "rtl",
        "dict_name": "quran_tafsir_ibn_kathir_ur",
        "bookname": "Tafsir Ibn Kathir (Urdu)",
    },
    "fi-zilal-ur": {
        "id": 157,
        "slug": "tafsir-fe-zalul-quran-syed-qatab",
        "name": "Fi Zilal al-Quran",
        "language": "ur",
        "direction": "rtl",
        "dict_name": "quran_tafsir_fi_zilal_ur",
        "bookname": "Fi Zilal al-Quran (Qutb, Urdu)",
    },
    "bayan-ul-quran": {
        "id": 159,
        "slug": "tafsir-bayan-ul-quran",
        "name": "Bayan ul Quran",
        "language": "ur",
        "direction": "rtl",
        "dict_name": "quran_tafsir_bayan_ul_quran",
        "bookname": "Bayan ul Quran (Israr Ahmad)",
    },
    "tazkir-ul-quran-ur": {
        "id": 818,
        "slug": "tazkiru-quran-ur",
        "name": "Tazkir ul Quran",
        "language": "ur",
        "direction": "rtl",
        "dict_name": "quran_tafsir_tazkir_ul_quran_ur",
        "bookname": "Tazkir ul Quran (Wahiduddin Khan, Urdu)",
    },
    # Bengali
    "ibn-kathir-bn": {
        "id": 164,
        "slug": "bn-tafseer-ibn-e-kaseer",
        "name": "Tafsir Ibn Kathir",
        "language": "bn",
        "direction": "ltr",
        "dict_name": "quran_tafsir_ibn_kathir_bn",
        "bookname": "Tafsir Ibn Kathir (Bengali)",
    },
    "ahsanul-bayaan": {
        "id": 165,
        "slug": "bn-tafsir-ahsanul-bayaan",
        "name": "Tafsir Ahsanul Bayaan",
        "language": "bn",
        "direction": "ltr",
        "dict_name": "quran_tafsir_ahsanul_bayaan",
        "bookname": "Tafsir Ahsanul Bayaan (Bengali)",
    },
    "abu-bakr-zakaria": {
        "id": 166,
        "slug": "bn-tafsir-abu-bakr-zakaria",
        "name": "Tafsir Abu Bakr Zakaria",
        "language": "bn",
        "direction": "ltr",
        "dict_name": "quran_tafsir_abu_bakr_zakaria",
        "bookname": "Tafsir Abu Bakr Zakaria (Bengali)",
    },
    "fathul-majid": {
        "id": 381,
        "slug": "tafisr-fathul-majid-bn",
        "name": "Tafsir Fathul Majid",
        "language": "bn",
        "direction": "ltr",
        "dict_name": "quran_tafsir_fathul_majid",
        "bookname": "Tafsir Fathul Majid (Bengali)",
    },
    # Russian
    "saddi-ru": {
        "id": 170,
        "slug": "ru-tafseer-al-saddi",
        "name": "Tafsir al-Sa'di",
        "language": "ru",
        "direction": "ltr",
        "dict_name": "quran_tafsir_saddi_ru",
        "bookname": "Tafsir al-Sa'di (Russian)",
    },
    # Kurdish
    "rebar": {
        "id": 804,
        "slug": "kurd-tafsir-rebar",
        "name": "Rebar Kurdish Tafsir",
        "language": "ku",
        "direction": "rtl",
        "dict_name": "quran_tafsir_rebar",
        "bookname": "Rebar Kurdish Tafsir",
    },
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
            is_client_error = isinstance(e, httpx.HTTPStatusError) and e.response.status_code < 500
            if is_client_error:
                raise
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_DELAY * (attempt + 1)
                print(f"  Retry {attempt + 1}/{MAX_RETRIES}, waiting {wait}s...")
                time.sleep(wait)
            else:
                raise


def fetch_chapter_tafsir(client: httpx.Client, tafsir_id: int,
                         chapter: int, cache_subdir: str) -> list[dict]:
    """Fetch all tafsir entries for a chapter, with file-based cache.

    Returns list of {verse_key, text} dicts for all ayahs in the chapter.
    Handles pagination (API max per_page=50).
    """
    cache_file = CACHE_DIR / cache_subdir / f"ch{chapter}.json"

    if cache_file.exists():
        return json.loads(cache_file.read_text(encoding="utf-8"))

    all_entries = []
    page = 1

    while True:
        url = f"{BASE_URL}/tafsirs/{tafsir_id}/by_chapter/{chapter}?per_page={PER_PAGE}&page={page}"
        resp = _api_get(client, url)
        data = resp.json()

        for entry in data.get("tafsirs", []):
            all_entries.append({
                "verse_key": entry["verse_key"],
                "text": entry.get("text", ""),
            })

        pagination = data.get("pagination", {})
        if pagination.get("next_page") is None:
            break
        page = pagination["next_page"]

    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(all_entries, ensure_ascii=False), encoding="utf-8")
    return all_entries


# ---------------------------------------------------------------------------
# HTML processing
# ---------------------------------------------------------------------------

# Inline style patterns to strip
_STYLE_RE = re.compile(r'\s*style="[^"]*"', flags=re.IGNORECASE)
# Class attributes to strip
_CLASS_RE = re.compile(r'\s*class="[^"]*"', flags=re.IGNORECASE)
# Empty tags after stripping
_EMPTY_TAG_RE = re.compile(r'<(\w+)>\s*</\1>')


def clean_tafsir_html(text: str) -> str:
    """Clean API tafsir HTML for StarDict display.

    KOReader's MuPDF dictionary renderer supports basic HTML.
    Keep structure (headings, paragraphs, divs) but strip inline styles,
    class attributes, and normalize.
    """
    if not text:
        return ""

    # Strip inline styles (color, font-size, etc.)
    text = _STYLE_RE.sub("", text)
    # Strip class attributes
    text = _CLASS_RE.sub("", text)
    # Remove <a> tags but keep their text
    text = re.sub(r'<a\b[^>]*>(.*?)</a>', r'\1', text, flags=re.DOTALL)
    # Remove <strong> wrapping (used for decorative PBUH markers etc.)
    text = re.sub(r'<strong>(.*?)</strong>', r'\1', text, flags=re.DOTALL)
    # Remove empty tags
    text = _EMPTY_TAG_RE.sub("", text)
    # Collapse excessive whitespace
    text = re.sub(r'\n\s*\n\s*\n', '\n\n', text)
    return text.strip()


# ---------------------------------------------------------------------------
# Ayah grouping detection
# ---------------------------------------------------------------------------

def detect_groups(entries: list[dict], total_ayahs: int) -> list[dict]:
    """Detect ayah groups from API entries.

    Returns a list of group dicts:
      {"start": int, "end": int, "text": str}

    Handles two grouping patterns:
    - Ibn Kathir style: all ayahs present, grouped ones have empty text
    - Muyassar style: grouped ayahs are simply omitted (verse_keys jump)

    For both patterns, the group extends from the entry's ayah up to (but not
    including) the next non-empty entry's ayah, or to total_ayahs.
    """
    # Collect non-empty entries with their ayah numbers
    non_empty = []
    for entry in entries:
        text = entry.get("text", "")
        if text:
            ayah = int(entry["verse_key"].split(":")[1])
            non_empty.append({"ayah": ayah, "text": text})

    if not non_empty:
        return []

    groups = []
    for i, item in enumerate(non_empty):
        start = item["ayah"]
        if i + 1 < len(non_empty):
            end = non_empty[i + 1]["ayah"] - 1
        else:
            end = total_ayahs
        groups.append({"start": start, "end": end, "text": item["text"]})

    return groups


# ---------------------------------------------------------------------------
# Entry building
# ---------------------------------------------------------------------------

def build_entry_html(chapter: int, group: dict, direction: str) -> str:
    """Build HTML content for a tafsir dictionary entry."""
    name_ar = SURAH_NAMES_ARABIC.get(chapter, "")
    name_en = SURAH_NAMES.get(chapter, f"Surah {chapter}")
    start = group["start"]
    end = group["end"]
    text = group["text"]

    parts = []

    # Header with ayah range
    if start == end:
        ayah_label = str(start)
    else:
        ayah_label = f"{start}–{end}"

    dir_attr = f' dir="{direction}"' if direction == "rtl" else ""

    parts.append(
        f'<p style="text-align:center;font-size:110%">'
        f'<b>{name_ar} — {name_en} {ayah_label}</b></p>'
    )

    # Tafsir content
    cleaned = clean_tafsir_html(text)
    if cleaned:
        parts.append(f'<div{dir_attr}>{cleaned}</div>')

    return "\n".join(parts)


def build_entries(client: httpx.Client, tafsir_cfg: dict) -> list[tuple[str, str]]:
    """Fetch all 114 surahs and build dictionary entries."""
    tafsir_id = tafsir_cfg["id"]
    cache_subdir = tafsir_cfg["slug"]
    direction = tafsir_cfg["direction"]

    entries = []
    total_groups = 0
    total_keys = 0
    skipped_chapters = []

    for ch in range(1, 115):
        surah_name = SURAH_NAMES.get(ch, f"Surah {ch}")
        total_ayahs = SURAH_AYAH_COUNTS[ch]

        try:
            raw_entries = fetch_chapter_tafsir(client, tafsir_id, ch, cache_subdir)
        except Exception as e:
            print(f"  ERROR fetching chapter {ch}: {e}")
            skipped_chapters.append(ch)
            continue

        if not raw_entries:
            skipped_chapters.append(ch)
            continue

        groups = detect_groups(raw_entries, total_ayahs)
        total_groups += len(groups)

        for group in groups:
            html = build_entry_html(ch, group, direction)

            # Create a key for every ayah in the group
            for ayah in range(group["start"], group["end"] + 1):
                key = f"{surah_name} {ayah}"
                entries.append((key, html))
                total_keys += 1

        if ch % 10 == 0:
            print(f"  Processed {ch}/114 surahs...")

    if skipped_chapters:
        print(f"  Skipped {len(skipped_chapters)} chapters: {skipped_chapters}")

    print(f"  {total_groups} groups, {total_keys} keys")
    return entries


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
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Build Quran tafseer dictionary")
    parser.add_argument("--tafsir", "-t",
                        help="Tafsir key from registry (e.g. muyassar, ibn-kathir-en)")
    parser.add_argument("--all", action="store_true",
                        help="Build all tafsirs")
    parser.add_argument("--list", action="store_true",
                        help="List available tafsirs and exit")
    args = parser.parse_args()

    if args.list:
        print(f"\nAvailable tafsirs ({len(TAFSIR_REGISTRY)}):\n")
        print(f"  {'Key':<25} {'ID':>4}  {'Lang':>4}  Name")
        print(f"  {'-'*25} {'-'*4}  {'-'*4}  {'-'*40}")
        for key, cfg in sorted(TAFSIR_REGISTRY.items()):
            print(f"  {key:<25} {cfg['id']:>4}  {cfg['language']:>4}  {cfg['bookname']}")
        return

    if not args.tafsir and not args.all:
        parser.error("Specify --tafsir KEY or --all (use --list to see available tafsirs)")

    if args.all:
        tafsirs = list(TAFSIR_REGISTRY.keys())
    else:
        if args.tafsir not in TAFSIR_REGISTRY:
            parser.error(f"Unknown tafsir '{args.tafsir}'. Use --list to see available tafsirs.")
        tafsirs = [args.tafsir]

    with httpx.Client(timeout=30.0) as client:
        for tafsir_key in tafsirs:
            cfg = TAFSIR_REGISTRY[tafsir_key]
            print(f"\n{'='*60}")
            print(f"Building: {cfg['bookname']} (id={cfg['id']})")
            print(f"{'='*60}")

            entries = build_entries(client, cfg)
            print(f"Total entries: {len(entries):,}")

            if not entries:
                print(f"  No entries — skipping {tafsir_key}")
                continue

            output_dir = OUTPUT_BASE / tafsir_key
            write_stardict(entries, output_dir, cfg["dict_name"], cfg["bookname"])


if __name__ == "__main__":
    main()
