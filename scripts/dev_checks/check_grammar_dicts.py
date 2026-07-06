#!/usr/bin/env python3
"""Verify the built combined grammar dictionary.

Checks (2026-07-06 rebuild): kana/inna roles render "subject ‎(اسم كان)‎"
with no crude romanization ("of kan"), the dead exclamation label is gone
(exl = "detail"), state = "explication", lemmas are wasla-normalized.
"""
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BASE = ROOT / "output" / "grammar_dictionary" / "combined" / "quran_grammar_combined"

idx = Path(f"{BASE}.idx").read_bytes()
raw = Path(f"{BASE}.dict").read_bytes().decode("utf-8")

n = 0
i = 0
while i < len(idx):
    j = idx.index(b"\0", i)
    i = j + 9
    n += 1

fails = []
for bad in ["of kan", "of inna", "of lays", "of ykon", "exclamation"]:
    if bad in raw:
        fails.append(f"{bad!r} present")
for good, minimum in [("اسم كان", 500), ("explication", 10), ("detail", 50)]:
    if raw.count(good) < minimum:
        fails.append(f"{good!r} count {raw.count(good)} < {minimum}")
if re.search("‎\\[[^\\]]*ٱ", raw):
    fails.append("alef-wasla inside lemma brackets (normalization regression)")

print(f"entries: {n}")
for f in fails:
    print("FAIL:", f)
print("PASS" if not fails and n == 6236 else "FAIL")
sys.exit(0 if not fails and n == 6236 else 1)
