#!/usr/bin/env python3
"""Generate the OPDS catalogs (Atom XML + OPDS 2.0 JSON) from catalog.json.

KOReader's built-in OPDS client handles browsing + downloading natively —
static feeds, hosted on gh-pages (release) or as test-build release assets
(test feeds via --asset-base/--base-url overrides).

Feed tree (facet round DA-6(b), owner 2026-07-27; base tree 2026-07-20):

  root.xml                 navigation
    languages.xml          navigation  -> lang-<code>.xml   (per language)
    layouts.xml            navigation  -> layout-<slug>.xml (per gran+placement)
    scripts.xml            navigation  -> script-<slug>.xml (per riwayah+ortho)
    arabic.xml             acquisition (Arabic only — no translation layer)
    tafsir.xml             acquisition (tafsir popups + tafsir-as-text)

FACETS (--facets, default ON): every axis shelf carries OPDS 1.1 facet
links (rel=http://opds-spec.org/facet, opds:facetGroup=Language/Layout/
Script, opds:activeFacet on the shelf's own group, thr:count) — KOReader
renders them as its Facets menu (since 2025.08, #14089). Facet targets
are PRE-BAKED PAIR feeds (lang-en+layout-….xml …): one narrowing step
deep, empty combos pruned, pair feeds switch within their two consumed
groups but never offer the third axis (triples would triple the file
count for a tail nobody browses: 472 triples vs 319 pairs at 679
variants). The Arabic-only / With-tafsir filter shelves stay flat.

OPDS 2.0 (--json, default ON): every feed gets an application/opds+json
twin (same slug, .json) — navigation, publications, groups-free flat
lists, facets as Feed objects with numberOfItems. KOReader parses these
since 2026.07 (#15696). The XML root links rel=alternate to the JSON
root and vice versa.

HOSTING BUDGET: gh-pages (stable channel) carries the full tree (~380
files per format — plain files, no cap). The TEST channel stages feeds
as release assets under the 1000-asset hard cap, so
publish_test_build.py passes --no-facets --no-json there (level-1 XML
only, the channel-e2e surface).

Usage:
    python scripts/gen_opds.py [-i output/catalog.json] [-o output/opds]
        [--base-url https://zeeyado.github.io/quran-ebook/opds]
        [--asset-base https://github.com/.../releases/download/test-build]
        [--no-facets] [--no-json]

--base-url   where the FEED files live (inter-feed links).
--asset-base override for the EPUB download links; default keeps each
             variant's catalog url (releases/latest/download — the stable
             release contract). Set both to the test-build download base to
             produce a fully working pre-release test feed.
"""

import argparse
import json
import re
from datetime import datetime, timezone
from itertools import combinations
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_BASE = "https://zeeyado.github.io/quran-ebook/opds"

NAV = "application/atom+xml;profile=opds-catalog;kind=navigation"
ACQ = "application/atom+xml;profile=opds-catalog;kind=acquisition"
JSONFEED = "application/opds+json"
FACET_REL = "http://opds-spec.org/facet"

AXIS_ORDER = ("lang", "layout", "script")
AXIS_GROUP_LABELS = {"lang": "Language", "layout": "Layout", "script": "Script"}


def _feed_head(feed_id: str, title: str, base: str, kind: str,
               updated: str) -> list[str]:
    return [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom"'
        ' xmlns:dc="http://purl.org/dc/terms/"'
        ' xmlns:thr="http://purl.org/syndication/thread/1.0"'
        ' xmlns:opds="http://opds-spec.org/2010/catalog">',
        f"  <id>urn:quran-ebook:opds:{feed_id}</id>",
        f"  <title>{escape(title)}</title>",
        f"  <updated>{updated}</updated>",
        f'  <link rel="self" href="{base}/{feed_id}.xml" type="{kind}"/>',
        f'  <link rel="start" href="{base}/root.xml" type="{NAV}"/>',
        "  <author><name>quran-ebook</name></author>",
    ]


