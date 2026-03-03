#!/usr/bin/env python
"""Extract Clear Quran translation with footnotes from EPUB.

One-time extraction: parses the official Clear Quran EPUB and writes
per-chapter translation data to ~/.cache/quran-ebook/ in the same
format as _fetch_translation() returns, so it flows through the
existing pipeline unchanged.

Usage:
    python tools/extract_clear_quran.py [path/to/epub]

Default path:
    docs/The Clear Quran_ A Thematic English Transl - Mustafa Khattab.epub
"""

import html
import re
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from quran_ebook.data.cache import cache_set

# Expected ayah counts per surah (indices 0-113 for surahs 1-114)
EXPECTED_AYAH_COUNTS = [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,
    5, 4, 5, 6,
]

# --- Regex patterns for HTML parsing ---

# Surah header: bold "N. Name" followed by <br/>
_SURAH_HEADER = re.compile(
    r'<span style="font-size:1\.0rem; font-weight:bold">(\d+)\.\s+(.+?)</span>\s*<br\s*/?>'
)

# Ayah number marker: bold "N." — usually in one span, but 54:49 has a
# split format where the period is in a separate bold span with extra styling.
_AYAH_MARKER = re.compile(
    r'<span style="font-size:1\.0rem; font-weight:bold[^"]*">(\d+)'
    r'(?:\.</span>'  # Standard: number and period in same span
    r'|\s*</span>\s*<span style="font-size:1\.0rem; font-weight:bold[^"]*">\.</span>)'  # Split
)

# Footnote reference: <a id="_ednrefN"></a><a href="..."><span>[N]</span></a>
_FOOTNOTE_REF = re.compile(
    r'<a id="_ednref(\d+)"[^>]*></a>\s*'
    r'<a href="text00000\.html#_edn\d+"[^>]*>\s*'
    r'<span[^>]*>\[?\d+\]?</span>\s*'
    r'</a>',
    re.DOTALL,
)

# Thematic heading paragraphs (blue italic, may contain footnote refs)
_THEMATIC_HEADING = re.compile(
    r'<p[^>]*>\s*<span[^>]*color:#002060[^>]*>.*?</p>',
    re.DOTALL,
)

# Separator blocks (*** in maroon)
_SEPARATOR = re.compile(
    r'<p[^>]*>\s*<span[^>]*color:#943634[^>]*>\*\*\*</span>\s*</p>',
    re.DOTALL,
)

# Surah introduction paragraphs (red italic)
_SURAH_INTRO = re.compile(
    r'<p[^>]*>\s*<span[^>]*color:#c00000[^>]*>.*?</p>',
    re.DOTALL,
)

# Centered bismillah paragraphs (non-ayah bismillah above surah text)
_CENTERED_BISMILLAH = re.compile(
    r'<p[^>]*text-align:center[^>]*>\s*<span[^>]*>In the Name of Allah[^<]*</span>\s*</p>',
    re.DOTALL,
)

# Endnote block: <div id="_ednN">...</div>
_ENDNOTE_BLOCK = re.compile(
    r'<div id="_edn(\d+)"[^>]*>(.*?)</div>',
    re.DOTALL,
)

# Endnote back-reference link
_ENDNOTE_BACKREF = re.compile(
    r'<a href="text00000\.html#_ednref\d+"[^>]*>.*?</a>',
    re.DOTALL,
)


def read_epub_html(epub_path: str) -> str:
    """Extract the main HTML file from the EPUB."""
    with zipfile.ZipFile(epub_path) as zf:
        return zf.read("OEBPS/text00000.html").decode("utf-8")


def extract_endnotes(content: str) -> dict[str, str]:
    """Parse all endnote definitions from the endnotes section.

    Returns a dict mapping endnote ID (string) to cleaned text.
    """
    endnotes = {}
    for match in _ENDNOTE_BLOCK.finditer(content):
        edn_id = match.group(1)
        edn_html = match.group(2)
        # Remove the back-reference link [N]
        edn_html = _ENDNOTE_BACKREF.sub("", edn_html)
        # Strip all HTML tags
        text = re.sub(r"<[^>]+>", "", edn_html)
        # Unescape HTML entities
        text = html.unescape(text)
        # Normalize whitespace
        text = " ".join(text.split()).strip()
        endnotes[edn_id] = text
    return endnotes


def find_surah_sections(content: str) -> list[tuple[int, str, str]]:
    """Split content into per-surah HTML sections.

    Returns [(surah_number, english_name, section_html), ...]
    """
    headers = list(_SURAH_HEADER.finditer(content))
    if len(headers) != 114:
        print(f"  WARNING: Found {len(headers)} surah headers (expected 114)")

    # Cut off content at back matter (Thematic Index / endnotes)
    last_header_pos = headers[-1].start() if headers else 0
    thematic_pos = content.find("THEMATIC INDEX", last_header_pos)
    endnotes_pos = content.find('<div id="_edn')
    candidates = [p for p in [thematic_pos, endnotes_pos] if p > 0]
    end_boundary = min(candidates) if candidates else len(content)

    sections = []
    for idx, header in enumerate(headers):
        num = int(header.group(1))
        name = html.unescape(header.group(2)).strip()
        start = header.end()
        if idx + 1 < len(headers):
            end = headers[idx + 1].start()
        else:
            end = end_boundary
        sections.append((num, name, content[start:end]))
    return sections


