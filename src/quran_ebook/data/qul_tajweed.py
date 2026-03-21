"""QUL QPC Hafs tajweed data loader.

Loads QPC-encoded Quran text with tajweed color annotations from the
QUL resource 87 JSON file (docs/qpc-hafs-tajweed.json.zip).

The text uses QPC encoding (U+06E1 sukun, etc.) with inline
<rule class=X> tags marking tajweed rules. These are converted to
<span class="tj-X"> for EPUB/CSS rendering.
"""

import json
import re
import zipfile
from pathlib import Path

import click

from ..models import Ayah, Mushaf, Surah

# Path to the downloaded QUL resource 87 data
QUL_TAJWEED_ZIP = Path(__file__).parent.parent.parent.parent / "docs" / "qpc-hafs-tajweed.json.zip"

# Strip trailing ayah numbers (Arabic-Indic digits, optional space prefix)
_TRAILING_AYAH_NUM = re.compile(r"\s*[\u0660-\u0669]+$")

# Strip rub al-hizb marker
_RUB_ALHIZB = re.compile(r"\u06DE\xa0?")

# Match <rule class=X> tags (with or without quotes, handle dirty data)
_RULE_TAG = re.compile(r"<rule\s+class=['\"]?([a-z_]+)['\"]?(?:\s[^>]*)?>")
_RULE_CLOSE = re.compile(r"</rule>")

# Absorb combining marks that follow </span> back into the span.
# The QUL data places </rule> before the letter's harakat (fatha, kasra,
# shadda, etc.), leaving 18k+ diacritics uncolored.  This regex pulls
# trailing combining marks (Unicode category M) inside the closing tag.
_ABSORB_COMBINING = re.compile(r"</span>([\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u08D3-\u08FF]+)")

# Match <span class=end> ayah-end markers from the data
_SPAN_END = re.compile(r"<span\s+class=['\"]?end['\"]?\s*>.*?</span>")

# Sajdah sign
_SAJDAH_SIGN = "\u06E9"


def _convert_tajweed_tags(text: str) -> str:
    """Convert <rule class=X> to <span class="tj-X"> for CSS styling.

    Also strips:
    - <span class=end>N</span> ayah-end markers (we render our own)
    - Trailing Arabic-Indic ayah numbers
    - Rub al-hizb markers (handled via metadata)
    """
    # Strip ayah-end span markers
    text = _SPAN_END.sub("", text)

    # Convert <rule> to <span>
    text = _RULE_TAG.sub(r'<span class="tj-\1">', text)
    text = _RULE_CLOSE.sub("</span>", text)

    # Absorb combining marks (harakat) that fell outside closing </span>
    text = _ABSORB_COMBINING.sub(r"\1</span>", text)

    # Strip trailing ayah numbers
    text = _TRAILING_AYAH_NUM.sub("", text)

    # Handle rub al-hizb
    has_hizb = "\u06DE" in text
    text = _RUB_ALHIZB.sub("", text)

    # Add hair space after sajdah sign
    if _SAJDAH_SIGN in text:
        text = text.replace(_SAJDAH_SIGN, _SAJDAH_SIGN + "\u200A")

    return text.strip(), has_hizb


def load_quran_qul_tajweed() -> Mushaf:
    """Load the Quran from the QUL QPC Hafs tajweed JSON.

    Returns a Mushaf with tajweed-annotated QPC text (HTML spans).
    """
    if not QUL_TAJWEED_ZIP.exists():
        raise FileNotFoundError(
            f"QUL tajweed data not found: {QUL_TAJWEED_ZIP}\n"
            "Download resource 87 from https://qul.tarteel.ai/resources/quran-script/87"
        )

    click.echo(f"Loading QUL QPC tajweed data from {QUL_TAJWEED_ZIP}")

    with zipfile.ZipFile(QUL_TAJWEED_ZIP) as zf:
        with zf.open("qpc-hafs-tajweed.json") as f:
            data = json.load(f)

    # Chapter metadata — we need this from quran.com API cache or hardcode
    # For now, use the quran_api loader's chapter fetch
    from .quran_api import _fetch_chapters

    import httpx
    with httpx.Client(timeout=30) as client:
        chapters = _fetch_chapters(client)

    surahs = []
    for ch in chapters:
        ch_num = ch["id"]
        ayahs = []

        for ayah_num in range(1, ch["verses_count"] + 1):
            verse_key = f"{ch_num}:{ayah_num}"
            verse = data.get(verse_key)
            if not verse:
                click.echo(f"  WARNING: missing {verse_key} in QUL data")
                ayahs.append(Ayah(
                    surah_number=ch_num,
                    ayah_number=ayah_num,
                    text="",
                ))
                continue

            raw_text = verse["text"]
            text, has_hizb = _convert_tajweed_tags(raw_text)

            ayahs.append(Ayah(
                surah_number=ch_num,
                ayah_number=ayah_num,
                text=text,
                hizb_marker=has_hizb,
            ))

        surahs.append(Surah(
            number=ch_num,
            name_arabic=ch["name_arabic"],
            name_transliteration=ch["name_simple"],
            revelation_type=ch["revelation_place"],
            ayah_count=ch["verses_count"],
            ayahs=ayahs,
        ))

    # Bismillah from Al-Fatiha 1:1 (strip tajweed spans for plain bismillah)
    bismillah = surahs[0].ayahs[0].text

    click.echo(f"  Loaded {len(data)} verses with tajweed annotations")

    return Mushaf(
        surahs=surahs,
        script="qpc_uthmani_hafs_tajweed",
        bismillah_text=bismillah,
        metadata={
            "source": "qul",
            "resource": 87,
        },
    )
