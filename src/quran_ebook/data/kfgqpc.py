"""KFGQPC data loader for non-Hafs riwayat.

Downloads and parses text+font packages from the King Fahd Glorious Quran
Printing Complex (KFGQPC) via GitHub mirror (thetruetruth/quran-data-kfgqpc).

Each riwayah uses a unique Unicode encoding tied to its specific font —
font and text are inseparable.  A Warsh text rendered with a Hafs font
shows wrong diacritics, just as QPC text with a standard font breaks sukun.
"""

import json
import re

import click
import httpx

from ..models import Ayah, Mushaf, Surah
from .cache import cache_get, cache_set

# jsDelivr CDN base for the GitHub mirror.
_CDN_BASE = (
    "https://cdn.jsdelivr.net/gh/thetruetruth/quran-data-kfgqpc@main"
)

# Riwayah → (JSON filename, font filename) on the CDN.
_RIWAYAH_FILES: dict[str, tuple[str, str]] = {
    "warsh": ("warsh/data/warshData_v10.json", "warsh/font/warsh.10.ttf"),
    "qalun": ("qaloon/data/qaloonData_v10.json", "qaloon/font/qaloon.10.ttf"),
    "shubah": ("shouba/data/shoubaData_v8.json", "shouba/font/shouba.8.ttf"),
    "doori": ("doori/data/dooriData_v9.json", "doori/font/doori.9.ttf"),
    "soosi": ("soosi/data/soosiData_v9.json", "soosi/font/soosi.9.ttf"),
    "bazzi": ("bazzi/data/bazziData_v7.json", "bazzi/font/bazzi.7.ttf"),
    "qunbul": ("qumbul/data/qumbulData_v7.json", "qumbul/font/qumbul.7.ttf"),
}

# QPC-style trailing ayah numbers: NBSP (or space) + Arabic-Indic digits.
# All KFGQPC riwayat embed these the same way as the Hafs QPC encoding.
_TRAILING_NUMBER = re.compile(r"[\xa0 ][\u0660-\u0669]+$")

# Rub al-hizb (U+06DE) appears at the start of hizb-boundary ayahs,
# optionally followed by NBSP.  We detect it for hizb_marker metadata.
_RUB_ALHIZB = re.compile(r"\u06DE\xa0?")


def _fetch_json(riwayah: str) -> list[dict]:
    """Download (or load from cache) the KFGQPC JSON for a riwayah."""
    cache_key = f"kfgqpc_{riwayah}_json"
    cached = cache_get(cache_key)
    if cached:
        return cached

    json_path, _ = _RIWAYAH_FILES[riwayah]
    url = f"{_CDN_BASE}/{json_path}"
    click.echo(f"  Fetching KFGQPC {riwayah} data from CDN...")
    resp = httpx.get(url, timeout=60, follow_redirects=True)
    resp.raise_for_status()
    data = resp.json()
    cache_set(cache_key, data)
    return data


def _normalize_entry(entry: dict) -> dict:
    """Normalize inconsistent field names across riwayat.

    KFGQPC packages use different field names:
      Hafs:  sora, sora_name_en, sora_name_ar
      Warsh: sura_no, sura_name_en, sura_name_ar

    Returns a dict with canonical keys.
    """
    return {
        "surah_number": entry.get("sura_no") or entry.get("sora"),
        "surah_name_en": entry.get("sura_name_en") or entry.get("sora_name_en", ""),
        "surah_name_ar": (
            (entry.get("sura_name_ar") or entry.get("sora_name_ar", "")).strip()
        ),
        "ayah_number": entry["aya_no"],
        "text": entry["aya_text"],
        "juz": entry.get("jozz"),
        "page": entry.get("page"),
        "line_start": entry.get("line_start"),
        "line_end": entry.get("line_end"),
    }


def _parse_page(page_value) -> int:
    """Convert page field to int.

    Most entries have a plain int (as string or int).  A few Warsh entries
    span two pages as "85-86" — we take the first page.
    """
    s = str(page_value)
    if "-" in s:
        return int(s.split("-")[0])
    return int(s)


def _strip_trailing_number(text: str) -> str:
    """Strip inline ayah numbers appended to KFGQPC text."""
    return _TRAILING_NUMBER.sub("", text)



