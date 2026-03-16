"""EPUB3 builder — assembles a valid EPUB from Quran data and templates.

An EPUB is a ZIP file containing:
  mimetype          — "application/epub+zip" (uncompressed, first entry, byte offset 0)
  META-INF/
    container.xml   — points to the OPF file
    com.apple.ibooks.display-options.xml  — tells iBooks to use embedded fonts
  OEBPS/
    package.opf     — manifest, spine, metadata
    toc.xhtml       — EPUB3 navigation document
    cover.xhtml     — cover page
    chapter-N.xhtml — one per surah (by_surah mode, 114 files)
    chapters.xhtml  — all surahs continuous (inline mode)
    styles/
      base.css      — RTL + font styles
    fonts/
      *.ttf         — embedded Arabic fonts
"""

import logging
import re
import uuid
import zipfile
from datetime import datetime, timezone
from html import escape as xml_escape
from io import BytesIO
from pathlib import Path

import click
import jinja2
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont

# Suppress fonttools "TSIS NOT subset; don't know how to subset; dropped"
# warnings — harmless noise about unknown font tables.
logging.getLogger("fontTools.subset").setLevel(logging.ERROR)

from ..config.registry import (
    FONTS,
    LAYOUT_LABELS,
    NATIVE_LANGUAGE_NAMES,
    RIWAYAH_ARABIC,
    SCRIPT_LABELS,
    get_riwayah,
)
from ..config.registry import get_translation_font_size
from ..config.schema import BuildConfig
from ..models import Mushaf, Surah
from ..data.quran_api import get_language_direction, load_quran as load_quran_api
from ..data.kfgqpc import load_quran_kfgqpc
from ..data.tanzil import load_quran as load_quran_tanzil
from ..data.validate import validate_and_report
from ..fonts.manager import get_font_path


# Symbol font used for hizb markers (۞) and plain Arabic-Indic digits.
# Scheherazade New renders ۞ as an ornamental 8-petaled flower/lotus
# that matches the aesthetic of traditional Quran printing, and digits
# as plain numbers (unlike KFGQPC which renders all digits as ornate markers).
SYMBOL_FONT_KEY = "scheherazade_new"

# Basmala font — used for the U+FDFD (﷽) ornamental bismillah ligature.
# quran-common renders U+FDFD as a compact traditional mushaf-style basmala.
# Also provides juz labels, markers, and icons for future use.
BASMALA_FONT_KEY = "quran_common"

# Header label font — used for Arabic labels "ترتيبها" / "آياتها" in surah
# header side columns.  Me Quran is a naskh-style Quran font with beautiful
# Arabic letter forms.  Subsetted to only the letters needed (no digits —
# Me Quran renders digits as ornate markers like KFGQPC).
HEADER_LABEL_FONT_KEY = "me_quran"

# Surah name font — ligature-based icon font from QUL/Tarteel.
# ASCII triggers like "surah001" render as calligraphic mushaf-style
# surah name glyphs via OpenType liga substitution.
# Bundled as package data (modified: RSB fix for 3 glyphs).
SURAH_NAME_FONT_KEY = "surah_name_v4"

# Cover font for Arabic riwayah line (PNG only) — full Scheherazade, not subsetted.
COVER_RIWAYAH_FONT_KEY = "scheherazade_new"

# Cover fonts for translator line (PNG only).
# Maps language code → (filename in fonts/cover/, CSS family name).
# Arabic-script non-Urdu langs use Scheherazade (same as riwayah, already loaded).
# Latin/Cyrillic langs use NotoSans as default.
_COVER_FONTS: dict[str, tuple[str, str]] = {
    "ur": ("NotoNastaliqUrdu-Regular.ttf", "Noto Nastaliq Urdu"),
    "bn": ("NotoSansBengali-Regular.ttf", "Noto Sans Bengali"),
    "hi": ("NotoSansDevanagari-Regular.ttf", "Noto Sans Devanagari"),
    "ta": ("NotoSansTamil-Regular.ttf", "Noto Sans Tamil"),
    "ml": ("NotoSansMalayalam-Regular.ttf", "Noto Sans Malayalam"),
    "th": ("NotoSansThai-Regular.ttf", "Noto Sans Thai"),
    "am": ("NotoSansEthiopic-Regular.ttf", "Noto Sans Ethiopic"),
    "ti": ("NotoSansEthiopic-Regular.ttf", "Noto Sans Ethiopic"),
    "zh": ("NotoSansCJKsc-Regular.otf", "Noto Sans CJK SC"),
    "ja": ("NotoSansCJKsc-Regular.otf", "Noto Sans CJK SC"),
    "ko": ("NotoSansCJKsc-Regular.otf", "Noto Sans CJK SC"),
}
# Arabic-script languages (non-Urdu) that should use Scheherazade for translator line
_ARABIC_SCRIPT_LANGS = {"fa", "ps", "ku", "ug", "sd"}
# Default cover font for Latin/Cyrillic scripts
_COVER_FONT_DEFAULT = ("NotoSans-Regular.ttf", "Noto Sans")
# Base size for translator line; bumped langs get ~17% increase
_COVER_TR_BASE_SIZE = 72
_COVER_TR_BUMPED_SIZE = 84
# Languages where em dash separator is confusing (Japanese ー looks like —)
_COVER_DOT_SEPARATOR_LANGS = {"ja"}

# Project namespace UUID for deterministic EPUB identifiers.
# Same config rebuilt produces the same UUID, so e-readers recognise updates.
_NAMESPACE = uuid.UUID("d4f76c9a-3b1e-4f2d-9a5c-8b7e6d1c2f3a")

# Unicode codepoints to keep when subsetting auxiliary fonts.
# Scheherazade New: core Arabic letters, tashkeel, digits, hizb marker.
# Used for in-book cover (riwayah, layout descriptor), TOC (surah names,
# juz labels), hizb markers, and plain-numeral display.
_SYMBOL_FONT_CODEPOINTS = {
    0x0020,                   # space
    *range(0x0621, 0x064B),   # all Arabic letters (hamza through yaa)
    *range(0x064B, 0x0656),   # tashkeel (fathatan through maddah, hamza above/below)
    0x0670,                   # superscript alef
    *range(0x0660, 0x066A),   # Arabic-Indic digits ٠١٢٣٤٥٦٧٨٩
    0x06DE,                   # rub al-hizb ۞
}

