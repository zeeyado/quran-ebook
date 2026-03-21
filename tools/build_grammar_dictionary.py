#!/usr/bin/env python3
"""Build the Quran grammar dictionary (StarDict format).

Per-ayah entries with word-by-word analysis: translation, syntactic role,
morphology (POS/case/mood/root/form), and i'rab prose from QAC.

Data sources:
  - EQTB (Extended Quranic Treebank): morphology + dependency treebank (unified)
  - Quran.com API: WBW translations + QPC Uthmani Hafs text
  - QAC irab.tsv: i'rab (grammatical analysis prose)
  - Lane's Lexicon: root meanings (reserved for future enrichment)

Keys: "Surah_Name N" (e.g. "Al-Baqarah 255") — matches quran.koplugin candidates.
Fallback key: "NNN:NNN" (e.g. "002:255").

Variants:
  combined  — WBW + morphology + syntax roles + i'rab (default)
  grammar   — WBW + morphology + syntax roles only (no i'rab)
  irab      — i'rab prose only
  all       — build all three variants

Usage:
    python tools/build_grammar_dictionary.py              # combined (default)
    python tools/build_grammar_dictionary.py --variant grammar
    python tools/build_grammar_dictionary.py --variant irab
    python tools/build_grammar_dictionary.py --variant all
"""

import argparse
import csv
import json
import re
import struct
from collections import defaultdict
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / ".cache" / "dictionary"
EQTB_PATH = PROJECT_ROOT / "docs" / "eqtb" / "Quranic.csv"
LANES_PATH = PROJECT_ROOT / ".cache" / "lanes" / "quran_roots_lane.json"
IRAB_PATH = PROJECT_ROOT / ".cache" / "qac" / "irab.tsv"
OUTPUT_BASE = PROJECT_ROOT / "output" / "grammar_dictionary"

VARIANT_CONFIG = {
    "combined": {"name": "quran_grammar", "dir": "combined", "bookname": "Quran Grammar"},
    "grammar": {"name": "quran_grammar_lite", "dir": "grammar", "bookname": "Quran Grammar (Lite)"},
    "irab": {"name": "quran_irab", "dir": "irab", "bookname": "Quran I'rab"},
}

# Surah names (name_simple from Quran.com API)
SURAH_NAMES = {
    1: "Al-Fatihah", 2: "Al-Baqarah", 3: "Ali 'Imran", 4: "An-Nisa",
    5: "Al-Ma'idah", 6: "Al-An'am", 7: "Al-A'raf", 8: "Al-Anfal",
    9: "At-Tawbah", 10: "Yunus", 11: "Hud", 12: "Yusuf", 13: "Ar-Ra'd",
    14: "Ibrahim", 15: "Al-Hijr", 16: "An-Nahl", 17: "Al-Isra",
    18: "Al-Kahf", 19: "Maryam", 20: "Taha", 21: "Al-Anbya",
    22: "Al-Hajj", 23: "Al-Mu'minun", 24: "An-Nur", 25: "Al-Furqan",
    26: "Ash-Shu'ara", 27: "An-Naml", 28: "Al-Qasas", 29: "Al-'Ankabut",
    30: "Ar-Rum", 31: "Luqman", 32: "As-Sajdah", 33: "Al-Ahzab",
    34: "Saba", 35: "Fatir", 36: "Ya-Sin", 37: "As-Saffat",
    38: "Sad", 39: "Az-Zumar", 40: "Ghafir", 41: "Fussilat",
    42: "Ash-Shuraa", 43: "Az-Zukhruf", 44: "Ad-Dukhan", 45: "Al-Jathiyah",
    46: "Al-Ahqaf", 47: "Muhammad", 48: "Al-Fath", 49: "Al-Hujurat",
    50: "Qaf", 51: "Adh-Dhariyat", 52: "At-Tur", 53: "An-Najm",
    54: "Al-Qamar", 55: "Ar-Rahman", 56: "Al-Waqi'ah", 57: "Al-Hadid",
    58: "Al-Mujadila", 59: "Al-Hashr", 60: "Al-Mumtahanah",
    61: "As-Saf", 62: "Al-Jumu'ah", 63: "Al-Munafiqun", 64: "At-Taghabun",
    65: "At-Talaq", 66: "At-Tahrim", 67: "Al-Mulk", 68: "Al-Qalam",
    69: "Al-Haqqah", 70: "Al-Ma'arij", 71: "Nuh", 72: "Al-Jinn",
    73: "Al-Muzzammil", 74: "Al-Muddaththir", 75: "Al-Qiyamah",
    76: "Al-Insan", 77: "Al-Mursalat", 78: "An-Naba", 79: "An-Nazi'at",
    80: "'Abasa", 81: "At-Takwir", 82: "Al-Infitar", 83: "Al-Mutaffifin",
    84: "Al-Inshiqaq", 85: "Al-Buruj", 86: "At-Tariq", 87: "Al-A'la",
    88: "Al-Ghashiyah", 89: "Al-Fajr", 90: "Al-Balad", 91: "Ash-Shams",
    92: "Al-Layl", 93: "Ad-Duhaa", 94: "Ash-Sharh", 95: "At-Tin",
    96: "Al-'Alaq", 97: "Al-Qadr", 98: "Al-Bayyinah", 99: "Az-Zalzalah",
    100: "Al-'Adiyat", 101: "Al-Qari'ah", 102: "At-Takathur",
    103: "Al-'Asr", 104: "Al-Humazah", 105: "Al-Fil", 106: "Quraysh",
    107: "Al-Ma'un", 108: "Al-Kawthar", 109: "Al-Kafirun",
    110: "An-Nasr", 111: "Al-Masad", 112: "Al-Ikhlas", 113: "Al-Falaq",
    114: "An-Nas",
}

