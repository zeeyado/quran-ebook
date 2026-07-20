#!/usr/bin/env python3
"""Generate the OPDS 1.2 catalog (Atom) from catalog.json.

KOReader's built-in OPDS client handles browsing + downloading natively —
static XML, hosted on gh-pages (release) or as test-build release assets
(test feeds via --asset-base/--base-url overrides).

Facet tree (owner ask 2026-07-20 — ~600 books need several entry ways):

  root.xml                 navigation
    languages.xml          navigation  -> lang-<code>.xml   (per language)
    layouts.xml            navigation  -> layout-<slug>.xml (per gran+placement)
    scripts.xml            navigation  -> script-<slug>.xml (per riwayah+ortho)
    arabic.xml             acquisition (Arabic only — no translation layer)
    tafsir.xml             acquisition (tafsir popups + tafsir-as-text)
    beta.xml               acquisition (tier rule 7 — feedback welcome)

Every grouping is DERIVED from catalog axes — a new language/layout/script
appears automatically; unknown (granularity, placement) combos get a
fallback label rather than being dropped (no silent caps).

Usage:
    python scripts/gen_opds.py [-i output/catalog.json] [-o output/opds]
        [--base-url https://zeeyado.github.io/quran-ebook/opds]
        [--asset-base https://github.com/.../releases/download/test-build]

--base-url   where the FEED XMLs live (inter-feed links).
--asset-base override for the EPUB download links; default keeps each
             variant's catalog url (releases/latest/download — the stable
             release contract). Set both to the test-build download base to
             produce a fully working pre-release test feed.
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_BASE = "https://zeeyado.github.io/quran-ebook/opds"

NAV = "application/atom+xml;profile=opds-catalog;kind=navigation"
ACQ = "application/atom+xml;profile=opds-catalog;kind=acquisition"

# (granularity, placement) -> shelf label; unknown combos fall back to the
# raw token pair so new layout classes are never silently dropped.
LAYOUT_SHELVES = {
    ("flow", None): "Continuous flow",
    ("ayah", None): "Ayah-by-ayah (Arabic only)",
    ("ayah", "inline"): "Ayah-by-ayah with translation",
    ("ayah", "popup"): "Ayah-by-ayah + tap-translation",
    ("flow", "popup"): "Continuous + tap-translation",
    ("word", "inline"): "Word-by-word",
}

SCRIPT_SHELVES = {
    ("hafs", "uthmani"): "Hafs · Uthmani (KFGQPC)",
    ("hafs", "indopak"): "Hafs · IndoPak (Nastaleeq)",
    ("warsh", "uthmani"): "Warsh · Uthmani (KFGQPC)",
}


def _feed_head(feed_id: str, title: str, base: str, kind: str, updated: str) -> list[str]:
    return [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom"'
        ' xmlns:dc="http://purl.org/dc/terms/"'
        ' xmlns:opds="http://opds-spec.org/2010/catalog">',
        f"  <id>urn:quran-ebook:opds:{feed_id}</id>",
        f"  <title>{escape(title)}</title>",
        f"  <updated>{updated}</updated>",
        f'  <link rel="self" href="{base}/{feed_id}.xml" type="{kind}"/>',
        f'  <link rel="start" href="{base}/root.xml" type="{NAV}"/>',
        "  <author><name>quran-ebook</name></author>",
    ]


def _book_entry(v: dict, updated: str, asset_base: str | None) -> list[str]:
    title = v["title_en"] or v["id"]
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    author = (layer or {}).get("name") or "Quran"
    lang = (layer or {}).get("language") or "ar"
    href = f"{asset_base}/{v['filename']}" if asset_base else v["url"]
    return [
        "  <entry>",
        f"    <id>urn:quran-ebook:variant:{v['id']}</id>",
        f"    <title>{escape(title)}</title>",
        f"    <updated>{updated}</updated>",
        f"    <author><name>{escape(author)}</name></author>",
        f"    <dc:language>{lang}</dc:language>",
        f"    <content type=\"text\">{escape(v['title'])}"
        f"{' — BETA: feedback welcome' if v['status'] == 'beta' else ''}</content>",
        f'    <link rel="http://opds-spec.org/acquisition" href="{href}"'
        ' type="application/epub+zip"/>',
        "  </entry>",
    ]


def _nav_entry(slug: str, title: str, count: int, base: str, kind: str,
               updated: str) -> list[str]:
    return [
        "  <entry>",
        f"    <id>urn:quran-ebook:opds:{slug}</id>",
        f"    <title>{escape(title)}</title>",
        f"    <updated>{updated}</updated>",
        f'    <link rel="subsection" href="{base}/{slug}.xml" type="{kind}"/>',
        f"    <content type=\"text\">{count} books</content>",
        "  </entry>",
    ]


def _write_acq(out: Path, slug: str, title: str, members: list[dict], base: str,
               updated: str, asset_base: str | None) -> None:
    lines = _feed_head(slug, title, base, ACQ, updated)
    for v in members:
        lines += _book_entry(v, updated, asset_base)
    lines.append("</feed>")
    (out / f"{slug}.xml").write_text("\n".join(lines) + "\n")


def _lang_names(variants: list[dict]) -> dict[str, str]:
    """code -> display name, learned from every layered variant."""
    names: dict[str, str] = {}
    for v in variants:
        layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
        if layer and layer.get("language_name"):
            names.setdefault(layer["language"], layer["language_name"])
    return names


def _entry_lang(v: dict, names: dict[str, str]) -> tuple[str, str] | None:
    """(code, display) of the variant's language entry way, None for bare Arabic.

    Glosses-only wbw has no translation layer but DOES have a gloss
    language — surface it there (an English-shelf browser should find the
    en-gloss book), not under Arabic only.
    """
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    code = layer["language"] if layer else v["axes"]["gloss_language"]
    if code is None:
        return None
    name = (layer or {}).get("language_name") or names.get(code) or code
    return (code, name)


def _sort_key(v: dict):
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    return ((layer or {}).get("language") or "", v["id"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-i", "--catalog", default="output/catalog.json")
    ap.add_argument("-o", "--out-dir", default="output/opds")
    ap.add_argument("--base-url", default=DEFAULT_BASE)
    ap.add_argument("--asset-base", default=None,
                    help="Override EPUB link base (e.g. the test-build "
                         "explicit-tag download URL); default = catalog urls "
                         "(releases/latest).")
    args = ap.parse_args()

    catalog = json.loads((ROOT / args.catalog).read_text())
    variants = catalog["variants"]
    out = ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    # Clear stale feeds: the shelf set is derived from the catalog, so a
    # removed shelf's file would otherwise linger and ship to gh-pages.
    for old in out.glob("*.xml"):
        old.unlink()
    base = args.base_url.rstrip("/")
    asset_base = args.asset_base.rstrip("/") if args.asset_base else None
    updated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # --- By language --------------------------------------------------------
    names = _lang_names(variants)
    by_lang: dict[tuple[str, str], list[dict]] = {}
    for v in variants:
        lang = _entry_lang(v, names)
        if lang:
            by_lang.setdefault(lang, []).append(v)
    lang_nav = _feed_head("languages", "By language", base, NAV, updated)
    for (code, name) in sorted(by_lang, key=lambda x: x[1].lower()):
        members = sorted(by_lang[(code, name)], key=_sort_key)
        slug = f"lang-{code}"
        _write_acq(out, slug, f"{name} ({code})", members, base, updated, asset_base)
        lang_nav += _nav_entry(slug, f"{name} ({code})", len(members), base, ACQ, updated)
    lang_nav.append("</feed>")
    (out / "languages.xml").write_text("\n".join(lang_nav) + "\n")

    # --- By layout ----------------------------------------------------------
    by_layout: dict[tuple[str, str | None], list[dict]] = {}
    for v in variants:
        key = (v["axes"]["granularity"], v["axes"]["placement"])
        by_layout.setdefault(key, []).append(v)
    layout_nav = _feed_head("layouts", "By layout", base, NAV, updated)
    for key in sorted(by_layout, key=lambda k: (k[0], k[1] or "")):
        label = LAYOUT_SHELVES.get(key) or " + ".join(t for t in key if t)
        slug = "layout-" + "-".join(t for t in key if t)
        members = sorted(by_layout[key], key=_sort_key)
        _write_acq(out, slug, label, members, base, updated, asset_base)
        layout_nav += _nav_entry(slug, label, len(members), base, ACQ, updated)
    layout_nav.append("</feed>")
    (out / "layouts.xml").write_text("\n".join(layout_nav) + "\n")

    # --- By script ----------------------------------------------------------
    by_script: dict[tuple[str, str], list[dict]] = {}
    for v in variants:
        key = (v["axes"]["riwayah"], v["axes"]["orthography"])
        by_script.setdefault(key, []).append(v)
    script_nav = _feed_head("scripts", "By script", base, NAV, updated)
    for key in sorted(by_script):
        label = SCRIPT_SHELVES.get(key) or " · ".join(key)
        slug = f"script-{key[0]}-{key[1]}"
        members = sorted(by_script[key], key=_sort_key)
        _write_acq(out, slug, label, members, base, updated, asset_base)
        script_nav += _nav_entry(slug, label, len(members), base, ACQ, updated)
    script_nav.append("</feed>")
    (out / "scripts.xml").write_text("\n".join(script_nav) + "\n")

    # --- Direct shelves -----------------------------------------------------
    shelves = [
        ("arabic", "Arabic only",
         [v for v in variants if _entry_lang(v, names) is None]),
        ("tafsir", "With tafsir",
         [v for v in variants
          if v["axes"]["tafsir"] or v["axes"]["tafsir_as_text"]]),
        ("beta", "Beta (feedback welcome)",
         [v for v in variants if v["status"] == "beta"]),
    ]
    for slug, title, members in shelves:
        _write_acq(out, slug, title, sorted(members, key=_sort_key), base,
                   updated, asset_base)

    # --- Root ---------------------------------------------------------------
    root = _feed_head("root", "Quran EPUBs (quran-ebook)", base, NAV, updated)
    root += _nav_entry("languages", "By language",
                       sum(len(m) for m in by_lang.values()), base, NAV, updated)
    root += _nav_entry("layouts", "By layout", len(variants), base, NAV, updated)
    root += _nav_entry("scripts", "By script", len(variants), base, NAV, updated)
    for slug, title, members in shelves:
        root += _nav_entry(slug, title, len(members), base, ACQ, updated)
    root.append("</feed>")
    (out / "root.xml").write_text("\n".join(root) + "\n")

    print(f"OPDS feeds -> {out}: root + languages({len(by_lang)}) + "
          f"layouts({len(by_layout)}) + scripts({len(by_script)}) + "
          f"{', '.join(f'{s}({len(m)})' for s, _, m in shelves)}")


if __name__ == "__main__":
    main()
