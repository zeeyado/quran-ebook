#!/usr/bin/env python3
"""Build an enhanced Quran StarDict dictionary.

Combines multiple data sources:
1. Quran.com API — QPC Uthmani Hafs word text (headwords) + WBW translations/transliterations
2. EQTB (Extended Quranic Treebank) — root, lemma, POS, verb form, case/mood/tense per word
3. quran-explorer KB (full-Perseus Lane layer) — per-headword Lane senses per root
   (the earlier aliozdenisik JSON was systemically truncated + mis-summarized;
   retired per docs/lane_handover_2026-07.md)

Output: StarDict dictionary files (.ifo, .idx, .dict.dz) for use in KOReader.

Usage:
    python tools/build_dictionary.py [--output-dir OUTPUT_DIR] [--cache-dir CACHE_DIR]
"""

import argparse
import csv
import gzip
import json
import os
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
EQTB_PATH = PROJECT_ROOT / "docs" / "eqtb" / "Quranic.csv"
# quran-explorer KB with the corrected full-Lane layer (lane_handover_2026-07.md)
KB_PATH = Path(os.environ.get(
    "QURAN_KB_PATH",
    str(Path.home() / "adm" / "projects" / "quran-explorer" / "kb" / "build" / "quran.sqlite"),
))


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