# ---------------------------------------------------------------------------
# Syntactic role labels
# ---------------------------------------------------------------------------

SYNTAX_ROLE_LABELS = {
    "subj": ("subject", "فاعل"),
    "obj": ("object", "مفعول به"),
    "pred": ("predicate", "خبر"),
    "predx": ("predicate", "خبر"),
    "subjx": ("subject", "مبتدأ"),
    "gen": ("genitive", "مضاف إليه"),
    "poss": ("possessive", "مضاف إليه"),
    "adj": ("adjective", "صفة"),
    "conj": ("conjunction", "عطف"),
    "sub": ("subordinate", "تابع"),
    "link": ("linked", "متعلق"),
    "circ": ("circumstantial", "حال"),
    "cond": ("conditional", "شرط"),
    "neg": ("negation", "نفي"),
    "app": ("apposition", "بدل"),
    "voc": ("vocative", "منادى"),
    "emph": ("emphatic", "تأكيد"),
    "rslt": ("result", "جواب"),
    "pass": ("passive subj.", "نائب فاعل"),
    "cert": ("certainty", "تحقيق"),
    "pro": ("prohibition", "نهي"),
    "cog": ("cognate acc.", "مفعول مطلق"),
    "res": ("resumption", "استئناف"),
    "exp": ("exceptive", "استثناء"),
    "spec": ("specification", "تمييز"),
    "sup": ("supplementary", "زائد"),
    "fut": ("future", "استقبال"),
    "caus": ("causative", "تعليل"),
    "prev": ("preventive", "كافة"),
    "impv": ("imperative", "أمر"),
    "prp": ("purpose", "غرض"),
    "exl": ("exclamation", "تعجب"),
    "amd": ("amendment", "استدراك"),
    "inc": ("inceptive", "ابتداء"),
    "ret": ("retraction", "إضراب"),
    "avr": ("aversion", "ردع"),
    "ans": ("answer", "جواب"),
    "int": ("interpretation", "تفسير"),
    "sur": ("surprise", "فجاءة"),
    "exh": ("exhortation", "تحضيض"),
    "eq": ("equalization", "تسوية"),
    "com": ("comitative", "معية"),
    # EQTB additional labels
    "cpnd": ("compound", "مركب"),
    "state": ("specification", "بيان"),
    "imrs": ("imp. result", "جواب أمر"),
    "exl": ("detail", "تفصيل"),
    "intg": ("interrogative", "استفهام"),
}

PHRASE_TYPE_LABELS = {
    "PP": ("prep. phrase", "جار ومجرور"),
    "VS": ("verbal sent.", "جملة فعلية"),
    "NS": ("nominal sent.", "جملة اسمية"),
    "SC": ("subord. clause", "جملة تابعة"),
    "S": ("sentence", "جملة"),
    "CS": ("cond. sent.", "جملة شرطية"),
}

# Roles that describe a relation to another word (show "of word N" target)
RELATIONAL_ROLES = {
    "subj", "subjx", "obj", "pred", "predx", "gen", "poss",
    "adj", "app", "conj", "link", "circ", "sub", "cog", "spec", "com",
}

# Syntax roles that explain grammatical case (for linking case to reason)
ROLE_TO_CASE = {
    "gen": "GEN", "poss": "GEN",
    "subj": "NOM", "subjx": "NOM",
    "obj": "ACC", "cog": "ACC", "circ": "ACC", "spec": "ACC", "com": "ACC",
}