# --- Surah name transliterations (from Quran.com API chapter metadata) ---
# KFGQPC data has its own transliterations but they're inconsistent across
# riwayat.  We use the standard Quran.com names for consistency with Hafs.
_SURAH_NAMES = {
    1: "Al-Fatihah", 2: "Al-Baqarah", 3: "Ali 'Imran", 4: "An-Nisa",
    5: "Al-Ma'idah", 6: "Al-An'am", 7: "Al-A'raf", 8: "Al-Anfal",
    9: "At-Tawbah", 10: "Yunus", 11: "Hud", 12: "Yusuf",
    13: "Ar-Ra'd", 14: "Ibrahim", 15: "Al-Hijr", 16: "An-Nahl",
    17: "Al-Isra", 18: "Al-Kahf", 19: "Maryam", 20: "Taha",
    21: "Al-Anbya", 22: "Al-Hajj", 23: "Al-Mu'minun", 24: "An-Nur",
    25: "Al-Furqan", 26: "Ash-Shu'ara", 27: "An-Naml", 28: "Al-Qasas",
    29: "Al-'Ankabut", 30: "Ar-Rum", 31: "Luqman", 32: "As-Sajdah",
    33: "Al-Ahzab", 34: "Saba", 35: "Fatir", 36: "Ya-Sin",
    37: "As-Saffat", 38: "Sad", 39: "Az-Zumar", 40: "Ghafir",
    41: "Fussilat", 42: "Ash-Shuraa", 43: "Az-Zukhruf", 44: "Ad-Dukhan",
    45: "Al-Jathiyah", 46: "Al-Ahqaf", 47: "Muhammad", 48: "Al-Fath",
    49: "Al-Hujurat", 50: "Qaf", 51: "Adh-Dhariyat", 52: "At-Tur",
    53: "An-Najm", 54: "Al-Qamar", 55: "Ar-Rahman", 56: "Al-Waqi'ah",
    57: "Al-Hadid", 58: "Al-Mujadila", 59: "Al-Hashr", 60: "Al-Mumtahanah",
    61: "As-Saf", 62: "Al-Jumu'ah", 63: "Al-Munafiqun", 64: "At-Taghabun",
    65: "At-Talaq", 66: "At-Tahrim", 67: "Al-Mulk", 68: "Al-Qalam",
    69: "Al-Haqqah", 70: "Al-Ma'arij", 71: "Nuh", 72: "Al-Jinn",
    73: "Al-Muzzammil", 74: "Al-Muddaththir", 75: "Al-Qiyamah", 76: "Al-Insan",
    77: "Al-Mursalat", 78: "An-Naba", 79: "An-Nazi'at", 80: "'Abasa",
    81: "At-Takwir", 82: "Al-Infitar", 83: "Al-Mutaffifin", 84: "Al-Inshiqaq",
    85: "Al-Buruj", 86: "At-Tariq", 87: "Al-A'la", 88: "Al-Ghashiyah",
    89: "Al-Fajr", 90: "Al-Balad", 91: "Ash-Shams", 92: "Al-Layl",
    93: "Ad-Duhaa", 94: "Ash-Sharh", 95: "At-Tin", 96: "Al-'Alaq",
    97: "Al-Qadr", 98: "Al-Bayyinah", 99: "Az-Zalzalah", 100: "Al-'Adiyat",
    101: "Al-Qari'ah", 102: "At-Takathur", 103: "Al-'Asr", 104: "Al-Humazah",
    105: "Al-Fil", 106: "Quraysh", 107: "Al-Ma'un", 108: "Al-Kawthar",
    109: "Al-Kafirun", 110: "An-Nasr", 111: "Al-Masad", 112: "Al-Ikhlas",
    113: "Al-Falaq", 114: "An-Nas",
}

