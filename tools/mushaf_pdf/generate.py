#!/usr/bin/env python3
"""
QCF Vector Path PDF Generator

Renders QCF glyph fonts as colored vector paths in PDF with invisible Arabic
text overlay for selection/search/dictionary lookup.

Architecture (OCR-style):
- Visible layer: glyph outlines drawn as PDF path operators (graphics, not text)
- Invisible layer: Arabic Uthmani text (render mode 3 = invisible)
- COLR v0 tajweed colors rendered as separate colored path fills per layer

Data sources:
- zonetecde/mushaf-layout: word→page/line/position + qpcV2 glyph codes
- nuqayah/qpc-fonts: QCF V2 (604 TTFs) or V4 (604 COLR TTFs)

Usage:
    source /opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh && conda activate clarify
    python docs/mushaf_poc.py --page 1 --v4
    python docs/mushaf_poc.py --range 1-5 --v4
    python docs/mushaf_poc.py --all --v4
"""

import argparse
import json
from pathlib import Path

from fontTools.pens.recordingPen import RecordingPen
from fontTools.ttLib import TTFont
from fpdf import FPDF
from fpdf.enums import TextMode

# --- Configuration ---

MUSHAF_LAYOUT_DIR = Path("/tmp/mushaf-layout/mushaf")
QCF_V2_FONT_DIR = Path("/tmp/qpc-fonts/mushaf-v2")
QCF_V4_COLOR_DIR = Path("/tmp/qpc-fonts-v4-color")
OUTPUT_DIR = Path("output/qcf")

# Page geometry (points) — Madinah Mushaf proportions
# Golden ratio page (like quran.com-images): height = width × φ
PAGE_W = 396
PAGE_H = int(PAGE_W * 1.618)  # 640pt

MARGIN_TOP = 48
MARGIN_BOTTOM = 40
MARGIN_LEFT = 34
MARGIN_RIGHT = 34

TEXT_W = PAGE_W - MARGIN_LEFT - MARGIN_RIGHT  # 328pt
TEXT_H = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM  # 552pt

NUM_LINES = 15
LINE_STEP = TEXT_H / NUM_LINES  # 36.8pt

# Fixed font size across all pages.  Derived from median max line width
# (~18.3em) to fill ~92% of TEXT_W.  The remaining 8% becomes inter-word gaps.
# Lines wider than TEXT_W (rare outliers) get gap=0 and overlap naturally.
FONT_SIZE = TEXT_W / 19.5  # ≈ 16.8pt

# Short lines: fewer than this many words → center instead of justify
SHORT_LINE_THRESHOLD = 4


# --- Font Cache ---


class FontCache:
    """Cache parsed TTFont objects to avoid re-reading."""

    def __init__(self):
        self._fonts: dict[tuple, TTFont] = {}

    def get(self, page_num: int, v4: bool = False) -> TTFont:
        key = (page_num, v4)
        if key not in self._fonts:
            if v4:
                path = QCF_V4_COLOR_DIR / f"QCF4_{page_num:03d}.ttf"
            else:
                path = QCF_V2_FONT_DIR / f"QCF2{page_num:03d}.ttf"
            if not path.exists():
                raise FileNotFoundError(f"QCF font not found: {path}")
            self._fonts[key] = TTFont(str(path))
        return self._fonts[key]

    def close_all(self):
        for f in self._fonts.values():
            f.close()
        self._fonts.clear()


# --- Glyph Path Extraction ---