# ---------------------------------------------------------------------------
# Morphology label maps
# ---------------------------------------------------------------------------

POS_LABELS = {
    "N": "noun", "V": "verb", "P": "particle", "PN": "proper noun",
    "PRON": "pronoun", "DEM": "demonstrative", "REL": "relative pronoun",
    "T": "time adverb", "LOC": "location adverb", "ADJ": "adjective",
    "ACC": "accusative part.", "NEG": "negation", "COND": "conditional",
    "CONJ": "conjunction", "SUB": "subordinator", "RES": "resumptive",
    "INTG": "interrogative", "CERT": "certainty", "PRO": "prohibitive",
    "PREV": "preventive", "VOC": "vocative part.", "RET": "retraction",
    "EXP": "exceptive", "INC": "inceptive", "EXL": "detail",
    "AMD": "amendment", "INT": "interpretive", "FUT": "future",
    "ANS": "answer", "EXH": "exhortative", "SUR": "surprise",
    "AVR": "aversion", "INL": "initial letters", "SUP": "supplementary",
    "IMPN": "verbal noun",
}
# POS types that are particles (suppress person/gender/number display)
_PARTICLE_POS = {
    "P", "ACC", "NEG", "COND", "CONJ", "SUB", "RES", "INTG", "CERT",
    "PRO", "PREV", "VOC", "RET", "EXP", "INC", "EXL", "AMD", "INT",
    "FUT", "ANS", "EXH", "SUR", "AVR", "SUP", "INL", "IMPN",
}
CASE_LABELS_EN = {"NOM": "nom.", "ACC": "acc.", "GEN": "gen."}
MOOD_LABELS_EN = {"IND": "indic.", "SUBJ": "subj.", "JUS": "juss."}
TENSE_LABELS_EN = {"PERF": "past", "IMPF": "present", "IMPV": "imperative"}
GENDER_LABELS_EN = {"M": "m.", "F": "f."}
NUMBER_LABELS_EN = {"S": "s.", "D": "d.", "P": "p."}
PERSON_LABELS_EN = {"1": "1", "2": "2", "3": "3"}
DERIVED_LABELS_EN = {"ACT_PCPL": "act.pcpl.", "PASS_PCPL": "pass.pcpl.", "VN": "verbal n."}
VERB_FORM_WAZN = [
    "فَعَلَ", "فَعَّلَ", "فاعَلَ", "أَفْعَلَ", "تَفَعَّلَ", "تَفاعَلَ",
    "انْفَعَلَ", "افْتَعَلَ", "افْعَلَّ", "اسْتَفْعَلَ",
]
VERB_FORM_NAMES = {i: n for i, n in enumerate(
    ["I","II","III","IV","V","VI","VII","VIII","IX","X","XI","XII"], 1)}


def format_root(root: str) -> str:
    if not root or "-" in root:
        return root
    return "-".join(root)


# ---------------------------------------------------------------------------
# Data loading — EQTB (Extended Quranic Treebank)
# ---------------------------------------------------------------------------

# Roman numeral for verb form from EQTB's "(IV)" format
_ROMAN_TO_INT = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6,
                 "VII": 7, "VIII": 8, "IX": 9, "X": 10, "XI": 11, "XII": 12}

# Parse "subj <<kan>>" or "pred<<in>>" into (base_role, modifier)
_REL_MODIFIER_RE = re.compile(r"(\w+)\s*<<(.+?)>>")


def _eqtb_val(row: dict, key: str) -> str | None:
    """Return EQTB cell value or None if empty/placeholder."""
    v = row.get(key, "")
    return v if v and v not in ("_", "ـ", "-") else None