# Me Quran: Arabic letters for header labels ترتيبها آياتها (no digits).
_HEADER_LABEL_CODEPOINTS = {
    0x0020,                   # space
    0x0622, 0x0627, 0x0628, 0x062A, 0x0631, 0x0647, 0x064A,
}

# quran-common: bismillah ligature (U+FDFD) + cover title ligature.
# The "quran" ASCII trigger fires a liga rule → U+E076 (ornamental القرآن الكريم).
# Both the ASCII codepoints and the PUA target must be in the subset to
# prevent the subsetter from pruning the GSUB rule.
_BASMALA_FONT_CODEPOINTS = {
    0xFDFD,                       # ﷽  bismillah ligature
    0xE076,                       # PUA: ornamental quran title glyph
    *[ord(c) for c in "quran"],   # ASCII trigger for liga → U+E076
}


def _subset_font(font_bytes: bytes, codepoints: set[int]) -> bytes:
    """Subset a TTF font to only include the specified Unicode codepoints.

    Preserves OpenType layout features (GSUB/GPOS) needed for proper
    Arabic shaping of the retained glyphs.
    """
    font = TTFont(BytesIO(font_bytes))
    options = Options()
    options.layout_features = ["*"]
    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)
    out = BytesIO()
    font.save(out)
    return out.getvalue()


def _get_version() -> str:
    """Get the package version for EPUB metadata."""
    from importlib.metadata import version as pkg_version
    try:
        return pkg_version("quran-ebook")
    except Exception:
        return "dev"


def _arabic_numerals(n: int) -> str:
    """Convert an integer to Eastern Arabic-Indic numerals (٠١٢٣٤٥٦٧٨٩)."""
    eastern = str.maketrans("0123456789", "٠١٢٣٤٥٦٧٨٩")
    return str(n).translate(eastern)


def _compute_page_markers(mushaf: Mushaf) -> None:
    """Set page_marker on each ayah that starts a new Madinah Mushaf page.

    Mutates ayah objects in-place. Only has effect when page_number data
    is available (Quran.com API source).
    """
    prev_page = None
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.page_number is not None and ayah.page_number != prev_page:
                ayah.page_marker = ayah.page_number
                prev_page = ayah.page_number


def _collect_footnotes(mushaf: Mushaf) -> list:
    """Collect unique footnotes from all ayahs across all surahs.

    Returns deduplicated footnotes in order of first appearance.
    Used by bilingual and WBW builders to populate endnotes.xhtml.
    """
    all_footnotes = []
    seen_ids: set[int] = set()
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            for fn in ayah.footnotes:
                if fn.id not in seen_ids:
                    all_footnotes.append(fn)
                    seen_ids.add(fn.id)
    return all_footnotes


def _compute_page_list(mushaf: Mushaf, page_href_fn) -> list[dict]:
    """Build page-list entries for EPUB3 navigation.

    Returns a list of dicts with keys: page, href, label.
    Only works when ayah data includes page_number (Quran.com API source).

    Args:
        page_href_fn: callable(surah_number, page_number) -> href string
            pointing to the pagebreak span's ID.
    """
    entries = []
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.page_marker is not None:
                entries.append({
                    "page": ayah.page_marker,
                    "href": page_href_fn(surah.number, ayah.page_marker),
                    "label": str(ayah.page_marker),
                })
    return entries


def _compute_juz_entries(mushaf: Mushaf, href_fn) -> list[dict]:
    """Extract juz boundary information for TOC navigation.

    Returns a list of dicts with keys: juz, href, label_text, label_num.
    Only works when ayah data includes juz_number (Quran.com API source).
    Always uses Arabic labels and numerals (Arabic-first design).

    Args:
        href_fn: callable(surah_number, ayah_number) -> href string
    """
    entries = []
    prev_juz = None
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.juz_number is not None and ayah.juz_number != prev_juz:
                entries.append({
                    "juz": ayah.juz_number,
                    "href": href_fn(surah.number, ayah.ayah_number),
                    "label_text": "جزء",
                    "label_num": _arabic_numerals(ayah.juz_number),
                })
                prev_juz = ayah.juz_number
    return entries


