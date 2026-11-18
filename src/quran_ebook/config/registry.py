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
    # The checksum of the font file as the books were made with it. When
    # set, a build stops on a file that differs (fonts/manager.py).
    sha256: str | None = None
    # Who made the font, as a book's metadata credits it (builder.py,
    # source_credits). Empty: the family name is used.
    credit: str = ""
    # Changes the books make to the font file, each (index of a lookup in
    # the font's GPOS table, the flag it must carry in the source file, the
    # flag it gets). Applied by fonts/manager.py, which refuses a source
    # file whose checksum is not `sha256`. The credit says so.
    gpos_lookup_flags: tuple[tuple[int, int, int], ...] = ()


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
        credit="Scheherazade New (SIL Global)",
    ),
    "kfgqpc_uthmanic_hafs": FontInfo(
        key="kfgqpc_uthmanic_hafs",
        family="KFGQPC HAFS Uthmanic Script",
        filename="UthmanicHafs_V22.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/UthmanicHafs_V22.ttf",
        zip_path=None,
        license="KFGQPC",
        sha256="aa68bffce289b4c0ebac68e90502eb69e42356abcd1603cb2b8e99c2c723f145",
        credit="KFGQPC Uthmanic Script Hafs (King Fahd Glorious Quran Printing Complex)",
    ),
    "kfgqpc_uthmanic_hafs_v17": FontInfo(
        key="kfgqpc_uthmanic_hafs_v17",
        family="KFGQPC HAFS Uthmanic Script",
        filename="UthmanicHafs1-Ver17.ttf",
        source_url="https://qul.tarteel.ai/resources/font/245",
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
        credit="me_quran (Meor Ridzuan)",
    ),
    "noto_sans_arabic": FontInfo(
        key="noto_sans_arabic",
        family="Noto Sans Arabic",
        filename="NotoSansArabic-Regular.ttf",
        source_url="https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf",
        zip_path=None,
        license="SIL OFL 1.1",
    ),
    "surah_name_v4": FontInfo(
        key="surah_name_v4",
        family="surah-name-v4",
        filename="surah-name-v4.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/surah-names/v4/surah-name-v4.ttf",
        zip_path=None,
        license="KFGQPC",
        credit="Surah Name V4 (QUL, King Fahd Complex)",
    ),
    "quran_common": FontInfo(
        key="quran_common",
        family="quran-common",
        filename="quran-common.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/common/quran-common.ttf",
        zip_path=None,
        license="KFGQPC",
        credit="Quran Common (QUL, King Fahd Complex)",
    ),
    "kfgqpc_uthmanic_warsh": FontInfo(
        key="kfgqpc_uthmanic_warsh",
        family="KFGQPC Warsh Uthmanic Script",
        filename="warsh.10.ttf",
        source_url="https://cdn.jsdelivr.net/gh/thetruetruth/quran-data-kfgqpc@main/warsh/font/warsh.10.ttf",
        zip_path=None,
        license="KFGQPC",
        sha256="e6347a1b4cf0ca32e9cb187a7db8c9ecee0d5e384269ca6a943373a34ff747fb",
        credit=("KFGQPC Warsh Uthmanic Script (King Fahd Glorious Quran Printing Complex; "
                "one setting changed so that Apple's reading apps show the vowel marks)"),
        # Lookup 2 attaches fatha, damma and sukun to their base letters and
        # at the same time carries the flags "ignore base glyphs" and "ignore
        # ligatures" (7 = those two plus right-to-left). The OpenType shaper
        # (KOReader, Calibre, Chromium) places the marks all the same; Apple's
        # shaper then places none of that lookup: 22,337 of the text's 22,643
        # different words lose marks in every Apple reader. With the flag of
        # the sibling lookups (1): no word differs in Apple's shaper, and the
        # OpenType result is the same for every word.
        gpos_lookup_flags=((2, 7, 1),),
    ),
    "indopak_nastaleeq": FontInfo(
        key="indopak_nastaleeq",
        family="IndoPak Nastaleeq",
        filename="indopak-nastaleeq-v4.2.2.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/nastaleeq/Hanafi/normal-v4.2.2/with-waqf-lazmi/font.ttf",
        zip_path=None,
        license="QUL",  # QUL project; verify redistribution rights
        # Not bundled and not part of the data snapshot: a build downloads
        # it, so the checksum is what keeps the file from changing unseen.
        sha256="a6463e24e36651404e9eff52dae26e18e9ef0718eb620636a66a20026a75c563",
        credit="AlQuran IndoPak by QuranWBW (Ayman Siddiqui), from QUL",
    ),
    "kfgqpc_nastaleeq": FontInfo(
        key="kfgqpc_nastaleeq",
        family="KFGQPC Nastaleeq",
        filename="KFGQPCNastaleeq-Regular.ttf",
        source_url="https://static-cdn.tarteel.ai/qul/fonts/nastaleeq/KFGQPCNastaleeq-Regular.ttf",
        zip_path=None,
        license="KFGQPC",
    ),
}