# Revelation type (Meccan/Medinan) — same across all readings.
_REVELATION_TYPE = {
    1: "meccan", 2: "medinan", 3: "medinan", 4: "medinan", 5: "medinan",
    6: "meccan", 7: "meccan", 8: "medinan", 9: "medinan", 10: "meccan",
    11: "meccan", 12: "meccan", 13: "medinan", 14: "meccan", 15: "meccan",
    16: "meccan", 17: "meccan", 18: "meccan", 19: "meccan", 20: "meccan",
    21: "meccan", 22: "medinan", 23: "meccan", 24: "medinan", 25: "meccan",
    26: "meccan", 27: "meccan", 28: "meccan", 29: "meccan", 30: "meccan",
    31: "meccan", 32: "meccan", 33: "medinan", 34: "meccan", 35: "meccan",
    36: "meccan", 37: "meccan", 38: "meccan", 39: "meccan", 40: "meccan",
    41: "meccan", 42: "meccan", 43: "meccan", 44: "meccan", 45: "meccan",
    46: "meccan", 47: "medinan", 48: "medinan", 49: "medinan", 50: "meccan",
    51: "meccan", 52: "meccan", 53: "meccan", 54: "meccan", 55: "meccan",
    56: "meccan", 57: "medinan", 58: "medinan", 59: "medinan", 60: "medinan",
    61: "medinan", 62: "medinan", 63: "medinan", 64: "medinan", 65: "medinan",
    66: "medinan", 67: "meccan", 68: "meccan", 69: "meccan", 70: "meccan",
    71: "meccan", 72: "meccan", 73: "meccan", 74: "meccan", 75: "meccan",
    76: "medinan", 77: "meccan", 78: "meccan", 79: "meccan", 80: "meccan",
    81: "meccan", 82: "meccan", 83: "meccan", 84: "meccan", 85: "meccan",
    86: "meccan", 87: "meccan", 88: "meccan", 89: "meccan", 90: "meccan",
    91: "meccan", 92: "meccan", 93: "meccan", 94: "meccan", 95: "meccan",
    96: "meccan", 97: "meccan", 98: "medinan", 99: "medinan", 100: "meccan",
    101: "meccan", 102: "meccan", 103: "meccan", 104: "meccan", 105: "meccan",
    106: "meccan", 107: "meccan", 108: "meccan", 109: "meccan", 110: "medinan",
    111: "meccan", 112: "meccan", 113: "meccan", 114: "meccan",
}


def load_quran_kfgqpc(riwayah: str) -> Mushaf:
    """Load the complete Quran from a KFGQPC data package.

    Args:
        riwayah: Which riwayah to load (e.g. "warsh", "qalun").
            Must be a key in _RIWAYAH_FILES.

    Returns:
        A Mushaf containing all 114 surahs with the riwayah's text encoding.
    """
    if riwayah not in _RIWAYAH_FILES:
        raise ValueError(
            f"Unknown riwayah '{riwayah}'. "
            f"Available: {', '.join(sorted(_RIWAYAH_FILES))}"
        )

    raw_data = _fetch_json(riwayah)
    click.echo(f"  Loaded {len(raw_data)} ayahs for riwayat {riwayah}")

    # Normalize and group by surah
    by_surah: dict[int, list[dict]] = {}
    surah_meta: dict[int, dict] = {}  # first entry per surah for names
    for entry in raw_data:
        norm = _normalize_entry(entry)
        sn = norm["surah_number"]
        by_surah.setdefault(sn, []).append(norm)
        if sn not in surah_meta:
            surah_meta[sn] = norm

    surahs = []
    for sn in sorted(by_surah.keys()):
        entries = by_surah[sn]
        meta = surah_meta[sn]

        ayahs = []
        for e in entries:
            text = _strip_trailing_number(e["text"]).strip()
            page = _parse_page(e["page"]) if e.get("page") else None

            # Detect and strip rub al-hizb (same as Hafs pipeline).
            # The template re-inserts it as a styled <span>.
            has_hizb = "\u06DE" in text
            text = _RUB_ALHIZB.sub("", text)

            ayahs.append(Ayah(
                surah_number=sn,
                ayah_number=e["ayah_number"],
                text=text,
                page_number=page,
                juz_number=e.get("juz"),
                hizb_marker=has_hizb,
            ))

        surahs.append(Surah(
            number=sn,
            name_arabic=meta["surah_name_ar"],
            name_transliteration=_SURAH_NAMES.get(sn, meta["surah_name_en"]),
            revelation_type=_REVELATION_TYPE.get(sn, "meccan"),
            ayah_count=len(ayahs),
            ayahs=ayahs,
            basmala_is_first_ayah=False,  # Non-Hafs: basmala is unnumbered
        ))

    # Script name for this riwayah (used in registry lookups).
    script = f"qpc_uthmani_{riwayah}"

    # Extract QPC-encoded basmala from S27:30 (Solomon's letter).
    # KFGQPC non-Hafs data omits basmala as a numbered ayah, but S27:30
    # contains the full basmala in-context with correct QPC encoding.
    # Tatweels after بِ and after ي mimic calligraphic stretching.
    bismillah = ""
    s27_entries = by_surah.get(27, [])
    for e in s27_entries:
        if e["ayah_number"] == 30:
            raw = _strip_trailing_number(e["text"])
            raw = _RUB_ALHIZB.sub("", raw)
            idx = raw.find("\u0628\u0650\u0633\u0652\u0645\u0650")  # بِسْمِ
            if idx >= 0:
                bismillah = raw[idx:]
            break

    return Mushaf(
        surahs=surahs,
        script=script,
        bismillah_text=bismillah,
        metadata={
            "source": "kfgqpc",
            "riwayah": riwayah,
        },
    )