def _render_cover_image(
    cover_html: str,
    cover_fonts: dict[str, bytes],
    cover_lines: list[str] | None = None,
    cover_style: str = "bilingual",
    arabic_font_family: str = "Scheherazade New",
    tr_font_family: str = "",
    tr_font_size: int = _COVER_TR_BASE_SIZE,
    cover_font_faces: dict[str, str] | None = None,
) -> bytes:
    """Render the cover XHTML to a PNG image via WeasyPrint (PDF) + PyMuPDF.

    WeasyPrint v68+ only outputs PDF.  We render to an in-memory PDF, then
    rasterise the single page to 1200×1600 PNG with PyMuPDF (fitz).

    Args:
        cover_html: Rendered cover XHTML string.
        cover_fonts: Mapping of font filenames to font bytes used by the cover.
        cover_lines: Optional lines of text shown below the glyph.
        arabic_font_family: CSS font-family for Arabic riwayah label.
        tr_font_family: CSS font-family for translator line (empty = sans-serif).
        tr_font_size: Font size in px for translator line (default 72, bumped 78).
        cover_font_faces: Mapping of CSS family name → filename for @font-face injection.
        cover_style: "arabic" (black/gold, centered glyph),
                     "interactive" (black/gold, glyph up),
                     "bilingual" (cream, glyph up).
    """
    import tempfile

    import fitz  # PyMuPDF — lazy import
    from weasyprint import HTML

    # Style presets: (background, glyph_color, text_color, glyph_top)
    # glyph_top: flex centering offset — higher padding = glyph pushed up
    if cover_style == "arabic":
        bg, glyph_color, text_color = "#1A1A1A", "#C5A55A", "#C5A55A"
        glyph_top = True  # centered (no extra top push)
    elif cover_style == "interactive":
        bg, glyph_color, text_color = "#1A1A1A", "#C5A55A", "#C5A55A"
        glyph_top = False  # pushed up for text room
    elif cover_style == "wbw":
        bg, glyph_color, text_color = "#F5F0E8", "#333", "#444"
        glyph_top = False  # pushed up for text room
    else:  # bilingual
        bg, glyph_color, text_color = "#B0B0B0", "#1A1A1A", "#222"
        glyph_top = False  # pushed up for text room

    # Glyph vertical position: centered uses align-items:center,
    # pushed-up uses padding-top to shift glyph into upper portion
    if glyph_top:
        body_align = "align-items: center;"
    else:
        body_align = "align-items: flex-start; padding-top: 200px;"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for filename, data in cover_fonts.items():
            (tmp_path / filename).write_bytes(data)

        # Rewrite relative font URLs to absolute paths for WeasyPrint.
        html_for_image = cover_html.replace(
            "url('fonts/", f"url('file://{tmp_path}/"
        )
        # Build label HTML (injected as a positioned div)
        label_block = ""
        if cover_lines:
            from xml.sax.saxutils import escape as xml_esc

            label_block = '<div class="cover-label">'
            label_block += (
                '<div class="cover-label-ar">'
                + xml_esc(cover_lines[0])
                + "</div>"
            )
            if len(cover_lines) > 1:
                label_block += (
                    '<div class="cover-label-tr">'
                    + xml_esc(cover_lines[1])
                    + "</div>"
                )
            label_block += "</div>"

        # Use a wrapper div for reliable absolute positioning within the page
        wrapper_html = (
            f'<div class="img-cover">'
            f'<div class="img-glyph">&#xE076;</div>'
            f'{label_block}'
            f'</div>'
        )

        # Build @font-face rules for cover-specific fonts (riwayah + translator).
        # cover_font_faces maps CSS family name → filename in cover_fonts dict.
        extra_faces = ""
        for family, filename in (cover_font_faces or {}).items():
            extra_faces += (
                f"\n        @font-face {{"
                f" font-family: '{family}';"
                f" src: url('file://{tmp_path}/{filename}') format('truetype');"
                f" }}"
            )

        image_css = (
            f"{extra_faces}\n" if extra_faces else ""
        ) + (
            "@page { size: 1200px 1600px; margin: 0; }\n"
            "        .cover-wrap { display: none; }\n"
            f"        body {{ margin: 0; padding: 0; background: {bg};"
            f" direction: ltr; }}\n"
            "        body::before { content: none; }\n"
            f"        .img-cover {{ width: 1200px; height: 1600px;"
            f" position: relative; }}\n"
            f"        .img-glyph {{ position: absolute;"
            f" top: 0; left: 0; right: 0;"
            f" {'height: 1200px;' if not glyph_top else 'height: 1600px;'}"
            f" display: flex; align-items: center; justify-content: center;"
            f" font-family: 'quran-common', serif;"
            f" font-size: 600px; color: {glyph_color}; }}\n"
            f"        .cover-label {{ position: absolute;"
            f" {'bottom: 140px;' if glyph_top else 'top: 980px;'}"
            f" left: 60px; right: 60px; text-align: center;"
            f" color: {text_color}; }}\n"
            f"        .cover-label-ar {{ font-family: '{arabic_font_family}', sans-serif;"
            f" font-size: 120px; margin-bottom: 20px; }}\n"
            f"        .cover-label-tr {{ font-family:"
            f" {chr(39) + tr_font_family + chr(39) + ', ' if tr_font_family else ''}"
            f"sans-serif; font-size: {tr_font_size}px; line-height: 1.35;"
            f" overflow-wrap: break-word; word-wrap: break-word; }}"
        )
        # Inject wrapper before </body>
        html_for_image = html_for_image.replace(
            "</body>", f"{wrapper_html}\n</body>"
        )
        html_for_image = html_for_image.replace(
            "</style>", f"  {image_css}\n    </style>"
        )

        pdf_bytes = HTML(string=html_for_image).write_pdf()

    # Rasterise the single-page PDF to PNG.
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    page = doc[0]
    # Scale so the longer dimension is 1600px.
    scale = 1600 / max(page.rect.width, page.rect.height)
    mat = fitz.Matrix(scale, scale)
    pix = page.get_pixmap(matrix=mat, alpha=False)
    png_bytes = pix.tobytes("png")
    doc.close()
    return png_bytes


def _build_cover_subtitle(config: BuildConfig) -> str | None:
    """Build the Arabic riwayah subtitle for the cover page."""
    script_info = SCRIPT_LABELS.get(
        "text_uthmani" if config.quran.source == "tanzil" else config.quran.script
    )
    return script_info[1] if script_info else None


def _build_descriptive_title(config: BuildConfig) -> str:
    """Build a descriptive title for OPF metadata.

    Arabic-only:    "القرآن الكريم برواية حفص عن عاصم"
    Bilingual:      "القرآن الكريم برواية حفص عن عاصم · آية بآية · English"
    WBW:            "القرآن الكريم برواية حفص عن عاصم · كلمة بكلمة · Türkçe"
    WBW cross-lang: "القرآن الكريم برواية حفص عن عاصم · كلمة بكلمة · Français · English WBW"
    """
    full_riwayah = _build_cover_subtitle(config) or RIWAYAH_ARABIC.get(
        get_riwayah(config.quran.script), get_riwayah(config.quran.script)
    )
    # Title + riwayah read as one phrase (no separator)
    base = f"{config.book.title} {full_riwayah}"
    if not config.translation:
        return base
    parts = [base]
    layout_info = LAYOUT_LABELS.get(config.layout.structure)
    if layout_info:
        parts.append(layout_info[1])
    lang_name = (
        config.translation.language_name
        or NATIVE_LANGUAGE_NAMES.get(config.translation.language)
        or config.translation.language.upper()
    )
    parts.append(lang_name)
    # Cross-language WBW indicator
    if config.layout.structure == "wbw" and config.layout.wbw_gloss_language:
        gloss = config.layout.wbw_gloss_language
        if gloss != config.translation.language:
            gloss_name = (
                NATIVE_LANGUAGE_NAMES.get(gloss)
                or gloss.upper()
            )
            parts.append(f"{gloss_name} WBW")
    return " · ".join(parts)


