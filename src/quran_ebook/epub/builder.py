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

import re
import uuid
import zipfile
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

import click
import jinja2

from ..config.registry import (
    FONTS,
    LAYOUT_LABELS,
    NATIVE_LANGUAGE_NAMES,
    RIWAYAH_ARABIC,
    SCRIPT_LABELS,
    get_riwayah,
)
from ..config.schema import BuildConfig
from ..models import Mushaf, Surah
from ..data.quran_api import get_language_direction, load_quran as load_quran_api
from ..data.tanzil import load_quran as load_quran_tanzil
from ..data.validate import validate_and_report
from ..fonts.manager import get_font_path


# Symbol font used for hizb markers (۞) and plain Arabic-Indic digits.
# Scheherazade New renders ۞ as an ornamental 8-petaled flower/lotus
# that matches the aesthetic of traditional Quran printing, and digits
# as plain numbers (unlike KFGQPC which renders all digits as ornate markers).
SYMBOL_FONT_KEY = "scheherazade_new"

# Project namespace UUID for deterministic EPUB identifiers.
# Same config rebuilt produces the same UUID, so e-readers recognise updates.
_NAMESPACE = uuid.UUID("d4f76c9a-3b1e-4f2d-9a5c-8b7e6d1c2f3a")


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


def _build_cover_subtitle(config: BuildConfig) -> str | None:
    """Build the Arabic riwayah subtitle for the cover page."""
    script_info = SCRIPT_LABELS.get(
        "text_uthmani" if config.quran.source == "tanzil" else config.quran.script
    )
    return script_info[1] if script_info else None


def _build_descriptive_title(config: BuildConfig) -> str:
    """Build a descriptive title for OPF metadata.

    Arabic-only:  "القرآن الكريم — حفص"
    Bilingual:    "القرآن الكريم — حفص — آية بآية — Sahih International"
    Interactive:  "القرآن الكريم — حفص — نص مستمر — Sahih International"
    """
    riwayah = get_riwayah(config.quran.script)
    riwayah_ar = RIWAYAH_ARABIC.get(riwayah, riwayah)
    parts = [config.book.title, riwayah_ar]
    # Layout descriptor only when translation exists (distinguishes modes)
    if config.translation:
        layout_info = LAYOUT_LABELS.get(config.layout.structure)
        if layout_info:
            parts.append(layout_info[1])
        parts.append(config.translation.name)
    return " — ".join(parts)


def _create_jinja_env() -> jinja2.Environment:
    """Create a Jinja2 environment with the templates directory."""
    templates_dir = Path(__file__).parent.parent / "templates"
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(templates_dir)),
        autoescape=False,  # XHTML templates handle their own escaping
    )
    env.filters["arabic_numerals"] = _arabic_numerals
    return env


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

    # Cover
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

    # Build description — includes layout type for disambiguation
    riwayah = get_riwayah(config.quran.script)
    layout_info = LAYOUT_LABELS.get(config.layout.structure)
    layout_en = layout_info[0] if layout_info else config.layout.structure
    desc_parts = [f"Riwayat {riwayah.title()} 'an 'Asim"]
    desc_parts.append(layout_en)
    desc_parts.append("Madinah Mushaf (1405 AH) page references (604 pages)")
    if config.translation:
        desc_parts.append(
            f"{config.translation.name} translation ({config.translation.language.upper()})"
        )
    description = ", ".join(desc_parts)

    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="bookid" xml:lang="{config.book.language}" dir="rtl">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:{book_id}</dc:identifier>
    <dc:title>{descriptive_title}</dc:title>
    <dc:language>{config.book.language}</dc:language>{extra_lang}
    <dc:description>{description}</dc:description>
    <dc:publisher>quran-ebook</dc:publisher>
    <dc:subject>Quran</dc:subject>
    <dc:rights>Quran text and translation sourced from Quran.com API</dc:rights>
    <meta property="dcterms:modified">{modified}</meta>
    <meta name="generator" content="quran-ebook {version}"/>
    <meta name="primary-writing-mode" content="horizontal-rl"/>
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
    if source == "quran_api":
        mushaf = load_quran_api(
            script,
            translation_id=translation_id,
            translation_language=translation_language,
        )
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

    # 4. Resolve fonts (primary + symbol)
    font_info = FONTS[config.font.arabic]
    font_path = get_font_path(config.font.arabic)
    font_bytes = font_path.read_bytes()

    symbol_font_info = FONTS[SYMBOL_FONT_KEY]
    symbol_font_path = get_font_path(SYMBOL_FONT_KEY)
    symbol_font_bytes = symbol_font_path.read_bytes()

    # 5. Render CSS with font info
    css_template_path = Path(__file__).parent.parent / "templates" / "styles" / "base.css"
    css_text = css_template_path.read_text(encoding="utf-8")
    css_text = css_text.replace("{{ font_family }}", font_info.family)
    css_text = css_text.replace("{{ font_filename }}", font_info.filename)
    css_text = css_text.replace("{{ symbol_font_family }}", symbol_font_info.family)
    css_text = css_text.replace("{{ symbol_font_filename }}", symbol_font_info.filename)

    # 6. Render XHTML files
    env = _create_jinja_env()
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
        translation_label = f"{lang_name} — {config.translation.name}"
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
        english_title=None,
        translation_label=translation_label,
        translation_name=None,
        layout_descriptor=layout_descriptor,
        version=_get_version(),
    )
    files["OEBPS/cover.xhtml"] = cover_html.encode("utf-8")

    # Chapters + TOC (layout-dependent)
    bismillah = mushaf.bismillah_text
    if layout == "interactive_inline":
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
    all_footnotes = []
    seen_fn_ids = set()

    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            for fn in ayah.footnotes:
                if fn.id not in seen_fn_ids:
                    all_footnotes.append(fn)
                    seen_fn_ids.add(fn.id)

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

    def href_fn(s, a):
        return f"chapter-{s}.xhtml#ayah-{s}-{a}"

    def page_href_fn(s, p):
        return f"chapter-{s}.xhtml#page{p}"

    def chapter_href(n):
        return f"chapter-{n}.xhtml"

    return chapter_items, href_fn, page_href_fn, chapter_href