def load_eqtb(path: Path) -> tuple[dict, dict]:
    """Load EQTB data, returning morphology and syntax structures.

    Returns:
        morph_words: dict keyed by "surah:ayah:word" -> merged morphology dict
        syntax: dict keyed by "surah:ayah" -> {
            "words": {word_pos: {"roles": [...], "phrase": str|None}},
            "elided": [...],
        }
    """
    # Read all rows grouped by sentence
    sentences: dict[int, list[dict]] = defaultdict(list)
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            sid = int(row["sentence_id"])
            sentences[sid].append(row)

    morph_words: dict[str, dict] = {}
    all_word_roles: dict[str, dict[int, list[dict]]] = defaultdict(lambda: defaultdict(list))
    all_word_phrases: dict[str, dict[int, str]] = defaultdict(dict)
    all_elided: dict[str, list[dict]] = defaultdict(list)

    for sid, rows in sentences.items():
        # Build token_id -> row index for head resolution within sentence
        token_map: dict[int, dict] = {}
        for row in rows:
            token_map[int(row["token_id"])] = row

        # Determine sentence's primary ayah from first real word
        sent_ayah = None
        for row in rows:
            loc = _eqtb_val(row, "location")
            if loc:
                parts = loc.strip("()").split(":")
                sent_ayah = f"{parts[0]}:{parts[1]}"
                break
        if not sent_ayah:
            continue

        for row in rows:
            loc = _eqtb_val(row, "location")
            segment = row.get("segment", "")
            ch = int(row["chapter_id"])
            vs = int(row["verse_id"])
            word_id = int(row["word_id"])
            ayah_key = f"{ch}:{vs}"

            # --- Morphology: extract from STEM segments ---
            if loc and segment == "STEM":
                parts = loc.strip("()").split(":")
                word_key = f"{parts[0]}:{parts[1]}:{parts[2]}"

                if word_key not in morph_words:
                    pos = _eqtb_val(row, "pos") or ""
                    mood_raw = _eqtb_val(row, "verb_mood")
                    mood = mood_raw.replace("MOOD:", "") if mood_raw else None

                    vf_raw = _eqtb_val(row, "verb_form")
                    verb_form = None
                    if vf_raw:
                        roman = vf_raw.strip("()")
                        verb_form = _ROMAN_TO_INT.get(roman)

                    morph_words[word_key] = {
                        "pos": pos,
                        "root": _eqtb_val(row, "root_ar"),
                        "lemma": _eqtb_val(row, "lemma_ar"),
                        "verb_form": verb_form,
                        "case": _eqtb_val(row, "nominal_case"),
                        "mood": mood,
                        "tense": _eqtb_val(row, "verb_aspect"),
                        "voice": _eqtb_val(row, "verb_voice"),
                        "gender": _eqtb_val(row, "gender"),
                        "number": _eqtb_val(row, "number"),
                        "person": _eqtb_val(row, "person"),
                        "derived_form": _eqtb_val(row, "derived_nouns"),
                        "nominal_state": _eqtb_val(row, "nominal_state"),
                    }

            # --- Syntax: extract dependency relations ---
            rel_label = _eqtb_val(row, "rel_label")
            if not rel_label or rel_label in ("root", "NonRel"):
                # Constituency: assign phrase type to word
                cl = _eqtb_val(row, "constituent_label")
                if cl and loc and word_id > 0:
                    if word_id not in all_word_phrases[ayah_key]:
                        all_word_phrases[ayah_key][word_id] = cl
                continue

            # Parse relation label: "subj <<kan>>" -> base="subj", modifier="kan"
            base_role = rel_label.lower()
            modifier = None
            m = _REL_MODIFIER_RE.match(rel_label)
            if m:
                base_role = m.group(1).lower()
                modifier = m.group(2)
            else:
                base_role = rel_label[0].lower() + rel_label[1:]  # Subj->subj etc.

            # Get labels: prefer EQTB's Arabic label, fall back to our map
            rel_ar = _eqtb_val(row, "rel_label_ar") or ""
            role_info = SYNTAX_ROLE_LABELS.get(base_role)
            en_label = role_info[0] if role_info else base_role
            ar_label = rel_ar if rel_ar else (role_info[1] if role_info else base_role)

            # Kana/inna modifier: enrich the English label
            if modifier and base_role in ("subj", "pred"):
                en_label = f"{en_label} of {modifier}"

            # Resolve head (source) word position
            ref_id = int(row["ref_token_id"])
            source_word_pos = None
            source_phrase = None
            if ref_id in token_map:
                src_row = token_map[ref_id]
                src_loc = _eqtb_val(src_row, "location")
                if src_loc:
                    src_parts = src_loc.strip("()").split(":")
                    src_ayah = f"{src_parts[0]}:{src_parts[1]}"
                    if src_ayah == ayah_key:
                        source_word_pos = int(src_parts[2])
                src_cl = _eqtb_val(src_row, "constituent_label")
                if src_cl and src_cl in PHRASE_TYPE_LABELS:
                    source_phrase = src_cl

            role_dict = {
                "role": base_role,
                "en": en_label,
                "ar": ar_label,
                "source_word": source_word_pos,
                "source_phrase": source_phrase,
            }

            # Assign role: to an elided element or a real word
            is_elided = not loc and row.get("uthmani_token", "").startswith("(")
            if is_elided:
                node_text = row.get("uthmani_token", "").strip("()")
                if node_text == "*":
                    el_type = _eqtb_val(row, "pos") or "V"
                    el_text = None
                else:
                    el_type = "PRON"
                    el_text = node_text
                all_elided[sent_ayah].append({
                    "type": el_type,
                    "text": el_text,
                    "roles": [role_dict],
                })
            elif word_id > 0:
                existing = all_word_roles[ayah_key][word_id]
                if not any(r["role"] == base_role and r["source_word"] == source_word_pos
                           for r in existing):
                    existing.append(role_dict)

            # Constituency from this row too
            cl = _eqtb_val(row, "constituent_label")
            if cl and loc and word_id > 0:
                if word_id not in all_word_phrases[ayah_key]:
                    all_word_phrases[ayah_key][word_id] = cl

    # Build final syntax structure
    all_ayahs = set(all_word_roles) | set(all_word_phrases) | set(all_elided)
    syntax: dict[str, dict] = {}
    for ak in all_ayahs:
        words_info: dict[int, dict] = {}
        for w, roles in all_word_roles.get(ak, {}).items():
            words_info[w] = {
                "roles": roles,
                "phrase": all_word_phrases.get(ak, {}).get(w),
            }
        for w, ptype in all_word_phrases.get(ak, {}).items():
            if w not in words_info:
                words_info[w] = {"roles": [], "phrase": ptype}
        syntax[ak] = {
            "words": words_info,
            "elided": all_elided.get(ak, []),
        }

    return morph_words, syntax