def _create_jinja_env() -> jinja2.Environment:
    """Create a Jinja2 environment with the templates directory."""
    templates_dir = Path(__file__).parent.parent / "templates"
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(templates_dir)),
        autoescape=False,  # XHTML templates handle their own escaping
    )
    env.filters["arabic_numerals"] = _arabic_numerals
    return env


def render_cover_png(
    config: BuildConfig,
    font_bytes: bytes,
    basmala_font_bytes: bytes,
    cover_html: str,
    version: str | None = None,
) -> bytes:
    """Render the PNG cover image for a given config.

    This is the single code path used by both the EPUB builder and the
    test-cover generator, so they always produce identical PNGs.

    Args:
        config: Build configuration.
        font_bytes: Primary Arabic font bytes (already loaded).
        basmala_font_bytes: quran-common font bytes (**already subsetted**).
        cover_html: Rendered cover.xhtml.j2 HTML string.
        version: Optional version string (unused in PNG, kept for parity).

    Returns:
        PNG image bytes.
    """
    font_info = FONTS[config.font.arabic]
    layout = config.layout.structure
    is_bilingual = config.translation is not None

    cover_fonts: dict[str, bytes] = {font_info.filename: font_bytes}
    cover_fonts[FONTS[BASMALA_FONT_KEY].filename] = basmala_font_bytes
    cover_font_dir = Path(__file__).parent.parent.parent.parent / "fonts" / "cover"

    # Load full Scheherazade for riwayah line from fonts/cover/ (not the subsetted
    # symbol version bundled in EPUB).  Committed to repo for CI determinism.
    riwayah_font_info = FONTS[COVER_RIWAYAH_FONT_KEY]
    riwayah_font_path = cover_font_dir / riwayah_font_info.filename
    riwayah_font_bytes = riwayah_font_path.read_bytes()
    cover_fonts[riwayah_font_info.filename] = riwayah_font_bytes
    cover_font_faces: dict[str, str] = {
        riwayah_font_info.family: riwayah_font_info.filename,
    }

    # Load per-language cover font for translator line
    tr_lang = config.translation.language if config.translation else ""
    tr_font_family = ""
    tr_font_size = _COVER_TR_BASE_SIZE
    if tr_lang in _COVER_FONTS:
        tr_filename, tr_font_family = _COVER_FONTS[tr_lang]
        tr_font_path = cover_font_dir / tr_filename
        if tr_font_path.exists():
            cover_fonts[tr_filename] = tr_font_path.read_bytes()
            cover_font_faces[tr_font_family] = tr_filename
            click.echo(f"  Cover font: {tr_font_path} ({tr_font_family})")
        else:
            raise click.ClickException(
                f"Cover font missing: {tr_font_path} — "
                f"cover text for '{tr_lang}' would render as tofu in CI"
            )
    elif tr_lang in _ARABIC_SCRIPT_LANGS:
        # Use Scheherazade (already loaded for riwayah)
        tr_font_family = riwayah_font_info.family
        click.echo(f"  Cover font: {riwayah_font_path} ({tr_font_family}, Arabic-script)")
    else:
        # Latin/Cyrillic — load Noto Sans as default
        default_filename, tr_font_family = _COVER_FONT_DEFAULT
        default_path = cover_font_dir / default_filename
        if default_path.exists():
            cover_fonts[default_filename] = default_path.read_bytes()
            cover_font_faces[tr_font_family] = default_filename
            click.echo(f"  Cover font: {default_path} ({tr_font_family}, default)")
        else:
            raise click.ClickException(
                f"Default cover font missing: {default_path}"
            )

    # Apply font size bump for languages with smaller apparent size
    if tr_lang and get_translation_font_size(tr_lang) == "0.65em":
        tr_font_size = _COVER_TR_BUMPED_SIZE

    # Build cover lines and style for PNG
    subtitle = _build_cover_subtitle(config)
    riwayah = get_riwayah(config.quran.script)
    riwayah_ar = RIWAYAH_ARABIC.get(riwayah, riwayah)
    full_riwayah = subtitle or riwayah_ar
    if is_bilingual:
        lang_name = (
            config.translation.language_name
            or NATIVE_LANGUAGE_NAMES.get(config.translation.language)
            or config.translation.language.upper()
        )
        sep = " · " if config.translation.language in _COVER_DOT_SEPARATOR_LANGS else " — "
        translator_line = f"{lang_name}{sep}{config.translation.display_name}"
        cover_lines: list[str] = [full_riwayah, translator_line]
        if layout == "wbw":
            cover_style = "wbw"
        elif layout == "interactive_inline":
            cover_style = "interactive"
        else:
            cover_style = "bilingual"
    else:
        cover_lines = [full_riwayah]
        cover_style = "arabic"

    return _render_cover_image(
        cover_html, cover_fonts, cover_lines=cover_lines, cover_style=cover_style,
        arabic_font_family=riwayah_font_info.family,
        tr_font_family=tr_font_family,
        tr_font_size=tr_font_size,
        cover_font_faces=cover_font_faces,
    )


