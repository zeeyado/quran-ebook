#!/usr/bin/env python3
"""Generate catalog.json — the machine-readable variant catalog.

One entry per config in configs/, or per config of the release set with
--set. This single file is simultaneously:
- the OPDS generator's input (scripts/gen_opds.py),
- the plugin's update-check manifest (v1.12 asset manager),
- the machine-readable rename map for sidecar migration,
- the contract that later consumers (a future plugin, a web page) build on.

Fields per variant:
  id            stable variant ID = frozen grammar-v1 filename stem
  filename      released EPUB filename (new scheme)
  old_filename  the file name under which release v0.10.0 published this
                very book, or null when v0.10.0 did not have it. Exact on
                purpose: the plugin matches a reader's old file to a
                catalog entry by this field, so no two entries may share
                a name (sources: data/filename_map_v1.csv and
                data/released_v0.10.0.txt)
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
                                  [--set release_set.txt]
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
from quran_ebook.release_set import (  # noqa: E402
    RENAME_TABLE as RENAME_TABLE_REL,
    load_release_set,
    published_before,
)

RELEASE_URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"
RENAME_TABLE = ROOT / RENAME_TABLE_REL


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


def config_paths_for(set_file: str | None) -> list[Path]:
    """The configs a catalog covers: the release set file, or every config."""
    if set_file:
        try:
            return load_release_set(ROOT / set_file, ROOT)
        except ValueError as e:
            sys.exit(f"ERROR: {e}")
    return sorted((ROOT / "configs").rglob("*.yaml"))


def build_catalog(config_paths: list[Path], out_dir: Path | None = None
                  ) -> tuple[dict, list[str]]:
    """The catalog for these configs, and the file names of books that are
    not in ``out_dir`` (their sha256 and size stay null). With no
    ``out_dir`` nothing is read from disk and every book counts as missing.
    """
    try:
        old_names = published_before(ROOT)
    except ValueError as e:
        sys.exit(f"ERROR: {e}")
    variants = []
    missing = []
    for p in config_paths:
        c = load_config(p)
        vid = c.output_filename
        filename = f"{vid}.epub"
        old, renamed_to = old_names.get(p.relative_to(ROOT).as_posix(), (None, None))
        if old and renamed_to != filename:
            sys.exit(f"ERROR: {RENAME_TABLE.name} says {old} became {renamed_to}, "
                     f"but {p.relative_to(ROOT)} now builds {filename}")
        epub = out_dir / filename if out_dir else None
        sha = size = None
        if epub and epub.exists():
            data = epub.read_bytes()
            sha = hashlib.sha256(data).hexdigest()
            size = len(data)
        else:
            missing.append(filename)
        axes = _axes(c)
        variants.append({
            "id": vid,
            "filename": filename,
            "old_filename": old,
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
    return catalog, missing


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", default="output/catalog.json")
    ap.add_argument("--output-dir", default="output",
                    help="Where built EPUBs live (for sha256/size)")
    ap.add_argument("--require-artifacts", action="store_true",
                    help="CI mode: fail if an EPUB is missing, or if the "
                         "output folder holds an EPUB the catalog does not list")
    ap.add_argument("--set", dest="set_file", default=None, metavar="FILE",
                    help="Only the configs listed in FILE (the release set); "
                         "default: every config under configs/")
    args = ap.parse_args()

    out_dir = ROOT / args.output_dir
    catalog, missing = build_catalog(config_paths_for(args.set_file), out_dir)
    variants = catalog["variants"]

    if missing:
        msg = f"{len(missing)} EPUBs missing from {out_dir} (no sha256/size)"
        if args.require_artifacts:
            sys.exit(f"ERROR: {msg}: {missing[:5]}")
        print(f"  note: {msg}")

    # CI mode: the release uploads every EPUB in the output folder, so a
    # book there that the catalog does not list would be published without
    # an entry (for example a canary build that is not in the release set).
    listed = {v["filename"] for v in variants}
    extra = sorted(p.name for p in out_dir.glob("*.epub") if p.name not in listed)
    if extra:
        msg = f"{len(extra)} EPUBs in {out_dir} are not in the catalog"
        if args.require_artifacts:
            sys.exit(f"ERROR: {msg}: {extra[:5]}")
        print(f"  note: {msg}")

    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + "\n")
    by_status = {}
    for v in variants:
        by_status[v["status"]] = by_status.get(v["status"], 0) + 1
    print(f"catalog.json: {len(variants)} variants ({by_status}) -> {out}")


if __name__ == "__main__":
    main()