# --- The marks of each Quran font ---


@dataclass(frozen=True)
class MarkLook:
    """How the ayah number and the hizb sign are drawn with a Quran font.

    number_size: the size of our own ayah number, counted in the size of
        the Quran text it stands in (the fonts draw a digit as the ornate
        circle; scripts whose font brings its own mark do not use it).
    hizb_font: which font draws the hizb sign: "symbol" (the rosette of the
        symbol font) or "text" (the Quran font's own sign).
    hizb_size: the size of the hizb sign, counted in the Quran text's size.
    """

    number_size: str
    hizb_font: str
    hizb_size: str
    # Room above and below a surah's bare name (the header of flowing books
    # whose name is written in the Quran font), counted in the name's size.
    bare_name_room: tuple[str, str] = ("0", "0")
    # Word by word: the room an ayah's last word box keeps for the mark that
    # follows it (browser engines; see the stylesheet), counted in the size
    # of the Quran text: the width of the font's widest mark with its side
    # margins. Empty: no such rule, and a browser engine may then put a
    # mark alone on a line.
    wbw_mark_room: str = ""


# Measured in the fonts (the height of the glyph's ink against the font
# size; the letter alef is 0.63 to 0.66 in all three text fonts, so the text
# itself needs no factor):
#   ayah number   Hafs font 0.89, Warsh font 1.06, IndoPak font's own 0.66
#   hizb sign     symbol font's rosette 1.24, Warsh font's star 0.48,
#                 Hafs font's own 0.44 (not used: the rosette is)
# Hafs: number 0.89 x 1.2 = 1.07 of the text size; rosette 1.24 x 0.8 = 0.99.
# Warsh: the font draws its number larger already, so no enlargement
# (1.06, level with Hafs); the font's own star at the size its makers drew
# it (0.48: the Warsh text carries the sign at 434 places, more than twice
# the Hafs text's 199, and a small star suits that). Owner, 2026-11-18.
# The room around a bare name is what KOReader drew when that room came
# from the font's own line height (104 screen dots for the Warsh font and
# 127 for the IndoPak font, where the name's own line is 93). Written out,
# it is the same in every reading app.
# The room for the mark on a word-by-word row: measured in both browser
# engines over every ayah of a book. The Hafs font draws every number 1.078
# wide; the IndoPak font's own mark is 1.012 to 1.454 wide. Each with the
# 0.16 of its box's side margins.
# A font that is not in the table: the rosette of the symbol font where the
# script goes with the ornament fonts, else the Quran font's own sign.
_MARK_LOOK_DEFAULT = MarkLook(number_size="1.2em", hizb_font="symbol", hizb_size="0.8em")
_MARK_LOOK_OWN_SIGN = MarkLook(number_size="1.2em", hizb_font="text", hizb_size="0.6em")
FONT_MARKS: dict[str, MarkLook] = {
    "kfgqpc_uthmanic_hafs": MarkLook(
        number_size="1.2em", hizb_font="symbol", hizb_size="0.8em",
        wbw_mark_room="1.24em",
    ),
    "kfgqpc_uthmanic_warsh": MarkLook(
        number_size="1em", hizb_font="text", hizb_size="1em",
        bare_name_room=("0", "0.145em"),
    ),
    # The IndoPak fonts bring their own ayah mark; the books' IndoPak text
    # holds no hizb sign.
    "indopak_nastaleeq": MarkLook(
        number_size="1.2em", hizb_font="text", hizb_size="0.6em",
        bare_name_room=("0.145em", "0.297em"),
        wbw_mark_room="1.62em",
    ),
}