ORTHO_LABELS = {"uthmani": "Uthmani", "indopak": "IndoPak"}


def _omitted(omit, key: str) -> bool:
    """omit is None, a single axis key, or a SET of them (pair feeds fix
    two axes — every fixed axis drops out of the entry titles)."""
    if omit is None:
        return False
    if isinstance(omit, (set, frozenset)):
        return key in omit
    return omit == key


def _entry_title(v: dict, languages: dict, omit=None) -> str:
    """Context-scoped entry title (owner formula 2026-07-22): LANGUAGE-first,
    always complete —

        <Language | "Arabic"> · <translator/tafsir> · <riwayah> · <script> · <layout>

    Riwayah + script always show (even the Hafs · Uthmani default); `omit`
    drops the axis/axes the surrounding shelf fixes; beta becomes an inline
    suffix. MUST stay identical to gen_catalog.py _title_en (neutral) and
    quran_assets.lua entryTitle (incl. the omit-set semantics).
    """
    axes = v["axes"]
    layer = axes["translation"] or axes["tafsir_as_text"]
    parts = []
    # 1. language (translation/gloss) — or "Arabic" for bare Arabic
    if not _omitted(omit, "lang"):
        code = (layer or {}).get("language") or axes["gloss_language"]
        if code:
            parts.append((languages.get(code) or {}).get("en") or code)
        else:
            parts.append("Arabic")
    # 2. translator / tafsir edition name
    if layer:
        parts.append(layer["name"])
    # 3. riwayah + script (always present, unless the shelf fixes script)
    if not _omitted(omit, "script"):
        if axes["riwayah"]:
            parts.append(axes["riwayah"].title())
        ortho = ORTHO_LABELS.get(axes["orthography"])
        if ortho:
            parts.append(ortho)
    # 4. layout / type
    glosses_only = axes["gloss_language"] and not layer
    tafsir_name = axes.get("tafsir_name")
    if not _omitted(omit, "layout"):
        layout = axes["layout_label"] + (" · glosses only" if glosses_only else "")
        # a named popup tafsir replaces the generic layout mention
        if tafsir_name:
            layout = layout.replace(" + tafsir popup", "")
        if layout:
            parts.append(layout)
    elif glosses_only:
        parts.append("glosses only")
    # 5. gloss language — only worth ink when it differs from the translation
    if layer and axes["gloss_language"] and axes["gloss_language"] != layer["language"]:
        gloss_en = (languages.get(axes["gloss_language"]) or {}).get("en") \
            or axes["gloss_language"]
        parts.append(f"{gloss_en} glosses")
    # 6. named popup tafsir
    if tafsir_name:
        parts.append(f"{tafsir_name} popup")
    if v["status"] == "beta":
        parts.append("beta")
    return " · ".join(parts) or v["id"]


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


