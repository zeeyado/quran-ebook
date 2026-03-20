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
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / ".cache" / "dictionary"
MORPHOLOGY_PATH = PROJECT_ROOT / ".cache" / "morphology" / "quran-morphology.txt"
LANES_PATH = PROJECT_ROOT / ".cache" / "lanes" / "quran_roots_lane.json"


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

def fetch_wbw_chapter(client: httpx.Client, chapter: int, cache_dir: Path) -> tuple[list[dict], bool]:
    """Fetch word-by-word data for a chapter from Quran.com API.

    Returns (list of verse dicts, from_cache).
    """
    cache_key = f"wbw_ch{chapter}"
    cached = cache_get(cache_dir, cache_key)
    if cached:
        return cached, True

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
    return all_verses, False


def fetch_qpc_chapter(client: httpx.Client, chapter: int, cache_dir: Path) -> tuple[list[dict], bool]:
    """Fetch QPC Uthmani Hafs verse text for a chapter.

    Returns (list of verse dicts, from_cache).
    """
    cache_key = f"qpc_ch{chapter}"
    cached = cache_get(cache_dir, cache_key)
    if cached:
        return cached, True

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
    return all_verses, False


# ---------------------------------------------------------------------------
# Morphology parsing
# ---------------------------------------------------------------------------

def parse_morphology(path: Path) -> dict[str, dict]:
    """Parse mustafa0x/quran-morphology into per-word morphological data.

    Returns dict keyed by "surah:ayah:word" with merged segment data:
    {
        "root": str or None,
        "lemma": str or None,
        "pos": str,  # N, V, P, PN, PRON, etc.
        "verb_form": int or None,
        "case": str or None,  # NOM, ACC, GEN
        "mood": str or None,  # IND, SUBJ, JUS
        "tense": str or None,  # PERF, IMPF, IMPV
        "gender": str or None,  # M, F
        "number": str or None,  # S, D, P
        "person": str or None,  # 1, 2, 3
        "derived_form": str or None,  # ACT_PCPL, PASS_PCPL, VN
        "pos_details": list[str],
    }
    """
    if not path.exists():
        print(f"WARNING: Morphology file not found: {path}")
        return {}

    _CASE_TAGS = {"NOM", "ACC", "GEN"}
    _MOOD_TAGS = {"IND", "SUBJ", "JUS"}
    _TENSE_TAGS = {"PERF", "IMPF", "IMPV"}
    _GENDER_TAGS = {"M", "F"}
    _NUMBER_TAGS = {"S", "D", "P"}
    _PERSON_TAGS = {"1", "2", "3"}
    _DERIVED_TAGS = {"ACT_PCPL", "PASS_PCPL", "VN"}

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
        case = None
        mood = None
        tense = None
        gender = None
        number = None
        person = None
        derived_form = None
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
            elif tag in _CASE_TAGS:
                case = tag
            elif tag in _MOOD_TAGS:
                mood = tag
            elif tag in _TENSE_TAGS:
                tense = tag
            elif tag in _GENDER_TAGS:
                gender = tag
            elif tag in _NUMBER_TAGS:
                number = tag
            elif tag in _PERSON_TAGS:
                person = tag
            elif tag in _DERIVED_TAGS:
                derived_form = tag
            else:
                pos_details.append(tag)

        # Merge segments into word entry.
        # Content segments (N, V) take priority over prefix segments (P/DET)
        # for lemma, root, and all grammatical features.
        is_content = pos_type in ("N", "V")

        if word_key not in words:
            words[word_key] = {
                "root": root,
                "lemma": lemma,
                "pos": pos_type,
                "verb_form": verb_form,
                "case": case,
                "mood": mood,
                "tense": tense,
                "gender": gender,
                "number": number,
                "person": person,
                "derived_form": derived_form,
                "pos_details": pos_details,
                "_is_content": is_content,
            }
        else:
            existing = words[word_key]
            prev_is_content = existing.get("_is_content", False)

            # Content segment (N/V) overwrites prefix (P/DET) unconditionally
            if is_content and not prev_is_content:
                existing["root"] = root or existing["root"]
                existing["lemma"] = lemma or existing["lemma"]
                existing["verb_form"] = verb_form or existing["verb_form"]
                existing["case"] = case or existing["case"]
                existing["mood"] = mood or existing["mood"]
                existing["tense"] = tense or existing["tense"]
                existing["gender"] = gender or existing["gender"]
                existing["number"] = number or existing["number"]
                existing["person"] = person or existing["person"]
                existing["derived_form"] = derived_form or existing["derived_form"]
                existing["pos"] = pos_type
                existing["_is_content"] = True
            else:
                # Same priority level — fill gaps only
                if root and not existing["root"]:
                    existing["root"] = root
                if lemma and not existing["lemma"]:
                    existing["lemma"] = lemma
                if verb_form and not existing["verb_form"]:
                    existing["verb_form"] = verb_form
                if case and not existing["case"]:
                    existing["case"] = case
                if mood and not existing["mood"]:
                    existing["mood"] = mood
                if tense and not existing["tense"]:
                    existing["tense"] = tense
                if gender and not existing["gender"]:
                    existing["gender"] = gender
                if number and not existing["number"]:
                    existing["number"] = number
                if person and not existing["person"]:
                    existing["person"] = person
                if derived_form and not existing["derived_form"]:
                    existing["derived_form"] = derived_form
                # Prefer V or N over P for overall POS
                if is_content and existing["pos"] == "P":
                    existing["pos"] = pos_type

    # Clean up internal tracking field
    for w in words.values():
        w.pop("_is_content", None)

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

