#!/usr/bin/env python3
"""Build an enhanced Quran StarDict dictionary.

Combines multiple data sources:
1. Quran.com API — QPC Uthmani Hafs word text (headwords) + WBW translations/transliterations
2. mustafa0x/quran-morphology — root, lemma, POS, verb form per word segment
3. aliozdenisik/quran-arabic-roots-lane-lexicon — Lane's Lexicon definitions per root

Output: StarDict dictionary files (.ifo, .idx, .dict.dz) for use in KOReader.

Usage:
    python tools/build_dictionary.py [--output-dir OUTPUT_DIR] [--cache-dir CACHE_DIR]
"""

import argparse
import gzip
import json
import re
import struct
import sys
import time
from collections import defaultdict
from pathlib import Path

import httpx

BASE_URL = "https://api.quran.com/api/v4"
CACHE_DIR = Path.home() / ".cache" / "quran-ebook" / "dictionary"
MORPHOLOGY_PATH = Path.home() / ".cache" / "quran-ebook" / "morphology" / "quran-morphology.txt"
LANES_PATH = Path.home() / ".cache" / "quran-ebook" / "lanes" / "quran_roots_lane.json"


# ---------------------------------------------------------------------------
# Caching helpers
# ---------------------------------------------------------------------------

def cache_get(cache_dir: Path, key: str):
    path = cache_dir / f"{key}.json"
    if path.exists():
        return json.loads(path.read_text("utf-8"))
    return None


def cache_set(cache_dir: Path, key: str, data):
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / f"{key}.json").write_text(json.dumps(data, ensure_ascii=False), "utf-8")


# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

def fetch_wbw_chapter(client: httpx.Client, chapter: int, cache_dir: Path) -> list[dict]:
    """Fetch word-by-word data for a chapter from Quran.com API.

    Returns list of verse dicts, each with 'verse_key' and 'words'.
    """
    cache_key = f"wbw_ch{chapter}"
    cached = cache_get(cache_dir, cache_key)
    if cached:
        return cached

    all_verses = []
    page = 1
    while True:
        resp = client.get(
            f"{BASE_URL}/verses/by_chapter/{chapter}",
            params={
                "words": "true",
                "word_fields": "text_uthmani",
                "per_page": "50",
                "page": str(page),
            },
        )
        resp.raise_for_status()
        data = resp.json()
        all_verses.extend(data["verses"])
        if data.get("pagination", {}).get("next_page") is None:
            break
        page += 1

    cache_set(cache_dir, cache_key, all_verses)
    return all_verses


def fetch_qpc_chapter(client: httpx.Client, chapter: int, cache_dir: Path) -> list[dict]:
    """Fetch QPC Uthmani Hafs verse text for a chapter.

    Returns list of verse dicts with 'verse_key' and 'qpc_uthmani_hafs'.
    """
    cache_key = f"qpc_ch{chapter}"
    cached = cache_get(cache_dir, cache_key)
    if cached:
        return cached

    all_verses = []
    page = 1
    while True:
        resp = client.get(
            f"{BASE_URL}/verses/by_chapter/{chapter}",
            params={
                "fields": "qpc_uthmani_hafs",
                "words": "false",
                "per_page": "50",
                "page": str(page),
            },
        )
        resp.raise_for_status()
        data = resp.json()
        all_verses.extend(data["verses"])
        if data.get("pagination", {}).get("next_page") is None:
            break
        page += 1

    cache_set(cache_dir, cache_key, all_verses)
    return all_verses


# ---------------------------------------------------------------------------
# Morphology parsing
# ---------------------------------------------------------------------------

