#!/usr/bin/env python3
"""Build the Quran grammar dictionary (StarDict format).

Per-ayah entries with word-by-word analysis: translation, syntactic role,
morphology (POS/case/mood/root/form), and i'rab prose from QAC.

5 data sources:
  - Quran.com API: WBW translations + QPC Uthmani Hafs text
  - mustafa0x/quran-morphology: ROOT/LEM/POS/case/gender/number/person/form
  - QAC syntax.txt: dependency treebank (syntactic roles)
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
import json
import re
import struct
from collections import defaultdict
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / ".cache" / "dictionary"
MORPHOLOGY_PATH = PROJECT_ROOT / ".cache" / "morphology" / "quran-morphology.txt"
LANES_PATH = PROJECT_ROOT / ".cache" / "lanes" / "quran_roots_lane.json"
IRAB_PATH = PROJECT_ROOT / ".cache" / "qac" / "irab.tsv"
SYNTAX_PATH = PROJECT_ROOT / ".cache" / "qac" / "syntax.txt"
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
    "pass": ("passive", "مبني للمجهول"),
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
}

PHRASE_TYPE_LABELS = {
    "PP": ("prep. phrase", "جار ومجرور"),
    "VS": ("verbal sent.", "جملة فعلية"),
    "NS": ("nominal sent.", "جملة اسمية"),
    "SC": ("subord. clause", "جملة تابعة"),
    "S": ("sentence", "جملة"),
    "CS": ("cond. sent.", "جملة شرطية"),
}


# ---------------------------------------------------------------------------
# Morphology label maps
# ---------------------------------------------------------------------------

POS_LABELS = {
    "N": "noun", "V": "verb", "P": "particle", "PN": "proper noun",
    "PRON": "pronoun", "DEM": "demonstrative", "REL": "relative pronoun",
    "T": "time adverb", "LOC": "location adverb",
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
VERB_FORM_NAMES = {i: n for i, n in enumerate(["I","II","III","IV","V","VI","VII","VIII","IX","X"], 1)}


def format_root(root: str) -> str:
    if not root or "-" in root:
        return root
    return "-".join(root)


# ---------------------------------------------------------------------------
# Data loading — morphology
# ---------------------------------------------------------------------------

_CASE_TAGS = {"NOM", "ACC", "GEN"}
_MOOD_TAGS = {"IND", "SUBJ", "JUS"}
_TENSE_TAGS = {"PERF", "IMPF", "IMPV"}
_GENDER_TAGS = {"M", "F"}
_NUMBER_TAGS = {"S", "D", "P"}
_PERSON_TAGS = {"1", "2", "3"}
_DERIVED_TAGS = {"ACT_PCPL", "PASS_PCPL", "VN"}


def parse_morphology_by_segment(path: Path) -> dict[str, list[dict]]:
    """Parse morphology into per-word SEGMENT lists."""
    words: dict[str, list[dict]] = defaultdict(list)

    for line in path.read_text("utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue

        loc, arabic_segment, pos_type, tags_str = parts
        loc_parts = loc.split(":")
        if len(loc_parts) != 4:
            continue

        surah, ayah, word_pos, _segment = loc_parts
        word_key = f"{surah}:{ayah}:{word_pos}"

        tags = tags_str.split("|")
        seg = {
            "pos_type": pos_type,
            "arabic_text": arabic_segment,
            "root": None, "lemma": None, "verb_form": None,
            "case": None, "mood": None, "tense": None,
            "gender": None, "number": None, "person": None,
            "derived_form": None, "pos_details": [],
        }

        for tag in tags:
            if tag.startswith("ROOT:"):
                seg["root"] = tag[5:]
            elif tag.startswith("LEM:"):
                seg["lemma"] = tag[4:]
            elif tag.startswith("VF:"):
                try:
                    seg["verb_form"] = int(tag[3:])
                except ValueError:
                    pass
            elif tag in _CASE_TAGS:
                seg["case"] = tag
            elif tag in _MOOD_TAGS:
                seg["mood"] = tag
            elif tag in _TENSE_TAGS:
                seg["tense"] = tag
            elif tag in _GENDER_TAGS:
                seg["gender"] = tag
            elif tag in _NUMBER_TAGS:
                seg["number"] = tag
            elif tag in _PERSON_TAGS:
                seg["person"] = tag
            elif tag in _DERIVED_TAGS:
                seg["derived_form"] = tag
            elif tag not in ("PREF", "DET", "SUFF", "ADJ"):
                seg["pos_details"].append(tag)

        words[word_key].append(seg)

    return words


def merge_segments(segments: list[dict]) -> dict:
    """Merge segments into a single word entry (content wins over prefix).

    Special handling:
    - DEM, REL tags on N-type segments override POS display
      (e.g. ذٰلِكَ is N with DEM tag → shows "demonstrative" not "noun").
    - PRON suffix segments (N-type with PRON tag following a V or N content
      segment) do NOT override the main POS — تَابُواْ stays "verb" not "pronoun",
      إِخۡوَٰنُكُمۡ stays "noun" not "pronoun".
    """
    result = {
        "root": None, "lemma": None, "pos": None, "verb_form": None,
        "case": None, "mood": None, "tense": None,
        "gender": None, "number": None, "person": None,
        "derived_form": None, "segments": segments,
        "semantic_pos": None,
    }

    for seg in segments:
        is_content = seg["pos_type"] in ("N", "V")
        # A PRON suffix (N-type with PRON tag after a content segment) should
        # not override the main verb/noun POS or its morphological fields.
        is_pron_suffix = (
            "PRON" in seg.get("pos_details", [])
            and seg["pos_type"] == "N"
            and result["pos"] is not None
        )
        if is_pron_suffix:
            # Still pick up person/gender/number from the suffix if the main
            # content segment didn't provide them (e.g. verb stem has no pgn).
            for field in ("person", "gender", "number"):
                if seg[field] is not None and result[field] is None:
                    result[field] = seg[field]
            continue

        if is_content or result["pos"] is None:
            for field in ("root", "lemma", "verb_form", "case", "mood",
                          "tense", "gender", "number", "person", "derived_form"):
                if seg[field] is not None:
                    if is_content or result[field] is None:
                        result[field] = seg[field]
            if is_content or result["pos"] is None:
                result["pos"] = seg["pos_type"]

        for detail in seg.get("pos_details", []):
            if detail in ("DEM", "REL"):
                result["semantic_pos"] = detail

    return result


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


def _morph_word_counts(morph_path: Path) -> dict[str, int]:
    """Get per-ayah word counts from the morphology corpus.

    The i'rab data uses the same word boundaries as the morphology corpus
    (both from the Quranic Arabic Corpus), so morphology word counts give
    correct alignment. QPC text has slightly different word splitting (~7 ayahs
    differ), which causes cumulative drift when used for i'rab alignment.
    """
    counts: dict[str, int] = defaultdict(int)
    for line in morph_path.read_text("utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        loc = parts[0].split(":")
        if len(loc) != 4:
            continue
        key = f"{loc[0]}:{loc[1]}"
        word_pos = int(loc[2])
        counts[key] = max(counts[key], word_pos)
    return dict(counts)


def load_irab(path: Path) -> dict[str, list[str]]:
    """Parse irab.tsv into per-ayah lists of analysis strings.

    Column 1 = word count of phrase being analyzed.
    Accumulate word counts to determine ayah boundaries using morphology
    corpus word counts (same word splitting as the i'rab data).
    """
    if not path.exists():
        return {}

    morph_wc = _morph_word_counts(MORPHOLOGY_PATH)
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
# Syntax (QAC dependency treebank) loading
# ---------------------------------------------------------------------------

_WORD_REF_RE = re.compile(r"word\((\d+):(\d+):(\d+)\)")
_NODE_DEF_RE = re.compile(r"(n\d+)(?:,\s*(n\d+))?\s*=\s*(\w+)\((.+?)\)")
_EDGE_RE = re.compile(r"(\w+)\((n\d+)\s*-\s*(n\d+)\)")


def load_syntax(path: Path) -> dict[str, dict[int, list[str]]]:
    """Parse syntax.txt into per-word syntactic role labels.

    Returns dict keyed by "surah:ayah" -> {word_pos: [role_labels]}.
    Each role_label is like "subject (فاعل)" or "object of word 2".
    """
    if not path.exists():
        return {}

    text = path.read_text("utf-8")
    blocks = text.split("\ngo\n")

    result: dict[str, dict[int, list[str]]] = defaultdict(lambda: defaultdict(list))

    for block in blocks:
        lines = [l.strip() for l in block.strip().splitlines()
                 if l.strip() and not l.strip().startswith("--")]
        if not lines:
            continue

        node_to_word: dict[str, tuple[int, int, int] | None] = {}
        node_to_phrase: dict[str, str] = {}

        for line in lines:
            m = _NODE_DEF_RE.match(line)
            if m:
                n1, n2, node_type, content = m.groups()
                if node_type in ("word", "reference"):
                    ref_parts = content.split(":")
                    if len(ref_parts) == 3:
                        s, a, w = int(ref_parts[0]), int(ref_parts[1]), int(ref_parts[2])
                        node_to_word[n1] = (s, a, w)
                        if n2:
                            node_to_word[n2] = (s, a, w)
                elif node_type in PHRASE_TYPE_LABELS:
                    node_to_phrase[n1] = node_type
                else:
                    node_to_word[n1] = None
                    if n2:
                        node_to_word[n2] = None

        for line in lines:
            em = _EDGE_RE.match(line)
            if not em:
                continue
            role, target_node, source_node = em.groups()

            target_word = node_to_word.get(target_node)
            if target_word is None:
                continue

            s, a, w = target_word
            ayah_key = f"{s}:{a}"

            role_info = SYNTAX_ROLE_LABELS.get(role)
            if role_info:
                en_label, ar_label = role_info
                role_str = f"{en_label} ({ar_label})"
                if role_str not in result[ayah_key][w]:
                    result[ayah_key][w].append(role_str)

    return dict(result)


# ---------------------------------------------------------------------------
# Entry formatting
# ---------------------------------------------------------------------------

def extract_qpc_words(qpc_text: str) -> list[str]:
    text = _AYAH_NUM_RE.sub("", qpc_text)
    text = text.replace(_RUB_ALHIZB, "")
    return text.split()


def format_word_line(
    qpc_word: str,
    wbw_translation: str,
    merged: dict | None,
    syntax_roles: list[str] | None,
) -> str:
    """Format a single word's line for the ayah entry."""
    line = qpc_word
    if wbw_translation:
        line += f" — {wbw_translation.strip()}"

    if syntax_roles:
        role_str = ", ".join(syntax_roles)
        line += f'<br/><span style="color:#777;font-size:85%">{role_str}</span>'

    if merged:
        morph_parts = []

        pos = merged.get("pos")
        semantic = merged.get("semantic_pos")
        if semantic and semantic in POS_LABELS:
            pos_en = POS_LABELS[semantic]
        else:
            pos_en = POS_LABELS.get(pos, pos or "")
        derived = merged.get("derived_form")
        if derived and pos == "N" and not semantic:
            pos_en = DERIVED_LABELS_EN.get(derived, pos_en)
        if pos_en:
            morph_parts.append(pos_en)

        if pos == "V":
            tense = merged.get("tense")
            if tense:
                morph_parts.append(TENSE_LABELS_EN.get(tense, tense))
            vf = merged.get("verb_form")
            if vf:
                roman = VERB_FORM_NAMES.get(vf, str(vf))
                wazn = VERB_FORM_WAZN[vf - 1] if 1 <= vf <= len(VERB_FORM_WAZN) else ""
                morph_parts.append(f"Form {roman} ({wazn})" if wazn else f"Form {roman}")

        if pos in ("N", "PN", "DEM", "REL", "T", "LOC"):
            case = merged.get("case")
            if case:
                morph_parts.append(CASE_LABELS_EN.get(case, case))
        if pos == "V":
            mood = merged.get("mood")
            if mood:
                morph_parts.append(MOOD_LABELS_EN.get(mood, mood))

        gn = []
        if merged.get("person"):
            gn.append(PERSON_LABELS_EN[merged["person"]])
        if merged.get("gender"):
            gn.append(GENDER_LABELS_EN[merged["gender"]])
        if merged.get("number"):
            gn.append(NUMBER_LABELS_EN[merged["number"]])
        if gn:
            morph_parts.append("".join(gn))

        if merged.get("root"):
            morph_parts.append(f"root: {format_root(merged['root'])}")

        if morph_parts:
            morph_str = " · ".join(morph_parts)
            line += f'<br/><span style="color:#777;font-size:85%">{morph_str}</span>'

    return line


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
    html_parts.append('<p style="color:#666">إعراب</p>')
    for analysis in irab_entries:
        analysis = _clean_irab_text(analysis)
        colon_pos = analysis.find(":")
        if 0 < colon_pos < 60:
            word_part = analysis[:colon_pos].strip()
            rest = analysis[colon_pos + 1:].strip()
            html_parts.append(
                f'<p style="font-size:120%">{word_part}: '
                f'<span style="color:#444">{rest}</span></p>'
            )
        else:
            html_parts.append(
                f'<p style="color:#444;font-size:120%">{analysis.strip()}</p>'
            )
    return html_parts


def build_entries(variant: str, morph_segments: dict, irab: dict, syntax: dict) -> list[tuple[str, str]]:
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

                for i, qpc_word in enumerate(qpc_words):
                    word_pos = i + 1

                    wbw_trans = ""
                    if i < len(wbw_words):
                        wbw_trans = wbw_words[i].get("translation", {}).get("text", "")

                    morph_key = f"{surah}:{ayah}:{word_pos}"
                    segs = morph_segments.get(morph_key, [])
                    merged = merge_segments(segs) if segs else None
                    roles = ayah_syntax.get(word_pos, [])
                    wl = format_word_line(qpc_word, wbw_trans, merged, roles)
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
    print("Loading morphology...")
    morph_segments = parse_morphology_by_segment(MORPHOLOGY_PATH)
    print(f"  {len(morph_segments):,} word entries")

    print("Loading Lane's Lexicon...")
    lanes = load_lanes(LANES_PATH)
    print(f"  {len(lanes):,} roots")

    print("Loading i'rab (QAC)...")
    irab = load_irab(IRAB_PATH)
    print(f"  {len(irab):,} ayah entries")

    print("Loading syntax (QAC treebank)...")
    syntax = load_syntax(SYNTAX_PATH)
    print(f"  {len(syntax):,} ayahs with syntactic roles")

    for variant in variants:
        cfg = VARIANT_CONFIG[variant]
        print(f"\n{'='*60}")
        print(f"Building variant: {variant} ({cfg['bookname']})")
        print(f"{'='*60}")

        entries = build_entries(variant, morph_segments, irab, syntax)
        print(f"Total entries: {len(entries):,}")

        output_dir = OUTPUT_BASE / cfg["dir"]
        write_stardict(entries, output_dir, cfg["name"], cfg["bookname"])


if __name__ == "__main__":
    main()
