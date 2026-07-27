#!/usr/bin/env python
"""Build translation content for the quran_text data-package family.

Two modes:

1. Monolithic append (the original, interim path until text-v2): add
   config-listed translations to a copy of text-v1.sqlite, reusing the
   EPUB pipeline's translation loaders (offline once the EPUBs built).

       python tools/build_text_translations.py \
           configs/bilingual/en_khattab.yaml configs/bilingual/en_haleem.yaml \
           --db data/text-v1.sqlite --out output/text_data/text-v1.sqlite

2. Per-translation packages (ND-28, decided 2026-07-27): one sqlite per
   QUL translation edition (the FULL catalog, ~200 editions in ~85
   languages), each a self-contained roster entry the plugin merges at
   runtime. Fetches ride ONE by_range call per edition (the endpoint
   spans chapters: from=1:1&to=114:6 returns all 6236 verses), cached
   per edition in .cache/ so re-runs are offline.

       python tools/build_text_translations.py --packages
       python tools/build_text_translations.py --packages --only 20,919
       python tools/build_text_translations.py --packages --lang urdu

   Output: output/text_data/translations/text_<slug>-v1.sqlite per
   edition + index.json (the registry package_release.py `translations`
   consumes at release time: trans_id/lang/bookname/rows per package).

Package schema matches text-v1 (schema_version 1, the plugin's gate):
translation / trans_meta / trans_fts / meta. trans_id convention:
KNOWN_TRANS_IDS maps QUL ids onto the ids already shipped in the
monolithic db (en-sahih, en-haleem, ...) so an installed package dedups
against text-v1 and existing enable/disable + order settings carry over;
everything else gets "<lang-code>-qul<id>".
"""

from __future__ import annotations

import argparse
import datetime
import html
import json
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from quran_ebook.data.cache import cache_get, cache_set  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
QUL_BASE = "https://qul.tarteel.ai/api/v1"
SCHEMA_VERSION = 1
NORM_VERSION = 1
# effectively no TTL: the cache is a pin, refresh by deleting the key
CACHE_TTL_DAYS = 36500
# below this row count the edition is visibly incomplete (full = 6236;
# a handful of QUL editions sit at 6030-6235, still practically whole)
PARTIAL_THRESHOLD = 6000

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


# --- norm() contract v1 — byte-for-byte the quran_text_extract.py /
# quran_norm.lua norm (norm_version 1); trans_fts must tokenize the SAME
# normalization the plugin applies to queries ---

_FOLD = {0x0622: "ا", 0x0623: "ا", 0x0625: "ا",
         0x0671: "ا", 0x0624: "و", 0x0626: "ي",
         0x0649: "ي", 0x0629: "ه"}

_SPACE_CP = {0x00A0, 0x00AB, 0x00BB, 0x060C, 0x061B, 0x061F, 0x066D,
             0x06DE, 0x06E9}


def _is_space_cp(cp: int) -> bool:
    return (0x21 <= cp <= 0x2F or 0x3A <= cp <= 0x40 or 0x5B <= cp <= 0x60
            or 0x7B <= cp <= 0x7E or cp in _SPACE_CP
            or 0x2000 <= cp <= 0x2027)


def _is_removed_cp(cp: int) -> bool:
    return (cp in (0x0621, 0x0640, 0xFEFF) or 0x0610 <= cp <= 0x061A
            or 0x064B <= cp <= 0x065F or cp == 0x0670
            or 0x06D6 <= cp <= 0x06ED or 0x08D3 <= cp <= 0x08FF
            or 0xFE00 <= cp <= 0xFE0F or 0x200B <= cp <= 0x200F)


def _is_digit_cp(cp: int) -> bool:
    return (0x30 <= cp <= 0x39 or 0x0660 <= cp <= 0x0669
            or 0x06F0 <= cp <= 0x06F9)


def norm(s: str) -> str:
    out = []
    for ch in s:
        cp = ord(ch)
        if cp in _FOLD:
            out.append(_FOLD[cp])
        elif _is_space_cp(cp):
            out.append(" ")
        elif _is_removed_cp(cp):
            pass
        elif _is_digit_cp(cp):
            out.append(" ")
        elif 0x41 <= cp <= 0x5A:
            out.append(chr(cp + 0x20))
        else:
            out.append(ch)
    return re.sub(r"[ \t\n\r\f\v]+", " ", "".join(out)).strip(" \t\n\r\f\v")


# --- ND-28 package mode ---

