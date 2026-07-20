#!/usr/bin/env python3
"""Generate the OPDS 1.2 catalog (Atom) from catalog.json.

KOReader's built-in OPDS client handles browsing + downloading natively —
static XML, hosted on gh-pages (release) or as test-build release assets
(test feeds via --asset-base/--base-url overrides).

Facet tree (owner ask 2026-07-20; presentation decisions same day):

  root.xml                 navigation
    languages.xml          navigation  -> lang-<code>.xml   (per language)
    layouts.xml            navigation  -> layout-<slug>.xml (per gran+placement)
    scripts.xml            navigation  -> script-<slug>.xml (per riwayah+ortho)
    arabic.xml             acquisition (Arabic only — no translation layer)
    tafsir.xml             acquisition (tafsir popups + tafsir-as-text)

Presentation (owner 2026-07-20): language shelves titled "English ·
native" (names from the catalog's languages map — the one code→name
home); shelf labels come stamped per variant (axes.layout_shelf /
script_shelf) so the plugin's Books screens group by the SAME strings;
entry titles are translator-first and OMIT the axis their shelf already
fixes; beta is an inline "· beta" title suffix — the 381-book Beta shelf
is gone. Every grouping is DERIVED from the catalog — a new
language/layout/script appears automatically (no silent caps).

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
import re
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_BASE = "https://zeeyado.github.io/quran-ebook/opds"

NAV = "application/atom+xml;profile=opds-catalog;kind=navigation"
ACQ = "application/atom+xml;profile=opds-catalog;kind=acquisition"

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


def _entry_title(v: dict, languages: dict, omit: str | None = None) -> str:
    """Context-scoped entry title (owner formula 2026-07-20).

    Translator-first; `omit` drops the axis the surrounding shelf already
    fixes ("lang" | "layout" | "script"); beta becomes an inline suffix.
    """
    axes = v["axes"]
    parts = []
    layer = axes["translation"] or axes["tafsir_as_text"]
    if layer:
        parts.append(layer["name"])
    code = (layer or {}).get("language") or axes["gloss_language"]
    if code and omit != "lang":
        parts.append((languages.get(code) or {}).get("en") or code)
    if omit != "script":
        if axes["riwayah"] != "hafs":
            parts.append(axes["riwayah"].title())
        if axes["orthography"] == "indopak":
            parts.append("IndoPak")
    glosses_only = axes["gloss_language"] and not layer
    tafsir_name = axes.get("tafsir_name")
    if omit != "layout":
        layout = axes["layout_label"] + (" · glosses only" if glosses_only else "")
        # a named popup tafsir replaces the generic layout mention
        if tafsir_name:
            layout = layout.replace(" + tafsir popup", "")
        parts.append(layout)
    elif glosses_only:
        parts.append("glosses only")
    # gloss language is only worth ink when it differs from the translation
    if layer and axes["gloss_language"] and axes["gloss_language"] != layer["language"]:
        gloss_en = (languages.get(axes["gloss_language"]) or {}).get("en") \
            or axes["gloss_language"]
        parts.append(f"{gloss_en} glosses")
    if tafsir_name:
        parts.append(f"{tafsir_name} popup")
    if v["status"] == "beta":
        parts.append("beta")
    return " · ".join(parts) or v["id"]


def _book_entry(v: dict, updated: str, asset_base: str | None,
                languages: dict, omit: str | None) -> list[str]:
    title = _entry_title(v, languages, omit)
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
               updated: str, asset_base: str | None, languages: dict,
               omit: str | None = None) -> None:
    # Sorted by the exact title the shelf renders (translator-first ⇒
    # alphabetical-by-translator lists).
    members = sorted(members, key=lambda v: _entry_title(v, languages, omit).lower())
    lines = _feed_head(slug, title, base, ACQ, updated)
    for v in members:
        lines += _book_entry(v, updated, asset_base, languages, omit)
    lines.append("</feed>")
    (out / f"{slug}.xml").write_text("\n".join(lines) + "\n")


def _entry_lang(v: dict) -> str | None:
    """Language code of the variant's language entry way, None for bare Arabic.

    Glosses-only wbw has no translation layer but DOES have a gloss
    language — surface it there (an English-shelf browser should find the
    en-gloss book), not under Arabic only.
    """
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    return layer["language"] if layer else v["axes"]["gloss_language"]


def _lang_shelf_title(code: str, languages: dict) -> str:
    """"English · native" (owner 2026-07-20); collapses when identical."""
    d = languages.get(code) or {}
    en = d.get("en") or code
    native = d.get("native") or ""
    return en if (not native or native == en) else f"{en} · {native}"


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
    languages = catalog.get("languages") or {}
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
    by_lang: dict[str, list[dict]] = {}
    for v in variants:
        code = _entry_lang(v)
        if code:
            by_lang.setdefault(code, []).append(v)
    lang_nav = _feed_head("languages", "By language", base, NAV, updated)
    for code in sorted(by_lang, key=lambda c: _lang_shelf_title(c, languages).lower()):
        title = _lang_shelf_title(code, languages)
        slug = f"lang-{code}"
        _write_acq(out, slug, title, by_lang[code], base, updated, asset_base,
                   languages, omit="lang")
        lang_nav += _nav_entry(slug, title, len(by_lang[code]), base, ACQ, updated)
    lang_nav.append("</feed>")
    (out / "languages.xml").write_text("\n".join(lang_nav) + "\n")

    # --- By layout (shelf labels stamped by gen_catalog) --------------------
    by_layout: dict[str, list[dict]] = {}
    for v in variants:
        by_layout.setdefault(v["axes"]["layout_shelf"], []).append(v)
    layout_nav = _feed_head("layouts", "By layout", base, NAV, updated)
    for label in sorted(by_layout, key=str.lower):
        slug = "layout-" + re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
        _write_acq(out, slug, label, by_layout[label], base, updated, asset_base,
                   languages, omit="layout")
        layout_nav += _nav_entry(slug, label, len(by_layout[label]), base, ACQ, updated)
    layout_nav.append("</feed>")
    (out / "layouts.xml").write_text("\n".join(layout_nav) + "\n")

    # --- By script (shelf labels stamped by gen_catalog) --------------------
    by_script: dict[str, list[dict]] = {}
    for v in variants:
        by_script.setdefault(v["axes"]["script_shelf"], []).append(v)
    script_nav = _feed_head("scripts", "By script", base, NAV, updated)
    for label in sorted(by_script, key=str.lower):
        slug = "script-" + re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
        _write_acq(out, slug, label, by_script[label], base, updated, asset_base,
                   languages, omit="script")
        script_nav += _nav_entry(slug, label, len(by_script[label]), base, ACQ, updated)
    script_nav.append("</feed>")
    (out / "scripts.xml").write_text("\n".join(script_nav) + "\n")

    # --- Direct shelves (Beta shelf dropped 2026-07-20 — inline suffix) -----
    shelves = [
        ("arabic", "Arabic only",
         [v for v in variants if _entry_lang(v) is None]),
        ("tafsir", "With tafsir",
         [v for v in variants
          if v["axes"]["tafsir"] or v["axes"]["tafsir_as_text"]]),
    ]
    for slug, title, members in shelves:
        _write_acq(out, slug, title, members, base, updated, asset_base, languages)

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