def _qcurve_to_cubics(start, points):
    """Convert qCurveTo control points to cubic Bézier segments.

    Args:
        start: (x, y) current point
        points: tuple of (x, y) — off-curve controls followed by on-curve end.
                Consecutive off-curve points have implied on-curve at midpoints.

    Returns:
        List of (cp1, cp2, end) cubic Bézier control point tuples.
    """
    off_curves = list(points[:-1])
    end_point = points[-1]

    if not off_curves:
        # Degenerate: just a line
        return [("line", end_point)]

    segments = []
    current = start

    for i, ctrl in enumerate(off_curves):
        if i == len(off_curves) - 1:
            on_curve = end_point
        else:
            # Implied on-curve at midpoint of consecutive off-curve points
            nxt = off_curves[i + 1]
            on_curve = ((ctrl[0] + nxt[0]) / 2, (ctrl[1] + nxt[1]) / 2)

        # Quadratic→Cubic: CP1 = start + 2/3*(ctrl-start), CP2 = end + 2/3*(ctrl-end)
        cp1 = (
            current[0] + 2 / 3 * (ctrl[0] - current[0]),
            current[1] + 2 / 3 * (ctrl[1] - current[1]),
        )
        cp2 = (
            on_curve[0] + 2 / 3 * (ctrl[0] - on_curve[0]),
            on_curve[1] + 2 / 3 * (ctrl[1] - on_curve[1]),
        )
        segments.append(("curve", cp1, cp2, on_curve))
        current = on_curve

    return segments


def _glyph_to_pdf_cmds(font, glyph_name):
    """Extract glyph outline as PDF path command strings in font coordinates.

    Returns a list of command strings like "100 200 m", "300 400 l", etc.
    Returns empty list for empty/missing glyphs.
    """
    glyf_table = font["glyf"]
    glyph = glyf_table.get(glyph_name)
    if glyph is None:
        return []

    pen = RecordingPen()
    try:
        glyph.draw(pen, glyf_table)
    except Exception:
        return []

    if not pen.value:
        return []

    cmds = []
    current = (0, 0)

    for op, args in pen.value:
        if op == "moveTo":
            current = args[0]
            cmds.append(f"{current[0]:.0f} {current[1]:.0f} m")
        elif op == "lineTo":
            current = args[0]
            cmds.append(f"{current[0]:.0f} {current[1]:.0f} l")
        elif op == "qCurveTo":
            for seg in _qcurve_to_cubics(current, args):
                if seg[0] == "line":
                    current = seg[1]
                    cmds.append(f"{current[0]:.0f} {current[1]:.0f} l")
                else:
                    _, cp1, cp2, end = seg
                    cmds.append(
                        f"{cp1[0]:.0f} {cp1[1]:.0f} "
                        f"{cp2[0]:.0f} {cp2[1]:.0f} "
                        f"{end[0]:.0f} {end[1]:.0f} c"
                    )
                    current = end
        elif op == "curveTo":
            cp1, cp2, end = args
            cmds.append(
                f"{cp1[0]:.0f} {cp1[1]:.0f} "
                f"{cp2[0]:.0f} {cp2[1]:.0f} "
                f"{end[0]:.0f} {end[1]:.0f} c"
            )
            current = end
        elif op == "closePath":
            cmds.append("h")

    return cmds


# Cache glyph path commands per (font_id, glyph_name)
_path_cache: dict[tuple, list[str]] = {}


def _get_glyph_cmds(font, glyph_name, font_id):
    """Get glyph path commands with caching."""
    key = (font_id, glyph_name)
    if key not in _path_cache:
        _path_cache[key] = _glyph_to_pdf_cmds(font, glyph_name)
    return _path_cache[key]


def _get_colr_layers(font, glyph_name):
    """Get COLR v0 layers for a glyph.

    Returns list of (layer_glyph_name, r, g, b) tuples.
    Falls back to [(glyph_name, 0, 0, 0)] for non-COLR glyphs.
    """
    if "COLR" not in font or "CPAL" not in font:
        return [(glyph_name, 0, 0, 0)]

    colr = font["COLR"]
    cpal = font["CPAL"]
    palette = cpal.palettes[0]

    if hasattr(colr, "ColorLayers") and colr.ColorLayers:
        layers = colr.ColorLayers.get(glyph_name)
        if layers:
            result = []
            for layer in layers:
                cid = layer.colorID
                if cid == 0xFFFF or cid >= len(palette):
                    # 0xFFFF = foreground color sentinel in COLR v0
                    result.append((layer.name, 0, 0, 0))
                else:
                    c = palette[cid]
                    result.append((layer.name, c.red, c.green, c.blue))
            return result

    return [(glyph_name, 0, 0, 0)]