def _render_package_opf(
    config: BuildConfig,
    chapter_items: list[tuple[str, str]],
    font_filenames: list[str],
    descriptive_title: str,
) -> str:
    """Render the OPF package document.

    Args:
        chapter_items: list of (id, href) pairs for chapter manifest/spine entries.
        font_filenames: list of font filenames to include in manifest.
    """
    # Stable UUID — same config always produces same identifier
    book_id = str(uuid.uuid5(_NAMESPACE, config.output_filename))
    modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    version = _get_version()

    manifest_items = []
    spine_items = []

    # Navigation document
    manifest_items.append(
        '<item id="toc" href="toc.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>'
    )

    # Cover image (for library/cover browsers)
    manifest_items.append(
        '<item id="cover-image" href="cover.png" '
        'media-type="image/png" properties="cover-image"/>'
    )

    # Cover page (reading order)
    manifest_items.append(
        '<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>'
    )
    spine_items.append('<itemref idref="cover"/>')

    # TOC in spine (visible as readable page, not just nav menu)
    spine_items.append('<itemref idref="toc"/>')

    # Chapters (+ endnotes as non-linear)
    for item_id, href in chapter_items:
        manifest_items.append(
            f'<item id="{item_id}" href="{href}" '
            f'media-type="application/xhtml+xml"/>'
        )
        if item_id == "endnotes":
            spine_items.append(f'<itemref idref="{item_id}" linear="no"/>')
        else:
            spine_items.append(f'<itemref idref="{item_id}"/>')

    # Stylesheet
    manifest_items.append(
        '<item id="css" href="styles/base.css" media-type="text/css"/>'
    )

    # Fonts
    for i, filename in enumerate(font_filenames):
        font_id = "font-arabic" if i == 0 else f"font-symbol-{i}"
        manifest_items.append(
            f'<item id="{font_id}" href="fonts/{filename}" '
            f'media-type="font/ttf"/>'
        )

    # Add translation language if bilingual
    extra_lang = ""
    if config.translation:
        extra_lang = f"\n    <dc:language>{config.translation.language}</dc:language>"

    # Translator as dc:creator (only for translated variants)
    creator_line = ""
    if config.translation:
        creator_line = f"\n    <dc:creator>{xml_escape(config.translation.display_name)}</dc:creator>"

    # Build description — includes layout type for disambiguation
    riwayah = get_riwayah(config.quran.script)
    layout_info = LAYOUT_LABELS.get(config.layout.structure)
    layout_en = layout_info[0] if layout_info else config.layout.structure
    # Each riwayah has a specific teacher (qari) in the chain of transmission.
    _RIWAYAH_TEACHER = {
        "hafs": "'Asim", "shubah": "'Asim",
        "warsh": "Nafi'", "qalun": "Nafi'",
        "doori": "Abu 'Amr", "soosi": "Abu 'Amr",
        "bazzi": "Ibn Kathir", "qunbul": "Ibn Kathir",
    }
    teacher = _RIWAYAH_TEACHER.get(riwayah, "'Asim")
    desc_parts = [f"Riwayat {riwayah.title()} 'an {teacher}"]
    desc_parts.append(layout_en)
    is_kfgqpc = config.quran.source == "kfgqpc"
    if is_kfgqpc:
        desc_parts.append("KFGQPC digital page layout (604 pages)")
    else:
        desc_parts.append("Madinah Mushaf (1405 AH) page references (604 pages)")
    if config.translation:
        desc_parts.append(
            f"{config.translation.display_name} translation ({config.translation.language.upper()})"
        )
    description = ", ".join(desc_parts)

    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="bookid" xml:lang="{config.book.language}" dir="rtl">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:{book_id}</dc:identifier>
    <dc:title>{xml_escape(descriptive_title)}</dc:title>
    <dc:language>{config.book.language}</dc:language>{extra_lang}
    <dc:description>{xml_escape(description)}</dc:description>{creator_line}
    <dc:publisher>quran-ebook</dc:publisher>
    <dc:subject>Quran</dc:subject>
    <dc:rights>Quran text and translation sourced from Quran.com API</dc:rights>
    <meta property="dcterms:modified">{modified}</meta>
    <meta name="generator" content="quran-ebook {version}"/>
    <meta name="primary-writing-mode" content="horizontal-rl"/>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    {"".join(f"    {item}" + chr(10) for item in manifest_items)}  </manifest>
  <spine page-progression-direction="rtl">
    {"".join(f"    {item}" + chr(10) for item in spine_items)}  </spine>
</package>
"""


def _render_container_xml() -> str:
    return """<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def _render_ibooks_options() -> str:
    return """<?xml version="1.0" encoding="utf-8"?>
<display_options>
  <platform name="*">
    <option name="specified-fonts">true</option>
  </platform>
</display_options>
"""


def _assemble_epub(files: dict[str, bytes]) -> bytes:
    """Assemble an EPUB zip archive.

    The EPUB spec requires:
    - mimetype must be the first entry
    - mimetype must be stored uncompressed (ZIP_STORED)
    - mimetype must have no extra field (byte offset 0 for the content after the local header)
    """
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        # mimetype MUST be first, uncompressed, no extra field
        info = zipfile.ZipInfo("mimetype")
        info.compress_type = zipfile.ZIP_STORED
        info.extra = b""
        zf.writestr(info, "application/epub+zip")

        # Everything else, deflated
        for path, content in files.items():
            zf.writestr(path, content)

    return buf.getvalue()