def fetch_indopak_chapter(client: httpx.Client, chapter: int, cache_dir: Path) -> tuple[list[dict], bool]:
    """Fetch verse-level IndoPak Nastaleeq text for a chapter.

    text_indopak_nastaleeq is the exact encoding the IndoPak EPUBs are built
    from, so synonym headwords derived from it match KOReader text selections
    byte-for-byte (word-level text_indopak differs: U+06E1 vs U+0652 sukun,
    Arabic vs Farsi yeh, bare-vs-marked Allah, trailing RLM).
    """
    cache_key = f"indopak_nast_ch{chapter}"
    cached = cache_get(cache_dir, cache_key)
    if cached:
        return cached, True

    all_verses = []
    page = 1
    while True:
        resp = client.get(
            f"{BASE_URL}/verses/by_chapter/{chapter}",
            params={
                "fields": "text_indopak_nastaleeq",
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

_ROMAN_TO_INT = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6,
                 "VII": 7, "VIII": 8, "IX": 9, "X": 10, "XI": 11, "XII": 12}


def _eqtb_val(row: dict, key: str) -> str | None:
    """Return EQTB cell value or None if empty/placeholder."""
    v = row.get(key, "")
    return v if v and v not in ("_", "ـ", "-") else None


def _normalize_lemma(lemma: str) -> str:
    """Normalize EQTB lemma from Uthmani script to standard Arabic.

    EQTB stores lemmas in Uthmani orthography with two non-standard codepoints:
    - U+0671 (alef wasla ٱ) → U+0627 (regular alef ا)
    - U+0670 (superscript alef ٰ) → U+0627 (regular alef ا) mid-word,
      or dropped after yaa maqsura (U+0649) where it's just a reading aid
    """
    # Alef wasla → regular alef
    lemma = lemma.replace("\u0671", "\u0627")
    # Superscript alef after yaa maqsura → drop
    lemma = lemma.replace("\u0649\u0670", "\u0649")
    # Remaining superscript alef → regular alef
    lemma = lemma.replace("\u0670", "\u0627")
    return lemma


def _bidi_paren(ar: str) -> str:
    """Wrap parenthesized Arabic in LRM marks to prevent BiDi reordering.

    Without anchoring, MuPDF's BiDi algorithm merges adjacent RTL runs
    and drags the parentheses into RTL reordering, flipping/misplacing them.
    """
    return f"\u200E({ar}\u200E)"


def load_morphology(path: Path) -> dict[str, dict]:
    """Load per-word morphology from EQTB (Extended Quranic Treebank).

    Extracts STEM segment data for each word. STEM carries the word's primary
    POS, root, lemma, case, mood, tense, gender, number, person, verb form,
    and derived noun form — the same fields previously parsed from mustafa0x.

    Returns dict keyed by "surah:ayah:word" -> {
        "root": str or None,
        "lemma": str or None,
        "pos": str,  # N, V, P, PN, PRON, ADJ, etc.
        "verb_form": int or None,
        "case": str or None,  # NOM, ACC, GEN
        "mood": str or None,  # IND, SUBJ, JUS
        "tense": str or None,  # PERF, IMPF, IMPV
        "voice": str or None,  # PASS (active is unmarked)
        "gender": str or None,  # M, F
        "number": str or None,  # S, D, P
        "person": str or None,  # 1, 2, 3
        "derived_form": str or None,  # ACT_PCPL, PASS_PCPL, VN
    }
    """
    if not path.exists():
        print(f"WARNING: EQTB file not found: {path}")
        return {}

    words: dict[str, dict] = {}

    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            # Only extract morphology from STEM segments
            if row.get("segment") != "STEM":
                continue
            loc = _eqtb_val(row, "location")
            if not loc:
                continue

            parts = loc.strip("()").split(":")
            if len(parts) < 3:
                continue
            word_key = f"{parts[0]}:{parts[1]}:{parts[2]}"

            # First STEM per word wins (same as grammar dictionary)
            if word_key in words:
                continue

            pos = _eqtb_val(row, "pos") or ""

            mood_raw = _eqtb_val(row, "verb_mood")
            mood = mood_raw.replace("MOOD:", "") if mood_raw else None

            vf_raw = _eqtb_val(row, "verb_form")
            verb_form = None
            if vf_raw:
                verb_form = _ROMAN_TO_INT.get(vf_raw.strip("()"))

            words[word_key] = {
                "pos": pos,
                "root": _eqtb_val(row, "root_ar"),
                "lemma": _normalize_lemma(v) if (v := _eqtb_val(row, "lemma_ar")) else None,
                "verb_form": verb_form,
                "case": _eqtb_val(row, "nominal_case"),
                "mood": mood,
                "tense": _eqtb_val(row, "verb_aspect"),
                "voice": _eqtb_val(row, "verb_voice"),
                "gender": _eqtb_val(row, "gender"),
                "number": _eqtb_val(row, "number"),
                "person": _eqtb_val(row, "person"),
                "derived_form": _eqtb_val(row, "derived_nouns"),
            }

    return words


# ---------------------------------------------------------------------------
# Lane's Lexicon
# ---------------------------------------------------------------------------

# EQTB roots write hamza as its bare carrier letter (اله, not أله), while
# Lane's keys carry the hamza — fold Lane's keys to the EQTB convention or
# 20% of root lookups miss (including اله, the root of الله).
_HAMZA_FOLD = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ؤ": "و", "ئ": "ي", "ء": "ا"})


def load_lanes(kb_path: Path = None) -> dict[str, list[dict]]:
    """Load Lane senses from the quran-explorer KB (full-Perseus layer).

    Returns {root (hamza-folded, matches EQTB): [{"headword", "gloss"}] up to
    3 senses, best first (quran_freq DESC, then Lane's article order)}.
    Quality flags respected per docs/lane_handover_2026-07.md: suspect and
    cross-reference rows excluded; 11 roots genuinely absent from Lane stay
    absent. The retired truncated-JSON layer must never be rendered again.
    """
    import sqlite3
    kb_path = kb_path or KB_PATH
    if not kb_path.exists():
        print(f"WARNING: quran-explorer KB not found: {kb_path} — Lane sections omitted")
        return {}
    con = sqlite3.connect(str(kb_path))
    rows = con.execute(
        """SELECT r.arabic, le.headword, le.definition_short
           FROM lexicon_entry le
           JOIN lane_headword lh ON lh.lexicon_entry_id = le.id
           JOIN root r ON r.id = le.root_id
           WHERE le.source = 'lane-full' AND lh.suspect = 0 AND lh.is_xref = 0
             AND le.definition_short IS NOT NULL
           ORDER BY r.arabic, lh.quran_freq DESC, lh.seq"""
    ).fetchall()
    con.close()
    lanes: dict[str, list[dict]] = {}
    for arabic, headword, gloss in rows:
        senses = lanes.setdefault(arabic.translate(_HAMZA_FOLD), [])
        if len(senses) < 3:
            senses.append({"headword": headword, "gloss": gloss})
    return lanes


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
    "ADJ": "adjective",
    "ACC": "accusative part.",
    "NEG": "negation",
    "COND": "conditional",
    "CONJ": "conjunction",
    "SUB": "subordinator",
    "RES": "resumptive",
    "INTG": "interrogative",
    "CERT": "certainty",
    "PRO": "prohibitive",
    "RET": "retraction",
    "EXP": "exceptive",
    "INC": "inceptive",
    "EXL": "detail",
    "AMD": "amendment",
    "INT": "interpretive",
    "FUT": "future",
    "ANS": "answer",
    "EXH": "exhortative",
    "SUR": "surprise",
    "AVR": "aversion",
    "INL": "initial letters",
    "SUP": "supplementary",
    "IMPN": "imperative verbal noun",
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
    "ADJ": "صفة",
    "NEG": "نفي",
    "COND": "شرط",
    "CONJ": "عطف",
    "SUB": "مصدري",
    "INTG": "استفهام",
    "IMPN": "اسم فعل أمر",
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
    11: "XI",
    12: "XII",
}