# QUL ids that ARE editions already shipped in the monolithic text-v1
# (same translation, whatever pipeline originally loaded it). Their
# packages reuse the shipped trans_id so the plugin's runtime merge
# dedups them and the user's translations_off/_order settings keep
# applying. en-mukhtasar is a TAFSIR (QUL tafsir 171), not in this
# catalog — it stays monolithic-only.
KNOWN_TRANS_IDS = {
    20: "en-sahih",
    85: "en-haleem",
    95: "en-maududi",
    131: "en-khattab",       # fawazahmed0-sourced in configs; same edition
    203: "en-hilali-khan",
    919: "en-asad",
}

# Catalog language name -> ISO 639 code (for trans_id prefixes and
# trans_meta.lang; GROUPING in the plugin uses the display name).
LANG_CODES = {
    "afar": "aa", "albanian": "sq", "amazigh": "ber", "amharic": "am",
    "asante": "tw", "dagbani": "dag",
    "assamese": "as", "azeri": "az", "bambara": "bm", "belarusian": "be",
    "bengali": "bn", "bisayan": "ceb", "bosnian": "bs", "bulgarian": "bg",
    "central khmer": "km", "chechen": "ce",
    "chichewa, chewa, nyanja": "ny", "chinese": "zh",
    "circassian(adyghe)": "ady", "circassian": "ady", "croatian": "hr",
    "czech": "cs", "dari": "prs", "divehi": "dv",
    "divehi, dhivehi, maldivian": "dv", "dutch": "nl", "english": "en",
    "filipino": "fil", "finnish": "fi", "french": "fr", "fulah": "ff",
    "ganda": "lg", "georgian": "ka", "german": "de", "greek": "el",
    "gujarati": "gu", "hausa": "ha", "hebrew": "he", "hindi": "hi",
    "indonesian": "id", "iranun": "ill", "italian": "it", "japanese": "ja",
    "kannada": "kn", "kashmiri": "ks", "kazakh": "kk", "khmer": "km",
    "kinyarwanda": "rw", "kirundi": "rn", "korean": "ko", "kurdish": "ku",
    "kyrgyz": "ky", "lingala": "ln", "lithuanian": "lt", "luhya": "luy",
    "macedonian": "mk", "maguindanao": "mdh", "malagasy": "mg",
    "malay": "ms", "malayalam": "ml", "maltese": "mt", "maranao": "mrw",
    "marathi": "mr", "moore": "mos", "nepali": "ne", "norwegian": "no",
    "oromo": "om", "pashto": "ps", "persian": "fa", "polish": "pl",
    "portuguese": "pt", "punjabi": "pa", "romanian": "ro", "russian": "ru",
    "serbian": "sr", "shona": "sn", "sindhi": "sd",
    "sinhala, sinhalese": "si", "somali": "so", "spanish": "es",
    "swahili": "sw", "swedish": "sv", "tagalog": "tl", "tajik": "tg",
    "tamil": "ta", "tatar": "tt", "telugu": "te", "thai": "th",
    "turkish": "tr", "turkmen": "tk", "uighur, uyghur": "ug",
    "ukrainian": "uk", "urdu": "ur", "uzbek": "uz", "vietnamese": "vi",
    "yau,yuw": "yuw", "yoruba": "yo", "zulu": "zu",
}

# Display name for grouping: first alias, title-cased, hand-fixed where
# title-casing mangles it.
LANG_DISPLAY = {
    "chichewa, chewa, nyanja": "Chichewa",
    "circassian(adyghe)": "Circassian",
    "divehi, dhivehi, maldivian": "Divehi",
    "sinhala, sinhalese": "Sinhala",
    "uighur, uyghur": "Uyghur",
    "central khmer": "Khmer",
    "yau,yuw": "Yau",
}

# Editions whose catalog row AND fetched verses carry no language —
# curated 2026-07-27 from the edition names, with the three
# name-ambiguous ones identified from their sampled 1:1 text (854
# "Yallih" = Afar, 944 Kannada script, 1270 "Naawuni" = Dagbani).
# Re-check when the catalog grows.
LANG_OVERRIDES = {
    853: "chinese", 854: "afar", 855: "lingala", 857: "punjabi",
    858: "kyrgyz", 868: "uzbek", 942: "dutch", 943: "pashto",
    944: "kannada", 945: "kirundi", 1173: "moore", 1254: "russian",
    1255: "croatian", 1256: "bisayan", 1257: "iranun",
    1258: "maguindanao", 1259: "chinese", 1260: "korean",
    1261: "khmer", 1263: "kurdish", 1264: "kurdish", 1266: "kannada",
    1267: "malagasy", 1268: "luhya", 1269: "amharic", 1270: "dagbani",
}


def _api_client():
    import httpx
    return httpx.Client(timeout=60, follow_redirects=True)