# ---------------------------------------------------------------------------
# Data loading — other sources
# ---------------------------------------------------------------------------

def load_lanes(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text("utf-8"))
    return {e["root"]: e for e in data.get("roots", []) if e.get("root")}


def load_wbw(cache_dir: Path, chapter: int) -> list[dict]:
    path = cache_dir / f"wbw_ch{chapter}.json"
    if path.exists():
        return json.loads(path.read_text("utf-8"))
    return []


def load_qpc(cache_dir: Path, chapter: int) -> list[dict]:
    path = cache_dir / f"qpc_ch{chapter}.json"
    if path.exists():
        return json.loads(path.read_text("utf-8"))
    return []


# ---------------------------------------------------------------------------
# I'rab (QAC) loading
# ---------------------------------------------------------------------------

_AYAH_NUM_RE = re.compile(r"[\u00A0\s]*[\u0660-\u0669]+\s*$")
_RUB_ALHIZB = "\u06DE"

# Quran ayah counts per surah (1-indexed)
SURAH_AYAH_COUNTS = [
    0,  # placeholder for 0-index
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,  # 1-10
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,   # 11-20
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,      # 21-30
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,        # 31-40
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,         # 41-50
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,         # 51-60
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,         # 61-70
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,         # 71-80
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,         # 81-90
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,              # 91-100
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,                  # 101-110
    5, 4, 5, 6,                                       # 111-114
]


def _morph_word_counts(morph_words: dict[str, dict]) -> dict[str, int]:
    """Get per-ayah word counts from pre-loaded morphology data.

    The i'rab data uses the same word boundaries as the morphology corpus
    (both from the Quranic Arabic Corpus / EQTB), so morphology word counts
    give correct alignment.
    """
    counts: dict[str, int] = defaultdict(int)
    for word_key in morph_words:
        parts = word_key.split(":")
        if len(parts) != 3:
            continue
        ayah_key = f"{parts[0]}:{parts[1]}"
        word_pos = int(parts[2])
        counts[ayah_key] = max(counts[ayah_key], word_pos)
    return dict(counts)


def load_irab(path: Path, morph_words: dict) -> dict[str, list[str]]:
    """Parse irab.tsv into per-ayah lists of analysis strings.

    Column 1 = word count of phrase being analyzed.
    Accumulate word counts to determine ayah boundaries using morphology
    word counts (same word splitting as the i'rab data).
    """
    if not path.exists():
        return {}

    morph_wc = _morph_word_counts(morph_words)
    lines = path.read_text("utf-8").splitlines()
    result: dict[str, list[str]] = {}

    line_idx = 0
    for surah in range(1, 115):
        num_ayahs = SURAH_AYAH_COUNTS[surah]

        for ayah_num in range(1, num_ayahs + 1):
            key = f"{surah}:{ayah_num}"
            target_words = morph_wc.get(key, 0)
            if target_words == 0:
                continue

            consumed_words = 0
            ayah_analyses = []

            while consumed_words < target_words and line_idx < len(lines):
                line = lines[line_idx].strip()
                if not line:
                    line_idx += 1
                    continue

                parts = line.split("\t", 1)
                if len(parts) != 2:
                    line_idx += 1
                    continue

                word_count = int(parts[0])
                analysis_text = parts[1]
                ayah_analyses.append(analysis_text)
                consumed_words += word_count
                line_idx += 1

            if ayah_analyses:
                result[key] = ayah_analyses

    return result


