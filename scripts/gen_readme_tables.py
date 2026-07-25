#!/usr/bin/env python3
"""Generate the README download tables from catalog.json (runway 3.1).

catalog.json is the truth (axes carry everything); the README never
hand-edits a download link again. The generated block is injected
between two HTML-comment markers, so the prose around it stays
hand-written:

    <!-- gen:epub-tables:begin -->
    ... generated tables ...
    <!-- gen:epub-tables:end -->

Sections emitted (presentation decisions, agenda post-commit round
item 4): Arabic (the ayah trio + tafsir-as-text editions join it) ·
English · "With tafsir popups" as its OWN subsection (only flagships
have cells — never a column on every language table) · one details
block per other language. Beta = inline "· beta" suffix, no beta
shelf; the IndoPak/Warsh columns carry it in the header (tier rule 7:
whole script families are beta until community feedback clears them).

Usage:
    python scripts/gen_readme_tables.py                      # inject into README.md
    python scripts/gen_readme_tables.py --stdout             # print the block
    python scripts/gen_readme_tables.py \
        --asset-base https://github.com/zeeyado/quran-ebook/releases/download/test-build

--asset-base overrides every download link's base (gen_opds precedent:
default keeps each variant's catalog url = releases/latest/download,
the stable floating link; the test channel passes
releases/download/test-build so the release-prep branch is exercisable
during the soak). At release, rerun WITHOUT --asset-base and commit.
"""

import argparse
import json
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

BEGIN = "<!-- gen:epub-tables:begin -->"
END = "<!-- gen:epub-tables:end -->"
FLAG_BEGIN = "<!-- gen:flagship-links:begin -->"
FLAG_END = "<!-- gen:flagship-links:end -->"

# the pinned "Start here" row (runway 3.1) — stable variant ids
FLAGSHIPS = [
    ("quran_hafs-uthmani_kfgqpc_ayah_ar", "Arabic, ayah by ayah"),
    ("quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih",
     "Arabic + English (Sahih International)"),
    ("quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih_tafsir-mukhtasar",
     "Arabic + English with tafsir popups"),
    ("quran_hafs-uthmani_kfgqpc_word-inline_ar-en-sahih",
     "Word-by-word English"),
]

# Column order + headers: riwayah · orthography, never conflated
# (ND-21). The non-Hafs-Uthmani families are beta by tier rule 7.
SCRIPTS = [
    ("qpc_uthmani_hafs", "Hafs · Uthmani"),
    ("text_indopak_nastaleeq", "Hafs · IndoPak Nastaleeq · beta"),
    ("qpc_uthmani_warsh", "Warsh · Uthmani · beta"),
]

LAYOUT_ROW_LABELS = {
    "by_surah": "Ayah-by-ayah",
    "inline": "Continuous flow",
    "interactive_inline": "Continuous · tap for translation",
    "ayah_popup": "Ayah-by-ayah · tap for translation",
    "wbw": "Word-by-word",
    "wbw_popup": "Word-by-word · tap for translation",
    "bilingual_interactive": "Ayah-by-ayah + tafsir popups",
}
# stable presentation order for format rows within one edition
LAYOUT_ORDER = ["by_surah", "inline", "ayah_popup", "interactive_inline",
                "wbw", "wbw_popup", "bilingual_interactive"]


def _script_key(axes):
    return axes.get("script")


def _link(v, asset_base):
    url = (f"{asset_base}/{v['filename']}" if asset_base else v["url"])
    return f"[epub]({url})"


def _format_label(v):
    """Row label for one variant: layout + gloss qualifier."""
    axes = v["axes"]
    label = LAYOUT_ROW_LABELS.get(axes["layout"], axes["layout_label"])
    gloss = axes.get("gloss_language")
    tr = axes.get("translation")
    if axes["layout"] in ("wbw", "wbw_popup") and gloss:
        if not tr or gloss != tr["language"]:
            gname = {"en": "English", "id": "Indonesian"}.get(gloss, gloss)
            label += f" · {gname} word glosses"
    return label


def _row_beta(cells):
    """'· beta' suffix when the row's Hafs·Uthmani cell (the non-beta
    column) is itself beta — the script columns carry their own tier."""
    hafs = cells.get("qpc_uthmani_hafs")
    return hafs is not None and hafs["status"] != "stable"


def _table(rows, lead_headers):
    """rows: list of (lead_cells:list[str], cells:dict script->variant,
    asset_base). Emits one markdown table."""
    out = []
    headers = list(lead_headers) + [h for _k, h in SCRIPTS]
    out.append("| " + " | ".join(headers) + " |")
    out.append("|" + "|".join(
        [":--" for _ in lead_headers] + [":-:" for _ in SCRIPTS]) + "|")
    for lead, cells, asset_base in rows:
        line = list(lead)
        for key, _h in SCRIPTS:
            v = cells.get(key)
            line.append(_link(v, asset_base) if v else "—")
        out.append("| " + " | ".join(line) + " |")
    return out