def fetch_catalog(client) -> list[dict]:
    key = "qul_trans_catalog_v1"
    cached = cache_get(key, ttl_days=CACHE_TTL_DAYS)
    if cached:
        return cached["translations"]
    resp = client.get(f"{QUL_BASE}/resources/translations")
    resp.raise_for_status()
    data = resp.json()
    cache_set(key, data)
    return data["translations"]


def fetch_edition(client, qul_id: int) -> list:
    """All verses of one edition: [[surah, ayah, raw_text], ...].

    ONE by_range call spanning the whole Quran (verified 2026-07-27: the
    endpoint crosses chapter boundaries; 6236 items, ~2.5 MB). Cached
    raw so clean()/norm() changes only rebuild, never re-fetch.
    """
    key = f"qul_trans_full_{qul_id}"
    cached = cache_get(key, ttl_days=CACHE_TTL_DAYS)
    if cached:
        return cached["rows"]
    resp = client.get(
        f"{QUL_BASE}/translations/{qul_id}/by_range",
        params={"from": "1:1", "to": "114:6"})
    resp.raise_for_status()
    rows = []
    for item in resp.json().get("translations") or []:
        vk = (item.get("verse_key") or "").split(":")
        text = item.get("text") or ""
        if len(vk) == 2 and text.strip():
            try:
                s, a = int(vk[0]), int(vk[1])
            except ValueError:
                continue
            if 1 <= s <= 114 and a >= 1:
                rows.append([s, a, text])
    cache_set(key, {"rows": rows})
    time.sleep(0.5)  # be gentle on uncached sweeps (~200 calls)
    return rows


def resolve_lang(entry: dict) -> tuple[str, str]:
    """(display_name, iso_code) for a catalog entry.

    Chain: catalog `language` -> LANG_OVERRIDES (the blank-language
    editions; per-verse language_name is ALSO blank for those, verified
    2026-07-27) -> ("Other", "und") flagged in the build report.
    """
    name = (entry.get("language") or "").strip().lower()
    if not name:
        name = LANG_OVERRIDES.get(int(entry["id"]), "")
    if not name:
        return "Other", "und"
    display = LANG_DISPLAY.get(name) or name.split(",")[0].strip().title()
    return display, LANG_CODES.get(name, re.sub(r"[^a-z]+", "", name)[:8])


def slug_for(trans_id: str) -> str:
    return re.sub(r"[^0-9A-Za-z]+", "_", trans_id).strip("_").lower()