# ---------------------------------------------------------------------------
# Entry formatting
# ---------------------------------------------------------------------------

def extract_qpc_words(qpc_text: str) -> list[str]:
    text = _AYAH_NUM_RE.sub("", qpc_text)
    text = text.replace(_RUB_ALHIZB, "")
    return text.split()


def _format_role(role_dict: dict, qpc_words: list[str] | None,
                  current_word_pos: int = 0) -> str:
    """Format a single syntax role, with target word for relational roles."""
    en, ar, role = role_dict["en"], role_dict["ar"], role_dict["role"]
    source_word = role_dict.get("source_word")
    source_phrase = role_dict.get("source_phrase")

    # Show target word for relational roles (skip if same word)
    if role in RELATIONAL_ROLES:
        if source_word is not None and source_word != current_word_pos and qpc_words:
            idx = source_word - 1
            if 0 <= idx < len(qpc_words):
                return f"{en} of {qpc_words[idx]} ({ar})"
        if source_phrase:
            pt = PHRASE_TYPE_LABELS.get(source_phrase)
            if pt:
                return f"{en} of {pt[0]} ({ar})"

    return f"{en} ({ar})"


def format_elided_line(elided: dict, qpc_words: list[str] | None) -> str:
    """Format an elided/implied element line."""
    node_type = elided["type"]
    text = elided.get("text")

    if node_type == "PRON" and text:
        header = f"(implied: {text})"
    elif node_type == "V":
        header = "(implied verb)"
    elif node_type == "N":
        header = "(implied noun)"
    else:
        header = f"(implied {node_type})"

    parts = [f'<span style="color:#888;font-style:italic">{header}</span>']
    for r in elided.get("roles", []):
        role_str = _format_role(r, qpc_words)
        parts.append(f'<br/><span style="color:#888;font-size:85%">{role_str}</span>')

    return "".join(parts)


def format_word_line(
    qpc_word: str,
    wbw_translation: str,
    merged: dict | None,
    word_syntax: dict | None,
    qpc_words: list[str] | None,
    word_pos: int = 0,
) -> str:
    """Format a single word's line for the ayah entry.

    Structure: word — translation
               phrase · role · POS · case — reason · pgn · root
    """
    parts = []

    # Line 1: Arabic word — English translation
    header = qpc_word
    if wbw_translation:
        header += f" — {wbw_translation.strip()}"
    parts.append(header)

    # Prepare syntax info
    phrase_type = None
    syntax_roles = []
    linked_case_role = None

    # Phrase types too generic to be useful per-word
    _SKIP_PHRASE_TYPES = {"VS", "NS", "S"}

    if word_syntax:
        phrase_type = word_syntax.get("phrase")
        roles = word_syntax.get("roles", [])

        # Find role that explains the grammatical case
        if merged:
            word_case = merged.get("case")
            for r in roles:
                expected_case = ROLE_TO_CASE.get(r["role"])
                if expected_case and expected_case == word_case:
                    linked_case_role = r
                    break

        # Remaining roles: exclude case-linked and self-referential
        # (self-referential = suffix is subject/object of its own verb,
        # already encoded in person/gender/number)
        syntax_roles = [
            r for r in roles
            if r is not linked_case_role
            and not (r.get("source_word") is not None
                     and r["source_word"] == word_pos)
        ]

    # Build single combined info line: syntax roles + morphology
    info_parts = []

    # Phrase type (skip VS/NS/S — too generic)
    if phrase_type and phrase_type not in _SKIP_PHRASE_TYPES:
        pt = PHRASE_TYPE_LABELS.get(phrase_type)
        if pt:
            info_parts.append(f"{pt[0]} ({pt[1]})")

    # Syntax roles
    for r in syntax_roles:
        role_str = _format_role(r, qpc_words, word_pos)
        info_parts.append(role_str)

    # Morphology
    if merged:
        pos = merged.get("pos")
        pos_en = POS_LABELS.get(pos, pos or "")
        derived = merged.get("derived_form")
        if derived and pos == "N":
            pos_en = DERIVED_LABELS_EN.get(derived, pos_en)
        if pos_en:
            info_parts.append(pos_en)

        if pos == "V":
            tense = merged.get("tense")
            if tense:
                info_parts.append(TENSE_LABELS_EN.get(tense, tense))
            voice = merged.get("voice")
            if voice == "PASS":
                info_parts.append("passive")
            vf = merged.get("verb_form")
            if vf:
                roman = VERB_FORM_NAMES.get(vf, str(vf))
                wazn = VERB_FORM_WAZN[vf - 1] if 1 <= vf <= len(VERB_FORM_WAZN) else ""
                info_parts.append(f"Form {roman} ({wazn})" if wazn else f"Form {roman}")

        # Case with linked reason (nouns, adjectives, demonstratives, etc.)
        if pos not in _PARTICLE_POS and pos != "V":
            case = merged.get("case")
            if case:
                case_str = CASE_LABELS_EN.get(case, case)
                if linked_case_role:
                    reason = _format_role(linked_case_role, qpc_words, word_pos)
                    case_str += f' \u2014 {reason}'
                info_parts.append(case_str)
            state = merged.get("nominal_state")
            if state == "INDEF":
                info_parts.append("indef.")

        if pos == "V":
            mood = merged.get("mood")
            if mood:
                info_parts.append(MOOD_LABELS_EN.get(mood, mood))

        # Person/gender/number (skip for particles)
        if pos not in _PARTICLE_POS:
            gn = []
            if merged.get("person"):
                gn.append(PERSON_LABELS_EN.get(merged["person"], merged["person"]))
            if merged.get("gender"):
                gn.append(GENDER_LABELS_EN.get(merged["gender"], merged["gender"]))
            if merged.get("number"):
                gn.append(NUMBER_LABELS_EN.get(merged["number"], merged["number"]))
            if gn:
                info_parts.append("".join(gn))

        if merged.get("root"):
            info_parts.append(f"root: {format_root(merged['root'])}")

    if info_parts:
        info_str = " · ".join(info_parts)
        parts.append(
            f'<br/><span style="color:#777;font-size:85%">{info_str}</span>')

    return "".join(parts)


