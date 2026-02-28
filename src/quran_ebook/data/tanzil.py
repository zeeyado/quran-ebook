"""Tanzil.net Quran data loader.

Downloads and parses Uthmani text from Tanzil.net in XML format.
Source: https://tanzil.net/ (CC-BY 3.0)
"""

import xml.etree.ElementTree as ET

import click
import httpx

from ..models import Ayah, Mushaf, Surah
from .cache import cache_get, cache_set, get_cache_dir

TANZIL_URL = "https://tanzil.net/pub/download/index.php"

# Surah metadata not included in Tanzil XML (transliteration + revelation type).
# Source: standard Islamic scholarship, consistent across all references.
SURAH_META: dict[int, tuple[str, str]] = {
    1: ("Al-Fatihah", "meccan"),
    2: ("Al-Baqarah", "medinan"),
    3: ("Ali 'Imran", "medinan"),
    4: ("An-Nisa", "medinan"),
    5: ("Al-Ma'idah", "medinan"),
    6: ("Al-An'am", "meccan"),
    7: ("Al-A'raf", "meccan"),
    8: ("Al-Anfal", "medinan"),
    9: ("At-Tawbah", "medinan"),
    10: ("Yunus", "meccan"),
    11: ("Hud", "meccan"),
    12: ("Yusuf", "meccan"),
    13: ("Ar-Ra'd", "medinan"),
    14: ("Ibrahim", "meccan"),
    15: ("Al-Hijr", "meccan"),
    16: ("An-Nahl", "meccan"),
    17: ("Al-Isra", "meccan"),
    18: ("Al-Kahf", "meccan"),
    19: ("Maryam", "meccan"),
    20: ("Taha", "meccan"),
    21: ("Al-Anbya", "meccan"),
    22: ("Al-Hajj", "medinan"),
    23: ("Al-Mu'minun", "meccan"),
    24: ("An-Nur", "medinan"),
    25: ("Al-Furqan", "meccan"),
    26: ("Ash-Shu'ara", "meccan"),
    27: ("An-Naml", "meccan"),
    28: ("Al-Qasas", "meccan"),
    29: ("Al-'Ankabut", "meccan"),
    30: ("Ar-Rum", "meccan"),
    31: ("Luqman", "meccan"),
    32: ("As-Sajdah", "meccan"),
    33: ("Al-Ahzab", "medinan"),
    34: ("Saba", "meccan"),
    35: ("Fatir", "meccan"),
    36: ("Ya-Sin", "meccan"),
    37: ("As-Saffat", "meccan"),
    38: ("Sad", "meccan"),
    39: ("Az-Zumar", "meccan"),
    40: ("Ghafir", "meccan"),
    41: ("Fussilat", "meccan"),
    42: ("Ash-Shura", "meccan"),
    43: ("Az-Zukhruf", "meccan"),
    44: ("Ad-Dukhan", "meccan"),
    45: ("Al-Jathiyah", "meccan"),
    46: ("Al-Ahqaf", "meccan"),
    47: ("Muhammad", "medinan"),
    48: ("Al-Fath", "medinan"),
    49: ("Al-Hujurat", "medinan"),
    50: ("Qaf", "meccan"),
    51: ("Adh-Dhariyat", "meccan"),
    52: ("At-Tur", "meccan"),
    53: ("An-Najm", "meccan"),
    54: ("Al-Qamar", "meccan"),
    55: ("Ar-Rahman", "medinan"),
    56: ("Al-Waqi'ah", "meccan"),
    57: ("Al-Hadid", "medinan"),
    58: ("Al-Mujadila", "medinan"),
    59: ("Al-Hashr", "medinan"),
    60: ("Al-Mumtahanah", "medinan"),
    61: ("As-Saf", "medinan"),
    62: ("Al-Jumu'ah", "medinan"),
    63: ("Al-Munafiqun", "medinan"),
    64: ("At-Taghabun", "medinan"),
    65: ("At-Talaq", "medinan"),
    66: ("At-Tahrim", "medinan"),
    67: ("Al-Mulk", "meccan"),
    68: ("Al-Qalam", "meccan"),
    69: ("Al-Haqqah", "meccan"),
    70: ("Al-Ma'arij", "meccan"),
    71: ("Nuh", "meccan"),
    72: ("Al-Jinn", "meccan"),
    73: ("Al-Muzzammil", "meccan"),
    74: ("Al-Muddaththir", "meccan"),
    75: ("Al-Qiyamah", "meccan"),
    76: ("Al-Insan", "medinan"),
    77: ("Al-Mursalat", "meccan"),
    78: ("An-Naba", "meccan"),
    79: ("An-Nazi'at", "meccan"),
    80: ("'Abasa", "meccan"),
    81: ("At-Takwir", "meccan"),
    82: ("Al-Infitar", "meccan"),
    83: ("Al-Mutaffifin", "meccan"),
    84: ("Al-Inshiqaq", "meccan"),
    85: ("Al-Buruj", "meccan"),
    86: ("At-Tariq", "meccan"),
    87: ("Al-A'la", "meccan"),
    88: ("Al-Ghashiyah", "meccan"),
    89: ("Al-Fajr", "meccan"),
    90: ("Al-Balad", "meccan"),
    91: ("Ash-Shams", "meccan"),
    92: ("Al-Layl", "meccan"),
    93: ("Ad-Duhaa", "meccan"),
    94: ("Ash-Sharh", "meccan"),
    95: ("At-Tin", "meccan"),
    96: ("Al-'Alaq", "meccan"),
    97: ("Al-Qadr", "meccan"),
    98: ("Al-Bayyinah", "medinan"),
    99: ("Az-Zalzalah", "medinan"),
    100: ("Al-'Adiyat", "meccan"),
    101: ("Al-Qari'ah", "meccan"),
    102: ("At-Takathur", "meccan"),
    103: ("Al-'Asr", "meccan"),
    104: ("Al-Humazah", "meccan"),
    105: ("Al-Fil", "meccan"),
    106: ("Quraysh", "meccan"),
    107: ("Al-Ma'un", "meccan"),
    108: ("Al-Kawthar", "meccan"),
    109: ("Al-Kafirun", "meccan"),
    110: ("An-Nasr", "medinan"),
    111: ("Al-Masad", "meccan"),
    112: ("Al-Ikhlas", "meccan"),
    113: ("Al-Falaq", "meccan"),
    114: ("An-Nas", "meccan"),
}

