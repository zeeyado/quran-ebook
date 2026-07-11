#!/usr/bin/env python3
"""Generate the OPDS 1.2 catalog (Atom) from catalog.json.

KOReader's built-in OPDS client handles browsing + downloading natively —
this is Wave 6 layer 1 (#10). Feeds are static XML for gh-pages hosting.

Layout:
  opds/root.xml          navigation feed (categories below)
  opds/arabic.xml        Arabic-only (no translation layer)
  opds/ayah-inline.xml   ayah-by-ayah with translation
  opds/flow-popup.xml    continuous + tap-translation
  opds/word-inline.xml   word-by-word
  opds/beta.xml          all beta variants (Warsh + IndoPak, tier rule 7)

Usage:
    python scripts/gen_opds.py [-i output/catalog.json] [-o output/opds]
        [--base-url https://zeeyado.github.io/quran-ebook/opds]
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

CATEGORIES = [
    # (slug, title, predicate over variant)
    ("arabic", "Arabic only",
     lambda v: v["axes"]["translation"] is None),
    ("ayah-inline", "Ayah-by-ayah with translation",
     lambda v: v["axes"]["granularity"] == "ayah" and v["axes"]["placement"] == "inline"),
    ("flow-popup", "Continuous + tap-translation",
     lambda v: v["axes"]["granularity"] == "flow" and v["axes"]["placement"] == "popup"),
    ("word-inline", "Word-by-word",
     lambda v: v["axes"]["granularity"] == "word"),
    ("beta", "Beta (Warsh + IndoPak — feedback welcome)",
     lambda v: v["status"] == "beta"),
]


def _feed_head(feed_id: str, title: str, base: str, self_href: str, updated: str) -> list[str]:
    return [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom"'
        ' xmlns:dc="http://purl.org/dc/terms/"'
        ' xmlns:opds="http://opds-spec.org/2010/catalog">',
        f"  <id>urn:quran-ebook:opds:{feed_id}</id>",
        f"  <title>{escape(title)}</title>",
        f"  <updated>{updated}</updated>",
        f'  <link rel="self" href="{self_href}" type="{ACQ if feed_id != "root" else NAV}"/>',
        f'  <link rel="start" href="{base}/root.xml" type="{NAV}"/>',
        "  <author><name>quran-ebook</name></author>",
    ]


def _entry(v: dict, updated: str) -> list[str]:
    title = v["title_en"] or v["id"]
    author = (v["axes"]["translation"] or {}).get("name") or "Quran"
    lang = (v["axes"]["translation"] or {}).get("language") or "ar"
    lines = [
        "  <entry>",
        f"    <id>urn:quran-ebook:variant:{v['id']}</id>",
        f"    <title>{escape(title)}</title>",
        f"    <updated>{updated}</updated>",
        f"    <author><name>{escape(author)}</name></author>",
        f"    <dc:language>{lang}</dc:language>",
        f"    <content type=\"text\">{escape(v['title'])}"
        f"{' — BETA: feedback welcome' if v['status'] == 'beta' else ''}</content>",
        f'    <link rel="http://opds-spec.org/acquisition" href="{v["url"]}"'
        ' type="application/epub+zip"/>',
        "  </entry>",
    ]
    return lines


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-i", "--catalog", default="output/catalog.json")
    ap.add_argument("-o", "--out-dir", default="output/opds")
    ap.add_argument("--base-url", default=DEFAULT_BASE)
    args = ap.parse_args()

    catalog = json.loads((ROOT / args.catalog).read_text())
    variants = catalog["variants"]
    out = ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    base = args.base_url.rstrip("/")
    updated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Acquisition feeds
    counts = {}
    for slug, title, pred in CATEGORIES:
        members = sorted(
            (v for v in variants if pred(v)),
            key=lambda v: ((v["axes"]["translation"] or {}).get("language") or "",
                           v["id"]),
        )
        counts[slug] = len(members)
        lines = _feed_head(slug, title, base, f"{base}/{slug}.xml", updated)
        for v in members:
            lines += _entry(v, updated)
        lines.append("</feed>")
        (out / f"{slug}.xml").write_text("\n".join(lines) + "\n")

    # Root navigation feed
    lines = _feed_head("root", "Quran EPUBs (quran-ebook)", base,
                       f"{base}/root.xml", updated)
    for slug, title, _ in CATEGORIES:
        lines += [
            "  <entry>",
            f"    <id>urn:quran-ebook:opds:{slug}</id>",
            f"    <title>{escape(title)}</title>",
            f"    <updated>{updated}</updated>",
            f'    <link rel="subsection" href="{base}/{slug}.xml" type="{ACQ}"/>',
            f"    <content type=\"text\">{counts[slug]} books</content>",
            "  </entry>",
        ]
    lines.append("</feed>")
    (out / "root.xml").write_text("\n".join(lines) + "\n")

    print(f"OPDS feeds -> {out}: root + {', '.join(f'{s}({counts[s]})' for s, _, _ in CATEGORIES)}")


if __name__ == "__main__":
    main()
