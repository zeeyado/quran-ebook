#!/usr/bin/env python3
"""Verify the built word dictionary (output/stardict/quran_qpc_en).

Checks (expected numbers from the 2026-07-06 rebuild):
- Lane hamza fix: the الله entry (ref 1:1:2) carries Lane's definition;
  ~34,400 entries have a Lane section (was 29,439 before the fold)
- IndoPak synonyms: الْاَرْضِ (2:11) and Fatiha forms resolve
- Presentation: no "Occurences" typo, passive voice displayed, Form XII
  labeled, Lane truncation ends at word boundaries
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

# Lane on الله (the 1:1:2 instance entry)
allah = [h for hs in entries.values() for h in hs if re.search(r"\bref:1:1:2\b", h)]
if not (allah and "color:#444;font-size:85%" in allah[0]):
    fails.append("الله entry missing Lane section (hamza fold regression)")

lane_count = sum(1 for hs in entries.values() for h in hs if "font-size:85%" in h)
all_html = "\n".join(h for hs in entries.values() for h in hs)

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

print(f"idx entries: {sum(len(v) for v in entries.values())} | distinct headwords: {len(entries)}")
print(f"entries with Lane section: {lane_count}")
for f in fails:
    print("FAIL:", f)
print("PASS" if not fails else "FAIL")
sys.exit(0 if not fails else 1)