def build_epub(config: BuildConfig) -> Path:
    """Build a complete EPUB from the given configuration.

    Returns the path to the generated EPUB file.
    """
    # 1. Load Quran data
    source = config.quran.source
    script = config.quran.script
    translation_id = config.translation.resource_id if config.translation else None
    translation_language = config.translation.language if config.translation else None
    translation_source = config.translation.source if config.translation else "quran_api"
    translation_edition = config.translation.edition if config.translation else ""
    layout = config.layout.structure
    # WBW layout needs word-level data; use explicit gloss language, translation language, or English
    wbw_language = None
    if layout == "wbw":
        wbw_language = (
            config.layout.wbw_gloss_language
            or (config.translation.language if config.translation else "en")
        )
    if source == "quran_api":
        mushaf = load_quran_api(
            script,
            translation_id=translation_id,
            translation_language=translation_language,
            translation_source=translation_source,
            translation_edition=translation_edition,
            wbw_language=wbw_language,
        )
    elif source == "kfgqpc":
        riwayah = config.quran.script.removeprefix("qpc_uthmani_")
        mushaf = load_quran_kfgqpc(riwayah)
    elif source == "tanzil":
        if translation_id:
            raise ValueError("Translation support requires quran_api source, not tanzil")
        quran_type = "uthmani" if "uthmani" in script else "simple"
        mushaf = load_quran_tanzil(quran_type)
    else:
        raise ValueError(f"Unknown data source: {source}")

    # 2. Validate loaded data
    validate_and_report(mushaf)

    # 3. Compute page markers (before rendering templates)
    _compute_page_markers(mushaf)

    # 4. Resolve fonts (primary + symbol + basmala)
    font_info = FONTS[config.font.arabic]
    font_path = get_font_path(config.font.arabic)
    font_bytes = font_path.read_bytes()

    symbol_font_info = FONTS[SYMBOL_FONT_KEY]
    symbol_font_path = get_font_path(SYMBOL_FONT_KEY)
    symbol_font_bytes = symbol_font_path.read_bytes()
    symbol_full_size = len(symbol_font_bytes)
    symbol_font_bytes = _subset_font(symbol_font_bytes, _SYMBOL_FONT_CODEPOINTS)
    click.echo(
        f"  Font subset: {symbol_font_info.family} "
        f"{symbol_full_size:,} → {len(symbol_font_bytes):,} bytes"
    )

    basmala_font_info = FONTS[BASMALA_FONT_KEY]
    basmala_font_path = (
        Path(__file__).parent.parent / "assets" / "fonts" / basmala_font_info.filename
    )
    basmala_font_bytes = basmala_font_path.read_bytes()
    basmala_full_size = len(basmala_font_bytes)
    basmala_font_bytes = _subset_font(basmala_font_bytes, _BASMALA_FONT_CODEPOINTS)
    click.echo(
        f"  Font subset: {basmala_font_info.family} "
        f"{basmala_full_size:,} → {len(basmala_font_bytes):,} bytes"
    )

    header_label_font_info = FONTS[HEADER_LABEL_FONT_KEY]
    header_label_font_path = get_font_path(HEADER_LABEL_FONT_KEY)
    header_label_font_bytes = header_label_font_path.read_bytes()
    header_label_full_size = len(header_label_font_bytes)
    header_label_font_bytes = _subset_font(
        header_label_font_bytes, _HEADER_LABEL_CODEPOINTS
    )
    click.echo(
        f"  Font subset: {header_label_font_info.family} "
        f"{header_label_full_size:,} → {len(header_label_font_bytes):,} bytes"
    )

    surah_name_font_info = FONTS[SURAH_NAME_FONT_KEY]
    surah_name_font_path = (
        Path(__file__).parent.parent / "assets" / "fonts" / surah_name_font_info.filename
    )
    surah_name_font_bytes = surah_name_font_path.read_bytes()

    # 5. Render CSS with font info
    css_template_path = Path(__file__).parent.parent / "templates" / "styles" / "base.css.j2"
    css_text = css_template_path.read_text(encoding="utf-8")
    css_text = css_text.replace("{{ font_family }}", font_info.family)
    css_text = css_text.replace("{{ font_filename }}", font_info.filename)
    css_text = css_text.replace("{{ symbol_font_family }}", symbol_font_info.family)
    css_text = css_text.replace("{{ symbol_font_filename }}", symbol_font_info.filename)
    # For KFGQPC non-Hafs, render basmala with primary font (no U+FDFD ligature).
    basmala_css_family = font_info.family if config.quran.source == "kfgqpc" else basmala_font_info.family
    css_text = css_text.replace("{{ basmala_font_family }}", basmala_css_family)
    css_text = css_text.replace("{{ basmala_font_filename }}", basmala_font_info.filename)
    css_text = css_text.replace("{{ header_label_font_family }}", header_label_font_info.family)
    css_text = css_text.replace("{{ header_label_font_filename }}", header_label_font_info.filename)
    css_text = css_text.replace("{{ surah_name_font_family }}", surah_name_font_info.family)
    css_text = css_text.replace("{{ surah_name_font_filename }}", surah_name_font_info.filename)
    # Hizb marker: KFGQPC uses primary font at 0.5em, Hafs uses Scheherazade at 0.8em.
    is_kfgqpc = config.quran.source == "kfgqpc"
    hizb_font_family = font_info.family if is_kfgqpc else symbol_font_info.family
    hizb_font_size = "0.6em" if is_kfgqpc else "0.8em"
    css_text = css_text.replace("{{ hizb_font_family }}", hizb_font_family)
    css_text = css_text.replace("{{ hizb_font_size }}", hizb_font_size)
    translation_font_size = (
        get_translation_font_size(config.translation.language)
        if config.translation
        else "0.6em"
    )
    css_text = css_text.replace("{{ translation_font_size }}", translation_font_size)
    # WBW gloss = 90% of translation size — scales with script-specific bumps
    trans_em = float(translation_font_size.replace("em", ""))
    wbw_gloss_font_size = f"{trans_em * 0.9:.3g}em"
    css_text = css_text.replace("{{ wbw_gloss_font_size }}", wbw_gloss_font_size)

    # 6. Render XHTML files
    env = _create_jinja_env()
    # KFGQPC non-Hafs sources lack the decorative glyph fonts (surah-name-v4,
    # quran-common basmala).  Templates fall back to plain Arabic text in the
    # primary font when use_glyph_fonts is False.
    use_glyph_fonts = config.quran.source != "kfgqpc"
    env.globals["use_glyph_fonts"] = use_glyph_fonts
    layout = config.layout.structure

    cover_template = env.get_template("cover.xhtml.j2")
    toc_template = env.get_template("toc.xhtml.j2")

    files: dict[str, bytes] = {}

    # META-INF
    files["META-INF/container.xml"] = _render_container_xml().encode("utf-8")
    files["META-INF/com.apple.ibooks.display-options.xml"] = (
        _render_ibooks_options().encode("utf-8")
    )

    # Cover
    is_bilingual = config.translation is not None
    subtitle = _build_cover_subtitle(config)
    translation_label = None
    if is_bilingual:
        lang_name = (
            config.translation.language_name
            or NATIVE_LANGUAGE_NAMES.get(config.translation.language)
            or config.translation.language.upper()
        )
        sep = " · " if config.translation.language in _COVER_DOT_SEPARATOR_LANGS else " — "
        translation_label = xml_escape(f"{lang_name}{sep}{config.translation.display_name}")
    # Layout descriptor for cover — only when translation exists
    # (distinguishes bilingual آية بآية from interactive نص مستمر)
    layout_descriptor = None
    if config.translation:
        layout_info = LAYOUT_LABELS.get(layout)
        if layout_info:
            layout_descriptor = layout_info[1]

    cover_html = cover_template.render(
        title=config.book.title,
        subtitle=subtitle,
        font_family=font_info.family,
        font_filename=font_info.filename,
        cover_font_family=basmala_font_info.family,
        cover_font_filename=basmala_font_info.filename,
        symbol_font_family=symbol_font_info.family,
        symbol_font_filename=symbol_font_info.filename,
        translation_label=translation_label,
        layout_descriptor=layout_descriptor,
        version=_get_version(),
    )
    files["OEBPS/cover.xhtml"] = cover_html.encode("utf-8")

    # Cover image for library/cover browsers
    click.echo("Rendering cover image...")
    cover_png = render_cover_png(config, font_bytes, basmala_font_bytes, cover_html)
    files["OEBPS/cover.png"] = cover_png
    click.echo(f"  Cover image: {len(cover_png):,} bytes")

    # Chapters + TOC (layout-dependent)
    # For Hafs (quran_api/tanzil): use U+FDFD ornamental basmala from quran-common.
    # For KFGQPC non-Hafs: use QPC-encoded basmala extracted from S27:30,
    # rendered in the primary font with correct riwayah-specific diacritics.
    use_glyph_fonts = config.quran.source != "kfgqpc"
    if use_glyph_fonts:
        bismillah = "\uFDFD"
    else:
        bismillah = mushaf.bismillah_text
    if layout == "wbw":
        if not config.translation:
            raise ValueError("wbw layout requires a translation config")
        wbw_gloss_lang = config.layout.wbw_gloss_language or config.translation.language
        wbw_gloss_dir = get_language_direction(wbw_gloss_lang)
        translation_lang = config.translation.language
        translation_dir = get_language_direction(translation_lang)
        chapter_items, href_fn, page_href_fn, chapter_href = _build_wbw(
            env, mushaf, files, bismillah, config,
            wbw_gloss_lang, wbw_gloss_dir,
            translation_lang, translation_dir,
        )
    elif layout == "interactive_inline":
        if not config.translation:
            raise ValueError("interactive_inline layout requires a translation config")
        translation_dir = get_language_direction(config.translation.language)
        chapter_items, href_fn, page_href_fn, chapter_href = _build_interactive(
            env, mushaf, files, bismillah, config.translation.language, translation_dir
        )
    elif config.translation:
        translation_dir = get_language_direction(config.translation.language)
        chapter_items, href_fn, page_href_fn, chapter_href = _build_bilingual(
            env, mushaf, files, bismillah, config.translation.language, translation_dir
        )
    elif layout == "inline":
        chapter_items, href_fn, page_href_fn, chapter_href = _build_continuous(
            env, mushaf, files, bismillah
        )
    else:
        chapter_items, href_fn, page_href_fn, chapter_href = _build_by_surah(
            env, mushaf, files, bismillah
        )

    # TOC
    juz_entries = _compute_juz_entries(mushaf, href_fn=href_fn)
    page_list = _compute_page_list(mushaf, page_href_fn=page_href_fn)
    toc_html = toc_template.render(
        surahs=mushaf.surahs,
        juz_entries=juz_entries,
        page_list=page_list,
        chapter_href=chapter_href,
        is_bilingual=is_bilingual,
        symbol_font_family=symbol_font_info.family,
    )
    files["OEBPS/toc.xhtml"] = toc_html.encode("utf-8")

    # CSS
    files["OEBPS/styles/base.css"] = css_text.encode("utf-8")

    # Fonts
    files[f"OEBPS/fonts/{font_info.filename}"] = font_bytes
    font_filenames = [font_info.filename]
    if symbol_font_info.filename != font_info.filename:
        files[f"OEBPS/fonts/{symbol_font_info.filename}"] = symbol_font_bytes
        font_filenames.append(symbol_font_info.filename)
    if basmala_font_info.filename not in font_filenames:
        files[f"OEBPS/fonts/{basmala_font_info.filename}"] = basmala_font_bytes
        font_filenames.append(basmala_font_info.filename)
    if header_label_font_info.filename not in font_filenames:
        files[f"OEBPS/fonts/{header_label_font_info.filename}"] = header_label_font_bytes
        font_filenames.append(header_label_font_info.filename)
    if surah_name_font_info.filename not in font_filenames:
        files[f"OEBPS/fonts/{surah_name_font_info.filename}"] = surah_name_font_bytes
        font_filenames.append(surah_name_font_info.filename)

    # OPF
    descriptive_title = _build_descriptive_title(config)
    opf = _render_package_opf(config, chapter_items, font_filenames, descriptive_title)
    files["OEBPS/package.opf"] = opf.encode("utf-8")

    # 7. Assemble EPUB
    epub_bytes = _assemble_epub(files)

    # 8. Write to output
    output_dir = Path(config.output.directory)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{config.output_filename}.epub"
    output_path.write_bytes(epub_bytes)

    click.echo(f"EPUB created: {output_path} ({len(epub_bytes):,} bytes)")
    return output_path


