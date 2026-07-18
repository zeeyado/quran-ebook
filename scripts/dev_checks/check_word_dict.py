#!/usr/bin/env python3
"""Verify the built word dictionary (output/stardict/quran_qpc_en).

Checks (pins refreshed 2026-07-18, the L2 dict-lemma rebuild):
- Lane RETIRED from the word dict (owner 2026-07-17, cc785e0): zero
  Lane digest blocks
- Lemma lines = the graded form_key witnesses from morphology-vN
  (L2/D-R3-22): يُؤْثَرُ shows أَثَرَ with the labeled EQTB variant,
  87:16 shows آثَرَ, عصي shows عَصا (not QM's wrong-root عَفَا),
  2:190 keeps Form III قاتَلَ; Lemma counts keyed (root, lemma) so
  homographs don't merge
- IndoPak synonyms: الْاَرْضِ (2:11) and Fatiha forms resolve
- Presentation: no "Occurences" typo, passive voice displayed, Form XII
  labeled
"""
import gzip
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BASE = ROOT / "output" / "stardict" / "quran_qpc_en"

idx = Path(f"{BASE}.idx").read_bytes()
dict_path = Path(f"{BASE}.dict")
raw = dict_path.read_bytes() if dict_path.exists() else gzip.open(f"{BASE}.dict.dz").read()

entries: dict[str, list[str]] = {}
i = 0
while i < len(idx):
    j = idx.index(b"\0", i)
    word = idx[i:j].decode("utf-8")
    off, size = struct.unpack(">II", idx[j + 1:j + 9])
    entries.setdefault(word, []).append(raw[off:off + size].decode("utf-8"))
    i = j + 9

fails = []

# Lane RETIRED (owner 2026-07-17): no digest blocks may reappear
lane_count = sum(1 for hs in entries.values() for h in hs if "font-size:85%" in h)
if lane_count:
    fails.append(f"{lane_count} Lane digest blocks present (retired cc785e0)")
all_html = "\n".join(h for hs in entries.values() for h in hs)


def entry_with_ref(ref):
    pat = re.compile(rf"<!-- ref:[0-9:,]*\b{re.escape(ref)}\b")
    for hs in entries.values():
        for h in hs:
            if pat.search(h):
                return h
    return ""


# Lemma witness overlay (L2/D-R3-22, 2026-07-18): form_key is the lemma
# line; EQTB survives only as a labeled variant where genuinely divergent
_h = entry_with_ref("74:24:6")
if "lemma: ‎أَثَرَ" not in _h or "EQTB: ‎يُؤْثَرُ" not in _h:
    fails.append("74:24:6: form_key lemma أَثَرَ + labeled EQTB variant missing")
if "lemma: ‎آثَرَ" not in entry_with_ref("87:16:2"):
    fails.append("87:16:2: Form IV lemma آثَرَ missing (the owner's يُؤْثَر case)")
_h = entry_with_ref("2:61:57")
if "lemma: ‎عَصا" not in _h:
    fails.append("2:61:57: lemma عَصا missing (QM wrong-root عَفَا back?)")
if "Lemma ‎(عَصا‎): 27" not in _h:
    fails.append("2:61:57: homograph merge back (Lemma count must be 27, per-root)")
_h = entry_with_ref("2:190:1")
if "lemma: ‎قاتَلَ" not in _h:
    fails.append("2:190:1: Form III lemma قاتَلَ missing (QM I/III collapse back?)")
if "EQTB: ‎قَاتَلَ" in _h:
    fails.append("2:190:1: noisy EQTB variant on an orthography-only difference")

# IndoPak synonym lookups (exact EPUB encoding of 2:11 al-ard + Fatiha word 1:2)
for w in ["الْاَرْضِ", "اَلْحَمْدُ", "لِلّٰهِ"]:
    if w not in entries:
        fails.append(f"IndoPak form {w!r} not a headword")

if "Occurences" in all_html:
    fails.append("'Occurences' typo present")
if "passive ‎(" not in all_html:
    fails.append("passive voice not displayed")
if not re.search(r"Form XII\b", all_html):
    fails.append("Form XII missing")


