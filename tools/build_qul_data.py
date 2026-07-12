#!/usr/bin/env python3
"""Build qul-vN.sqlite — the QUL connections data package for the plugin.

Compiles four QUL bulk resources (downloaded login-gated from
https://qul.tarteel.ai by the owner; raw files live in the quran-explorer
repo's data/qul-bulk/, provenance there) into one device-friendly SQLite
consumed by the KOReader plugin's browser (quran_qul.lua):

  theme          1,049 ranged themes (surah + ayah range + title;
                 QUL's raw file duplicates every row — deduped here)
  topic          2,512 hierarchical topics (thematic + ontology parents,
                 HTML description, wiki link, related ids)
  topic_ayah     exploded per-ayah topic index
  phrase_group   814 mutashabihat phrase groups (source span + stats)
  phrase_occ     per-ayah phrase occurrences with word spans
  similar        matching-ayah pairs (score, coverage)
  meta           schema_version + provenance + row counts

Ships as the `quran_qul` data asset (package_release.py DATA_ASSETS).
All ayah numbering is Hafs (QUL's space) — the plugin converts to book
space where needed, same as the juz machinery.

Usage:
    python tools/build_qul_data.py [--qul-data PATH] [-o output/qul_data/qul-v1.sqlite]
"""

import argparse
import datetime
import json
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_QUL = Path.home() / "adm/projects/quran-explorer/data/qul-bulk"
SCHEMA_VERSION = 1

# Display-name fixes for upstream QUL typos, applied at build time so the
# raw source stays QUL-faithful (owner 2026-07-12; topic 1882 is one of
# the three thematic tree roots, so the typo headlines the Topics screen).
TOPIC_NAME_FIXES = {
    1882: ("Doctraine", "Doctrine"),
}