# QPC repurposes three Unicode codepoints for tanween variants — the QPC font
# has custom glyphs, but standard Arabic fonts (including KOReader's dictionary
# popup) render the literal Unicode-standard glyph instead (inverted damma,
# percent-like mark, subscript alef).  Map to standard tanween codepoints.
_QPC_TANWEEN_MAP = str.maketrans({
    "\u0657": "\u064B",  # ARABIC INVERTED DAMMA  → FATHATAN
    "\u065E": "\u064C",  # ARABIC FATHA WITH TWO DOTS → DAMMATAN
    "\u0656": "\u064D",  # ARABIC SUBSCRIPT ALEF  → KASRATAN
})


def normalize_qpc_tanween(text: str) -> str:
    """Map QPC-repurposed tanween codepoints to standard Arabic equivalents."""
    return text.translate(_QPC_TANWEEN_MAP)


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

# Arabic verb patterns (wazn) indexed by form number (1-based)
VERB_FORM_WAZN = [
    "فَعَلَ", "فَعَّلَ", "فاعَلَ", "أَفْعَلَ", "تَفَعَّلَ", "تَفاعَلَ",
    "انْفَعَلَ", "افْتَعَلَ", "افْعَلَّ", "اسْتَفْعَلَ", "افْعالَّ",
]

CASE_LABELS = {"NOM": "مرفوع", "ACC": "منصوب", "GEN": "مجرور"}
CASE_LABELS_EN = {"NOM": "nom.", "ACC": "acc.", "GEN": "gen."}
MOOD_LABELS = {"IND": "مرفوع", "SUBJ": "منصوب", "JUS": "مجزوم"}
MOOD_LABELS_EN = {"IND": "indic.", "SUBJ": "subj.", "JUS": "juss."}
TENSE_LABELS = {"PERF": "ماض", "IMPF": "مضارع", "IMPV": "أمر"}
TENSE_LABELS_EN = {"PERF": "past", "IMPF": "present", "IMPV": "imperative"}
GENDER_LABELS = {"M": "مذكر", "F": "مؤنث"}
GENDER_LABELS_EN = {"M": "m.", "F": "f."}
NUMBER_LABELS = {"S": "مفرد", "D": "مثنى", "P": "جمع"}
NUMBER_LABELS_EN = {"S": "s.", "D": "d.", "P": "p."}
PERSON_LABELS_EN = {"1": "1", "2": "2", "3": "3"}
DERIVED_LABELS = {"ACT_PCPL": "اسم فاعل", "PASS_PCPL": "اسم مفعول", "VN": "مصدر"}
DERIVED_LABELS_EN = {"ACT_PCPL": "act.pcpl.", "PASS_PCPL": "pass.pcpl.", "VN": "verbal n."}


# ---------------------------------------------------------------------------
# Root formatting & Lane's summary cleanup
# ---------------------------------------------------------------------------

def format_root(root: str) -> str:
    """Format a root string with dashes between letters.

    Morphology stores roots as connected letters (e.g. 'ترب').
    Display convention separates them: 'ت-ر-ب'.
    """
    if not root:
        return root
    # Already has dashes (Lane's format)
    if "-" in root:
        return root
    # Insert dashes between each character
    return "-".join(root)