def build_package(out_dir: Path, entry: dict, rows: list) -> dict | None:
    qul_id = int(entry["id"])
    lang_name, lang = resolve_lang(entry)
    trans_id = KNOWN_TRANS_IDS.get(qul_id) or f"{lang}-qul{qul_id}"
    name = (entry.get("name") or f"QUL translation {qul_id}").strip()

    cleaned = []
    for s, a, raw in rows:
        text = clean(raw)
        if text:
            cleaned.append((trans_id, s, a, text))
    if not cleaned:
        print(f"  SKIP {qul_id} {name}: no usable rows")
        return None
    display = name + (" (partial)" if len(cleaned) < PARTIAL_THRESHOLD else "")

    pkg_name = f"text_{slug_for(trans_id)}"
    db_path = out_dir / f"{pkg_name}-v{SCHEMA_VERSION}.sqlite"
    db_path.unlink(missing_ok=True)
    conn = sqlite3.connect(db_path)
    conn.executescript("""
        CREATE TABLE translation (
          trans_id TEXT NOT NULL, surah INTEGER NOT NULL, ayah INTEGER NOT NULL,
          text TEXT NOT NULL, PRIMARY KEY (trans_id, surah, ayah));
        CREATE TABLE trans_meta (
          trans_id TEXT PRIMARY KEY, name TEXT NOT NULL, lang TEXT NOT NULL,
          source TEXT NOT NULL);
        CREATE VIRTUAL TABLE trans_fts USING fts5(
          text_norm, trans_id UNINDEXED, surah UNINDEXED, ayah UNINDEXED,
          tokenize="unicode61 remove_diacritics 2");
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    conn.executemany(
        "INSERT INTO translation (trans_id, surah, ayah, text)"
        " VALUES (?, ?, ?, ?)", cleaned)
    conn.executemany(
        "INSERT INTO trans_fts (text_norm, trans_id, surah, ayah)"
        " VALUES (?, ?, ?, ?)",
        [(norm(t), tid, s, a) for tid, s, a, t in cleaned])
    source = f"QUL translation {qul_id} (qul.tarteel.ai)"
    conn.execute(
        "INSERT INTO trans_meta (trans_id, name, lang, source)"
        " VALUES (?, ?, ?, ?)", (trans_id, display, lang, source))
    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "norm_version": str(NORM_VERSION),
        "extract": "quran_text_translation",
        "created": datetime.date.today().isoformat(),
        "source": source,
        "trans_id": trans_id,
        "qul_id": str(qul_id),
        "lang": lang,
        "lang_name": lang_name,
        "name": display,
        "rows_translation": str(len(cleaned)),
        "translations": trans_id,
    }
    conn.executemany("INSERT INTO meta (key, value) VALUES (?, ?)",
                     sorted(meta.items()))
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    size_kb = db_path.stat().st_size / 1024
    print(f"  BUILT {pkg_name} · {trans_id} · {lang_name}"
          f" · {len(cleaned)} rows · {size_kb:.0f} KB")
    return registry_entry(db_path)


def registry_entry(db_path: Path) -> dict:
    """Registry row from a built package's own meta (self-describing, so
    the index regenerates from whatever is on disk)."""
    conn = sqlite3.connect(db_path)
    meta = dict(conn.execute("SELECT key, value FROM meta"))
    conn.close()
    return {
        "name": db_path.name.rsplit("-v", 1)[0],
        "filename": db_path.name,
        "trans_id": meta.get("trans_id", ""),
        "qul_id": int(meta.get("qul_id", 0)),
        "lang": meta.get("lang", ""),
        "lang_name": meta.get("lang_name", ""),
        "bookname": meta.get("name", ""),
        "rows": int(meta.get("rows_translation", 0)),
    }


def write_index(out_dir: Path) -> list[dict]:
    entries = sorted(
        (registry_entry(p) for p in sorted(out_dir.glob("text_*-v*.sqlite"))),
        key=lambda e: (e["lang_name"], e["bookname"]))
    (out_dir / "index.json").write_text(
        json.dumps(entries, ensure_ascii=False, indent=1) + "\n", "utf-8")
    return entries


def run_packages(args) -> int:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    client = _api_client()
    catalog = fetch_catalog(client)
    only = ({int(x) for x in args.only.split(",")} if args.only else None)
    built = skipped = 0
    failures = []
    for entry in sorted(catalog, key=lambda e: int(e["id"])):
        qul_id = int(entry["id"])
        if only and qul_id not in only:
            continue
        if args.lang and (entry.get("language") or "").strip().lower() != args.lang.lower():
            continue
        trans_id = KNOWN_TRANS_IDS.get(qul_id) \
            or f"{resolve_lang(entry)[1]}-qul{qul_id}"
        db_path = out_dir / f"text_{slug_for(trans_id)}-v{SCHEMA_VERSION}.sqlite"
        if db_path.exists() and not args.replace:
            skipped += 1
            continue
        try:
            rows = fetch_edition(client, qul_id)
        except Exception as exc:  # noqa: BLE001 — sweep must survive one bad edition
            failures.append((qul_id, entry.get("name", "?"), str(exc)))
            print(f"  FAIL {qul_id} {entry.get('name', '?')}: {exc}")
            continue
        if build_package(out_dir, entry, rows):
            built += 1
    entries = write_index(out_dir)
    others = [e for e in entries if e["lang_name"] == "Other"]
    print(f"DONE: {built} built, {skipped} skipped (present),"
          f" {len(failures)} failed · index.json {len(entries)} entries")
    if others:
        print(f"  UNRESOLVED LANGUAGE ({len(others)}):"
              f" {[e['qul_id'] for e in others]} — extend LANG_OVERRIDES")
    for qul_id, name, err in failures:
        print(f"  FAILED {qul_id} {name}: {err}")
    return 1 if failures else 0


# --- monolithic append mode (original) ---

def run_monolithic(args) -> int:
    from quran_ebook.data.quran_api import load_quran

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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="*", help="bilingual config yamls (monolithic mode)")
    ap.add_argument("--db", default="data/text-v1.sqlite")
    ap.add_argument("--out", default="output/text_data/text-v1.sqlite")
    ap.add_argument("--replace", action="store_true",
                    help="rebuild translations/packages that already exist")
    ap.add_argument("--packages", action="store_true",
                    help="ND-28: build one sqlite per QUL edition")
    ap.add_argument("--out-dir", default="output/text_data/translations",
                    help="package mode output directory")
    ap.add_argument("--only", help="package mode: comma-separated QUL ids")
    ap.add_argument("--lang", help="package mode: one catalog language name")
    args = ap.parse_args()

    if args.packages:
        return run_packages(args)
    if not args.configs:
        ap.error("either config yamls or --packages required")
    return run_monolithic(args)


if __name__ == "__main__":
    raise SystemExit(main())
