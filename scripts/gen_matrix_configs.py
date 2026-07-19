#!/usr/bin/env python
"""Generate the IndoPak/Warsh config matrix from the Hafs base configs.

Owner decision 2026-07-18: every translation ships for every script variant
— IndoPak (bilingual + interactive + wbw; Hafs numbering, no gate) and
Warsh (bilingual + interactive via the alignment table; wbw impossible —
no word-level Warsh data exists). QCF/tajweed stay parked.
Owner decision 2026-07-19: the ayah_popup layout joins the matrix with full
parity (layouts are the mechanical axis; hafs cells ship non-beta, script
variants beta per tier rule 7).

Derivation:
  configs/bilingual/<stem>.yaml (hafs)  -> bilingual/<stem>_nastaleeq.yaml
                                           bilingual/<stem>_warsh.yaml
                                           interactive/<stem>_nastaleeq.yaml
                                           interactive/<stem>_warsh.yaml
                                           ayah-popup/<stem>.yaml (hafs)
                                           ayah-popup/<stem>_nastaleeq.yaml
                                           ayah-popup/<stem>_warsh.yaml
  configs/wbw/<stem>.yaml (hafs)       -> wbw/<stem>_nastaleeq.yaml
                                           (gloss settings preserved)

Cells whose variant_id already exists (the hand-written en_sahih_warsh,
en_sahih_nastaleeq, ur_jalandhari_nastaleeq, wbw/en_indopak, …) are
skipped, as are existing files. All generated cells are status "beta"
per tier rule 7 (feedback-gated — owner cannot proof these scripts).

Run:  python scripts/gen_matrix_configs.py [--dry-run]
Idempotent: re-running creates only missing cells.
"""

import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.config.schema import load_config  # noqa: E402

INDOPAK_TITLE = "القرآن الکریم"  # Farsi kaf, matching the shipped IndoPak cells


def _quote(v) -> str:
    s = str(v)
    assert '"' not in s and "\\" not in s, f"unquotable value: {s!r}"
    return f'"{s}"'


def _translation_block(tr: dict) -> str:
    lines = ["translation:"]
    for key in ("resource_id", "source", "edition", "language", "name",
                "native_name", "abbreviation", "language_name"):
        if key in tr and tr[key] not in (None, ""):
            v = tr[key] if key == "resource_id" else _quote(tr[key])
            lines.append(f"  {key}: {v}")
    return "\n".join(lines)


def _layout_block(structure: str, layout: dict) -> str:
    lines = ["layout:", f"  structure: {_quote(structure)}"]
    lines.append("  show_ayah_numbers: true")
    lines.append("  show_bismillah: true")
    if structure == "wbw":
        lines.append(
            f"  wbw_transliteration: {str(layout.get('wbw_transliteration', False)).lower()}")
        if layout.get("wbw_gloss_language"):
            lines.append(f"  wbw_gloss_language: {_quote(layout['wbw_gloss_language'])}")
    return "\n".join(lines)


def render(base: dict, script: str, font: str, title: str, structure: str,
           src_name: str, status: str = "beta") -> str:
    quran_source = "kfgqpc" if script == "qpc_uthmani_warsh" else "quran_api"
    status_note = (
        "Beta per tier rule 7 (feedback-gated\n# — owner cannot proof this script). "
        if status == "beta" else ""
    )
    status_line = f'\n  status: "{status}"' if status != "stable" else ""
    return f"""# Generated matrix cell (scripts/gen_matrix_configs.py, owner decisions
# 2026-07-18/19) from configs/{src_name}. {status_note}Regenerate, don't hand-edit.
book:
  title: {_quote(title)}
  language: "ar"

quran:
  script: {_quote(script)}
  source: {_quote(quran_source)}

font:
  arabic: {_quote(font)}

{_translation_block(base["translation"])}

{_layout_block(structure, base.get("layout", {}))}

output:
  directory: "output"{status_line}
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    existing_vids = set()
    for p in sorted((ROOT / "configs").rglob("*.yaml")):
        existing_vids.add(load_config(p).variant_id)

    plans: list[tuple[Path, str]] = []  # (target path, content)

    def plan(target: Path, content: str) -> None:
        if target.exists():
            return
        plans.append((target, content))

    # bilingual + interactive cells from the hafs bilingual bases
    for p in sorted((ROOT / "configs" / "bilingual").glob("*.yaml")):
        base = yaml.safe_load(p.read_text(encoding="utf-8"))
        if base.get("quran", {}).get("script") != "qpc_uthmani_hafs":
            continue  # script-variant file, not a base
        stem = p.stem
        for family, structure in (("bilingual", "by_surah"),
                                  ("interactive", "interactive_inline"),
                                  ("ayah-popup", "ayah_popup")):
            if family == "ayah-popup":
                # Hafs ayah-popup cell (non-beta — proofable script)
                plan(ROOT / "configs" / family / f"{stem}.yaml",
                     render(base, "qpc_uthmani_hafs", "kfgqpc_uthmanic_hafs",
                            base["book"]["title"], structure,
                            f"bilingual/{p.name}", status="stable"))
            plan(ROOT / "configs" / family / f"{stem}_nastaleeq.yaml",
                 render(base, "text_indopak_nastaleeq", "indopak_nastaleeq",
                        INDOPAK_TITLE, structure, f"bilingual/{p.name}"))
            plan(ROOT / "configs" / family / f"{stem}_warsh.yaml",
                 render(base, "qpc_uthmani_warsh", "kfgqpc_uthmanic_warsh",
                        base["book"]["title"], structure, f"bilingual/{p.name}"))

    # wbw cells mirror the shipped hafs wbw matrix (gloss variants intact)
    for p in sorted((ROOT / "configs" / "wbw").glob("*.yaml")):
        base = yaml.safe_load(p.read_text(encoding="utf-8"))
        if base.get("quran", {}).get("script") != "qpc_uthmani_hafs":
            continue
        if "translation" not in base:
            continue  # glosses-only pilot — no auto script twins for now
        plan(ROOT / "configs" / "wbw" / f"{p.stem}_nastaleeq.yaml",
             render(base, "text_indopak_nastaleeq", "indopak_nastaleeq",
                    INDOPAK_TITLE, "wbw", f"wbw/{p.name}"))

    created, skipped_vid = [], []
    for target, content in plans:
        target.write_text(content, encoding="utf-8")
        vid = load_config(target).variant_id
        if vid in existing_vids:
            target.unlink()
            skipped_vid.append((target.name, vid))
            continue
        existing_vids.add(vid)
        if args.dry_run:
            target.unlink()
        created.append(target)

    for name, vid in skipped_vid:
        print(f"skip (variant exists): {name} -> {vid}")
    print(f"{'would create' if args.dry_run else 'created'} {len(created)} configs")
    for t in created:
        print(t.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