def _build_by_surah(env, mushaf, files, bismillah):
    """Build per-surah chapter files (one XHTML per surah)."""
    click.echo("Rendering 114 surahs...")
    chapter_template = env.get_template("chapter.xhtml.j2")
    chapter_items = []

    for surah in mushaf.surahs:
        chapter_html = chapter_template.render(surah=surah, bismillah_text=bismillah)
        files[f"OEBPS/chapter-{surah.number}.xhtml"] = chapter_html.encode("utf-8")
        chapter_items.append((f"chapter-{surah.number}", f"chapter-{surah.number}.xhtml"))

    def href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, href_fn, page_href_fn, chapter_href


def _build_continuous(env, mushaf, files, bismillah):
    """Build inline layout — one XHTML per surah with continuous text flow.

    Each surah starts on a new page (file boundary = guaranteed page break).
    """
    click.echo("Rendering 114 surahs (inline flow, per-surah files)...")

    template = env.get_template("chapter_inline.xhtml.j2")
    chapter_items = []

    for surah in mushaf.surahs:
        chapter_html = template.render(surah=surah, bismillah_text=bismillah)
        files[f"OEBPS/chapter-{surah.number}.xhtml"] = chapter_html.encode("utf-8")
        chapter_items.append((f"chapter-{surah.number}", f"chapter-{surah.number}.xhtml"))

    def href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, href_fn, page_href_fn, chapter_href