# Regex to replace the root notation in Lane's summaries with our dashed Arabic root.
# Lane's summaries use 8+ formats for the root: Buckwalter ("kwn"), spaced Arabic
# (ق و ل), connected Arabic (أمن), vocalized (كَتَبَ), dashed (K-L-L), etc.
# We replace just the root notation (+ optional parenthetical romanization),
# keeping "The root" prefix and all other text intact.
#
# Captures group 1: "The root " prefix (kept)
# Matches root notation + optional parenthetical (replaced)
_LANE_ROOT_NOTATION_RE = re.compile(
    r'^(The root\s+)'           # group 1: "The root " — kept
    r'(?:'
    r'"[^"]*"|\'[^\']*\'|`[^`]*`'  # anything in quotes (double, single, backtick)
    r'|\([^)]*\)'                   # parenthesized token like (lwH)
    r'|[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\s\-]+'  # Arabic chars (possibly spaced)
    r'|[\w\-]+'                    # Latin/Buckwalter token
    r')\s*'
    r'(?:\([^)]*\)\s*)?',         # optional parenthetical (romanization)
    re.UNICODE,
)


def clean_lane_summary(summary: str, arabic_root: str | None = None) -> str:
    """Replace root notation in Lane's summary with dashed Arabic root.

    Transforms e.g. 'The root "kwn" primarily means...'
    into 'The root ك-و-ن primarily means...'
    """
    if not summary.startswith("The root") or not arabic_root:
        return summary
    dashed = format_root(arabic_root)
    cleaned = _LANE_ROOT_NOTATION_RE.sub(rf'\1{dashed} ', summary, count=1)
    return cleaned


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
        parts.append(f'<span style="color:#555;font-style:italic">{transliteration}</span>')

    # Morphology line 1: POS + grammatical features
    if morph:
        morph_parts = []
        pos = morph.get("pos")

        # POS with Arabic label
        if pos:
            pos_en = POS_LABELS.get(pos, pos)
            pos_ar = POS_LABELS_AR.get(pos, "")

            # Derived noun form (active participle, etc.) overrides generic "noun"
            derived = morph.get("derived_form")
            if derived and pos == "N":
                pos_en = DERIVED_LABELS_EN.get(derived, pos_en)
                pos_ar = DERIVED_LABELS.get(derived, pos_ar)

            if pos_ar:
                morph_parts.append(f"{pos_en} ({pos_ar})")
            else:
                morph_parts.append(pos_en)

        # Verb: tense + form + wazn
        if pos == "V":
            tense = morph.get("tense")
            if tense:
                morph_parts.append(
                    f"{TENSE_LABELS_EN.get(tense, tense)} ({TENSE_LABELS.get(tense, '')})"
                )
            vf = morph.get("verb_form")
            if vf:
                roman = VERB_FORM_NAMES.get(vf, str(vf))
                wazn = VERB_FORM_WAZN[vf - 1] if 1 <= vf <= len(VERB_FORM_WAZN) else ""
                if wazn:
                    morph_parts.append(f"Form {roman} ({wazn})")
                else:
                    morph_parts.append(f"Form {roman}")

            # Verb mood
            mood = morph.get("mood")
            if mood:
                morph_parts.append(
                    f"{MOOD_LABELS_EN.get(mood, mood)} ({MOOD_LABELS.get(mood, '')})"
                )

        # Noun/adjective: case
        if pos in ("N", "PN", "DEM", "REL", "T", "LOC"):
            case = morph.get("case")
            if case:
                morph_parts.append(
                    f"{CASE_LABELS_EN.get(case, case)} ({CASE_LABELS.get(case, '')})"
                )

        # Gender + number + person (compact)
        gn_parts = []
        person = morph.get("person")
        gender = morph.get("gender")
        number = morph.get("number")
        if person:
            gn_parts.append(PERSON_LABELS_EN[person])
        if gender:
            gn_parts.append(GENDER_LABELS_EN.get(gender, gender))
        if number:
            gn_parts.append(NUMBER_LABELS_EN.get(number, number))
        if gn_parts:
            abbrev = "".join(gn_parts)
            # Arabic expansion
            ar_parts = []
            if gender:
                ar_parts.append(GENDER_LABELS.get(gender, ""))
            if number:
                ar_parts.append(NUMBER_LABELS.get(number, ""))
            ar_str = " ".join(ar_parts)
            if ar_str:
                morph_parts.append(f"{abbrev} ({ar_str})")
            else:
                morph_parts.append(abbrev)

        if morph_parts:
            parts.append(f'<span style="color:#444;font-size:90%">{" · ".join(morph_parts)}</span>')

        # Morphology line 2: lemma + root (with dashes)
        lem_root_parts = []
        if morph.get("lemma"):
            lem_root_parts.append(f"lemma: {morph['lemma']}")
        if morph.get("root"):
            lem_root_parts.append(f"root: {format_root(morph['root'])}")
        if lem_root_parts:
            parts.append(f'<span style="color:#444;font-size:90%">{" · ".join(lem_root_parts)}</span>')

    # Lane's root definition (root notation replaced with dashed Arabic)
    if lane_root and lane_root.get("summary_en"):
        arabic_root = morph.get("root") if morph else None
        summary = clean_lane_summary(lane_root["summary_en"], arabic_root)
        # Truncate very long summaries
        if len(summary) > 200:
            summary = summary[:197] + "..."
        parts.append(f'<span style="color:#444;font-size:85%">{summary}</span>')

    # Occurrence locations (always show count)
    if locations:
        count = len(locations)
        sample = locations[:5]
        loc_str = ", ".join(sample)
        if count > 5:
            loc_str += f" … ({count} total)"
        elif count > 1:
            loc_str += f" ({count})"
        else:
            loc_str += " (1 occurrence)"
        parts.append(f'<span style="color:#666;font-size:80%">{loc_str}</span>')

    return "<br/>".join(parts)


