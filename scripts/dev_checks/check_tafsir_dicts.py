#!/usr/bin/env python3
"""Verify tafsir export-style classification + attribution ground truth.

Expected (2026-07-06 cache): 9 PER-AYAH, 6 GROUP/text-on-FIRST,
5 GROUP/text-on-LAST (ru-saddi, fathul-majid, bayan-ul-quran, tazkiru-ur,
tazkirul-en — the five that the pre-2026-07 heuristic misattributed).

Attribution spot checks against built dicts (run tools/build_tafseer_dictionary.py
--all first); ground truth: fathul-majid's 1:7 text opens "tafsir of ayahs 6-7",
tazkirul stores the Fatiha group at 1:7 with a standalone bismillah entry at 1:1.
"""
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from build_tafseer_dictionary import SURAH_AYAH_COUNTS, classify_style  # noqa: E402

CACHE = ROOT / ".cache" / "tafseer"
fails = []

# 1. Classification of all cached exports
styles = {}
for sub in sorted(p.name for p in CACHE.iterdir() if p.is_dir()):
    chapters = {}
    for chf in (CACHE / sub).glob("ch*.json"):
        chapters[int(chf.stem[2:])] = json.loads(chf.read_text(encoding="utf-8"))
    styles[sub] = classify_style(chapters)
    print(f"{sub:35s} {styles[sub]}")

from collections import Counter
counts = Counter(styles.values())
print(dict(counts))
if counts != Counter({"per_ayah": 9, "group_first": 6, "group_last": 5}):
    fails.append(f"style distribution changed: {dict(counts)}")

expect_last = {"ru-tafseer-al-saddi", "tafisr-fathul-majid-bn", "tafsir-bayan-ul-quran",
               "tazkiru-quran-ur", "tazkirul-quran-en"}
got_last = {s for s, st in styles.items() if st == "group_last"}
if got_last != expect_last:
    fails.append(f"text-on-last set changed: {got_last}")


# 2. Attribution spot checks in built dicts
def load(base):
    idx = Path(f"{base}.idx").read_bytes()
    raw = Path(f"{base}.dict").read_bytes()
    d = {}
    i = 0
    while i < len(idx):
        j = idx.index(b"\0", i)
        w = idx[i:j].decode("utf-8")
        off, size = struct.unpack(">II", idx[j + 1:j + 9])
        d.setdefault(w, []).append(raw[off:off + size].decode("utf-8"))
        i = j + 9
    return d


out = ROOT / "output" / "tafseer_dictionary"
if (out / "tazkirul-quran-en").exists():
    d = load(out / "tazkirul-quran-en" / "quran_tafsir_tazkirul_quran_en")
    if "Al-Fatihah 1" not in d or "1" not in d["Al-Fatihah 1"][0][:400]:
        fails.append("tazkirul: Fatiha 1 entry wrong/missing")
    if d.get("Al-Fatihah 2") != d.get("Al-Fatihah 7"):
        fails.append("tazkirul: 1:2 and 1:7 should share the 2-7 group")
    if d.get("Al-Fatihah 1") == d.get("Al-Fatihah 2"):
        fails.append("tazkirul: 1:1 must be its own group, not merged with 2-7")

if (out / "fathul-majid").exists():
    d = load(out / "fathul-majid" / "quran_tafsir_fathul_majid")
    if d.get("Al-Fatihah 6") != d.get("Al-Fatihah 7"):
        fails.append("fathul: 1:6-7 must share the '6-7' group (text-on-last)")

if (out / "ibn-kathir-en").exists():
    d = load(out / "ibn-kathir-en" / "quran_tafsir_ibn_kathir_en")
    if d.get("Yunus 1") != d.get("Yunus 2") or d.get("Yunus 2") == d.get("Yunus 3"):
        fails.append("en-ibn-kathir: 10:1-2 grouping (text-on-first) broken")

if (out / "wasit").exists():
    d = load(out / "wasit" / "quran_tafsir_wasit")
    if "Hud 31" in d:
        fails.append("wasit: genuinely-empty 11:31 must have NO entry (per-ayah)")

for f in fails:
    print("FAIL:", f)
print("PASS" if not fails else "FAIL")
sys.exit(0 if not fails else 1)