# ---------------------------------------------------------------------------
# StarDict writer
# ---------------------------------------------------------------------------

def write_stardict(entries: list[tuple[str, str]], output_dir: Path, name: str,
                    bookname: str):
    output_dir.mkdir(parents=True, exist_ok=True)
    entries_sorted = sorted(entries, key=lambda e: e[0].encode("utf-8"))

    dict_data = bytearray()
    idx_data = bytearray()
    for key, definition in entries_sorted:
        key_bytes = key.encode("utf-8")
        def_bytes = definition.encode("utf-8")
        offset = len(dict_data)
        size = len(def_bytes)
        dict_data.extend(def_bytes)
        idx_data.extend(key_bytes + b"\x00")
        idx_data.extend(struct.pack(">II", offset, size))

    dict_path = output_dir / f"{name}.dict"
    idx_path = output_dir / f"{name}.idx"
    ifo_path = output_dir / f"{name}.ifo"

    dict_path.write_bytes(dict_data)
    idx_path.write_bytes(idx_data)
    ifo_path.write_text(
        f"StarDict's dict ifo file\n"
        f"version=2.4.2\n"
        f"wordcount={len(entries_sorted)}\n"
        f"idxfilesize={len(idx_data)}\n"
        f"bookname={bookname}\n"
        f"sametypesequence=h\n",
        encoding="utf-8",
    )

    print(f"\nBuilt {len(entries_sorted)} entries ({bookname}):")
    print(f"  {ifo_path}")
    print(f"  {idx_path} ({len(idx_data):,} bytes)")
    print(f"  {dict_path} ({len(dict_data):,} bytes)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _clean_irab_text(text: str) -> str:
    """Clean i'rab text: normalize brackets, quotes, whitespace."""
    # Collapse literal \n to spaces
    text = text.replace("\\n", " ").replace("\n", " ")
    # Replace ASCII curly brackets with ornamental Quran parentheses
    text = text.replace("{", "\uFD3F").replace("}", "\uFD3E")
    # Standardize ASCII double quotes to guillemets
    text = re.sub(r'"([^"]+)"', r"«\1»", text)
    return text


def format_irab_html(irab_entries: list[str]) -> list[str]:
    """Format i'rab entries as HTML paragraphs."""
    html_parts = []
    html_parts.append("<hr/>")
    html_parts.append('<p style="color:#666;text-align:right">إعراب</p>')
    for analysis in irab_entries:
        analysis = _clean_irab_text(analysis)
        colon_pos = analysis.find(":")
        if 0 < colon_pos < 60:
            word_part = analysis[:colon_pos].strip()
            rest = analysis[colon_pos + 1:].strip()
            html_parts.append(
                f'<p style="font-size:120%;text-align:right">{word_part}: '
                f'<span style="color:#444">{rest}</span></p>'
            )
        else:
            html_parts.append(
                f'<p style="color:#444;font-size:120%;text-align:right">{analysis.strip()}</p>'
            )
    return html_parts


def build_entries(variant: str, morph_words: dict, irab: dict, syntax: dict) -> list[tuple[str, str]]:
    """Build dictionary entries for a given variant."""
    include_grammar = variant in ("combined", "grammar")
    include_irab = variant in ("combined", "irab")

    entries = []
    skipped = []

    for ch in range(1, 115):
        wbw_verses = load_wbw(CACHE_DIR, ch) if include_grammar else []
        qpc_verses = load_qpc(CACHE_DIR, ch)

        if not qpc_verses:
            skipped.append(ch)
            continue
        if include_grammar and not wbw_verses:
            skipped.append(ch)
            continue
        if include_grammar and len(qpc_verses) != len(wbw_verses):
            print(f"  WARNING: Chapter {ch} verse count mismatch, skipping")
            skipped.append(ch)
            continue

        surah_name = SURAH_NAMES.get(ch, f"Surah {ch}")

        for v_idx, qpc_v in enumerate(qpc_verses):
            verse_key = qpc_v["verse_key"]
            surah, ayah = verse_key.split(":")
            surah_int, ayah_int = int(surah), int(ayah)

            qpc_text = qpc_v.get("qpc_uthmani_hafs", "")
            if not qpc_text:
                continue

            html_parts = []

            # Grammar section: WBW + syntax + morphology
            if include_grammar:
                wbw_v = wbw_verses[v_idx] if v_idx < len(wbw_verses) else {}
                qpc_words = extract_qpc_words(qpc_text)
                wbw_words = [w for w in wbw_v.get("words", [])
                             if w.get("char_type_name") == "word"]
                ayah_syntax = syntax.get(verse_key, {})
                ayah_word_syntax = ayah_syntax.get("words", {}) if ayah_syntax else {}

                for i, qpc_word in enumerate(qpc_words):
                    word_pos = i + 1

                    wbw_trans = ""
                    if i < len(wbw_words):
                        wbw_trans = wbw_words[i].get("translation", {}).get("text", "")

                    morph_key = f"{surah}:{ayah}:{word_pos}"
                    merged = morph_words.get(morph_key)
                    word_syn = ayah_word_syntax.get(word_pos)
                    wl = format_word_line(qpc_word, wbw_trans, merged,
                                          word_syn, qpc_words, word_pos)
                    html_parts.append(f'<p style="margin:0.1em 0">{wl}</p>')

            # I'rab section
            if include_irab:
                irab_key = f"{surah_int}:{ayah_int}"
                irab_entries = irab.get(irab_key, [])
                if irab_entries:
                    html_parts.extend(format_irab_html(irab_entries))

            if html_parts:
                key = f"{surah_name} {ayah_int}"
                entries.append((key, "\n".join(html_parts)))

    if skipped:
        print(f"  Skipped {len(skipped)} chapters (no cached data): {skipped}")

    return entries


def main():
    parser = argparse.ArgumentParser(description="Build Quran grammar dictionary")
    parser.add_argument("--variant", default="combined",
                        choices=["combined", "grammar", "irab", "all"],
                        help="Dictionary variant (default: combined)")
    args = parser.parse_args()

    variants = list(VARIANT_CONFIG.keys()) if args.variant == "all" else [args.variant]

    # Load all data sources once
    print("Loading EQTB (morphology + syntax)...")
    morph_words, syntax = load_eqtb(EQTB_PATH)
    print(f"  {len(morph_words):,} word entries, {len(syntax):,} ayahs with syntax")

    print("Loading Lane's Lexicon...")
    lanes = load_lanes(LANES_PATH)
    print(f"  {len(lanes):,} roots")

    print("Loading i'rab (QAC)...")
    irab = load_irab(IRAB_PATH, morph_words)
    print(f"  {len(irab):,} ayah entries")

    for variant in variants:
        cfg = VARIANT_CONFIG[variant]
        print(f"\n{'='*60}")
        print(f"Building variant: {variant} ({cfg['bookname']})")
        print(f"{'='*60}")

        entries = build_entries(variant, morph_words, irab, syntax)
        print(f"Total entries: {len(entries):,}")

        output_dir = OUTPUT_BASE / cfg["dir"]
        write_stardict(entries, output_dir, cfg["name"], cfg["bookname"])


if __name__ == "__main__":
    main()