def _strip_noteref_links(text: str) -> str:
    """Replace <a> noteref links with plain <sup> for popup display.

    KOReader's footnote popup doesn't support interactive links or superscript
    styling within popups. Converting noterefs to plain <sup> ensures footnote
    numbers display as superscripts in the popup.
    """
    return re.sub(r'<a\s[^>]*class="noteref"[^>]*>(.*?)</a>', r'<sup>\1</sup>', text)


def _build_interactive(env, mushaf, files, bismillah, translation_lang, translation_dir):
    """Build interactive layout — per-surah inline flow with clickable ayah markers.

    Each ayah marker is an EPUB3 noteref linking to a translation endnote.
    KOReader shows the translation as a popup on tap. Translator footnotes
    are inlined directly into each translation note (since KOReader popups
    don't support nested links).
    """
    click.echo("Rendering 114 surahs (interactive inline flow, per-surah files)...")

    template = env.get_template("chapter_interactive.xhtml.j2")
    endnotes_template = env.get_template("endnotes.xhtml.j2")
    chapter_items = []

    for surah in mushaf.surahs:
        chapter_html = template.render(surah=surah, bismillah_text=bismillah)
        files[f"OEBPS/chapter-{surah.number}.xhtml"] = chapter_html.encode("utf-8")
        chapter_items.append((f"chapter-{surah.number}", f"chapter-{surah.number}.xhtml"))

    # Collect translation notes with inlined footnotes for endnotes.
    # Noteref links in translation text are replaced with plain <sup> tags,
    # and the footnote text is appended inline so everything shows in one popup.
    translation_notes = []

    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.translation:
                translation_notes.append({
                    "surah": surah.number,
                    "ayah": ayah.ayah_number,
                    "text": _strip_noteref_links(ayah.translation),
                    "footnotes": list(ayah.footnotes),
                })

    # Render endnotes (translation notes with inlined footnotes, no separate footnote asides)
    endnotes_html = endnotes_template.render(
        translation_notes=translation_notes,
        footnotes=[],
        endnotes_lang=translation_lang,
        endnotes_dir=translation_dir,
    )
    files["OEBPS/endnotes.xhtml"] = endnotes_html.encode("utf-8")
    chapter_items.append(("endnotes", "endnotes.xhtml"))

    def href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, href_fn, page_href_fn, chapter_href


def _build_bilingual(env, mushaf, files, bismillah, translation_lang, translation_dir):
    """Build bilingual ayah-by-ayah chapter files (one XHTML per surah).

    Each ayah shows Arabic text followed by translation. Footnotes are
    collected into a separate endnotes.xhtml file so EPUB3 readers can
    show them as popups when noteref links are tapped.
    """
    click.echo("Rendering 114 surahs (bilingual ayah-by-ayah)...")
    template = env.get_template("chapter_bilingual.xhtml.j2")
    endnotes_template = env.get_template("endnotes.xhtml.j2")
    chapter_items = []
    all_footnotes = _collect_footnotes(mushaf)

    for surah in mushaf.surahs:
        chapter_html = template.render(
            surah=surah,
            bismillah_text=bismillah,
            translation_lang=translation_lang,
            translation_dir=translation_dir,
        )
        files[f"OEBPS/chapter-{surah.number}.xhtml"] = chapter_html.encode("utf-8")
        chapter_items.append((f"chapter-{surah.number}", f"chapter-{surah.number}.xhtml"))

    # Render endnotes file (all footnotes across all surahs)
    if all_footnotes:
        endnotes_html = endnotes_template.render(
            footnotes=all_footnotes,
            endnotes_lang=translation_lang,
            endnotes_dir=translation_dir,
        )
        files["OEBPS/endnotes.xhtml"] = endnotes_html.encode("utf-8")
        chapter_items.append(("endnotes", "endnotes.xhtml"))

    def _bilin_href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def _bilin_page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def _bilin_chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, _bilin_href_fn, _bilin_page_href_fn, _bilin_chapter_href


def _build_wbw(
    env, mushaf, files, bismillah, config,
    wbw_gloss_lang, wbw_gloss_dir,
    translation_lang, translation_dir,
):
    """Build word-by-word interlinear chapter files (one XHTML per surah).

    Each ayah shows Arabic words as inline-table stacks (Arabic on top,
    gloss below, optional transliteration). When a full translation is
    configured, it appears as a paragraph below the word stacks.
    """
    has_translation = translation_lang is not None
    show_translit = config.layout.wbw_transliteration
    click.echo(
        f"Rendering 114 surahs (word-by-word, "
        f"gloss={wbw_gloss_lang}, translit={'on' if show_translit else 'off'}, "
        f"translation={'on' if has_translation else 'off'})..."
    )
    template = env.get_template("chapter_wbw.xhtml.j2")
    endnotes_template = env.get_template("endnotes.xhtml.j2")
    chapter_items = []
    all_footnotes = _collect_footnotes(mushaf) if has_translation else []

    for surah in mushaf.surahs:
        chapter_html = template.render(
            surah=surah,
            bismillah_text=bismillah,
            show_transliteration=show_translit,
            show_translation=has_translation,
            translation_lang=translation_lang or "",
            translation_dir=translation_dir or "ltr",
            wbw_gloss_lang=wbw_gloss_lang,
            wbw_gloss_dir=wbw_gloss_dir,
        )
        files[f"OEBPS/chapter-{surah.number}.xhtml"] = chapter_html.encode("utf-8")
        chapter_items.append((f"chapter-{surah.number}", f"chapter-{surah.number}.xhtml"))

    # Render endnotes file if we have footnotes from the full translation
    if all_footnotes:
        endnotes_html = endnotes_template.render(
            footnotes=all_footnotes,
            endnotes_lang=translation_lang,
            endnotes_dir=translation_dir,
        )
        files["OEBPS/endnotes.xhtml"] = endnotes_html.encode("utf-8")
        chapter_items.append(("endnotes", "endnotes.xhtml"))

    def _wbw_href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def _wbw_page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def _wbw_chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, _wbw_href_fn, _wbw_page_href_fn, _wbw_chapter_href
