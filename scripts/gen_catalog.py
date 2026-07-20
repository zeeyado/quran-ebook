#!/usr/bin/env python3
"""Generate catalog.json — the machine-readable variant catalog.

One entry per config in configs/. This single file is simultaneously:
- the OPDS generator's input (scripts/gen_opds.py),
- the plugin's update-check manifest (v1.12 asset manager),
- the machine-readable rename map for sidecar migration,
- the contract the future explorer-side plugin consumes (H2).

Fields per variant:
  id            stable variant ID = frozen grammar-v1 filename stem
  filename      released EPUB filename (new scheme)
  old_filename  pre-sweep filename stem (grammar-v0 auto name) or null —
                informational; the alias-upload step must intersect this
                with the PREVIOUS release's actual asset list (never-released
                variants need no alias)
  title         the EPUB's dc:title (Arabic descriptive title)
  title_en      English label: layout + translation summary
  status        stable | beta | experimental (tier rules, plan §0c)
  axes          the parsed grammar axes (riwayah, orthography, font,
                granularity, placement, translation, gloss, tafsir)
  url           floating download URL (releases/latest/download/)
  sha256, size  of the built EPUB (only when --output-dir has the file;
                CI runs this after `build --all`)

Usage:
    python scripts/gen_catalog.py [-o output/catalog.json] [--output-dir output]
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.config.registry import LAYOUT_LABELS, get_riwayah  # noqa: E402
from quran_ebook.config.schema import load_config  # noqa: E402
from quran_ebook.epub.builder import _build_descriptive_title  # noqa: E402

RELEASE_URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"


def _axes(config) -> dict:
    """Decompose the variant into its grammar axes (self-describing entry)."""
    vid = config.variant_id
    # riwayah-ortho token is slot 2 of the frozen grammar
    riwayah_ortho = vid.split("_")[1]
    riwayah, _, ortho = riwayah_ortho.partition("-")
    gran_slot = vid.split("_")[3]
    granularity, _, placement = gran_slot.partition("-")
    return {
        "riwayah": riwayah or get_riwayah(config.quran.script),
        "orthography": ortho,
        "font": vid.split("_")[2],
        "granularity": granularity,
        "placement": placement or None,
        "layout": config.layout.structure,
        "layout_label": (LAYOUT_LABELS.get(config.layout.structure) or ("", ""))[0],
        "script": config.quran.script,
        "translation": (
            {
                "language": config.translation.language,
                "language_name": config.translation.language_name,
                "name": config.translation.display_name,
                "slug": config.translation.abbreviation,
            }
            if config.translation and not config.translation.is_tafsir_style
            else None
        ),
        # Tafsir-style content occupying the translation slot (Al-Mukhtasar):
        # deliberately NOT under "translation" — download tables must never
        # present it as one (owner decision 2026-07-18).
        "tafsir_as_text": (
            {
                "language": config.translation.language,
                "language_name": config.translation.language_name,
                "name": config.translation.display_name,
                "slug": config.translation.abbreviation,
            }
            if config.translation and config.translation.is_tafsir_style
            else None
        ),
        "gloss_language": (
            (config.layout.wbw_gloss_language
             or (config.translation.language if config.translation else None))
            if config.layout.structure == "wbw" else None
        ),
        "tafsir": config.tafsir.abbreviation if config.tafsir else None,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", default="output/catalog.json")
    ap.add_argument("--output-dir", default="output",
                    help="Where built EPUBs live (for sha256/size)")
    ap.add_argument("--require-artifacts", action="store_true",
                    help="Fail if any EPUB is missing (CI mode)")
    args = ap.parse_args()

    out_dir = ROOT / args.output_dir
    variants = []
    missing = []
    for p in sorted((ROOT / "configs").rglob("*.yaml")):
        c = load_config(p)
        vid = c.output_filename
        filename = f"{vid}.epub"
        old = c.auto_filename
        epub = out_dir / filename
        sha = size = None
        if epub.exists():
            data = epub.read_bytes()
            sha = hashlib.sha256(data).hexdigest()
            size = len(data)
        else:
            missing.append(filename)
        axes = _axes(c)
        label_bits = []
        if axes["riwayah"] != "hafs":
            label_bits.append(axes["riwayah"].title())
        if axes["orthography"] == "indopak":
            label_bits.append("IndoPak")
        label_bits.append(
            (LAYOUT_LABELS.get(c.layout.structure) or (c.layout.structure,))[0])
        en_label = " · ".join(label_bits)
        if c.translation:
            kind = (f"{c.translation.language} tafsir"
                    if c.translation.is_tafsir_style else c.translation.language)
            en_label += f", {c.translation.display_name} ({kind})"
        variants.append({
            "id": vid,
            "filename": filename,
            "old_filename": None if old == vid else f"{old}.epub",
            "title": _build_descriptive_title(c),
            "title_en": en_label,
            "status": c.output.status,
            "axes": axes,
            "url": f"{RELEASE_URL_BASE}/{filename}",
            "sha256": sha,
            "size": size,
        })

    ids = [v["id"] for v in variants]
    assert len(ids) == len(set(ids)), "variant id collision"

    if missing:
        msg = f"{len(missing)} EPUBs missing from {out_dir} (no sha256/size)"
        if args.require_artifacts:
            sys.exit(f"ERROR: {msg}: {missing[:5]}")
        print(f"  note: {msg}")

    catalog = {
        "schema": 1,
        "variants": variants,
    }
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + "\n")
    by_status = {}
    for v in variants:
        by_status[v["status"]] = by_status.get(v["status"], 0) + 1
    print(f"catalog.json: {len(variants)} variants ({by_status}) -> {out}")


if __name__ == "__main__":
    main()