SCHEMA = """
CREATE TABLE theme (
    id INTEGER PRIMARY KEY,
    theme TEXT NOT NULL,
    surah INTEGER NOT NULL,
    ayah_from INTEGER NOT NULL,
    ayah_to INTEGER NOT NULL,
    keywords TEXT
);
CREATE INDEX idx_theme_surah ON theme(surah);
CREATE TABLE topic (
    topic_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    arabic_name TEXT,
    parent_id INTEGER,
    thematic_parent_id INTEGER,
    ontology_parent_id INTEGER,
    description TEXT,
    wiki_link TEXT,
    thematic INTEGER,
    ontology INTEGER,
    related_topics TEXT
);
CREATE INDEX idx_topic_thematic_parent ON topic(thematic_parent_id);
CREATE INDEX idx_topic_ontology_parent ON topic(ontology_parent_id);
CREATE TABLE topic_ayah (
    topic_id INTEGER NOT NULL,
    surah INTEGER NOT NULL,
    ayah INTEGER NOT NULL
);
CREATE INDEX idx_topic_ayah ON topic_ayah(surah, ayah);
CREATE INDEX idx_topic_ayah_topic ON topic_ayah(topic_id);
CREATE TABLE phrase_group (
    group_id INTEGER PRIMARY KEY,
    src_surah INTEGER,
    src_ayah INTEGER,
    src_from INTEGER,
    src_to INTEGER,
    surahs INTEGER,
    ayahs INTEGER,
    count INTEGER
);
CREATE TABLE phrase_occ (
    group_id INTEGER NOT NULL,
    surah INTEGER NOT NULL,
    ayah INTEGER NOT NULL,
    w_from INTEGER,
    w_to INTEGER
);
CREATE INDEX idx_phrase_occ ON phrase_occ(surah, ayah);
CREATE INDEX idx_phrase_occ_group ON phrase_occ(group_id);
CREATE TABLE similar (
    surah INTEGER NOT NULL,
    ayah INTEGER NOT NULL,
    m_surah INTEGER NOT NULL,
    m_ayah INTEGER NOT NULL,
    score INTEGER,
    coverage INTEGER
);
CREATE INDEX idx_similar ON similar(surah, ayah);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def parse_key(key: str) -> tuple[int, int] | None:
    m = re.match(r"^(\d+):(\d+)$", key.strip())
    if not m:
        return None
    s, a = int(m.group(1)), int(m.group(2))
    if not (1 <= s <= 114 and a >= 1):
        return None
    return s, a


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--qul-data", default=str(DEFAULT_QUL))
    ap.add_argument("-o", "--out",
                    default=str(ROOT / "output" / "qul_data" / f"qul-v{SCHEMA_VERSION}.sqlite"))
    args = ap.parse_args()

    qul = Path(args.qul_data)
    themes_db = qul / "themes" / "ayah-themes.db"
    topics_db = qul / "topics" / "topics.db"
    mutash_dir = qul / "mutashabihat" / "Mutashabihat ul Quran.json"
    matching = qul / "similar-ayah" / "matching-ayah.json"
    for p in (themes_db, topics_db, mutash_dir / "phrases.json", matching):
        if not p.exists():
            sys.exit(f"ERROR: missing QUL source: {p}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    dst = sqlite3.connect(out)
    dst.executescript(SCHEMA)

    # -- themes (rowid becomes the id) --
    # QUL's file carries every row exactly twice (2,098 = 2 x 1,049) — dedup.
    src = sqlite3.connect(f"file:{themes_db}?mode=ro", uri=True)
    rows = src.execute(
        "SELECT DISTINCT theme, surah_number, ayah_from, ayah_to, keywords"
        " FROM themes ORDER BY surah_number, ayah_from").fetchall()
    src.close()
    dst.executemany(
        "INSERT INTO theme(theme, surah, ayah_from, ayah_to, keywords) VALUES (?,?,?,?,?)",
        rows)
    n_themes = len(rows)

    # -- topics + exploded ayah index --
    src = sqlite3.connect(f"file:{topics_db}?mode=ro", uri=True)
    topic_rows = src.execute(
        "SELECT topic_id, name, arabic_name, parent_id, thematic_parent_id,"
        " ontology_parent_id, description, wiki_link, thematic, ontology,"
        " ayahs, related_topics FROM topics").fetchall()
    src.close()
    n_topic_ayahs = 0
    bad_keys = 0
    n_name_fixes = 0
    for r in topic_rows:
        name = r[1]
        fix = TOPIC_NAME_FIXES.get(r[0])
        if fix and name == fix[0]:
            name = fix[1]
            n_name_fixes += 1
        dst.execute(
            "INSERT INTO topic VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (r[0], name, r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[11]))
        seen = set()
        for key in (r[10] or "").split(","):
            sa = parse_key(key)
            if sa is None:
                if key.strip():
                    bad_keys += 1
                continue
            if sa in seen:
                continue
            seen.add(sa)
            dst.execute("INSERT INTO topic_ayah VALUES (?,?,?)", (r[0], sa[0], sa[1]))
            n_topic_ayahs += 1

    # -- mutashabihat --
    phrases = json.loads((mutash_dir / "phrases.json").read_text("utf-8"))
    n_occ = 0
    for gid_str, g in phrases.items():
        gid = int(gid_str)
        src_sa = parse_key(g.get("source", {}).get("key", "")) or (None, None)
        dst.execute(
            "INSERT INTO phrase_group VALUES (?,?,?,?,?,?,?,?)",
            (gid, src_sa[0], src_sa[1],
             g.get("source", {}).get("from"), g.get("source", {}).get("to"),
             g.get("surahs"), g.get("ayahs"), g.get("count")))
        for key, spans in (g.get("ayah") or {}).items():
            sa = parse_key(key)
            if sa is None:
                continue
            for span in spans:
                dst.execute(
                    "INSERT INTO phrase_occ VALUES (?,?,?,?,?)",
                    (gid, sa[0], sa[1], span[0] if span else None,
                     span[1] if span and len(span) > 1 else None))
                n_occ += 1

    # -- similar ayahs --
    match = json.loads(matching.read_text("utf-8"))
    n_similar = 0
    for key, entries in match.items():
        sa = parse_key(key)
        if sa is None:
            continue
        for e in entries:
            msa = parse_key(e.get("matched_ayah_key", ""))
            if msa is None:
                continue
            dst.execute(
                "INSERT INTO similar VALUES (?,?,?,?,?,?)",
                (sa[0], sa[1], msa[0], msa[1], e.get("score"), e.get("coverage")))
            n_similar += 1

    counts = {
        "themes": n_themes,
        "topics": len(topic_rows),
        "topic_ayahs": n_topic_ayahs,
        "phrase_groups": len(phrases),
        "phrase_occurrences": n_occ,
        "similar_pairs": n_similar,
    }
    # Shape assertions against the QUL provenance numbers
    assert n_themes == 1049, n_themes  # 2,098 raw = every row twice
    assert len(topic_rows) == 2512, len(topic_rows)
    assert len(phrases) == 814, len(phrases)
    assert n_similar >= 1162, n_similar

    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "extract": "qul",
        "created": datetime.date.today().isoformat(),
        "source": "QUL (Quranic Universal Library, Tarteel) — qul.tarteel.ai; "
                  "themes/topics/mutashabihat/matching-ayah bulk resources",
        **{f"rows_{k}": str(v) for k, v in counts.items()},
    }
    dst.executemany("INSERT INTO meta VALUES (?,?)", meta.items())
    dst.commit()
    dst.execute("VACUUM")
    dst.close()

    size_mb = out.stat().st_size / (1024 * 1024)
    print(f"qul data -> {out} ({size_mb:.1f} MB)")
    for k, v in counts.items():
        print(f"  {k}: {v}")
    if bad_keys:
        print(f"  note: {bad_keys} unparseable ayah keys skipped in topics")
    if n_name_fixes:
        print(f"  note: {n_name_fixes} upstream topic-name typo(s) fixed at build time")


if __name__ == "__main__":
    main()
