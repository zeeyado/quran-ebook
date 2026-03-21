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
    python tools/mushaf_pdf/generate.py --page 1 --v4
    python tools/mushaf_pdf/generate.py --range 1-5 --v4
    python tools/mushaf_pdf/generate.py --all --v4
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

# --- Page geometry ---
# quran.com CSS: font-size=3.2vh, width=56vh → TEXT_W = 17.5em (V2 fonts)
# V4 fonts are ~4% wider per line → TEXT_W = 18em gives equivalent word gaps
# Page dimensions from quran.com-images golden ratio spec (font_factor × φ)
# Same font used for layout and rendering (V4 when --v4, V2 otherwise).

import math

FONT_SIZE = 18                                  # pt — the one adjustable parameter
NUM_LINES = 15
SHORT_LINE_THRESHOLD = 4

_PHI = (1 + math.sqrt(5)) / 2                   # golden ratio ≈ 1.618
_TEXT_W_EM = 18.0                               # em — fits V4 advances, ~5pt median gap


def _compute_geometry():
    """Page geometry derived from quran.com specs + V4 font metrics."""
    text_w = FONT_SIZE * _TEXT_W_EM
    margin = FONT_SIZE                           # 1em margins
    page_w = text_w + 2 * margin
    page_h = page_w * _PHI
    text_h = page_h - 2 * margin
    line_step = text_h / NUM_LINES

    # Baseline at ~65% from top of line slot (typical Arabic ascender ratio)
    baseline_frac = 0.65

    print(f"  PAGE={page_w:.0f}×{page_h:.0f}pt, "
          f"TEXT_W={text_w:.0f}pt ({text_w/FONT_SIZE:.1f}em), "
          f"LINE_STEP={line_step:.1f}pt ({line_step/FONT_SIZE:.2f}em)")

    return {
        "text_w": text_w,
        "line_step": line_step,
        "margin": margin,
        "page_w": page_w,
        "page_h": page_h,
        "baseline_frac": baseline_frac,
    }


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


def _draw_glyph(pdf, font, glyph_name, glyph_x, baseline_y_fpdf, font_size, font_id, page_h):
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
    ty = page_h - baseline_y_fpdf  # fpdf2 y-down → PDF y-up

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


def _render_page(pdf, page_num, font_cache, geom, v4=False):
    """Render a single mushaf page: vector path glyphs + invisible text layer.

    Same font used for both layout (advance widths) and rendering (glyph paths).
    Lines justified to TEXT_W. Never broken.
    """
    text_w = geom["text_w"]
    line_step = geom["line_step"]
    margin = geom["margin"]
    page_w = geom["page_w"]
    page_h = geom["page_h"]
    baseline_frac = geom["baseline_frac"]
    font_size = FONT_SIZE

    layout_path = MUSHAF_LAYOUT_DIR / f"page-{page_num:03d}.json"
    with open(layout_path) as f:
        layout = json.load(f)

    # Single font for both layout and rendering (V4 when --v4, else V2)
    font = font_cache.get(page_num, v4=v4)
    cmap = font.getBestCmap()
    upm = font["head"].unitsPerEm
    hmtx = font["hmtx"]
    font_id = (page_num, v4)

    # Pages with < 8 text lines (pages 1-2): center all lines
    text_lines = [l for l in layout["lines"] if l["type"] == "text" and l.get("words")]
    center_all = len(text_lines) < 8

    pdf.add_page()

    for line_data in layout["lines"]:
        line_num = line_data["line"]
        words = line_data.get("words", [])
        if not words:
            continue

        # Word widths from font advance widths
        word_widths = []
        for w in words:
            w_pt = 0
            for ch in w["qpcV2"]:
                gname = cmap.get(ord(ch))
                if gname:
                    w_pt += hmtx[gname][0] / upm * font_size
            word_widths.append(w_pt)

        total_glyph_w = sum(word_widths)
        n_gaps = len(words) - 1

        # Justify to TEXT_W; center short/special lines; gap=0 for overflow lines
        center = center_all or len(words) < SHORT_LINE_THRESHOLD
        if center or total_glyph_w >= text_w:
            gap = 0
        else:
            gap = (text_w - total_glyph_w) / n_gaps if n_gaps > 0 else 0

        # Baseline Y from line number and font-derived baseline fraction
        baseline_y = margin + (line_num - 1) * line_step + line_step * baseline_frac

        # X start: centered or right edge (RTL)
        if center or total_glyph_w >= text_w:
            x = margin + (text_w + total_glyph_w) / 2
        else:
            x = margin + text_w

        for i, w in enumerate(words):
            word_w = word_widths[i]
            x -= word_w
            word_x = x

            # --- Visible layer: vector path glyphs (RTL within word) ---
            char_x = word_x + word_w
            for ch in w["qpcV2"]:
                gname = cmap.get(ord(ch))
                if gname:
                    glyph_w = (hmtx[gname][0] / upm) * font_size
                    char_x -= glyph_w
                    _draw_glyph(pdf, font, gname, char_x, baseline_y,
                                font_size, font_id, page_h)

            # --- Invisible layer: per-word Arabic text at glyph position ---
            uthmani = w["word"]
            if uthmani.strip():
                reversed_text = (" " + uthmani + " ")[::-1]
                with pdf.local_context(text_mode=TextMode.INVISIBLE):
                    pdf.set_font("arabic", size=font_size * 0.5)
                    cell_y = margin + (line_num - 1) * line_step
                    pdf.set_xy(word_x, cell_y)
                    pdf.cell(w=word_w, h=line_step, text=reversed_text)

            x -= gap

    # Page number (centered at bottom)
    pdf.set_font("Helvetica", size=8)
    pdf.set_text_color(128, 128, 128)
    pdf.set_xy(page_w / 2 - 10, page_h - margin)
    pdf.cell(w=20, h=10, text=str(page_num), align="C")


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

    font_cache = FontCache()

    # Page geometry from quran.com-images spec
    geom = _compute_geometry()

    pdf = FPDF(unit="pt", format=(geom["page_w"], geom["page_h"]))
    pdf.set_auto_page_break(auto=False)

    # Register Arabic font for invisible text layer
    arabic_font = Path("src/quran_ebook/assets/fonts/UthmanicHafs_V22.ttf")
    if arabic_font.exists():
        pdf.add_font("arabic", fname=str(arabic_font))
    else:
        print("WARNING: UthmanicHafs_V22.ttf not found — no text layer will be added")

    for i, page_num in enumerate(pages):
        try:
            _render_page(pdf, page_num, font_cache, geom, v4=args.v4)
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