def extract_ayahs(surah_html: str, surah_num: int, endnotes: dict[str, str]) -> list[dict]:
    """Extract ayah translations from a surah's HTML section.

    Returns list of dicts in _fetch_translation() format:
    [{"text": "...<sup foot_note=N>N</sup>...", "foot_notes": {"N": "text"}}, ...]
    """
    # Remove structural elements that aren't ayah text
    surah_html = _THEMATIC_HEADING.sub("", surah_html)
    surah_html = _SEPARATOR.sub("", surah_html)
    surah_html = _SURAH_INTRO.sub("", surah_html)
    surah_html = _CENTERED_BISMILLAH.sub("", surah_html)

    markers = list(_AYAH_MARKER.finditer(surah_html))
    if not markers:
        return []

    ayahs = []
    for idx, marker in enumerate(markers):
        ayah_num = int(marker.group(1))
        start = marker.end()
        end = markers[idx + 1].start() if idx + 1 < len(markers) else len(surah_html)
        ayah_html = surah_html[start:end]

        # Convert footnote refs to <sup foot_note=N>N</sup>
        footnote_ids = []

        def replace_fn(m, _ids=footnote_ids):
            fn_id = m.group(1)
            _ids.append(fn_id)
            return f"<sup foot_note={fn_id}>{fn_id}</sup>"

        ayah_html = _FOOTNOTE_REF.sub(replace_fn, ayah_html)

        # Strip all HTML tags except <sup> and </sup>
        ayah_html = re.sub(r"<(?!/?sup[\s>])/?[a-zA-Z][^>]*>", "", ayah_html)

        # Unescape HTML entities
        text = html.unescape(ayah_html)

        # Normalize whitespace (collapse runs, trim)
        text = " ".join(text.split()).strip()

        # Build foot_notes dict for referenced endnotes
        fn_dict = {}
        for fn_id in footnote_ids:
            if fn_id in endnotes:
                fn_dict[fn_id] = endnotes[fn_id]
            else:
                print(f"  WARNING: Surah {surah_num}:{ayah_num} refs endnote {fn_id} but not found")

        ayahs.append({"text": text, "foot_notes": fn_dict})

    return ayahs


def main():
    epub_path = sys.argv[1] if len(sys.argv) > 1 else (
        "docs/The Clear Quran_ A Thematic English Transl - Mustafa Khattab.epub"
    )

    if not Path(epub_path).exists():
        print(f"Error: EPUB not found at {epub_path}")
        sys.exit(1)

    print(f"Reading: {epub_path}")
    content = read_epub_html(epub_path)
    print(f"  {len(content):,} chars, {content.count(chr(10)):,} lines")

    # Step 1: Extract endnotes
    print("\nExtracting endnotes...")
    endnotes = extract_endnotes(content)
    print(f"  {len(endnotes)} endnotes")

    # Step 2: Split into surah sections
    print("\nFinding surah boundaries...")
    sections = find_surah_sections(content)
    print(f"  {len(sections)} surahs")

    # Step 3: Extract ayahs per surah and write to cache
    print("\nExtracting ayahs...")
    total_ayahs = 0
    total_fn = 0
    all_fn_ids = set()
    errors = []

    for surah_num, name, section_html in sections:
        ayahs = extract_ayahs(section_html, surah_num, endnotes)
        expected = EXPECTED_AYAH_COUNTS[surah_num - 1]
        fn_count = sum(len(a["foot_notes"]) for a in ayahs)

        for a in ayahs:
            all_fn_ids.update(a["foot_notes"].keys())

        if len(ayahs) != expected:
            errors.append((surah_num, name, len(ayahs), expected))
            print(f"  ✗ {surah_num:3d}. {name:30s}  {len(ayahs):3d}/{expected} ayahs, {fn_count} fn")

        total_ayahs += len(ayahs)
        total_fn += fn_count

        cache_set(f"local_clearquran_ch{surah_num}", ayahs)

    # Summary
    print(f"\n{'='*60}")
    print(f"Ayahs:     {total_ayahs:,} (expected 6,236)")
    print(f"Footnotes: {total_fn:,} mapped to ayahs")
    print(f"Endnotes:  {len(endnotes):,} total, {len(all_fn_ids):,} in ayahs, "
          f"{len(endnotes) - len(all_fn_ids):,} heading-only")

    if errors:
        print(f"\n✗ {len(errors)} surah(s) with wrong ayah count:")
        for num, name, got, expected in errors:
            print(f"  Surah {num} ({name}): got {got}, expected {expected}")
    elif total_ayahs == 6236:
        print(f"\n✓ All 114 surahs match expected ayah counts")

    # Show samples for verification
    print(f"\nSample ayahs:")
    from quran_ebook.data.cache import cache_get
    for ch in [1, 2, 9, 112]:
        data = cache_get(f"local_clearquran_ch{ch}", ttl_days=365000)
        if data:
            a = data[0]
            text_preview = a["text"][:100] + ("..." if len(a["text"]) > 100 else "")
            fn_keys = list(a["foot_notes"].keys())
            print(f"  {ch}:1 = {text_preview}")
            if fn_keys:
                print(f"         fn keys: {fn_keys}")

    print(f"\nCache: ~/.cache/quran-ebook/local_clearquran_ch*.json")


if __name__ == "__main__":
    main()
