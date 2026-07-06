#!/usr/bin/env python3
"""Verify data/hafs_warsh_alignment.json against the design invariants
(docs/warsh_alignment_design.md): per surah, mapping length == Hafs count,
values in [1, Warsh count], monotone, starts at 1 / ends at Warsh count,
every Warsh ayah covered; 6,236 entries total. Prints spot checks for the
known-tricky surahs (al-Fatihah basmala, 2:1 merge, surah 5 splits).
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "src"))
from quran_ebook.data.validate import AYAH_COUNTS_HAFS, AYAH_COUNTS_WARSH  # noqa: E402

table = json.loads((ROOT / "data" / "hafs_warsh_alignment.json").read_text())["hafs_to_warsh"]

fails = []
total = 0
divergent = []
count_diff = {s for s in range(1, 115) if AYAH_COUNTS_HAFS[s] != AYAH_COUNTS_WARSH[s]}

for s in range(1, 115):
    m = table[str(s)]
    hc, wc = AYAH_COUNTS_HAFS[s], AYAH_COUNTS_WARSH[s]
    total += len(m)
    if len(m) != hc:
        fails.append(f"s{s}: length {len(m)} != {hc}")
        continue
    covered = set()
    prev_first = prev_last = 0
    for i, (a, b) in enumerate(m):
        if not (1 <= a <= b <= wc):
            fails.append(f"s{s} h{i+1}: bad range [{a},{b}] (wc={wc})")
        if a < prev_first or b < prev_last:
            fails.append(f"s{s} h{i+1}: non-monotone [{a},{b}] after [{prev_first},{prev_last}]")
        prev_first, prev_last = a, b
        covered.update(range(a, b + 1))
    if m[0][0] != 1:
        fails.append(f"s{s}: first maps to {m[0]}")
    if m[-1][1] != wc:
        fails.append(f"s{s}: last maps to {m[-1]}, want end {wc}")
    if covered != set(range(1, wc + 1)):
        missing = sorted(set(range(1, wc + 1)) - covered)
        fails.append(f"s{s}: Warsh ayahs uncovered: {missing[:8]}")
    if any(pair != [i + 1, i + 1] for i, pair in enumerate(m)):
        divergent.append(s)

print(f"total mappings: {total} (want 6236)")
if total != 6236:
    fails.append("total != 6236")

equal_count_divergent = [s for s in divergent if s not in count_diff]
print(f"divergent surahs: {len(divergent)}; of those with EQUAL counts: {equal_count_divergent}")
print(f"count-differing surahs NOT divergent (suspicious if any): {sorted(count_diff - set(divergent))}")

print("\nSpot checks (eyeball):")
print("  al-Fatihah:", table["1"])
print("  2:1-6:", table["2"][:6])
print("  surah 5 (Warsh splits, 120->122) first 12:", table["5"][:12])
print("  surah 103 (equal counts):", table["103"])
print("  surah 106:", table["106"], "| 107:", table["107"])

for f in fails:
    print("FAIL:", f)
print("PASS" if not fails else "FAIL")
sys.exit(0 if not fails else 1)