# Sajdah ayahs (verse numbers where prostration is prescribed)
SAJDAH_AYAHS: set[tuple[int, int]] = {
    (7, 206), (13, 15), (16, 50), (17, 109), (19, 58), (22, 18),
    (22, 77), (25, 60), (27, 26), (32, 15), (38, 24), (41, 38),
    (53, 62), (84, 21), (96, 19),
}


def _download_xml(quran_type: str = "uthmani") -> str:
    """Download Quran XML from Tanzil.net."""
    cache_key = f"tanzil_{quran_type}_xml"
    cached = cache_get(cache_key)
    if cached:
        return cached["xml"]

    # Check if we have it saved locally already
    local_path = get_cache_dir() / f"quran-{quran_type}.xml"
    if local_path.exists():
        xml_text = local_path.read_text(encoding="utf-8")
    else:
        click.echo(f"Downloading Quran text from Tanzil.net ({quran_type})...")
        resp = httpx.get(
            TANZIL_URL,
            params={"quranType": quran_type, "outType": "xml"},
            follow_redirects=True,
            timeout=60,
        )
        resp.raise_for_status()
        xml_text = resp.text
        local_path.write_text(xml_text, encoding="utf-8")

    cache_set(cache_key, {"xml": xml_text})
    return xml_text


def _parse_xml(xml_text: str) -> list[Surah]:
    """Parse Tanzil XML into Surah models."""
    root = ET.fromstring(xml_text)
    surahs = []

    for sura_elem in root.findall("sura"):
        sura_idx = int(sura_elem.get("index"))
        name_arabic = sura_elem.get("name")
        meta = SURAH_META.get(sura_idx, (f"Surah {sura_idx}", "unknown"))

        ayahs = []
        for aya_elem in sura_elem.findall("aya"):
            aya_idx = int(aya_elem.get("index"))
            ayahs.append(Ayah(
                surah_number=sura_idx,
                ayah_number=aya_idx,
                text=aya_elem.get("text"),
                sajdah=(sura_idx, aya_idx) in SAJDAH_AYAHS,
            ))

        surahs.append(Surah(
            number=sura_idx,
            name_arabic=name_arabic,
            name_transliteration=meta[0],
            revelation_type=meta[1],
            ayah_count=len(ayahs),
            ayahs=ayahs,
        ))

    return surahs


def load_quran(quran_type: str = "uthmani") -> Mushaf:
    """Load the complete Quran from Tanzil.net.

    Args:
        quran_type: Text type — "uthmani" or "simple".

    Returns:
        A Mushaf containing all 114 surahs.
    """
    xml_text = _download_xml(quran_type)
    surahs = _parse_xml(xml_text)

    script_map = {
        "uthmani": "text_uthmani",
        "simple": "text_imlaei",
    }

    return Mushaf(
        surahs=surahs,
        script=script_map.get(quran_type, quran_type),
        metadata={
            "source": "tanzil.net",
            "license": "CC-BY 3.0",
            "version": "1.1",
        },
    )