# Arabic verb patterns (wazn) indexed by form number (1-based)
VERB_FORM_WAZN = [
    "فَعَلَ", "فَعَّلَ", "فاعَلَ", "أَفْعَلَ", "تَفَعَّلَ", "تَفاعَلَ",
    "انْفَعَلَ", "افْتَعَلَ", "افْعَلَّ", "اسْتَفْعَلَ", "افْعالَّ", "افْعَوْعَلَ",
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
# IndoPak Nastaleeq word extraction (synonym headwords for IndoPak EPUBs)
# ---------------------------------------------------------------------------

# Non-letter inventory of text_indopak_nastaleeq: waqf marks (some encoded as
# PUA codepoints), PUA ayah medallions (U+F500 + n - 1) and sajdah/ruku
# ornaments, hizb/sajdah signs, stray directional controls.
_INDOPAK_MARK_CHARS = (
    "ؐ-ؚ"  # Arabic small-high signs
    "ۖ-۞"  # waqf marks + rub el hizb
    "۟-ۤ"
    "ۧ-۩"  # small high yeh/noon + sajdah sign
    "۪-ۭ"
    "-"  # PUA: medallions, PUA-encoded waqf, ornaments
    "‎‏"   # directional marks
)
# Token that is ONLY marks/glyphs = not a word (ayah-marker clusters,
# standalone mid-verse waqf signs, sajdah/ruku ornaments). Cluster tokens can
# also carry vowel signs and small letters (18:1 has U+065A, 38:32/88:17-20
# U+06E5), so this class additionally admits harakat/superscript-alef/small
# waw+yeh — a real word can never be ALL marks, so this stays safe.
_INDOPAK_NONWORD_RE = re.compile(f"^[{_INDOPAK_MARK_CHARS}\u064B-\u065F\u0670\u06E5\u06E6]+$")
# Marks attached to the end of a real word (selection may or may not include
# them, so both forms are emitted as synonyms). Deliberately does NOT admit
# harakat: stripping a word-final vowel would fabricate wrong synonyms.
_INDOPAK_TRAIL_RE = re.compile(f"[{_INDOPAK_MARK_CHARS}]+$")


# Arabic base letters — a token containing one is a real word.
_ARABIC_LETTER_RE = re.compile(r"[ء-يٮ-ٯٱ-ەۮ-ۿݐ-ݿ]")

# Whole words rendered as single PUA ligature glyphs in
# text_indopak_nastaleeq (printed red in IndoPak mushafs): U+F658 =
# walyatalattaf (18:19), U+F666 = thuluthay (73:20). The only two
# corpus-wide; other bare-PUA standalone tokens are waqf glyphs that
# _INDOPAK_NONWORD_RE correctly drops. KEEP IN SYNC with
# src/quran_ebook/data/quran_api.py (_INDOPAK_WORD_GLYPHS).
_INDOPAK_WORD_GLYPHS = frozenset({"\uF658", "\uF666"})

# Segmentation repairs, all keyed by (surah, ayah). The instance axis is
# the word-level API (= corpus) positions — glosses, transliteration and
# morphology keys all live there — so verse-text tokens are mapped onto
# it. Corpus-verified: with these tables every ayah aligns exactly
# (previously 4 verses shipped with glosses/morphology SHIFTED from the
# join point on, 3 more shifted the other way, and 6 were skipped for
# IndoPak synonyms).
#
# QPC verse text keeps two tokens where the API joins one word
# (3x "ba'da maa" + "Il Yaseen"): value = 1-based API position; the two
# QPC tokens merge (space-kept headword; halves become synonyms).
_QPC_API_JOINS = {(2, 181): 3, (8, 6): 4, (13, 37): 8, (37, 130): 3}
# QPC writes one solid token where the API splits two corpus words
# (law-maa 15:7, maa-liya 27:20, wa-maa-liya 36:22): value = first API
# position; the QPC token serves both instances (same headword, each
# with its own gloss/morphology — pressing the word shows both).
_QPC_API_SPLITS = {(15, 7): 1, (27, 20): 4, (36, 22): 1}
# IndoPak verse text vs API words: same joins as QPC plus 72:16
# (wa-an-law written apart). KEEP IN SYNC with
# src/quran_ebook/data/quran_api.py (_INDOPAK_API_JOINS).
_INDOPAK_API_JOINS = {(2, 181): 3, (8, 6): 4, (13, 37): 8,
                      (37, 130): 3, (72, 16): 1}

# KOReader word selection breaks at PUA codepoints (invisible spacer
# glyphs like U+F64B, partial-word ligature glyphs like U+F61F/F664), so
# pressing an affected word yields a letter FRAGMENT. Fragments are
# emitted as synonym headwords; Patch 3 position filtering keeps the
# results instance-accurate.
_PUA_RUN_RE = re.compile(r"[-]+")


def extract_indopak_words(text: str, surah: int = 0, ayah: int = 0) -> list[str]:
    """Word tokens from verse-level text_indopak_nastaleeq, aligned to the
    word-level API positions.

    IndoPak is the Hafs riwayah; with the whole-word-glyph rule and the
    join table the tokens align 1:1 with API words for all 6,236 ayahs
    (callers still verify counts and skip on mismatch as a safety net).
    """
    words = [w for w in text.split()
             if not _INDOPAK_NONWORD_RE.match(w) or w in _INDOPAK_WORD_GLYPHS]
    join_at = _INDOPAK_API_JOINS.get((surah, ayah))
    if join_at is not None and join_at < len(words):
        words[join_at - 1 : join_at + 1] = [
            words[join_at - 1] + " " + words[join_at]
        ]
    return words


def align_qpc_words(qpc_words: list[str], surah: int, ayah: int) -> list[str]:
    """Map QPC verse tokens onto API word positions (join/split repairs)."""
    j = _QPC_API_JOINS.get((surah, ayah))
    if j is not None and j < len(qpc_words):
        qpc_words = (qpc_words[: j - 1]
                     + [qpc_words[j - 1] + " " + qpc_words[j]]
                     + qpc_words[j + 1 :])
    s = _QPC_API_SPLITS.get((surah, ayah))
    if s is not None and s <= len(qpc_words):
        qpc_words = qpc_words[: s] + [qpc_words[s - 1]] + qpc_words[s :]
    return qpc_words


def pua_fragments(word: str) -> list[str]:
    """Letter-bearing fragments a PUA-broken selection can produce.

    Returns [] when the word has no interior/edge PUA (nothing to add).
    """
    if not _PUA_RUN_RE.search(word):
        return []
    frags = []
    for f in _PUA_RUN_RE.split(word):
        f = f.strip()
        if f and f != word and _ARABIC_LETTER_RE.search(f):
            frags.append(f)
    return frags


# ---------------------------------------------------------------------------
# Root formatting
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


# ---------------------------------------------------------------------------
# Dictionary entry building
# ---------------------------------------------------------------------------

def _format_morphology_html(morph: dict) -> list[str]:
    """Format morphology data as HTML parts (shared by aggregated and instance modes)."""
    parts = []
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
            morph_parts.append(f"{pos_en} {_bidi_paren(pos_ar)}")
        else:
            morph_parts.append(pos_en)

    # Verb: tense + voice + form + wazn
    if pos == "V":
        tense = morph.get("tense")
        if tense:
            morph_parts.append(
                f"{TENSE_LABELS_EN.get(tense, tense)} {_bidi_paren(TENSE_LABELS.get(tense, ''))}"
            )
        if morph.get("voice") == "PASS":
            morph_parts.append(f"passive {_bidi_paren('مبني للمجهول')}")
        vf = morph.get("verb_form")
        if vf:
            roman = VERB_FORM_NAMES.get(vf, str(vf))
            wazn = VERB_FORM_WAZN[vf - 1] if 1 <= vf <= len(VERB_FORM_WAZN) else ""
            if wazn:
                morph_parts.append(f"Form {roman} {_bidi_paren(wazn)}")
            else:
                morph_parts.append(f"Form {roman}")

        # Verb mood
        mood = morph.get("mood")
        if mood:
            morph_parts.append(
                f"{MOOD_LABELS_EN.get(mood, mood)} {_bidi_paren(MOOD_LABELS.get(mood, ''))}"
            )

    # Noun/adjective: case
    if pos in ("N", "PN", "DEM", "REL", "T", "LOC", "ADJ"):
        case = morph.get("case")
        if case:
            morph_parts.append(
                f"{CASE_LABELS_EN.get(case, case)} {_bidi_paren(CASE_LABELS.get(case, ''))}"
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
            morph_parts.append(f"{abbrev} {_bidi_paren(ar_str)}")
        else:
            morph_parts.append(abbrev)

    if morph_parts:
        parts.append(f'<span style="color:#444;font-size:90%">{" · ".join(morph_parts)}</span>')

    # Morphology line 2: lemma + root (with dashes)
    lem_root_parts = []
    if morph.get("lemma"):
        lem_root_parts.append(f"lemma: \u200E{morph['lemma']}")
    if morph.get("root"):
        lem_root_parts.append(f"root: \u200E{format_root(morph['root'])}")
    if lem_root_parts:
        parts.append(f'<span style="color:#444;font-size:90%">{" · ".join(lem_root_parts)}</span>')

    return parts


def _format_lane_html(lane_senses: list | None, arabic_root: str | None = None) -> str | None:
    """Format Lane senses (KB layer) as "headword — gloss" lines.

    Framed with a root label: the block describes the ROOT's sense breadth
    (decision J4 — the WBW translation covers the instance meaning), so it
    is identical for every word sharing the root, by design.
    """
    if not lane_senses:
        return None
    label = f"Lane, root \u200E{format_root(arabic_root)}\u200E:" if arabic_root else "Lane:"
    lines = [f"<i>{label}</i>"]
    for i, sense in enumerate(lane_senses):
        gloss = sense["gloss"]
        # Budget by rank: the top sense gets room, the tail stays terse.
        # (The popup is a digest — the root-explorer window shows full text.)
        limit = 220 if i == 0 else 120
        if len(gloss) > limit:
            gloss = gloss[:limit - 3].rsplit(" ", 1)[0].rstrip(" ,;:") + "..."
        # "· headword: gloss" — compact, and each sense stays self-delimiting
        # even if a text-mode renderer flows the lines together.
        lines.append(f"\u00B7 \u200E{sense['headword']}\u200E: {gloss}")
    return '<span style="color:#444;font-size:85%">' + "<br/>".join(lines) + "</span>"


def build_entry_html(
    translations: list[str],
    transliteration: str | None,
    morph: dict | None,
    lane_root: dict | None,
    locations: list[str],
    *,
    instance_ref: str | None = None,
    lemma_count: int | None = None,
    exact_count: int | None = None,
) -> str:
    """Build HTML content for a single dictionary entry.

    In instance mode, instance_ref is the S:A:W key (hidden comment for plugin
    matching) and lemma_count is the total occurrences of this lemma in the Quran.
    """
    parts = []
    ref_prefix = f"<!-- ref:{instance_ref} -->" if instance_ref else ""

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
        parts.append(ref_prefix + "; ".join(unique_trans))
        ref_prefix = ""  # consumed

    # Transliteration
    if transliteration:
        parts.append(ref_prefix + f'<span style="color:#555;font-style:italic">{transliteration}</span>')
        ref_prefix = ""

    # Morphology
    if morph:
        parts.extend(_format_morphology_html(morph))

    # Lane's root definition
    lane_html = _format_lane_html(lane_root, morph.get("root") if morph else None)
    if lane_html:
        parts.append(lane_html)

    # Footer: occurrence counts (instance mode) or locations (aggregated mode)
    if lemma_count is not None or exact_count is not None:
        lemma = morph.get("lemma", "") if morph else ""
        occ_parts = []
        if lemma and lemma_count is not None:
            occ_parts.append(f"Lemma \u200E({lemma}\u200E): {lemma_count}")
        if exact_count is not None:
            occ_parts.append(f"Exact: {exact_count}")
        if occ_parts:
            parts.append(f'<span style="color:#666;font-size:80%">Occurrences: {", ".join(occ_parts)}</span>')
    elif locations:
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

def write_stardict(entries: list[tuple[str, str]], output_dir: Path, dict_name: str,
                    bookname: str = "Quran Word-by-Word (QPC Uthmani Hafs)"):
    """Write StarDict dictionary files.

    entries: list of (headword, html_definition) tuples.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # StarDict requires .idx entries sorted by headword UTF-8 bytes
    entries.sort(key=lambda e: e[0].encode("utf-8"))

    # Build .dict content and .idx entries. Identical definitions (synonym
    # entries) share one byte range — StarDict permits overlapping offsets.
    dict_data = bytearray()
    idx_entries = []
    seen_defs: dict[bytes, tuple[int, int]] = {}

    for headword, definition in entries:
        def_bytes = definition.encode("utf-8")
        if def_bytes in seen_defs:
            offset, size = seen_defs[def_bytes]
        else:
            offset = len(dict_data)
            size = len(def_bytes)
            dict_data.extend(def_bytes)
            seen_defs[def_bytes] = (offset, size)

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
        f"bookname={bookname}\n"
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
    parser.add_argument(
        "--instance", action="store_true",
        help="Build per-instance entries (one per word occurrence) for plugin use",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    # Step 1: Load morphology from EQTB
    print(f"Loading morphology data (EQTB)...")
    print(f"  {EQTB_PATH}")
    morphology = load_morphology(EQTB_PATH)
    print(f"  {len(morphology)} word entries")

    # Step 2: Load Lane's Lexicon
    print(f"Loading Lane's Lexicon root definitions...")
    print(f"  {KB_PATH}")
    lanes = load_lanes()
    print(f"  {len(lanes)} roots with Lane senses")

    if args.instance:
        # Per-instance mode: one entry per word occurrence
        # Precompute lemma occurrence counts
        lemma_counts: dict[str, int] = defaultdict(int)
        for m in morphology.values():
            lemma = m.get("lemma")
            if lemma:
                lemma_counts[lemma] += 1
        print(f"  {len(lemma_counts)} unique lemmas")

        # Pass 1: collect per-instance data (no HTML yet — need exact counts first)
        print(f"\nBuilding per-instance dictionary...")
        print(f"  Loading QPC + WBW data from cache...")
        instances = []  # (canonical, headword, qpc_word, morph_key, translation, transliteration, morph, lane_root)
        form_counts: dict[str, int] = defaultdict(int)  # exact form occurrence count

        indopak_skipped = []
        qpc_misaligned = []
        with httpx.Client(timeout=30) as client:
            for ch in range(1, 115):
                qpc_verses, _ = fetch_qpc_chapter(client, ch, cache_dir)
                wbw_verses, _ = fetch_wbw_chapter(client, ch, cache_dir)
                indopak_verses, _ = fetch_indopak_chapter(client, ch, cache_dir)
                indopak_texts = {v["verse_key"]: v.get("text_indopak_nastaleeq", "")
                                 for v in indopak_verses}

                if len(qpc_verses) != len(wbw_verses):
                    print(f"  WARNING: Chapter {ch} verse count mismatch")
                    continue

                for qpc_v, wbw_v in zip(qpc_verses, wbw_verses):
                    verse_key = qpc_v["verse_key"]
                    qpc_text = qpc_v.get("qpc_uthmani_hafs", "")
                    if not qpc_text:
                        continue

                    surah, ayah = verse_key.split(":")
                    s_num, a_num = int(surah), int(ayah)

                    # The instance axis is the word-level API (= EQTB
                    # corpus) positions; QPC verse tokens are mapped onto
                    # it (join/split repairs — previously 7 verses shipped
                    # with glosses AND morphology shifted).
                    qpc_words = align_qpc_words(extract_qpc_words(qpc_text),
                                                s_num, a_num)
                    wbw_words = [w for w in wbw_v.get("words", [])
                                 if w.get("char_type_name") == "word"]
                    if len(qpc_words) != len(wbw_words):
                        qpc_misaligned.append(verse_key)

                    # IndoPak words align 1:1 with API positions (Hafs);
                    # skip defensively if a data update breaks alignment
                    indopak_words = extract_indopak_words(
                        indopak_texts.get(verse_key, ""), s_num, a_num)
                    if len(indopak_words) != len(wbw_words):
                        if indopak_texts.get(verse_key):
                            indopak_skipped.append(verse_key)
                        indopak_words = None

                    for i, qpc_word in enumerate(qpc_words):
                        if i >= len(wbw_words):
                            break

                        wbw = wbw_words[i]
                        translation = wbw.get("translation", {}).get("text", "")
                        transliteration = wbw.get("transliteration", {}).get("text", "")

                        headword = normalize_qpc_tanween(qpc_word)
                        canonical = strip_pause_marks(headword)

                        word_pos = i + 1
                        morph_key = f"{surah}:{ayah}:{word_pos}"
                        morph = morphology.get(morph_key)
                        lane_root = None
                        if morph and morph.get("root") and morph["root"] in lanes:
                            lane_root = lanes[morph["root"]]

                        indopak_word = indopak_words[i] if indopak_words else None
                        instances.append((canonical, headword, qpc_word, morph_key,
                                          translation, transliteration, morph, lane_root,
                                          indopak_word))
                        # Split verses duplicate one written token across two
                        # instances — count the written form once ("Exact: N"
                        # is a textual occurrence count).
                        split_pos = _QPC_API_SPLITS.get((s_num, a_num))
                        if not (split_pos is not None and word_pos == split_pos + 1):
                            form_counts[canonical] += 1

        print(f"  {len(instances)} word instances")
        if qpc_misaligned:
            print(f"  WARNING: QPC/API word-count mismatch in "
                  f"{len(qpc_misaligned)} verses (glosses+morphology shift "
                  f"there — extend the repair tables): "
                  f"{', '.join(qpc_misaligned[:8])}"
                  f"{', ...' if len(qpc_misaligned) > 8 else ''}")
        if indopak_skipped:
            print(f"  IndoPak synonyms skipped for {len(indopak_skipped)} verses "
                  f"(word segmentation differs): {', '.join(indopak_skipped[:8])}"
                  f"{', ...' if len(indopak_skipped) > 8 else ''}")

        # Pass 2: build HTML without ref, group identical (headword, content) pairs
        # to combine refs into one entry
        from collections import OrderedDict
        # Key: (canonical, html_without_ref) -> list of morph_keys
        grouped: dict[tuple[str, str], list[str]] = OrderedDict()
        # Track variant headwords per group
        group_variants: dict[tuple[str, str], set[str]] = defaultdict(set)

        for canonical, headword, qpc_word, morph_key, translation, transliteration, morph, lane_root, indopak_word in instances:
            lc = None
            if morph and morph.get("lemma"):
                lc = lemma_counts.get(morph["lemma"])
            ec = form_counts.get(canonical)

            html_body = build_entry_html(
                translations=[translation] if translation else [],
                transliteration=transliteration,
                morph=morph,
                lane_root=lane_root,
                locations=[],
                lemma_count=lc,
                exact_count=ec,
            )

            key = (canonical, html_body)
            if key not in grouped:
                grouped[key] = []
            grouped[key].append(morph_key)

            # Track synonym headwords for this group
            if headword != canonical:
                group_variants[key].add(headword)
            if qpc_word != headword:
                group_variants[key].add(qpc_word)
                qpc_canonical = strip_pause_marks(qpc_word)
                if qpc_canonical not in (qpc_word, canonical, headword):
                    group_variants[key].add(qpc_canonical)
            # Joined instances ("ba'da maa"): selection yields ONE half —
            # key each half (raw + normalized) to the joined entry
            if " " in qpc_word:
                for half in qpc_word.split():
                    for syn in (half, normalize_qpc_tanween(half),
                                strip_pause_marks(normalize_qpc_tanween(half))):
                        if syn and syn not in (canonical, headword, qpc_word):
                            group_variants[key].add(syn)
            # IndoPak Nastaleeq forms: as-rendered and with attached trailing
            # marks stripped (KOReader selection may include either)
            if indopak_word:
                for syn in (indopak_word, _INDOPAK_TRAIL_RE.sub("", indopak_word)):
                    if syn and syn not in (canonical, headword, qpc_word):
                        group_variants[key].add(syn)
                # PUA-broken selection fragments (invisible spacers,
                # partial-word ligature glyphs) + space-joined halves
                pieces = pua_fragments(indopak_word)
                if " " in indopak_word:
                    pieces.extend(indopak_word.split())
                for frag in pieces:
                    for syn in (frag, _INDOPAK_TRAIL_RE.sub("", frag)):
                        if syn and syn not in (canonical, headword, qpc_word):
                            group_variants[key].add(syn)

        # Pass 3: build final entries with combined refs
        entries = []
        for (canonical, html_body), refs in grouped.items():
            ref_comment = f"<!-- ref:{','.join(refs)} -->"
            html = ref_comment + html_body
            entries.append((canonical, html))
            for variant in sorted(group_variants.get((canonical, html_body), set())):
                entries.append((variant, html))

        print(f"  {len(grouped)} unique entries (from {len(instances)} instances)")
        print(f"  {len(entries)} total entries (including synonyms)")

        print(f"\nWriting StarDict ({len(entries)} entries)...")
        write_stardict(entries, output_dir, args.dict_name,
                       bookname="Quran Word-by-Word (QPC Uthmani Hafs)")
        print("\nDone!")
        print(f"Output: {output_dir}/{args.dict_name}.*")
        return

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

                s_num, a_num = (int(x) for x in verse_key.split(":"))
                qpc_words = align_qpc_words(extract_qpc_words(qpc_text),
                                            s_num, a_num)
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

                    # Split verses duplicate the solid QPC token across two
                    # API positions — record the written word's location once
                    # (its second gloss still gets appended).
                    split_pos = _QPC_API_SPLITS.get((s_num, a_num))
                    is_split_dup = split_pos is not None and i + 1 == split_pos + 1

                    entry = word_db[headword]
                    if qpc_word != headword:
                        entry["qpc_originals"].add(qpc_word)
                    if translation:
                        entry["translations"].append(translation)
                    if transliteration and not entry["transliteration"]:
                        entry["transliteration"] = transliteration
                    if not is_split_dup:
                        entry["locations"].append(verse_key)

                    # Joined instances ("ba'da maa", "Il Yaseen"): a tap can
                    # only ever select ONE half — record the occurrence under
                    # each half's own headword too, so both stay findable.
                    if " " in qpc_word:
                        for half in qpc_word.split():
                            half_hw = normalize_qpc_tanween(half)
                            half_entry = word_db[half_hw]
                            if half != half_hw:
                                half_entry["qpc_originals"].add(half)
                            if translation:
                                half_entry["translations"].append(translation)
                            half_entry["locations"].append(verse_key)

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