def parse_morphology(path: Path) -> dict[str, dict]:
    """Parse mustafa0x/quran-morphology into per-word morphological data.

    Returns dict keyed by "surah:ayah:word" with merged segment data:
    {
        "root": str or None,
        "lemma": str or None,
        "pos": str,  # N, V, P
        "pos_detail": str,  # Full tag string
        "verb_form": int or None,
        "is_noun": bool,
        "is_verb": bool,
    }
    """
    if not path.exists():
        print(f"WARNING: Morphology file not found: {path}")
        return {}

    words: dict[str, dict] = {}

    for line in path.read_text("utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue

        loc, _arabic_segment, pos_type, tags_str = parts
        loc_parts = loc.split(":")
        if len(loc_parts) != 4:
            continue

        surah, ayah, word_pos, _segment = loc_parts
        word_key = f"{surah}:{ayah}:{word_pos}"

        # Parse tags
        tags = tags_str.split("|")
        root = None
        lemma = None
        verb_form = None
        pos_details = []

        for tag in tags:
            if tag.startswith("ROOT:"):
                root = tag[5:]
            elif tag.startswith("LEM:"):
                lemma = tag[4:]
            elif tag.startswith("VF:"):
                try:
                    verb_form = int(tag[3:])
                except ValueError:
                    pass
            else:
                pos_details.append(tag)

        # Merge into word entry (first segment with root/lemma wins)
        if word_key not in words:
            words[word_key] = {
                "root": root,
                "lemma": lemma,
                "pos": pos_type,
                "verb_form": verb_form,
                "pos_details": pos_details,
            }
        else:
            existing = words[word_key]
            if root and not existing["root"]:
                existing["root"] = root
            if lemma and not existing["lemma"]:
                existing["lemma"] = lemma
            if verb_form and not existing["verb_form"]:
                existing["verb_form"] = verb_form
            # Prefer V or N over P for overall POS
            if pos_type in ("V", "N") and existing["pos"] == "P":
                existing["pos"] = pos_type

    return words


# ---------------------------------------------------------------------------
# Lane's Lexicon
# ---------------------------------------------------------------------------

def load_lanes(path: Path) -> dict[str, dict]:
    """Load Lane's Lexicon root definitions.

    Returns dict keyed by Arabic root string.
    """
    if not path.exists():
        print(f"WARNING: Lane's Lexicon file not found: {path}")
        return {}

    data = json.loads(path.read_text("utf-8"))
    roots = {}
    for entry in data.get("roots", []):
        root = entry.get("root", "")
        if root:
            roots[root] = {
                "summary_en": entry.get("summary_en", ""),
                "definition_en": entry.get("definition_en", ""),
                "frequency": entry.get("quran_frequency", 0),
            }
    return roots


# ---------------------------------------------------------------------------
# QPC text word extraction
# ---------------------------------------------------------------------------

_AYAH_NUM_RE = re.compile(r"[\u00A0\s]*[\u0660-\u0669]+\s*$")
_RUB_ALHIZB = "\u06DE"
_SAJDAH = "\u06E9"

# Quranic pause/stop marks that appear at word boundaries
# These are waqf (pause) signs in QPC text — KOReader may or may not include
# them when selecting a word, so we normalize headwords to strip them and
# add the marked forms as synonym entries.
_PAUSE_MARKS = frozenset({
    "\u06D6",  # Small high ligature sad with lam with alef maksura
    "\u06D7",  # Small high ligature qaf with lam with alef maksura
    "\u06D8",  # Small high meem initial form
    "\u06D9",  # Small high lam alef
    "\u06DA",  # Small high jeem
    "\u06DB",  # Small high three dots
    "\u06DC",  # Small high seen
    "\u06DD",  # End of ayah
    "\u06DF",  # Small high rounded zero
    "\u06E0",  # Small high upright rectangular zero
    "\u0615",  # Small high tah
    "\u0617",  # Small high zain
})
_PAUSE_RE = re.compile("[" + "".join(_PAUSE_MARKS) + "]+$")


def strip_pause_marks(word: str) -> str:
    """Strip trailing QPC pause marks from a word."""
    return _PAUSE_RE.sub("", word)


def extract_qpc_words(qpc_text: str) -> list[str]:
    """Split QPC verse text into individual words.

    Strips trailing ayah numbers and rub al-hizb markers first.
    """
    text = _AYAH_NUM_RE.sub("", qpc_text)
    text = text.replace(_RUB_ALHIZB, "")
    # Sajdah sign stays attached to its word
    return text.split()


# ---------------------------------------------------------------------------
# POS tag to human-readable
# ---------------------------------------------------------------------------

POS_LABELS = {
    "N": "noun",
    "V": "verb",
    "P": "particle",
    "PN": "proper noun",
    "PRON": "pronoun",
    "DEM": "demonstrative",
    "REL": "relative pronoun",
    "T": "time adverb",
    "LOC": "location adverb",
    "NV": "verbal noun",
    "COND": "conditional",
    "INTG": "interrogative",
}

POS_LABELS_AR = {
    "N": "اسم",
    "V": "فعل",
    "P": "حرف",
    "PN": "علم",
    "PRON": "ضمير",
    "DEM": "اسم اشارة",
    "REL": "اسم موصول",
    "T": "ظرف زمان",
    "LOC": "ظرف مكان",
}

VERB_FORM_NAMES = {
    1: "I",
    2: "II",
    3: "III",
    4: "IV",
    5: "V",
    6: "VI",
    7: "VII",
    8: "VIII",
    9: "IX",
    10: "X",
}


# ---------------------------------------------------------------------------
# Dictionary entry building
# ---------------------------------------------------------------------------

def build_entry_html(
    translations: list[str],
    transliteration: str | None,
    morph: dict | None,
    lane_root: dict | None,
    locations: list[str],
) -> str:
    """Build HTML content for a single dictionary entry."""
    parts = []

    # Translation(s) — deduplicated
    unique_trans = []
    seen = set()
    for t in translations:
        t_clean = t.strip()
        t_lower = t_clean.lower()
        if t_lower not in seen and t_clean:
            seen.add(t_lower)
            unique_trans.append(t_clean)

    if unique_trans:
        parts.append("; ".join(unique_trans))

    # Transliteration
    if transliteration:
        parts.append(f'<span style="color:#666;font-style:italic">{transliteration}</span>')

    # Morphology line
    if morph:
        morph_parts = []
        if morph.get("pos"):
            pos_en = POS_LABELS.get(morph["pos"], morph["pos"])
            pos_ar = POS_LABELS_AR.get(morph["pos"], "")
            if pos_ar:
                morph_parts.append(f"{pos_en} ({pos_ar})")
            else:
                morph_parts.append(pos_en)
        if morph.get("verb_form"):
            morph_parts.append(f"Form {VERB_FORM_NAMES.get(morph['verb_form'], morph['verb_form'])}")
        if morph.get("lemma"):
            morph_parts.append(f"lemma: {morph['lemma']}")
        if morph.get("root"):
            morph_parts.append(f"root: {morph['root']}")
        if morph_parts:
            parts.append(f'<span style="color:#888;font-size:90%">{" · ".join(morph_parts)}</span>')

    # Lane's root definition (short summary)
    if lane_root and lane_root.get("summary_en"):
        summary = lane_root["summary_en"]
        # Truncate very long summaries
        if len(summary) > 200:
            summary = summary[:197] + "..."
        parts.append(f'<span style="color:#555;font-size:85%">Root: {summary}</span>')

    # Occurrence count and sample locations
    if locations:
        count = len(locations)
        sample = locations[:5]
        loc_str = ", ".join(sample)
        if count > 5:
            loc_str += f" … ({count} total)"
        parts.append(f'<span style="color:#999;font-size:80%">{loc_str}</span>')

    return "<br/>".join(parts)


# ---------------------------------------------------------------------------
# StarDict writer
# ---------------------------------------------------------------------------

def write_stardict(entries: list[tuple[str, str]], output_dir: Path, dict_name: str):
    """Write StarDict dictionary files.

    entries: list of (headword, html_definition) tuples, sorted by headword.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # Build .dict content and .idx entries
    dict_data = bytearray()
    idx_entries = []

    for headword, definition in entries:
        def_bytes = definition.encode("utf-8")
        offset = len(dict_data)
        size = len(def_bytes)
        dict_data.extend(def_bytes)

        hw_bytes = headword.encode("utf-8")
        # idx entry: headword\0 + offset(4 bytes big-endian) + size(4 bytes big-endian)
        idx_entry = hw_bytes + b"\x00" + struct.pack(">II", offset, size)
        idx_entries.append(idx_entry)

    # Write .dict (uncompressed — KOReader requires dictzip for .dict.dz,
    # which needs random-access headers that Python's gzip doesn't produce)
    dict_path = output_dir / f"{dict_name}.dict"
    with open(dict_path, "wb") as f:
        f.write(bytes(dict_data))

    # Write .idx
    idx_path = output_dir / f"{dict_name}.idx"
    with open(idx_path, "wb") as f:
        for entry in idx_entries:
            f.write(entry)

    # Write .ifo
    idx_size = sum(len(e) for e in idx_entries)
    ifo_path = output_dir / f"{dict_name}.ifo"
    ifo_content = (
        "StarDict's dict ifo file\n"
        "version=2.4.2\n"
        f"wordcount={len(entries)}\n"
        f"idxfilesize={idx_size}\n"
        f"bookname=Quran Dictionary (Enhanced)\n"
        f"description=Quran word-by-word dictionary with morphology, transliteration, and Lane's Lexicon root definitions. QPC Uthmani Hafs encoding.\n"
        f"author=quran-ebook project\n"
        f"sametypesequence=h\n"
    )
    ifo_path.write_text(ifo_content, "utf-8")

    # Optionally compress with dictzip if available (produces .dict.dz with
    # random-access headers that KOReader can seek into)
    import shutil
    import subprocess as sp
    if shutil.which("dictzip"):
        sp.run(["dictzip", str(dict_path)], check=True)
        print(f"  Compressed with dictzip → {dict_name}.dict.dz")

    print(f"StarDict written: {output_dir / dict_name}.*")
    print(f"  Entries: {len(entries)}")
    print(f"  Dict size: {len(dict_data):,} bytes")
    print(f"  Idx size: {idx_size:,} bytes")


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Build enhanced Quran StarDict dictionary")
    parser.add_argument(
        "--output-dir", "-o",
        default="output/dictionary",
        help="Output directory for StarDict files (default: output/dictionary)",
    )
    parser.add_argument(
        "--cache-dir",
        default=str(CACHE_DIR),
        help="Cache directory for API responses",
    )
    parser.add_argument(
        "--dict-name",
        default="quran_qpc_en",
        help="Base filename for StarDict files (default: quran_qpc_en)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    # Step 1: Load morphology
    print("Loading morphology data...")
    morphology = parse_morphology(MORPHOLOGY_PATH)
    print(f"  {len(morphology)} word entries")

    # Step 2: Load Lane's Lexicon
    print("Loading Lane's Lexicon root definitions...")
    lanes = load_lanes(LANES_PATH)
    print(f"  {len(lanes)} root entries")

    # Step 3: Fetch QPC text + WBW from API for all 114 surahs
    # Build a word database: QPC headword -> {translations, transliteration, morphology, locations}
    word_db: dict[str, dict] = defaultdict(lambda: {
        "translations": [],
        "transliteration": None,
        "morph": None,
        "root": None,
        "locations": [],
    })

    print("Fetching Quran.com API data (QPC text + word-by-word)...")
    with httpx.Client(timeout=30) as client:
        for ch in range(1, 115):
            if ch % 10 == 1 or ch == 1:
                print(f"  Chapters {ch}-{min(ch+9, 114)}...")

            # Fetch QPC verse text and WBW data
            qpc_verses = fetch_qpc_chapter(client, ch, cache_dir)
            wbw_verses = fetch_wbw_chapter(client, ch, cache_dir)

            if len(qpc_verses) != len(wbw_verses):
                print(f"  WARNING: Chapter {ch} verse count mismatch: QPC={len(qpc_verses)}, WBW={len(wbw_verses)}")
                continue

            for qpc_v, wbw_v in zip(qpc_verses, wbw_verses):
                verse_key = qpc_v["verse_key"]
                qpc_text = qpc_v.get("qpc_uthmani_hafs", "")
                if not qpc_text:
                    continue

                qpc_words = extract_qpc_words(qpc_text)
                wbw_words = [w for w in wbw_v.get("words", []) if w.get("char_type_name") == "word"]

                # Map by position
                for i, qpc_word in enumerate(qpc_words):
                    if i >= len(wbw_words):
                        break

                    wbw = wbw_words[i]
                    translation = wbw.get("translation", {}).get("text", "")
                    transliteration = wbw.get("transliteration", {}).get("text", "")

                    # Strip QPC pause marks from headword for cleaner matching
                    # (these are part of the text but shouldn't differentiate entries)
                    headword = qpc_word

                    entry = word_db[headword]
                    if translation:
                        entry["translations"].append(translation)
                    if transliteration and not entry["transliteration"]:
                        entry["transliteration"] = transliteration
                    entry["locations"].append(verse_key)

                    # Morphology lookup (1-indexed word position)
                    surah, ayah = verse_key.split(":")
                    morph_key = f"{surah}:{ayah}:{i+1}"
                    if morph_key in morphology and not entry["morph"]:
                        entry["morph"] = morphology[morph_key]
                        # Also look up Lane's root
                        root = morphology[morph_key].get("root")
                        if root and root in lanes:
                            entry["root"] = root

            # Rate limiting
            time.sleep(0.05)

    print(f"\nTotal raw unique headwords: {len(word_db)}")

    # Step 4: Normalize headwords — merge words that differ only by trailing pause marks
    print("Normalizing headwords (merging pause mark variants)...")
    canonical_db: dict[str, dict] = defaultdict(lambda: {
        "translations": [],
        "transliteration": None,
        "morph": None,
        "root": None,
        "locations": [],
        "variants": set(),  # original forms with pause marks
    })

    for headword, data in word_db.items():
        canonical = strip_pause_marks(headword)
        entry = canonical_db[canonical]
        entry["translations"].extend(data["translations"])
        if data["transliteration"] and not entry["transliteration"]:
            entry["transliteration"] = data["transliteration"]
        if data["morph"] and not entry["morph"]:
            entry["morph"] = data["morph"]
        if data["root"] and not entry["root"]:
            entry["root"] = data["root"]
        entry["locations"].extend(data["locations"])
        if headword != canonical:
            entry["variants"].add(headword)

    print(f"  Canonical headwords: {len(canonical_db)}")
    variant_count = sum(len(v["variants"]) for v in canonical_db.values())
    print(f"  Pause mark variants: {variant_count}")

    # Step 5: Build dictionary entries
    print("Building dictionary entries...")
    entries = []
    for headword, data in sorted(canonical_db.items()):
        lane_root = lanes.get(data["root"]) if data["root"] else None
        html = build_entry_html(
            translations=data["translations"],
            transliteration=data["transliteration"],
            morph=data["morph"],
            lane_root=lane_root,
            locations=data["locations"],
        )
        entries.append((headword, html))
        # Add synonym entries for pause-marked variants pointing to same definition
        for variant in sorted(data["variants"]):
            entries.append((variant, html))

    # Step 6: Write StarDict
    print(f"\nWriting StarDict ({len(entries)} entries)...")
    write_stardict(entries, output_dir, args.dict_name)

    print("\nDone!")
    print(f"Output: {output_dir}/{args.dict_name}.*")
    print("Copy the .ifo, .idx, and .dict.dz files to your KOReader dictionaries folder.")


if __name__ == "__main__":
    main()