def get_mark_look(font_key: str, ornament_fonts: bool = True) -> MarkLook:
    """How the ayah number and the hizb sign are drawn with this Quran font.

    ornament_fonts: whether the book's script goes with the ornament fonts
    (it decides the look for a font that the table does not name).
    """
    look = FONT_MARKS.get(font_key)
    if look is not None:
        return look
    return _MARK_LOOK_DEFAULT if ornament_fonts else _MARK_LOOK_OWN_SIGN


# --- Script/Font Pairing Validation ---
# Each script maps to a list of fonts known to render it correctly.
# The first font in each list is the recommended default.

SCRIPT_FONT_PAIRS: dict[str, list[str]] = {
    "text_uthmani": ["amiri_quran", "scheherazade_new", "me_quran"],
    "text_uthmani_simple": ["amiri_quran", "scheherazade_new"],
    "qpc_uthmani_hafs": ["kfgqpc_uthmanic_hafs", "amiri_quran"],
    "text_imlaei": ["amiri_quran", "scheherazade_new"],
    "text_imlaei_simple": ["amiri_quran", "scheherazade_new"],
    "text_indopak": ["indopak_nastaleeq", "kfgqpc_nastaleeq"],
    "text_indopak_nastaleeq": ["indopak_nastaleeq", "kfgqpc_nastaleeq"],
    "qpc_uthmani_warsh": ["kfgqpc_uthmanic_warsh"],
    "qpc_uthmani_hafs_tajweed": ["kfgqpc_uthmanic_hafs", "kfgqpc_uthmanic_hafs_v17"],  # QPC text + CSS tajweed color spans
    "qcf_v4_tajweed": ["qcf_v4"],  # QCF per-page glyph fonts (COLR v0 tajweed colors)
    "qcf_v1_plain": ["qcf_v1"],  # QCF per-page glyph fonts (no color)
}

# --- Glyph Font Compatibility ---
# Scripts that are NOT compatible with the decorative Naskh glyph fonts
# (surah-name-v4 calligraphy, quran-common U+FDFD basmala ligature).
# These scripts render basmala from the actual ayah text in the primary font,
# and use plain Arabic for surah headers (same approach as Warsh).
_SCRIPTS_NO_GLYPH_FONTS: frozenset[str] = frozenset({
    "text_indopak",
    "text_indopak_nastaleeq",
})


def script_uses_glyph_fonts(script: str) -> bool:
    """Whether decorative Naskh glyph fonts are compatible with this script."""
    return script not in _SCRIPTS_NO_GLYPH_FONTS


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
# (English name, Arabic cover subtitle) for cover pages and metadata.

SCRIPT_LABELS: dict[str, tuple[str, str]] = {
    "qpc_uthmani_hafs": ("QPC Uthmani Hafs", "برواية حفص عن عاصم"),
    "qpc_uthmani_warsh": ("QPC Uthmani Warsh", "برواية ورش عن نافع"),
    "text_uthmani": ("Uthmani", "بالرسم العثماني"),
    "text_uthmani_simple": ("Uthmani (Simplified)", "بالرسم العثماني المبسّط"),
    "text_imlaei": ("Imla'i", "بالرسم الإملائي"),
    "text_imlaei_simple": ("Imla'i (Simplified)", "بالرسم الإملائي المبسّط"),
    "text_indopak": ("IndoPak", "بالرسم الهندي"),
    "text_indopak_nastaleeq": ("IndoPak Nastaleeq", "بالرسم الهندي"),
    "qpc_uthmani_hafs_tajweed": ("QPC Uthmani Hafs Tajweed", "برواية حفص عن عاصم · تجويد"),
    "qcf_v4_tajweed": ("QCF V4 Tajweed", "برواية حفص عن عاصم · تجويد"),
    "qcf_v1_plain": ("QCF V1 Plain", "برواية حفص عن عاصم"),
}


