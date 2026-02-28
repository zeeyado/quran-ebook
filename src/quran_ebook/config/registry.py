"""Script/font pairing registry.

This is the critical safety mechanism that prevents the rendering bug documented
in rockneverdies55/quran-epub issues #2 and #4. The bug was caused by using
text_uthmani script with a font that doesn't properly support its special Unicode
characters (U+06DF small high rounded zero instead of U+0652 sukun).

The fix (identified by bilalsaci) is to use matched script+font combinations.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class FontInfo:
    """Metadata for a downloadable font."""

    key: str
    family: str  # CSS font-family name
    filename: str  # Expected TTF filename on disk
    source_url: str  # Direct download URL or zip URL
    zip_path: str | None  # Path inside zip archive, or None for direct download
    license: str
    sha256: str | None = None  # For integrity verification


# --- Font Registry ---

FONTS: dict[str, FontInfo] = {
    "amiri_quran": FontInfo(
        key="amiri_quran",
        family="Amiri Quran",
        filename="AmiriQuran.ttf",
        source_url="https://github.com/aliftype/amiri/releases/download/1.003/Amiri-1.003.zip",
        zip_path="Amiri-1.003/AmiriQuran.ttf",
        license="SIL OFL 1.1",
    ),
    "scheherazade_new": FontInfo(
        key="scheherazade_new",
        family="Scheherazade New",
        filename="ScheherazadeNew-Regular.ttf",
        source_url="https://github.com/silnrsi/font-scheherazade/releases/download/v4.400/ScheherazadeNew-4.400.zip",
        zip_path="ScheherazadeNew-4.400/ScheherazadeNew-Regular.ttf",
        license="SIL OFL 1.1",
    ),
    "kfgqpc_uthmanic_hafs": FontInfo(
        key="kfgqpc_uthmanic_hafs",
        family="KFGQPC HAFS Uthmanic Script",
        filename="UthmanicHafs_V22.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/UthmanicHafs_V22.ttf",
        zip_path=None,
        license="KFGQPC",
    ),
    "me_quran": FontInfo(
        key="me_quran",
        family="me_quran",
        filename="me_quran_volt_newmet.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/me_quran_volt_newmet.ttf",
        zip_path=None,
        license="Free",
    ),
    "noto_sans_arabic": FontInfo(
        key="noto_sans_arabic",
        family="Noto Sans Arabic",
        filename="NotoSansArabic-Regular.ttf",
        source_url="https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf",
        zip_path=None,
        license="SIL OFL 1.1",
    ),
}

# --- Script/Font Pairing Validation ---
# Each script maps to a list of fonts known to render it correctly.
# The first font in each list is the recommended default.

SCRIPT_FONT_PAIRS: dict[str, list[str]] = {
    "text_uthmani": ["amiri_quran", "scheherazade_new", "me_quran"],
    "text_uthmani_simple": ["amiri_quran", "scheherazade_new"],
    "qpc_uthmani_hafs": ["kfgqpc_uthmanic_hafs", "amiri_quran"],
    "text_imlaei": ["amiri_quran", "scheherazade_new"],
    "text_imlaei_simple": ["amiri_quran", "scheherazade_new"],
    "text_indopak": [],  # v2: add pdms_saleem, kfgqpc_nastaleeq
}


def validate_script_font_pair(script: str, font_key: str) -> list[str]:
    """Validate a script/font combination.

    Returns a list of warnings (empty if the combination is valid).
    Does not raise — users may want to experiment with unregistered combos.
    """
    warnings = []

    if script not in SCRIPT_FONT_PAIRS:
        warnings.append(
            f"Script '{script}' is not in the registry. "
            f"Known scripts: {', '.join(SCRIPT_FONT_PAIRS.keys())}"
        )
        return warnings

    if font_key not in FONTS:
        warnings.append(
            f"Font '{font_key}' is not in the registry. "
            f"Known fonts: {', '.join(FONTS.keys())}"
        )
        return warnings

    valid_fonts = SCRIPT_FONT_PAIRS[script]
    if valid_fonts and font_key not in valid_fonts:
        warnings.append(
            f"Font '{font_key}' is not a validated match for script '{script}'. "
            f"Recommended fonts: {', '.join(valid_fonts)}. "
            f"This may cause rendering artifacts (sukun dots, broken ligatures)."
        )

    return warnings


def get_default_font(script: str) -> str | None:
    """Get the recommended default font for a script."""
    fonts = SCRIPT_FONT_PAIRS.get(script, [])
    return fonts[0] if fonts else None


# --- Script Display Labels ---
# (English name, Arabic name) for cover pages and metadata.

SCRIPT_LABELS: dict[str, tuple[str, str]] = {
    "qpc_uthmani_hafs": ("QPC Uthmani Hafs", "برواية حفص عن عاصم"),
    "text_uthmani": ("Uthmani", "الرسم العثماني"),
    "text_uthmani_simple": ("Uthmani (Simplified)", "الرسم العثماني المبسّط"),
    "text_imlaei": ("Imla'i", "الرسم الإملائي"),
    "text_imlaei_simple": ("Imla'i (Simplified)", "الرسم الإملائي المبسّط"),
    "text_indopak": ("IndoPak", "الرسم الهندي"),
}


# --- Script → Riwayah Mapping ---
# Extracts the riwayah from the script identifier for filenames and metadata.
# Scripts without an explicit riwayah default to "hafs" (the standard Uthmani text is Hafs).

SCRIPT_RIWAYAH: dict[str, str] = {
    "qpc_uthmani_hafs": "hafs",
    "text_qpc_hafs": "hafs",
    "text_qpc_nastaleeq_hafs": "hafs",
    "text_uthmani": "hafs",  # Standard Uthmani = Hafs reading
    "text_uthmani_simple": "hafs",
    "text_uthmani_tajweed": "hafs",
    "text_imlaei": "hafs",
    "text_imlaei_simple": "hafs",
    "text_indopak": "hafs",
    "text_indopak_nastaleeq": "hafs",
    "text_qpc_nastaleeq": "hafs",
    # Future riwayat:
    # "qpc_uthmani_warsh": "warsh",
    # "qpc_uthmani_qalun": "qalun",
    # "qpc_uthmani_shubah": "shubah",
}


def get_riwayah(script: str) -> str:
    """Get the riwayah for a script. Defaults to 'hafs'."""
    return SCRIPT_RIWAYAH.get(script, "hafs")


# --- Shorthand Abbreviations ---
# Compact codes used in output filenames.

ABBREV_FONTS: dict[str, str] = {
    "amiri_quran": "amiri",
    "scheherazade_new": "schz",
    "kfgqpc_uthmanic_hafs": "kfgqpc",
    "kfgqpc_uthmanic_warsh": "kfgqpc",
    "me_quran": "meq",
    "noto_sans_arabic": "noto",
}

ABBREV_LAYOUTS: dict[str, str] = {
    "by_surah": "ayah",
    "inline": "inline",
    "bilingual_interleaved": "bilin",
    "bilingual_columns": "cols",
    "arabic_tafseer": "tafseer",
    "spread": "spread",
    "mushaf_fixed": "mushaf",
    "translation_only": "trans",
}


def abbreviate(category: str, key: str) -> str:
    """Get the shorthand abbreviation for a key.

    Args:
        category: One of "font", "layout".
        key: The full key to abbreviate.

    Returns:
        The shorthand code, or the key itself if no abbreviation exists.
    """
    tables = {
        "font": ABBREV_FONTS,
        "layout": ABBREV_LAYOUTS,
    }
    table = tables.get(category, {})
    return table.get(key, key)
