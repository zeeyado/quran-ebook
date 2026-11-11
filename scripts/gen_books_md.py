#!/usr/bin/env python3
"""Write BOOKS.md: the table of every book in the release set.

The release text stays short and links here. One row per edition and
layout, one column per Arabic text, under the same names that the OPDS
catalog and the plugin show. The page is made from the configs alone, so
it can be written and committed before a release is built. Its links
point at the files of the latest release.

Usage:
    python scripts/gen_books_md.py              # write BOOKS.md
    python scripts/gen_books_md.py --check      # exit 1 if BOOKS.md is not current
    python scripts/gen_books_md.py --stdout     # print it instead

The release workflow runs --check on a tag build: a release never goes out
with a table that does not match its books.
"""

import argparse
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from gen_catalog import build_catalog, config_paths_for  # noqa: E402

OUT = ROOT / "BOOKS.md"
DEFAULT_SET = "release_set.txt"
# The README section that says how to build a book that is not published.
BUILD_HEADING = "Build Your Own EPUBs"

# Column order: the Arabic text of the book (riwayah and script).
SCRIPTS = ["qpc_uthmani_hafs", "text_indopak_nastaleeq", "qpc_uthmani_warsh"]
# Row order inside one edition.
LAYOUT_ORDER = ["by_surah", "inline", "ayah_popup", "interactive_inline",
                "wbw", "wbw_popup", "bilingual_interactive"]


def _layout_rank(v: dict) -> tuple:
    layout = v["axes"]["layout"]
    return (LAYOUT_ORDER.index(layout) if layout in LAYOUT_ORDER else 99,
            v["axes"].get("gloss_language") or "")


def _layout_label(v: dict, languages: dict) -> str:
    """The row's layout name, plus the gloss language of a word-by-word
    book when it is not the language of the translation."""
    axes = v["axes"]
    label = axes["layout_shelf"]
    gloss = axes.get("gloss_language")
    layer = axes["translation"] or axes["tafsir_as_text"]
    if gloss and (not layer or gloss != layer["language"]):
        label += f", {languages.get(gloss, {}).get('en', gloss)} glosses"
    return label


def _cell(v: dict | None) -> str:
    if v is None:
        return ""
    link = f"[EPUB]({v['url']})"
    return link if v["status"] == "stable" else f"{link} ({v['status']})"


def _table(rows: list[tuple[list[str], dict]], lead_headers: list[str],
           script_names: dict) -> list[str]:
    """rows: (lead cells, {script: variant}). Columns with no book are left out."""
    used = [s for s in SCRIPTS if any(s in cells for _lead, cells in rows)]
    out = ["| " + " | ".join(lead_headers + [script_names[s] for s in used]) + " |",
           "|" + "|".join([":--"] * len(lead_headers) + [":-:"] * len(used)) + "|"]
    for lead, cells in rows:
        out.append("| " + " | ".join(lead + [_cell(cells.get(s)) for s in used]) + " |")
    return out


def _rows(variants: list[dict], key_fn) -> "OrderedDict[tuple, dict]":
    """Group variants by key_fn into {key: {script: variant}}, in input order."""
    groups: OrderedDict = OrderedDict()
    for v in variants:
        cells = groups.setdefault(key_fn(v), {})
        script = v["axes"]["script"]
        if script in cells:
            sys.exit(f"ERROR: two books for one table cell: {cells[script]['id']} "
                     f"and {v['id']}")
        cells[script] = v
    return groups


def _edition_table(variants: list[dict], languages: dict, script_names: dict,
                   layer_key: str, first_slug: str | None = None) -> list[str]:
    """One table for the editions of one language: edition, layout, links."""
    variants = sorted(variants, key=lambda v: (
        first_slug is not None and v["axes"][layer_key]["slug"] != first_slug,
        v["axes"][layer_key]["name"], _layout_rank(v)))
    groups = _rows(variants, lambda v: (
        v["axes"][layer_key]["slug"], v["axes"][layer_key]["name"],
        _layout_label(v, languages)))
    rows, prev = [], None
    for (slug, name, layout), cells in groups.items():
        rows.append(([name if slug != prev else "", layout], cells))
        prev = slug
    return _table(rows, ["Edition", "Layout"], script_names)


def _readme_anchor(heading: str) -> str:
    """The anchor of a README heading; stops if the README has no such heading."""
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    if f"\n## {heading}\n" not in readme:
        sys.exit(f"ERROR: README.md has no heading '## {heading}' "
                 f"(BOOKS.md links to it: update BUILD_HEADING)")
    return heading.lower().replace(" ", "-")


def _language_title(code: str, languages: dict) -> str:
    entry = languages.get(code, {})
    english, native = entry.get("en", code), entry.get("native", code)
    return english if native == english else f"{english} ({native})"