# --- Riwayah Short Names ---
# Short Arabic name for dc:title (compact). Full form is in SCRIPT_LABELS.

RIWAYAH_ARABIC: dict[str, str] = {
    "hafs": "حفص",
    "warsh": "ورش",
    "qalun": "قالون",
    "shubah": "شعبة",
}


# --- Layout Display Labels ---
# (English description, Arabic label) used in dc:title and cover
# when a translation is present (to distinguish bilingual from interactive).

LAYOUT_LABELS: dict[str, tuple[str, str]] = {
    "inline": ("continuous text", "نص مستمر"),
    "interactive_inline": ("continuous + tap-translation", "نص مستمر"),
    # تفاعلي disambiguates from bilingual's آية بآية — same granularity,
    # popup placement (owner call 2026-07-19: disambiguate only where
    # genuinely ambiguous; نص مستمر stays bare).
    "ayah_popup": ("ayah-by-ayah + tap-translation", "آية بآية · تفاعلي"),
    "by_surah": ("ayah-by-ayah", "آية بآية"),
    "wbw": ("word-by-word", "كلمة بكلمة"),
    "wbw_popup": ("word-by-word + tap-translation", "كلمة بكلمة · تفاعلي"),
    "qcf_inline": ("QCF glyph inline", "خط مصحف"),
    "qcf_by_surah": ("QCF glyph ayah-by-ayah", "خط مصحف · آية بآية"),
    "qcf_interactive": ("QCF glyph interactive", "خط مصحف"),
    "qcf_fixed": ("QCF mushaf layout", "خط مصحف"),
    "qcf_fixed_interactive": ("QCF mushaf interactive", "خط مصحف"),
    "bilingual_interactive": ("ayah-by-ayah + tafsir popup", "آية بآية"),
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
    "qpc_uthmani_hafs_tajweed": "hafs",
    "text_imlaei": "hafs",
    "text_imlaei_simple": "hafs",
    "text_indopak": "hafs",
    "text_indopak_nastaleeq": "hafs",
    "text_qpc_nastaleeq": "hafs",
    "qpc_uthmani_warsh": "warsh",
    "qcf_v4_tajweed": "hafs",
    "qcf_v1_plain": "hafs",
    # Future riwayat:
    # "qpc_uthmani_qalun": "qalun",
    # "qpc_uthmani_shubah": "shubah",
}


def get_riwayah(script: str) -> str:
    """Get the riwayah for a script. Defaults to 'hafs'."""
    return SCRIPT_RIWAYAH.get(script, "hafs")


# --- Shorthand Abbreviations ---
# Compact codes used in output filenames.

# Script abbreviations for filenames. Empty string = omitted (default script
# for that font, no disambiguation needed). Non-empty = inserted between
# riwayah and font in the filename.
ABBREV_SCRIPTS: dict[str, str] = {
    "qpc_uthmani_hafs": "",
    "qpc_uthmani_warsh": "",
    "text_qpc_hafs": "",
    "text_uthmani": "",
    "text_uthmani_simple": "simple",
    "text_imlaei": "imlaei",
    "text_imlaei_simple": "imlaeis",
    "text_indopak": "indopak",
    "text_indopak_nastaleeq": "indopak",
    "text_qpc_nastaleeq": "",
    "text_qpc_nastaleeq_hafs": "",
    "qpc_uthmani_hafs_tajweed": "tajweed",
    "qcf_v4_tajweed": "qcf4",
    "qcf_v1_plain": "qcf1",
}

ABBREV_FONTS: dict[str, str] = {
    "amiri_quran": "amiri",
    "scheherazade_new": "schz",
    "kfgqpc_uthmanic_hafs": "kfgqpc",
    "kfgqpc_uthmanic_warsh": "kfgqpc",
    "me_quran": "meq",
    "noto_sans_arabic": "noto",
    "qcf_v4": "",  # Redundant with script tag
    "qcf_v1": "",  # Redundant with script tag
    "indopak_nastaleeq": "indopak",
    "kfgqpc_nastaleeq": "nastaleeq",
}

