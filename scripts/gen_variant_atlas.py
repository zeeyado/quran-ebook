#!/usr/bin/env python
"""Generate the Variant Atlas page from configs/.

One row per configs/ cell, derived exactly as the build derives it
(BuildConfig.variant_id — the frozen grammar-v1 stem), spliced into
scripts/atlas_template.html together with a build stamp (date + commit +
parked-config disclosure). The two QUL-sampled panels (tafsir lengths,
Al-Mukhtasar reach) ride scripts/atlas_qul_data.json — refresh that file
separately when re-sampling; its `sampled` date is stamped on the page.

The output is a self-contained HTML page published as the
"Quran EPUB Variant Atlas" artifact (URL in the project memory).

Usage (clarify env):
    python scripts/gen_variant_atlas.py [-o output/atlas/variant_atlas.html]
"""

from __future__ import annotations

import argparse
import datetime
import json
import subprocess
from pathlib import Path

from quran_ebook.config.registry import ENGLISH_LANGUAGE_NAMES, get_riwayah
from quran_ebook.config.schema import _VARIANT_ORTHO, load_config

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "scripts" / "atlas_template.html"
QUL_DATA = ROOT / "scripts" / "atlas_qul_data.json"

# Column order is deliberate: flow → flow-popup → ayah-inline → ayah-popup →
# ayah-inline+tafsir → word-inline → word-popup. A new layout.structure must
# be added here (and given a label) before the atlas can show it — the
# generator hard-errors on unknown structures rather than dropping rows.
STRUCTS = [
    ("inline", "Flowing", "flow"),
    ("interactive_inline", "Flowing · popup", "flow-popup"),
    ("by_surah", "Ayah by ayah · inline", "ayah-inline"),
    ("ayah_popup", "Ayah by ayah · popup", "ayah-popup"),
    ("bilingual_interactive", "Ayah by ayah · inline + tafsir popup", "ayah-inline + tafsir"),
    ("wbw", "Word by word · inline", "word-inline"),
    ("wbw_popup", "Word by word · popup", "word-popup"),
]
SCRIPTS = ["Hafs", "Warsh", "IndoPak Nastaleeq"]
PIPS = {"Hafs": "H", "Warsh": "W", "IndoPak Nastaleeq": "N"}
BARE = "—"
BARE_LABEL = "None — bare mushaf"
GLOSSES_ONLY = "Glosses only"


def script_index(cfg) -> int:
    ortho, _ = _VARIANT_ORTHO[cfg.quran.script]
    if ortho == "indopak":
        return 2
    return 1 if get_riwayah(cfg.quran.script) == "warsh" else 0


def build_data() -> dict:
    paths = sorted((ROOT / "configs").rglob("*.yaml"))
    if not paths:
        raise SystemExit("no configs found under configs/")

    struct_ix = {key: i for i, (key, _, _) in enumerate(STRUCTS)}
    loaded = []
    lang_codes: set[str] = set()
    for p in paths:
        cfg = load_config(p)
        st = cfg.layout.structure
        if st not in struct_ix:
            raise SystemExit(
                f"{p}: structure {st!r} not in the atlas STRUCTS list — add a column"
            )
        gloss = ""
        if st in ("wbw", "wbw_popup"):
            g = cfg.layout.wbw_gloss_language
            if g and (not cfg.translation or g != cfg.translation.language):
                gloss = g
        if cfg.translation:
            code = cfg.translation.language
        elif gloss:
            code = gloss
        else:
            code = BARE
        lang_codes.add(code)
        loaded.append((p, cfg, gloss, code))

    # Alphabetical by English name, bare mushaf last (matrix + chip order).
    def lang_name(code: str) -> str:
        return BARE_LABEL if code == BARE else ENGLISH_LANGUAGE_NAMES.get(code, code)

    langs = sorted(
        ([c, lang_name(c)] for c in lang_codes),
        key=lambda l: (l[0] == BARE, l[1]),
    )
    lang_ix = {code: i for i, (code, _) in enumerate(langs)}

    translators: list[str] = [BARE]
    trans_ix = {BARE: 0}

    def t_idx(name: str) -> int:
        if name not in trans_ix:
            trans_ix[name] = len(translators)
            translators.append(name)
        return trans_ix[name]

    rows = []
    real_translations: set[str] = set()
    for p, cfg, gloss, code in loaded:
        tp = cfg.tafsir.abbreviation if cfg.tafsir else ""
        tt = ""
        if cfg.translation:
            if cfg.translation.is_tafsir_style:
                tt = cfg.translation.abbreviation
            else:
                real_translations.add(cfg.translation.name)
            ti = t_idx(cfg.translation.name)
        elif gloss:
            ti = t_idx(GLOSSES_ONLY)
        else:
            ti = 0
        rows.append([
            lang_ix[code],
            struct_ix[cfg.layout.structure],
            script_index(cfg),
            0 if cfg.output.status == "stable" else 1,
            ti,
            tp,
            tt,
            cfg.variant_id,
            str(p.relative_to(ROOT)),
            gloss,
        ])

    ids = [r[7] for r in rows]
    if len(set(ids)) != len(ids):
        dupes = sorted({v for v in ids if ids.count(v) > 1})
        raise SystemExit(f"variant_id collision(s): {dupes}")

    qul = json.loads(QUL_DATA.read_text(encoding="utf-8"))
    stable = sum(1 for r in rows if r[3] == 0)
    return {
        "langs": langs,
        "structs": [list(s) for s in STRUCTS],
        "scripts": SCRIPTS,
        "pips": PIPS,
        "translators": translators,
        "rows": rows,
        "stats": {
            "total": len(rows),
            "langs": len(langs) - (1 if BARE in lang_ix else 0),
            "stable": stable,
            "beta": len(rows) - stable,
            "tafsir": sum(1 for r in rows if r[5] or r[6]),
            # Distinct translation editions (annotated editions count
            # separately). Excludes the bare mushaf, glosses-only, and
            # tafsir-as-text entries — those are not translations.
            "translations": len(real_translations),
        },
        "mukh": qul["mukh"],
        "tlen": qul["tlen"],
    }, qul["sampled"]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", default="output/atlas/variant_atlas.html")
    args = ap.parse_args()

    data, qul_date = build_data()
    sha = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    n_parked = sum(
        len(list((ROOT / d).rglob("*.yaml")))
        for d in ("configs-experimental", "configs-tajweed")
        if (ROOT / d).is_dir()
    )

    html = TEMPLATE.read_text(encoding="utf-8")
    for marker, value in [
        ("__ATLAS_DATA__", json.dumps(data, ensure_ascii=False, separators=(",", ":"))),
        ("__GEN_DATE__", datetime.date.today().isoformat()),
        ("__GIT_SHA__", sha),
        ("__N_PARKED__", str(n_parked)),
        ("__QUL_DATE__", qul_date),
    ]:
        if marker not in html:
            raise SystemExit(f"template is missing the {marker} marker")
        html = html.replace(marker, value)

    out = ROOT / args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    s = data["stats"]
    print(
        f"wrote {out} — {s['total']} variants ({s['stable']} production / "
        f"{s['beta']} beta), {s['langs']} languages, {s['translations']} "
        f"translations, {s['tafsir']} with tafsir · commit {sha} · "
        f"{n_parked} parked configs excluded"
    )


if __name__ == "__main__":
    main()