def refs_of(hw):
    out = []
    for h in entries.get(hw, []):
        m = re.match(r"<!-- ref:([^>]*?) -->", h)
        if m:
            out.extend(m.group(1).split(","))
    return out


# 2026-07-10 alignment repairs + PUA fragment synonyms:
# fragment halves of 17:7 لِاَ[U+F64B]نْفُسِكُمْ must hit the word entry
for frag in ["لِاَ", "نْفُسِكُمْ"]:
    if "17:7:4" not in refs_of(frag):
        fails.append(f"17:7 fragment {frag!r} missing (PUA-split synonyms)")
# joined instance 2:181 'ba'da maa': half مَا keys the joined entry
if "2:181:3" not in refs_of("مَا"):
    fails.append("2:181 join half مَا missing")
# split instance 15:7 لَّوۡمَا carries BOTH corpus positions
_solid = "لَّوۡمَا"
_solid_refs = refs_of(_solid)
if not ("15:7:1" in _solid_refs and "15:7:2" in _solid_refs):
    fails.append("15:7 solid word missing dual positions (split repair)")
# previously fan-out-skipped verse now has IndoPak synonyms
if "18:19:2" not in refs_of("بَعَثْنٰهُمْ"):
    fails.append("18:19 IndoPak synonym missing (was fan-out-skipped)")
# red-word glyph headwords point at their words
if refs_of("") != ["18:19:34"] or refs_of("") != ["73:20:8"]:
    fails.append("whole-word PUA glyph headwords wrong")

# corpus coverage: every S:A:W exactly once across unique groups
from collections import Counter
_ref_counts = Counter()
_seen_html = set()
for hs in entries.values():
    for h in hs:
        if h not in _seen_html:
            _seen_html.add(h)
            m = re.match(r"<!-- ref:([^>]*?) -->", h)
            if m:
                _ref_counts.update(m.group(1).split(","))
_dupes = [r for r, c in _ref_counts.items() if c > 1]
if len(_ref_counts) != 77429 or _dupes:
    fails.append(f"corpus coverage broken: {len(_ref_counts)} positions, "
                 f"{len(_dupes)} duplicated")


# root-usage line (G1 polish 2026-07-11): pooled/peeled glosses; every
# family keeps its meaning (owner reverted the x1-folding experiment)
_usage_by_root = {}
for _hs in entries.values():
    for _h in _hs:
        for _m in re.finditer(
                r'<i>Quran usage, root ‎([^‎]+)‎ \(×(\d+)\):</i>[^<]*', _h):
            _usage_by_root.setdefault(_m.group(1), _m.group(0))
if len(_usage_by_root) < 1600:
    fails.append(f"root usage lines: {len(_usage_by_root)} roots (expected ~1642)")
_l = _usage_by_root.get("ع-ذ-ب", "")
if "‎عَذاب‎: punishment (×322)" not in _l or "palatable (×2)" not in _l:
    fails.append("adhab usage line lost its punishment/palatable families")
_l = _usage_by_root.get("ا-خ-ذ", "")
if ": seized (×127)" not in _l or "seized them" in _l:
    fails.append("akhadha gloss residue back ('seized them' vs 'seized')")
_l = _usage_by_root.get("ر-ب-ب", "")
if ": Lord (×975)" not in _l or "(×1)" not in _l:
    fails.append("rabb line: possessive residue, or x1 families lost their meanings")
_l = _usage_by_root.get("ع-ج-م", "")
if "(×1)" not in _l:
    fails.append("small root lost its x1 families")
if "in the Quran (×" in "".join(h for hs in entries.values() for h in hs):
    fails.append("old-format usage label still present")
if any(re.search(r"\+\d+ more", _l) for _l in _usage_by_root.values()):
    fails.append("usage-line family cap back ('+N more' tail found — "
                 "owner 2026-07-16: show ALL families)")

print(f"idx entries: {sum(len(v) for v in entries.values())} | distinct headwords: {len(entries)}")
print(f"Lane digest blocks (must be 0): {lane_count}")
for f in fails:
    print("FAIL:", f)
print("PASS" if not fails else "FAIL")
sys.exit(0 if not fails else 1)