ABBREV_LAYOUTS: dict[str, str] = {
    "by_surah": "ayah",
    "inline": "inline",
    "interactive_inline": "interactive",
    "ayah_popup": "ayah-int",
    "bilingual_interleaved": "bilin",
    "bilingual_columns": "cols",
    "arabic_tafseer": "tafseer",
    "spread": "spread",
    "mushaf_fixed": "mushaf",
    "translation_only": "trans",
    "wbw": "wbw",
    "wbw_popup": "wbwpop",
    "qcf_inline": "inline",
    "qcf_by_surah": "ayah",
    "qcf_interactive": "interactive",
    "qcf_fixed": "mushaf",
    "qcf_fixed_interactive": "mushaf-i",
    "bilingual_interactive": "bilin-int",
}


# --- Native Language Names ---
# Display names in their native script, used on bilingual cover pages.
# Source: Quran.com API /resources/languages endpoint.


# --- Translation Font Size by Script ---
# Scripts with smaller apparent size at the same em get a slight bump.
# Default is 0.6em (Latin, Cyrillic, Georgian, Armenian, CJK, Devanagari, Bengali).
_BUMPED_LANGS: set[str] = {
    # Arabic script — smallest apparent size, most needed
    "ur", "fa", "ps", "ku", "ug", "sd",  # Urdu, Farsi, Pashto, Kurdish, Uyghur, Sindhi
    # Thai / Khmer — small body, tall marks
    "th", "km",
    # South Indian scripts — rounder, more complex than Devanagari
    "ta", "te", "kn", "ml", "si",  # Tamil, Telugu, Kannada, Malayalam, Sinhala
    # Ethiopic — dense complex letterforms
    "am", "ti",  # Amharic, Tigrinya
    # Myanmar — notoriously small apparent size
    "my",
}


@dataclass(frozen=True)
class TranslationSizes:
    """The sizes of translated text in a book.

    block: a translation paragraph, counted in the reader's text size.
    in_note: a note's text, counted in the size of the note's box (which
        carries the Quran text's size, 1.5).
    word_meaning: a word's meaning under the word, counted in the size of
        the word-by-word row (the Quran text's size).
    """

    block: str
    in_note: str
    word_meaning: str


# The Quran text is 1.5 of the reader's text size; translated text is 0.6
# of that (0.65 for the scripts in _BUMPED_LANGS), a word's meaning 0.9 of
# the translation. `block` is that product, written a touch off the round
# value (0.9, 0.975) so that KOReader, which cuts every size down to whole
# screen dots, lands on the same dot as it did when the size was nested.
_TRANSLATION_SIZES = TranslationSizes(block="0.902em", in_note="0.6em", word_meaning="0.54em")
_TRANSLATION_SIZES_BUMPED = TranslationSizes(block="0.972em", in_note="0.65em", word_meaning="0.585em")


def is_bumped_language(lang_code: str | None) -> bool:
    """Whether translated text in this language gets the larger size."""
    return lang_code in _BUMPED_LANGS


def get_translation_sizes(lang_code: str | None) -> TranslationSizes:
    """The sizes of translated text for a language (None: no translation).

    Most scripts: 0.6 of the Quran text (tuned for Latin x-height; also fine
    for Cyrillic, CJK, Devanagari, Bengali, Hebrew, Georgian, Armenian).
    Bumped scripts: 0.65 (Arabic, Thai/Khmer, South Indian, Ethiopic, Myanmar).
    """
    return _TRANSLATION_SIZES_BUMPED if is_bumped_language(lang_code) else _TRANSLATION_SIZES