def _draw_glyph(pdf, font, glyph_name, glyph_x, baseline_y_fpdf, font_size, font_id):
    """Draw a glyph as colored vector paths using PDF path operators.

    Uses PDF transformation matrix (cm) to convert font coords → page coords.
    Font coords: origin at baseline, y-up.
    PDF native coords (_out): origin at bottom-left, y-up.
    fpdf2 coords: origin at top-left, y-down.
    """
    upm = font["head"].unitsPerEm
    scale = font_size / upm

    # Transform: font (0,0) → PDF page (glyph_x, baseline in PDF-native coords)
    tx = glyph_x
    ty = PAGE_H - baseline_y_fpdf  # fpdf2 y-down → PDF y-up

    layers = _get_colr_layers(font, glyph_name)

    for layer_glyph, r, g, b in layers:
        cmds = _get_glyph_cmds(font, layer_glyph, font_id)
        if not cmds:
            continue

        pdf._out("q")  # save graphics state
        pdf._out(f"{scale:.6f} 0 0 {scale:.6f} {tx:.2f} {ty:.2f} cm")
        pdf._out(f"{r / 255:.3f} {g / 255:.3f} {b / 255:.3f} rg")
        pdf._out(" ".join(cmds) + " f")
        pdf._out("Q")  # restore graphics state


# --- Page Rendering ---


def _render_page(pdf, page_num, font_cache, v4=False):
    """Render a single mushaf page: vector path glyphs + invisible text layer.

    Layout follows the data:
    - 15-line grid, line numbers from the JSON
    - Words justified to fill TEXT_W (space-between)
    - Short lines (< SHORT_LINE_THRESHOLD words) centered
    - Per-word invisible text placed at exact glyph positions
    """
    layout_path = MUSHAF_LAYOUT_DIR / f"page-{page_num:03d}.json"
    with open(layout_path) as f:
        layout = json.load(f)

    font = font_cache.get(page_num, v4=v4)
    cmap = font.getBestCmap()
    upm = font["head"].unitsPerEm
    hmtx = font["hmtx"]
    font_id = (page_num, v4)

    font_size = FONT_SIZE

    # Pages with < 8 text lines (pages 1-2): center all lines
    text_lines = [l for l in layout["lines"] if l["type"] == "text" and l.get("words")]
    center_all = len(text_lines) < 8

    pdf.add_page()

    for line_data in layout["lines"]:
        line_num = line_data["line"]
        words = line_data.get("words", [])
        if not words:
            continue

        # Calculate word widths in points
        word_widths = []
        for w in words:
            w_pt = 0
            for ch in w["qpcV2"]:
                if ch == " ":
                    w_pt += 0.12 * font_size
                else:
                    gname = cmap.get(ord(ch))
                    w_pt += (hmtx[gname][0] / upm * font_size) if gname else 0.5 * font_size
            word_widths.append(w_pt)

        total_glyph_w = sum(word_widths)
        n_gaps = len(words) - 1

        # Center: special pages, short lines, or overflow; justify otherwise
        center = center_all or len(words) < SHORT_LINE_THRESHOLD or total_glyph_w >= TEXT_W
        if center:
            gap = 0
        else:
            gap = (TEXT_W - total_glyph_w) / n_gaps if n_gaps > 0 else 0

        # Baseline Y: 15-line grid from line number
        baseline_y = MARGIN_TOP + (line_num - 1) * LINE_STEP + LINE_STEP * 0.7

        # X start: centered for short, right edge for justified
        if center:
            x = MARGIN_LEFT + (TEXT_W + total_glyph_w) / 2
        else:
            x = MARGIN_LEFT + TEXT_W

        # Render each word: visible glyphs + invisible text at same position
        for i, w in enumerate(words):
            word_w = word_widths[i]
            x -= word_w
            word_x = x  # left edge of this word's glyph block

            # --- Visible layer: vector path glyphs (RTL within word) ---
            char_x = word_x + word_w  # start from right edge
            for ch in w["qpcV2"]:
                if ch == " ":
                    char_x -= 0.12 * font_size
                    continue
                cp = ord(ch)
                gname = cmap.get(cp)
                if gname:
                    glyph_w = (hmtx[gname][0] / upm) * font_size
                    char_x -= glyph_w
                    _draw_glyph(pdf, font, gname, char_x, baseline_y, font_size, font_id)

            # --- Invisible layer: per-word Arabic text at glyph position ---
            uthmani = w["word"]
            if uthmani.strip():
                reversed_text = (" " + uthmani + " ")[::-1]
                with pdf.local_context(text_mode=TextMode.INVISIBLE):
                    pdf.set_font("arabic", size=font_size * 0.5)
                    # Position cell at line grid top so highlight covers the glyph
                    cell_y = baseline_y - LINE_STEP * 0.7
                    pdf.set_xy(word_x, cell_y)
                    pdf.cell(w=word_w, h=LINE_STEP, text=reversed_text)

            x -= gap

    # Page number (centered at bottom)
    page_str = str(page_num)
    pdf.set_font("Helvetica", size=8)
    pdf.set_text_color(128, 128, 128)
    pdf.set_xy(PAGE_W / 2 - 10, PAGE_H - 24)
    pdf.cell(w=20, h=10, text=page_str, align="C")


