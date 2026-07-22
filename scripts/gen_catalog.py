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

from quran_ebook.config.registry import (  # noqa: E402
    ENGLISH_LANGUAGE_NAMES,
    LAYOUT_LABELS,
    LAYOUT_SHELF_LABELS,
    NATIVE_LANGUAGE_NAMES,
    SCRIPT_SHELF_LABELS,
    get_riwayah,
)
from quran_ebook.config.schema import load_config  # noqa: E402
from quran_ebook.epub.builder import _build_descriptive_title  # noqa: E402

RELEASE_URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"


def _lang_names(code: str, config_name: str = "") -> tuple[str, str]:
    """(native, english) display names for a language code.

    Config-provided native name wins; registry fills the rest. Falls back
    to the bare code so an unmapped language degrades visibly, never
    crashes.
    """
    native = config_name or NATIVE_LANGUAGE_NAMES.get(code) or code
    english = ENGLISH_LANGUAGE_NAMES.get(code) or code
    return native, english


ORTHO_LABELS = {"uthmani": "Uthmani", "indopak": "IndoPak"}


def _title_en(axes: dict) -> str:
    """Neutral English label (owner formula 2026-07-22): LANGUAGE-first,
    always complete —

        <Language | "Arabic"> · <translator/tafsir> · <riwayah> · <script> · <layout>

    + gloss / tafsir-popup tails. Riwayah + script ALWAYS show (even the
    Hafs · Uthmani default). Browsing surfaces derive context-scoped titles
    by OMITTING the axis their shelf fixes; this full form is the neutral one
    (dialogs, tables, the plugin's My books). MUST stay identical to
    gen_opds.py _entry_title and quran_assets.lua entryTitle.
    """
    parts = []
    layer = axes["translation"] or axes["tafsir_as_text"]
    # 1. language (translation/gloss) — or "Arabic" for bare Arabic
    if layer:
        parts.append(layer["language_name_en"])
    elif axes["gloss_language"]:
        parts.append(_lang_names(axes["gloss_language"])[1])
    else:
        parts.append("Arabic")
    # 2. translator / tafsir edition name
    if layer:
        parts.append(layer["name"])
    # 3. riwayah + script (always present)
    if axes["riwayah"]:
        parts.append(axes["riwayah"].title())
    ortho = ORTHO_LABELS.get(axes["orthography"])
    if ortho:
        parts.append(ortho)
    # 4. layout / type
    layout = axes["layout_label"]
    if axes["gloss_language"] and not layer:
        layout += " · glosses only"
    # A named popup tafsir replaces the generic layout mention — two
    # variants may differ ONLY by which tafsir rides along.
    if axes["tafsir_name"]:
        layout = layout.replace(" + tafsir popup", "")
    if layout:
        parts.append(layout)
    # 5. wbw gloss language — only worth ink when it differs from the translation
    if layer and axes["gloss_language"] and axes["gloss_language"] != layer["language"]:
        parts.append(f"{_lang_names(axes['gloss_language'])[1]} glosses")
    # 6. named popup tafsir
    if axes["tafsir_name"]:
        parts.append(f"{axes['tafsir_name']} popup")
    return " · ".join(parts)


def _axes(config) -> dict:
    """Decompose the variant into its grammar axes (self-describing entry)."""
    vid = config.variant_id
    # riwayah-ortho token is slot 2 of the frozen grammar
    riwayah_ortho = vid.split("_")[1]
    riwayah, _, ortho = riwayah_ortho.partition("-")
    gran_slot = vid.split("_")[3]
    granularity, _, placement = gran_slot.partition("-")
    def _layer(config_t) -> dict:
        native, english = _lang_names(config_t.language, config_t.language_name)
        return {
            "language": config_t.language,
            "language_name": native,
            "language_name_en": english,
            "name": config_t.display_name,
            "slug": config_t.abbreviation,
        }

    riwayah = riwayah or get_riwayah(config.quran.script)
    return {
        "riwayah": riwayah,
        "orthography": ortho,
        "font": vid.split("_")[2],
        "granularity": granularity,
        "placement": placement or None,
        "layout": config.layout.structure,
        "layout_label": (LAYOUT_LABELS.get(config.layout.structure) or ("", ""))[0],
        # Shared facet-shelf labels (owner 2026-07-20): every browsing
        # surface (OPDS + plugin) groups by these exact strings.
        "layout_shelf": LAYOUT_SHELF_LABELS.get((granularity, placement or None))
        or " + ".join(t for t in (granularity, placement) if t),
        "script_shelf": SCRIPT_SHELF_LABELS.get((riwayah, ortho))
        or f"{riwayah} · {ortho}",
        "script": config.quran.script,
        "translation": (
            _layer(config.translation)
            if config.translation and not config.translation.is_tafsir_style
            else None
        ),
        # Tafsir-style content occupying the translation slot (Al-Mukhtasar):
        # deliberately NOT under "translation" — download tables must never
        # present it as one (owner decision 2026-07-18).
        "tafsir_as_text": (
            _layer(config.translation)
            if config.translation and config.translation.is_tafsir_style
            else None
        ),
        "gloss_language": (
            (config.layout.wbw_gloss_language
             or (config.translation.language if config.translation else None))
            if config.layout.structure == "wbw" else None
        ),
        "tafsir": config.tafsir.abbreviation if config.tafsir else None,
        "tafsir_name": config.tafsir.display_name if config.tafsir else None,
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
        variants.append({
            "id": vid,
            "filename": filename,
            "old_filename": None if old == vid else f"{old}.epub",
            "title": _build_descriptive_title(c),
            "title_en": _title_en(axes),
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

    # code -> display names, for every language any variant references
    # (translation, tafsir-as-text, or wbw gloss). THE code→name home:
    # OPDS + plugin read this, never their own maps.
    lang_codes = set()
    for v in variants:
        layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
        code = (layer or {}).get("language") or v["axes"]["gloss_language"]
        if code:
            lang_codes.add(code)
    languages = {}
    for code in sorted(lang_codes):
        native, english = _lang_names(code)
        languages[code] = {"en": english, "native": native}

    catalog = {
        "schema": 1,
        "languages": languages,
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