NATIVE_LANGUAGE_NAMES: dict[str, str] = {
    "ar": "العربية",
    "en": "English",
    "fr": "Français",
    "tr": "Türkçe",
    "ur": "اردو",
    "id": "Bahasa Indonesia",
    "ms": "Bahasa Melayu",
    "es": "Español",
    "ru": "Русский",
    "bn": "বাংলা",
    "fa": "فارسی",
    "de": "Deutsch",
    "nl": "Nederlands",
    "it": "Italiano",
    "pt": "Português",
    "ja": "日本語",
    "zh": "中文",
    "ko": "한국어",
    "ps": "پښتو",
    "ha": "Hausa",
    "sw": "Kiswahili",
    "so": "Soomaali",
    "am": "አማርኛ",
    "hi": "हिन्दी",
    "ta": "தமிழ்",
    "th": "ไทย",
    "tg": "Тоҷикӣ",
    "sq": "Shqip",
    "bs": "Bosanski",
    "az": "Azərbaycanca",
    "uz": "Oʻzbekcha",
    "kk": "Қазақша",
    "ku": "کوردی",
    "ug": "ئۇيغۇرچە",
    "ml": "മലയാളം",
    "vi": "Tiếng Việt",
    "tl": "Filipino",
    "yo": "Yorùbá",
    "ff": "Fulfulde",
    "sv": "Svenska",
    "pl": "Polski",
    "uk": "Українська",
    "no": "Norsk",
}

# English exonyms — catalog/OPDS/plugin shelf titles are "English · native"
# (owner decision 2026-07-20, presentation pass). Keep in step with
# NATIVE_LANGUAGE_NAMES; catalog.json carries both so downstream surfaces
# never maintain their own code→name maps.
ENGLISH_LANGUAGE_NAMES: dict[str, str] = {
    "ar": "Arabic",
    "en": "English",
    "fr": "French",
    "tr": "Turkish",
    "ur": "Urdu",
    "id": "Indonesian",
    "ms": "Malay",
    "es": "Spanish",
    "ru": "Russian",
    "bn": "Bengali",
    "fa": "Persian",
    "de": "German",
    "nl": "Dutch",
    "it": "Italian",
    "pt": "Portuguese",
    "ja": "Japanese",
    "zh": "Chinese",
    "ko": "Korean",
    "ps": "Pashto",
    "ha": "Hausa",
    "sw": "Swahili",
    "so": "Somali",
    "am": "Amharic",
    "hi": "Hindi",
    "ta": "Tamil",
    "th": "Thai",
    "tg": "Tajik",
    "sq": "Albanian",
    "bs": "Bosnian",
    "az": "Azerbaijani",
    "uz": "Uzbek",
    "kk": "Kazakh",
    "ku": "Kurdish",
    "ug": "Uyghur",
    "ml": "Malayalam",
    "vi": "Vietnamese",
    "tl": "Filipino",
    "yo": "Yoruba",
    "ff": "Fulfulde",
    "sv": "Swedish",
    "pl": "Polish",
    "uk": "Ukrainian",
    "no": "Norwegian",
}

# Shelf labels for the shared catalog/OPDS/plugin facet tree (owner
# decision 2026-07-20): gen_catalog stamps these per variant
# (axes.layout_shelf / axes.script_shelf) so every browsing surface groups
# by the SAME strings. Unknown combos fall back to raw tokens at stamp
# time — new classes are never silently dropped.
LAYOUT_SHELF_LABELS: dict[tuple[str, str | None], str] = {
    ("flow", None): "Continuous flow",
    ("ayah", None): "Ayah-by-ayah (Arabic only)",
    ("ayah", "inline"): "Ayah-by-ayah with translation",
    ("ayah", "popup"): "Ayah-by-ayah + tap-translation",
    ("flow", "popup"): "Continuous + tap-translation",
    ("word", "inline"): "Word-by-word",
}

SCRIPT_SHELF_LABELS: dict[tuple[str, str], str] = {
    ("hafs", "uthmani"): "Hafs · Uthmani (KFGQPC)",
    ("hafs", "indopak"): "Hafs · IndoPak (Nastaleeq)",
    ("warsh", "uthmani"): "Warsh · Uthmani (KFGQPC)",
}


def abbreviate(category: str, key: str) -> str:
    """Get the shorthand abbreviation for a key.

    Args:
        category: One of "script", "font", "layout".
        key: The full key to abbreviate.

    Returns:
        The shorthand code, or the key itself if no abbreviation exists.
        For "script", returns empty string if the script needs no tag.
    """
    tables = {
        "script": ABBREV_SCRIPTS,
        "font": ABBREV_FONTS,
        "layout": ABBREV_LAYOUTS,
    }
    table = tables.get(category, {})
    return table.get(key, key)