# --- Main ---


def main():
    parser = argparse.ArgumentParser(description="QCF Vector Path PDF Generator")
    parser.add_argument("--page", type=int, default=None, help="Single page (1-604)")
    parser.add_argument("--all", action="store_true", help="All 604 pages")
    parser.add_argument("--range", type=str, default=None, help="Page range, e.g. '1-5'")
    parser.add_argument("--v4", action="store_true", help="V4 tajweed color fonts")
    args = parser.parse_args()

    if args.all:
        pages = range(1, 605)
    elif args.range:
        start, end = map(int, args.range.split("-"))
        pages = range(start, end + 1)
    else:
        page = args.page or 1
        pages = range(page, page + 1)

    version = "v4" if args.v4 else "v2"
    if len(pages) == 1:
        output = OUTPUT_DIR / f"qcf_{version}_page{pages.start}.pdf"
    else:
        output = OUTPUT_DIR / f"qcf_{version}_{len(pages)}pages.pdf"

    print(f"Generating {len(pages)}-page QCF {version} vector-path PDF...")

    pdf = FPDF(unit="pt", format=(PAGE_W, PAGE_H))
    pdf.set_auto_page_break(auto=False)

    # Register Arabic font for invisible text layer
    arabic_font = Path("src/quran_ebook/assets/fonts/UthmanicHafs_V22.ttf")
    if arabic_font.exists():
        pdf.add_font("arabic", fname=str(arabic_font))
    else:
        print("WARNING: UthmanicHafs_V22.ttf not found — no text layer will be added")

    font_cache = FontCache()

    for i, page_num in enumerate(pages):
        try:
            _render_page(pdf, page_num, font_cache, v4=args.v4)
        except FileNotFoundError as e:
            print(f"  Skip page {page_num}: {e}")
            continue
        if (i + 1) % 50 == 0 or (i + 1) == len(pages):
            print(f"  {i + 1}/{len(pages)} pages...")

    output.parent.mkdir(parents=True, exist_ok=True)
    pdf.output(str(output))
    font_cache.close_all()
    _path_cache.clear()

    size = output.stat().st_size
    if size > 1024 * 1024:
        print(f"Done: {output} ({size / 1024 / 1024:.1f} MB)")
    else:
        print(f"Done: {output} ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
