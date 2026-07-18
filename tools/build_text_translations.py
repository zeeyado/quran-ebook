#!/usr/bin/env python
"""Add translations to the quran_text data package (text-v1.sqlite).

Interim path until the explorer-side text-v2 extract: reuses the EPUB
pipeline's own translation loaders (load_quran + the .cache/ API cache,
so runs offline once the EPUBs have built) and INSERTs into the
N-capable translation/trans_meta tables shipped since text-v1. Schema
version stays 1 — the plugin gate passes unchanged.

Usage (conda env `clarify`):
    python tools/build_text_translations.py \
        configs/bilingual/en_khattab.yaml configs/bilingual/en_haleem.yaml \
        --db data/text-v1.sqlite --out output/text_data/text-v1.sqlite

trans_id convention: "<lang>-<abbreviation>" from the config's
translation block (matches the existing en-sahih row). Tafsir-style
entries (is_tafsir_style / qul_tafsir source) get "(tafsir)" appended
to their display name — never presented as a translation (owner
contract 2026-07-18, axes.tafsir_as_text).
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import sqlite3
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from quran_ebook.data.quran_api import load_quran  # noqa: E402

_SUP_RE = re.compile(r"<sup[^>]*>.*?</sup>", re.S)
# the loader has already turned footnote sups into EPUB noteref anchors
# whose CONTENT is the bare digit — strip anchor AND digit together
_NOTEREF_RE = re.compile(r"<a[^>]*noteref[^>]*>.*?</a>", re.S)
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
# residual footnote refs some loaders leave as bracketed digits (EPUB
# builds turn them into endnote links; the db wants prose)
_NOTE_RE = re.compile(r"\[(\d{1,3})\]")


def clean(text: str) -> str:
    # footnote markers go WITH their digit (<sup foot_note=..>1</sup> —
    # a bare tag-strip would leave "Way.1")
    text = _SUP_RE.sub("", text)
    text = _NOTEREF_RE.sub("", text)
    text = _TAG_RE.sub("", text)
    text = html.unescape(text)
    text = _NOTE_RE.sub("", text)
    return _WS_RE.sub(" ", text).strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="+", help="bilingual config yamls")
    ap.add_argument("--db", default="data/text-v1.sqlite")
    ap.add_argument("--out", default="output/text_data/text-v1.sqlite")
    ap.add_argument("--replace", action="store_true",
                    help="re-import translations that already exist")
    args = ap.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.db, out)
    conn = sqlite3.connect(out)

    for cfg_path in args.configs:
        cfg = yaml.safe_load(Path(cfg_path).read_text())
        t = cfg.get("translation") or {}
        lang = t.get("language")
        abbrev = t.get("abbreviation")
        if not (lang and abbrev):
            print(f"SKIP {cfg_path}: no translation.language/abbreviation")
            continue
        trans_id = f"{lang}-{abbrev}"
        have = conn.execute(
            "SELECT count(*) FROM translation WHERE trans_id = ?",
            (trans_id,)).fetchone()[0]
        if have and not args.replace:
            print(f"SKIP {trans_id}: {have} rows already present")
            continue
        source = t.get("source", "quran_api")
        name = t.get("name") or abbrev
        if t.get("is_tafsir_style") or source == "qul_tafsir":
            name += " (tafsir)"
        print(f"LOAD {trans_id}: {name} [{source}"
              f" id={t.get('resource_id')} ed={t.get('edition', '')}]")
        mushaf = load_quran(
            "qpc_uthmani_hafs",
            translation_id=t.get("resource_id"),
            translation_language=lang,
            translation_source=source,
            translation_edition=t.get("edition", ""),
        )
        rows = []
        for surah in mushaf.surahs:
            for ayah in surah.ayahs:
                if ayah.translation:
                    text = clean(ayah.translation)
                    if text:
                        rows.append(
                            (trans_id, surah.number, ayah.ayah_number, text))
        if len(rows) < 6000:
            print(f"  WARNING: only {len(rows)} ayahs translated")
        conn.execute("DELETE FROM translation WHERE trans_id = ?",
                     (trans_id,))
        conn.execute("DELETE FROM trans_meta WHERE trans_id = ?",
                     (trans_id,))
        conn.executemany(
            "INSERT INTO translation (trans_id, surah, ayah, text)"
            " VALUES (?, ?, ?, ?)", rows)
        conn.execute(
            "INSERT INTO trans_meta (trans_id, name, lang, source)"
            " VALUES (?, ?, ?, ?)",
            (trans_id, name, lang, source))
        sample = conn.execute(
            "SELECT text FROM translation WHERE trans_id = ?"
            " AND surah = 1 AND ayah = 6", (trans_id,)).fetchone()
        print(f"  {len(rows)} rows · 1:6 = {sample[0] if sample else '??'}")

    n = conn.execute("SELECT count(*) FROM translation").fetchone()[0]
    ids = [r[0] for r in conn.execute(
        "SELECT trans_id FROM trans_meta ORDER BY trans_id")]
    conn.execute("UPDATE meta SET value = ? WHERE key = 'rows_translation'",
                 (str(n),))
    conn.execute("UPDATE meta SET value = ? WHERE key = 'translations'",
                 (",".join(ids),))
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    print(f"DONE: {out} · {n} translation rows · {', '.join(ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