def _group_rows(variants, key_fn):
    """Group variants into (key -> script -> variant), insertion-ordered."""
    groups = OrderedDict()
    for v in variants:
        k = key_fn(v)
        groups.setdefault(k, {})[_script_key(v["axes"])] = v
    return groups


def _layout_rank(v):
    lay = v["axes"]["layout"]
    return (LAYOUT_ORDER.index(lay) if lay in LAYOUT_ORDER else 99,
            v["axes"].get("gloss_language") or "")


def _sorted_by_layout(variants):
    return sorted(variants, key=_layout_rank)


def _edition_sort(vset, first_slug=None):
    """Translation-major: edition name, then format in layout order."""
    vset.sort(key=lambda v: (
        first_slug is not None
        and v["axes"]["translation"]["slug"] != first_slug,
        v["axes"]["translation"]["name"],
        _layout_rank(v)))
    return vset


def gen_arabic(vs, asset_base):
    """Arabic-only editions: the trio + glosses-only wbw, then the
    tafsir-as-text editions (tafsir rides in place of a translation)."""
    plain = [v for v in vs if not v["axes"]["translation"]
             and not v["axes"]["tafsir_as_text"] and not v["axes"]["tafsir"]]
    tat = [v for v in vs if not v["axes"]["translation"]
           and v["axes"]["tafsir_as_text"]]
    out = ["### Arabic", ""]
    rows = []
    for label, cells in _group_rows(
            _sorted_by_layout(plain), _format_label).items():
        if _row_beta(cells):
            label += " · beta"
        rows.append(([label], cells, asset_base))
    out += _table(rows, ["Format"])
    out += ["",
            "The ayah-by-ayah edition pairs best with the [KOReader plugin]"
            "(#koreader-plugin) — dynamic per-ayah content, theme bands; "
            "prefer a translated ayah-by-ayah edition if you want one fixed "
            "translation alongside the Arabic.", ""]

    out += ["#### Arabic with tafsir as the text", ""]
    def tat_key(v):
        t = v["axes"]["tafsir_as_text"]
        return (t["name"], t["language_name_en"], _format_label(v))
    rows = []
    for (name, lang, fmt), cells in _group_rows(
            _sorted_by_layout(tat),
            tat_key).items():
        label = f"{name} ({lang})"
        if _row_beta(cells):
            label += " · beta"
        rows.append(([label, fmt], cells, asset_base))
    out += _table(rows, ["Tafsir", "Format"])
    out += ["",
            "The tafsir rides in place of a translation — inline beneath "
            "each ayah (ayah-by-ayah) or in tap popups.", ""]
    return out


def _translation_rows(vset, asset_base, lead_with_name):
    """Rows for one language's plain translated editions —
    translation-major (pick your translation, then your format), the
    format rows in LAYOUT_ORDER within each edition. Callers pre-sort
    vset by edition; _group_rows preserves that insertion order."""
    def key(v):
        t = v["axes"]["translation"]
        return (t["slug"], t["name"], _format_label(v))
    rows = []
    prev_slug = None
    for (slug, name, fmt), cells in _group_rows(vset, key).items():
        label = f"{name} · beta" if _row_beta(cells) else name
        if lead_with_name and slug == prev_slug:
            label = ""  # repeat rows read as one edition block
        prev_slug = slug
        lead = [label, fmt] if lead_with_name else [fmt]
        rows.append((lead, cells, asset_base))
    return rows


def gen_language_tables(vs, languages, asset_base):
    plain = [v for v in vs if v["axes"]["translation"]
             and not v["axes"]["tafsir"]]
    by_lang = OrderedDict()
    for v in plain:
        by_lang.setdefault(v["axes"]["translation"]["language"], []).append(v)

    out = ["### English", ""]
    en = by_lang.pop("en", [])
    # flagship default-first: Sahih International leads, rest by name
    _edition_sort(en, first_slug="sahih")
    out += _table(_translation_rows(en, asset_base, True),
                  ["Translation", "Format"])
    out.append("")

    def lang_name(code):
        e = languages.get(code, {})
        native, en_name = e.get("native", code), e.get("en", code)
        return f"{native} — {en_name}" if native != en_name else en_name

    out += ["### Other languages", ""]
    for code in sorted(by_lang, key=lambda c: languages.get(c, {}).get("en", c)):
        vset = _edition_sort(by_lang[code])
        out.append(f"<details><summary>{lang_name(code)}</summary>")
        out.append("")
        out += _table(_translation_rows(vset, asset_base, True),
                      ["Translation", "Format"])
        out += ["", "</details>"]
    out.append("")
    return out