def render(catalog: dict) -> str:
    vs = catalog["variants"]
    languages = catalog["languages"]
    script_names = {}
    for v in vs:
        script_names.setdefault(v["axes"]["script"], v["axes"]["script_shelf"])

    arabic = [v for v in vs if not v["axes"]["translation"]
              and not v["axes"]["tafsir_as_text"] and not v["axes"]["tafsir"]]
    translated = [v for v in vs if v["axes"]["translation"] and not v["axes"]["tafsir"]]
    tafsir_text = [v for v in vs if v["axes"]["tafsir_as_text"] and not v["axes"]["tafsir"]]
    tafsir_popup = [v for v in vs if v["axes"]["tafsir"]]
    placed = len(arabic) + len(translated) + len(tafsir_text) + len(tafsir_popup)
    if placed != len(vs):
        sys.exit(f"ERROR: {len(vs) - placed} books fit no section of the table")

    n_editions = len({(v["axes"]["translation"]["language"], v["axes"]["translation"]["slug"])
                      for v in translated})
    n_languages = len({v["axes"]["translation"]["language"] for v in translated})
    n_beta = sum(1 for v in vs if v["status"] != "stable")

    out = [
        "# Books",
        "",
        "<!-- Generated by scripts/gen_books_md.py from release_set.txt. "
        "Do not edit by hand. -->",
        "",
        f"The latest release publishes **{len(vs)} books**: the Arabic text alone, "
        f"and with {n_editions} translations in {n_languages} languages.",
        "",
        "- Each link downloads one EPUB from the latest release.",
        "- The columns are the Arabic text of the book: its riwayah and its script.",
        f"- {n_beta} books are marked *beta*: they are complete, and they wait for "
        "readers' feedback on that script or layout.",
        "- Every other combination can be built on request: see "
        f"[Build your own](README.md#{_readme_anchor(BUILD_HEADING)}).",
        "",
        "## Arabic only",
        "",
    ]
    groups = _rows(sorted(arabic, key=_layout_rank), lambda v: _layout_label(v, languages))
    out += _table([([label], cells) for label, cells in groups.items()],
                  ["Layout"], script_names)

    out += ["", "## Arabic with a translation", ""]
    by_lang: dict[str, list[dict]] = {}
    for v in translated:
        by_lang.setdefault(v["axes"]["translation"]["language"], []).append(v)
    order = sorted(by_lang, key=lambda c: (c != "en", languages.get(c, {}).get("en", c)))
    for code in order:
        out += [f"### {_language_title(code, languages)}", ""]
        out += _edition_table(by_lang[code], languages, script_names, "translation",
                              first_slug="sahih" if code == "en" else None)
        out.append("")

    out += ["## Arabic with a tafsir as the second text", "",
            "The tafsir stands where a translation would stand. It explains "
            "the ayah; it is not a literal translation.", ""]
    by_lang = {}
    for v in tafsir_text:
        by_lang.setdefault(v["axes"]["tafsir_as_text"]["language"], []).append(v)
    for code in sorted(by_lang, key=lambda c: (c != "en", languages.get(c, {}).get("en", c))):
        out += [f"### {_language_title(code, languages)}", ""]
        out += _edition_table(by_lang[code], languages, script_names, "tafsir_as_text")
        out.append("")

    out += ["## Arabic with a translation, and a tafsir in a popup", "",
            "A tap on an ayah's number opens the tafsir of that ayah.", ""]
    popup_sorted = sorted(tafsir_popup, key=lambda v: (
        (v["axes"]["translation"] or v["axes"]["tafsir_as_text"])["name"],
        v["axes"]["tafsir_name"],
        v["axes"]["layout"] != "bilingual_interactive", _layout_rank(v)))

    def popup_key(v):
        layer = v["axes"]["translation"] or v["axes"]["tafsir_as_text"]
        lang = languages.get(layer["language"], {}).get("en", layer["language"])
        return (f"{layer['name']} ({lang})", v["axes"]["tafsir_name"],
                _layout_label(v, languages))
    out += _table([(list(key), cells) for key, cells in _rows(popup_sorted, popup_key).items()],
                  ["Translation", "Tafsir", "Layout"], script_names)
    return "\n".join(out) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--set", dest="set_file", default=DEFAULT_SET,
                    help=f"the release set file (default: {DEFAULT_SET})")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if BOOKS.md differs from what this would write")
    ap.add_argument("--stdout", action="store_true", help="print instead of writing")
    args = ap.parse_args()

    catalog, _missing = build_catalog(config_paths_for(args.set_file))
    text = render(catalog)
    if args.stdout:
        sys.stdout.write(text)
    elif args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
        if current != text:
            sys.exit(f"ERROR: {OUT.name} is {'missing' if current is None else 'not current'}. "
                     f"Run: python scripts/gen_books_md.py   and commit the file.")
        print(f"{OUT.name}: current ({len(catalog['variants'])} books)")
    else:
        OUT.write_text(text, encoding="utf-8")
        print(f"{OUT.name}: {len(catalog['variants'])} books, {len(text):,} characters")


if __name__ == "__main__":
    main()