# ---------------------------------------------------------------------------
# StarDict writer
# ---------------------------------------------------------------------------

def write_stardict(entries: list[tuple[str, str]], output_dir: Path, dict_name: str):
    """Write StarDict dictionary files.

    entries: list of (headword, html_definition) tuples.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # StarDict requires .idx entries sorted by headword UTF-8 bytes
    entries.sort(key=lambda e: e[0].encode("utf-8"))

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
        f"bookname=Quran Word-by-Word (QPC Uthmani Hafs)\n"
        f"description=Quran word-by-word English dictionary with morphology, transliteration, and Lane's Lexicon root definitions. Headwords use QPC Uthmani Hafs encoding.\n"
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
        default="output/stardict",
        help="Output directory for StarDict files (default: output/stardict)",
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
    print(f"Loading morphology data...")
    print(f"  {MORPHOLOGY_PATH}")
    morphology = parse_morphology(MORPHOLOGY_PATH)
    print(f"  {len(morphology)} word entries")

    # Step 2: Load Lane's Lexicon
    print(f"Loading Lane's Lexicon root definitions...")
    print(f"  {LANES_PATH}")
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
        "qpc_originals": set(),  # original QPC forms (before tanween normalization)
    })

    print(f"Loading Quran.com API data (QPC text + word-by-word)...")
    print(f"  Cache: {cache_dir}")
    cached_count = 0
    fetched_count = 0
    with httpx.Client(timeout=30) as client:
        for ch in range(1, 115):
            # Fetch QPC verse text and WBW data
            qpc_verses, qpc_cached = fetch_qpc_chapter(client, ch, cache_dir)
            wbw_verses, wbw_cached = fetch_wbw_chapter(client, ch, cache_dir)
            cached_count += qpc_cached + wbw_cached
            fetched_count += (not qpc_cached) + (not wbw_cached)

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

                    # Normalize QPC-repurposed tanween codepoints so headwords
                    # render correctly in standard Arabic fonts (dictionary popup)
                    headword = normalize_qpc_tanween(qpc_word)

                    entry = word_db[headword]
                    if qpc_word != headword:
                        entry["qpc_originals"].add(qpc_word)
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

    if fetched_count:
        print(f"  {cached_count} cached, {fetched_count} fetched from API")
    else:
        print(f"  All {cached_count} requests served from cache")

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
        "qpc_synonyms": set(),  # original QPC forms for backward compat
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
        # Collect original QPC forms (with and without pause marks) as synonyms
        for qpc_orig in data["qpc_originals"]:
            entry["qpc_synonyms"].add(qpc_orig)
            qpc_canonical = strip_pause_marks(qpc_orig)
            if qpc_canonical != qpc_orig:
                entry["qpc_synonyms"].add(qpc_canonical)

    print(f"  Canonical headwords: {len(canonical_db)}")
    variant_count = sum(len(v["variants"]) for v in canonical_db.values())
    print(f"  Pause mark variants: {variant_count}")
    qpc_synonym_count = sum(len(v["qpc_synonyms"]) for v in canonical_db.values())
    print(f"  QPC tanween synonyms: {qpc_synonym_count}")

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
        # Add QPC original forms as synonyms for non-plugin users
        for qpc_syn in sorted(data["qpc_synonyms"]):
            entries.append((qpc_syn, html))

    # Step 6: Write StarDict
    print(f"\nWriting StarDict ({len(entries)} entries)...")
    write_stardict(entries, output_dir, args.dict_name)

    print("\nDone!")
    print(f"Output: {output_dir}/{args.dict_name}.*")
    print("Copy the .ifo, .idx, and .dict.dz files to your KOReader dictionaries folder.")


if __name__ == "__main__":
    main()