def gen_tafsir_popups(vs, languages, asset_base):
    """The curated popup-tafsir set — its own subsection (only flagships
    have cells; a column on every language table would be mostly empty)."""
    cells_set = [v for v in vs if v["axes"]["tafsir"]
                 and v["axes"]["translation"]]
    out = ["### With tafsir popups", ""]
    out += ["Translation inline, tafsir one tap away on every ayah marker "
            "(and full-screen through the plugin's reading window).", ""]
    def key(v):
        t = v["axes"]["translation"]
        lang = languages.get(t["language"], {}).get("en", t["language"])
        fmt = ("Word-by-word" if v["axes"]["layout"] in ("wbw", "wbw_popup")
               else "Ayah-by-ayah")
        return (lang, t["name"], v["axes"]["tafsir_name"], fmt)
    groups = _group_rows(
        sorted(cells_set, key=lambda v: (
            v["axes"]["translation"]["language"] != "en",
            languages.get(v["axes"]["translation"]["language"],
                          {}).get("en", ""),
            v["axes"]["translation"]["name"],
            v["axes"]["tafsir_name"])),
        key)
    rows = []
    for (lang, name, tafsir, fmt), cells in groups.items():
        tafsir_label = f"{tafsir} · beta" if _row_beta(cells) else tafsir
        rows.append(([f"{lang} · {name}", tafsir_label, fmt],
                     cells, asset_base))
    out += _table(rows, ["Translation", "Tafsir", "Format"])
    out.append("")
    return out


def gen_flagships(catalog, asset_base):
    by_id = {v["id"]: v for v in catalog["variants"]}
    links = []
    for vid, label in FLAGSHIPS:
        v = by_id.get(vid)
        if not v:
            sys.exit(f"flagship id missing from catalog: {vid}")
        url = f"{asset_base}/{v['filename']}" if asset_base else v["url"]
        links.append(f"[{label}]({url})")
    return (FLAG_BEGIN + "\n"
            + "**Start here:**\n" + " ·\n".join(links) + " —\n"
            + "or browse the full [download tables](#epubs).\n"
            + FLAG_END)


def gen_block(catalog, asset_base):
    vs = catalog["variants"]
    languages = catalog["languages"]
    n_translations = len({(v["axes"]["translation"]["language"],
                           v["axes"]["translation"]["slug"])
                          for v in vs if v["axes"]["translation"]})
    n_langs = len({v["axes"]["translation"]["language"]
                   for v in vs if v["axes"]["translation"]})
    catalog_url = (f"{asset_base}/catalog.json" if asset_base
                   else "../../releases/latest/download/catalog.json")
    out = [BEGIN, ""]
    out += [f"**{len(vs)} editions** — {n_translations} translations in "
            f"{n_langs} languages, three Arabic text families "
            f"(Hafs·Uthmani, Hafs·IndoPak, Warsh·Uthmani), and every "
            f"layout below. All tables are generated from "
            f"[catalog.json]({catalog_url}).",
            ""]
    out += gen_arabic(vs, asset_base)
    out += gen_language_tables(vs, languages, asset_base)
    out += gen_tafsir_popups(vs, languages, asset_base)
    out.append(END)
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--catalog", default=str(ROOT / "output" / "catalog.json"),
                    help="catalog.json path (default: output/catalog.json — "
                         "regenerate via scripts/gen_catalog.py first)")
    ap.add_argument("--readme", default=str(ROOT / "README.md"))
    ap.add_argument("--asset-base", default=None,
                    help="download-link base override (test channel: "
                         ".../releases/download/test-build); default keeps "
                         "the catalog's releases/latest urls")
    ap.add_argument("--stdout", action="store_true",
                    help="print the generated block instead of injecting")
    args = ap.parse_args()

    catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    block = gen_block(catalog, args.asset_base)
    flagships = gen_flagships(catalog, args.asset_base)

    if args.stdout:
        sys.stdout.write(flagships + "\n\n" + block)
        return

    readme = Path(args.readme)
    text = readme.read_text(encoding="utf-8")

    def splice(text, begin, end, replacement):
        i, j = text.find(begin), text.find(end)
        if i == -1 or j == -1:
            sys.exit(f"markers not found in {readme}: {begin} / {end}")
        return text[:i] + replacement + text[j + len(end):]

    text = splice(text, BEGIN, END, block.rstrip("\n"))
    text = splice(text, FLAG_BEGIN, FLAG_END, flagships)
    readme.write_text(text, encoding="utf-8")
    print(f"README tables regenerated: {len(catalog['variants'])} variants, "
          f"asset base = {args.asset_base or 'catalog urls (releases/latest)'}")


if __name__ == "__main__":
    main()
