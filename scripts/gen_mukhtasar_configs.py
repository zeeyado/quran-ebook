#!/usr/bin/env python
"""Generate Al-Mukhtasar tafsir-popup configs for every flagship translation.

Owner decision 2026-07-24: Al-Mukhtasar is the *production* tafsir popup
(Ibn Kathir is only the English-only PILOT, kept small because of its size).
So every flagship translation whose language has an Al-Mukhtasar on QUL gets
a `bilingual_interactive` cell pairing that translation (inline) with the
matching-language Al-Mukhtasar in ayah-marker popups — with full script
parity (Hafs, Warsh, Nastaleeq), mirroring configs/bilingual-interactive/
en_sahih_mukhtasar{,_warsh,_nastaleeq}.yaml.

The popup is anchored at the AYAH level (surah:ayah), so there is no
word-alignment concern; the only Warsh subtlety (a few ayah-numbering
differences vs Hafs) is handled by the same verified alignment table the
interactive layout already uses — proven by the shipping en_sahih_mukhtasar
Warsh cell.

MUKHTASAR_BY_LANG is the authoritative QUL map (31 languages), pulled from
https://qul.tarteel.ai/api/v1/resources/tafsirs (Al-Mukhtasar / "Abridged
Explanation" / "Mokhtasar" families; ids 171-183, 776, 790-792, 905,
1271-1283). Languages with no flagship translation base of ours (as, km, ky,
si, sr, te, ar) have nowhere to attach and are simply never matched.

Derivation, for each configs/bilingual/<stem>.yaml (Hafs base) whose
translation language is in the map:
  bilingual-interactive/<stem>_mukhtasar.yaml            (Hafs,  non-beta)
  bilingual-interactive/<stem>_mukhtasar_warsh.yaml      (Warsh, beta)
  bilingual-interactive/<stem>_mukhtasar_nastaleeq.yaml  (IndoPak Nastaleeq, beta)

Bases whose Hafs `<stem>_mukhtasar.yaml` ALREADY exists (the hand-curated
en_sahih/en_khattab + tr/id/it/ru/tl/fa/vi + ms borrow) are skipped WHOLE —
this generator only fills genuinely new bases and never rewrites curated
cells or backfills their missing script twins.

Run:  python scripts/gen_mukhtasar_configs.py [--dry-run]
Idempotent: re-running creates only missing new-base cells.
"""

import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.config.schema import load_config  # noqa: E402

INDOPAK_TITLE = "القرآن الکریم"  # Farsi kaf, matching the shipped IndoPak cells
HAFS_TITLE = "القرآن الكريم"

# Authoritative QUL Al-Mukhtasar map (resources/tafsirs, 31 languages).
MUKHTASAR_BY_LANG = {
    "en": 171, "tr": 172, "fr": 173, "id": 174, "bs": 175, "it": 176,
    "vi": 177, "ru": 178, "tl": 179, "bn": 180, "fa": 181, "zh": 182,
    "ja": 183, "es": 776, "as": 790, "ml": 791, "km": 792, "ar": 905,
    "az": 1271, "ff": 1272, "hi": 1273, "ku": 1274, "ky": 1275, "ps": 1276,
    "si": 1277, "sr": 1278, "ta": 1279, "te": 1280, "th": 1281, "ug": 1282,
    "uz": 1283,
}


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


def _tafsir_block(resource_id: int, language: str) -> str:
    return "\n".join([
        "tafsir:",
        f"  resource_id: {resource_id}",
        '  source: "qul_tafsir"',
        '  name: "Al-Mukhtasar"',
        '  abbreviation: "mukhtasar"',
        f"  language: {_quote(language)}",
    ])