def _slugify(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")


def _epub_href(v: dict, asset_base: str | None) -> str:
    return f"{asset_base}/{v['filename']}" if asset_base else v["url"]


def _book_entry(v: dict, updated: str, asset_base: str | None,
                languages: dict, omit) -> list[str]:
    title = _entry_title(v, languages, omit)
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    author = (layer or {}).get("name") or "Quran"
    lang = (layer or {}).get("language") or "ar"
    href = _epub_href(v, asset_base)
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


def _facet_link_xml(base: str, target_slug: str, title: str, group: str,
                    count: int, active: bool) -> str:
    active_attr = ' opds:activeFacet="true"' if active else ""
    return (f'  <link rel="{FACET_REL}" href="{base}/{target_slug}.xml"'
            f' type="{ACQ}" title={quoteattr(title)}'
            f' opds:facetGroup="{group}"{active_attr}'
            f' thr:count="{count}"/>')


# ---------------------------------------------------------------------------
# JSON (OPDS 2.0) twins
# ---------------------------------------------------------------------------

def _json_links(base: str, slug: str, xml_kind: str) -> list[dict]:
    return [
        {"rel": "self", "href": f"{base}/{slug}.json", "type": JSONFEED},
        {"rel": "alternate", "href": f"{base}/{slug}.xml", "type": xml_kind},
    ]


def _json_publication(v: dict, updated: str, asset_base: str | None,
                      languages: dict, omit) -> dict:
    layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
    author = (layer or {}).get("name") or "Quran"
    lang = (layer or {}).get("language") or "ar"
    desc = v["title"] + (" — BETA: feedback welcome"
                         if v["status"] == "beta" else "")
    return {
        "metadata": {
            "@type": "http://schema.org/Book",
            "identifier": f"urn:quran-ebook:variant:{v['id']}",
            "title": _entry_title(v, languages, omit),
            "author": [{"name": author}],
            "language": lang,
            "description": desc,
            "modified": updated,
        },
        "links": [{
            "rel": "http://opds-spec.org/acquisition",
            "href": _epub_href(v, asset_base),
            "type": "application/epub+zip",
        }],
    }


def _write_json(out: Path, slug: str, doc: dict) -> None:
    (out / f"{slug}.json").write_text(
        json.dumps(doc, ensure_ascii=False, indent=1) + "\n")


# ---------------------------------------------------------------------------
# Feed model
# ---------------------------------------------------------------------------

def _axis_options(variants: list[dict], languages: dict) -> dict:
    """axis -> { key -> {slug, label, members} } (derived, no silent caps)."""
    opts: dict[str, dict] = {a: {} for a in AXIS_ORDER}

    def add(axis, key, slug, label, v):
        o = opts[axis].setdefault(key, {"slug": slug, "label": label,
                                        "members": []})
        o["members"].append(v)

    for v in variants:
        code = _entry_lang(v)
        if code:
            add("lang", code, f"lang-{code}",
                _lang_shelf_title(code, languages), v)
        lay = v["axes"]["layout_shelf"]
        add("layout", lay, "layout-" + _slugify(lay), lay, v)
        scr = v["axes"]["script_shelf"]
        add("script", scr, "script-" + _slugify(scr), scr, v)
    return opts


def _variant_keys(v: dict) -> dict:
    return {
        "lang": _entry_lang(v),
        "layout": v["axes"]["layout_shelf"],
        "script": v["axes"]["script_shelf"],
    }


def _combo_slug(opts: dict, combo: dict) -> str:
    return "+".join(opts[a][combo[a]]["slug"] for a in AXIS_ORDER if a in combo)


def _combo_title(opts: dict, combo: dict) -> str:
    return " · ".join(opts[a][combo[a]]["label"]
                      for a in AXIS_ORDER if a in combo)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-i", "--catalog", default="output/catalog.json")
    ap.add_argument("-o", "--out-dir", default="output/opds")
    ap.add_argument("--base-url", default=DEFAULT_BASE)
    ap.add_argument("--asset-base", default=None,
                    help="Override EPUB link base (e.g. the test-build "
                         "explicit-tag download URL); default = catalog urls "
                         "(releases/latest).")
    ap.add_argument("--no-facets", action="store_true",
                    help="Level-1 shelves only: no pair feeds, no facet "
                         "links (the test channel's release-asset budget).")
    ap.add_argument("--no-json", action="store_true",
                    help="Skip the OPDS 2.0 JSON twins.")
    args = ap.parse_args()

    catalog = json.loads((ROOT / args.catalog).read_text())
    variants = catalog["variants"]
    languages = catalog.get("languages") or {}
    out = ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    # Clear stale feeds: the shelf set is derived from the catalog, so a
    # removed shelf's file would otherwise linger and ship to gh-pages.
    for old in (*out.glob("*.xml"), *out.glob("*.json")):
        old.unlink()
    base = args.base_url.rstrip("/")
    asset_base = args.asset_base.rstrip("/") if args.asset_base else None
    updated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    facets = not args.no_facets
    emit_json = not args.no_json

    opts = _axis_options(variants, languages)

    # --- pair combos (facet targets; empty combos pruned by derivation) ----
    pair_members: dict[tuple, list[dict]] = {}
    if facets:
        for v in variants:
            keys = _variant_keys(v)
            present = [(a, keys[a]) for a in AXIS_ORDER if keys[a]]
            for pair in combinations(present, 2):
                pair_members.setdefault(tuple(pair), []).append(v)

    # acquisition feeds: slug -> {title, members, omit, combo}
    acq: dict[str, dict] = {}
    for axis in AXIS_ORDER:
        for key, o in opts[axis].items():
            acq[o["slug"]] = {"title": o["label"], "members": o["members"],
                              "omit": {axis}, "combo": {axis: key}}
    for pair, members in pair_members.items():
        combo = dict(pair)
        slug = _combo_slug(opts, combo)
        acq[slug] = {"title": _combo_title(opts, combo), "members": members,
                     "omit": set(combo), "combo": combo}
    # filter shelves (flat, facet-free: they are filters, not axes)
    arabic = [v for v in variants if _entry_lang(v) is None]
    tafsir = [v for v in variants
              if v["axes"]["tafsir"] or v["axes"]["tafsir_as_text"]]
    acq["arabic"] = {"title": "Arabic only", "members": arabic,
                     "omit": None, "combo": None}
    acq["tafsir"] = {"title": "With tafsir", "members": tafsir,
                     "omit": None, "combo": None}

    def facet_groups(feed: dict) -> list[tuple[str, list[dict]]]:
        """[(group_label, [{slug,title,count,active}])] for one acq feed.

        Consumed axes: switch within the group at the SAME depth (active
        on the current option). Unconsumed axes: narrowing links, only
        while the target stays within pair depth.
        """
        combo = feed["combo"]
        if not facets or combo is None:
            return []
        groups = []
        for axis in AXIS_ORDER:
            links = []
            if axis in combo:
                for key, o in opts[axis].items():
                    target = dict(combo)
                    target[axis] = key
                    slug = _combo_slug(opts, target)
                    if slug in acq:
                        links.append({
                            "slug": slug, "title": o["label"],
                            "count": len(acq[slug]["members"]),
                            "active": key == combo[axis],
                        })
            elif len(combo) < 2:
                for key, o in opts[axis].items():
                    target = dict(combo)
                    target[axis] = key
                    slug = _combo_slug(opts, target)
                    if slug in acq:
                        links.append({
                            "slug": slug, "title": o["label"],
                            "count": len(acq[slug]["members"]),
                            "active": False,
                        })
            if len(links) > 1:
                links.sort(key=lambda l: l["title"].lower())
                groups.append((AXIS_GROUP_LABELS[axis], links))
        return groups

    # --- write acquisition feeds (XML + JSON) -------------------------------
    for slug, feed in acq.items():
        omit = feed["omit"]
        members = sorted(feed["members"],
                         key=lambda v: _entry_title(v, languages, omit).lower())
        groups = facet_groups(feed)
        lines = _feed_head(slug, feed["title"], base, ACQ, updated)
        for group, links in groups:
            for l in links:
                lines.append(_facet_link_xml(base, l["slug"], l["title"],
                                             group, l["count"], l["active"]))
        for v in members:
            lines += _book_entry(v, updated, asset_base, languages, omit)
        lines.append("</feed>")
        (out / f"{slug}.xml").write_text("\n".join(lines) + "\n")
        if emit_json:
            doc = {
                "metadata": {"title": feed["title"], "modified": updated,
                             "numberOfItems": len(members)},
                "links": _json_links(base, slug, ACQ),
                "publications": [
                    _json_publication(v, updated, asset_base, languages, omit)
                    for v in members],
            }
            if groups:
                doc["facets"] = [{
                    "metadata": {"title": group},
                    "links": [{
                        "title": l["title"],
                        "href": f"{base}/{l['slug']}.json",
                        "type": JSONFEED,
                        "properties": {
                            "numberOfItems": l["count"],
                            **({"activeFacet": True} if l["active"] else {}),
                        },
                    } for l in links],
                } for group, links in groups]
            _write_json(out, slug, doc)

    # --- axis navigation feeds ----------------------------------------------
    nav_specs = [
        ("languages", "By language", "lang"),
        ("layouts", "By layout", "layout"),
        ("scripts", "By script", "script"),
    ]
    for slug, title, axis in nav_specs:
        entries = sorted(opts[axis].values(), key=lambda o: o["label"].lower())
        lines = _feed_head(slug, title, base, NAV, updated)
        for o in entries:
            lines += _nav_entry(o["slug"], o["label"], len(o["members"]),
                                base, ACQ, updated)
        lines.append("</feed>")
        (out / f"{slug}.xml").write_text("\n".join(lines) + "\n")
        if emit_json:
            _write_json(out, slug, {
                "metadata": {"title": title, "modified": updated},
                "links": _json_links(base, slug, NAV),
                "navigation": [{
                    "title": o["label"],
                    "href": f"{base}/{o['slug']}.json",
                    "type": JSONFEED,
                    "properties": {"numberOfItems": len(o["members"])},
                } for o in entries],
            })

    # --- root ---------------------------------------------------------------
    translated = sum(len(o["members"]) for o in opts["lang"].values())
    root = _feed_head("root", "Quran EPUBs (quran-ebook)", base, NAV, updated)
    if emit_json:
        root.append(f'  <link rel="alternate" href="{base}/root.json"'
                    f' type="{JSONFEED}"/>')
    root += _nav_entry("languages", "By language", translated, base, NAV, updated)
    root += _nav_entry("layouts", "By layout", len(variants), base, NAV, updated)
    root += _nav_entry("scripts", "By script", len(variants), base, NAV, updated)
    root += _nav_entry("arabic", "Arabic only", len(arabic), base, ACQ, updated)
    root += _nav_entry("tafsir", "With tafsir", len(tafsir), base, ACQ, updated)
    root.append("</feed>")
    (out / "root.xml").write_text("\n".join(root) + "\n")
    if emit_json:
        _write_json(out, "root", {
            "metadata": {"title": "Quran EPUBs (quran-ebook)",
                         "modified": updated},
            "links": _json_links(base, "root", NAV),
            "navigation": [
                {"title": "By language", "href": f"{base}/languages.json",
                 "type": JSONFEED, "properties": {"numberOfItems": translated}},
                {"title": "By layout", "href": f"{base}/layouts.json",
                 "type": JSONFEED,
                 "properties": {"numberOfItems": len(variants)}},
                {"title": "By script", "href": f"{base}/scripts.json",
                 "type": JSONFEED,
                 "properties": {"numberOfItems": len(variants)}},
                {"title": "Arabic only", "href": f"{base}/arabic.json",
                 "type": JSONFEED, "properties": {"numberOfItems": len(arabic)}},
                {"title": "With tafsir", "href": f"{base}/tafsir.json",
                 "type": JSONFEED, "properties": {"numberOfItems": len(tafsir)}},
            ],
        })

    # --- self-check: every facet target must have been emitted --------------
    missing = []
    for slug, feed in acq.items():
        for group, links in facet_groups(feed):
            for l in links:
                if not (out / f"{l['slug']}.xml").exists():
                    missing.append(f"{slug} -> {l['slug']}")
    if missing:
        raise SystemExit("facet targets missing: " + ", ".join(missing[:10]))

    n_pairs = len(pair_members)
    n_xml = len(list(out.glob("*.xml")))
    n_json = len(list(out.glob("*.json")))
    print(f"OPDS feeds -> {out}: {n_xml} xml + {n_json} json "
          f"(level-1 {sum(len(o) for o in opts.values())} shelves, "
          f"{n_pairs} pair feeds, facets={'on' if facets else 'off'})")


if __name__ == "__main__":
    main()