# (script, quran_source, font, title, status, header) per variant.
HAFS = ("qpc_uthmani_hafs", "quran_api", "kfgqpc_uthmanic_hafs", HAFS_TITLE, "stable",
        "# Bilingual + interactive: translation inline, Al-Mukhtasar in\n"
        "# ayah-marker popups (noteref endnotes — works in any EPUB3\n"
        "# popup-footnote reader). Al-Mukhtasar is the production tafsir popup\n"
        "# (owner 2026-07-24); grouped entries share one endnote.")
WARSH = ("qpc_uthmani_warsh", "kfgqpc", "kfgqpc_uthmanic_warsh", HAFS_TITLE, "beta",
         "# Warsh bilingual + interactive. BOTH content layers are Hafs-keyed\n"
         "# and remapped through the verified alignment table (translation via\n"
         "# attach_translations_via_alignment, tafsir via the book-axis group\n"
         "# mechanism). Beta per tier rule 7.")
NASTALEEQ = ("text_indopak_nastaleeq", "quran_api", "indopak_nastaleeq", INDOPAK_TITLE, "beta",
             "# IndoPak Nastaleeq bilingual + interactive (Hafs numbering — tafsir\n"
             "# keys align 1:1). Beta per tier rule 7 (script feedback-gated).")


def render(base: dict, tafsir_id: int, language: str, variant) -> str:
    script, quran_source, font, title, status, header = variant
    status_line = f'\n  status: "{status}"' if status != "stable" else ""
    return f"""{header}
book:
  title: {_quote(title)}
  language: "ar"

quran:
  script: {_quote(script)}
  source: {_quote(quran_source)}

font:
  arabic: {_quote(font)}

{_translation_block(base["translation"])}

{_tafsir_block(tafsir_id, language)}

layout:
  structure: "bilingual_interactive"
  show_ayah_numbers: true
  show_bismillah: true

output:
  directory: "output"{status_line}
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    out_dir = ROOT / "configs" / "bilingual-interactive"
    existing_vids = {load_config(p).variant_id
                     for p in sorted((ROOT / "configs").rglob("*.yaml"))}

    created, skipped_exists, skipped_vid = [], [], []

    for p in sorted((ROOT / "configs" / "bilingual").glob("*.yaml")):
        base = yaml.safe_load(p.read_text(encoding="utf-8"))
        if base.get("quran", {}).get("script") != "qpc_uthmani_hafs":
            continue  # script-variant file, not a Hafs base
        tr = base.get("translation")
        if not tr:
            continue
        lang = tr.get("language")
        tafsir_id = MUKHTASAR_BY_LANG.get(lang)
        if tafsir_id is None:
            continue  # language has no Al-Mukhtasar on QUL
        if tr.get("abbreviation") == "mukhtasar":
            continue  # base IS a Mukhtasar translation body — not a popup base
        if p.stem.endswith("_fn"):
            continue  # footnoted variant — mirror the Ibn Kathir roster (plain bases)

        # Only fill genuinely NEW bases; never touch curated cells or backfill.
        if (out_dir / f"{p.stem}_mukhtasar.yaml").exists():
            continue

        for suffix, variant in (("", HAFS), ("_warsh", WARSH),
                                ("_nastaleeq", NASTALEEQ)):
            target = out_dir / f"{p.stem}_mukhtasar{suffix}.yaml"
            if target.exists():
                skipped_exists.append(target.name)
                continue
            content = render(base, tafsir_id, lang, variant)
            if args.dry_run:
                created.append(target.name)
                continue
            target.write_text(content, encoding="utf-8")
            vid = load_config(target).variant_id
            if vid in existing_vids:
                target.unlink()
                skipped_vid.append((target.name, vid))
                continue
            existing_vids.add(vid)
            created.append(target.name)

    verb = "Would create" if args.dry_run else "Created"
    print(f"{verb} {len(created)} cell(s):")
    for n in created:
        print(f"  + {n}")
    if skipped_vid:
        print(f"\nSkipped {len(skipped_vid)} (variant_id collision):")
        for n, v in skipped_vid:
            print(f"  = {n}  ({v})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
