#!/usr/bin/env python
"""Verify the IndoPak WBW verse-token derivation across the full corpus.

The WBW redesign (docs/indopak_wbw_study.md, 2026-07-10) derives word
DISPLAY text from the verse body (text_indopak_nastaleeq) so WBW words are
byte-identical to the verse-text books — the Hafs WBW reference relation.
This check asserts, from the build caches:

  1. _indopak_word_texts aligns with the word-level API gloss count for
     ALL 6,236 ayahs (no fallback ayahs),
  2. reconstruction: stripping the NBSP mark-folds and the 5 join spaces
     reproduces the verse body tokens exactly (nothing added or lost),
  3. spot facts: 17:7 word 12 carries the verse encoding (Farsi yeh +
     U+0653/U+0657, no E0xx), 18:19 word 34 is the U+F658 whole-word
     glyph, 73:20 word 8 is U+F666, the 5 join ayahs produce two-token
     stacks, and no word contains E0xx codepoints anywhere.

Run from repo root:  python scripts/dev_checks/check_indopak_wbw_zip.py
Requires the .cache dir (populated by any IndoPak build).
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.data.quran_api import (  # noqa: E402
    _indopak_word_texts,
    _split_indopak_marker,
)

CACHE = ROOT / ".cache"

failed = []
total = 0
e0xx_hits = []
join_checks = {}
spot = {}

for ch in range(1, 115):
    verses = json.loads(
        (CACHE / f"quran_api_ch{ch}_text_indopak_nastaleeq.json").read_text()
    )["value"]
    words = json.loads(
        (CACHE / f"quran_api_words_text_indopak_en_ch{ch}.json").read_text()
    )["value"]
    for v in verses:
        total += 1
        vn = v["verse_number"]
        body, marker = _split_indopak_marker(v["text_indopak_nastaleeq"])
        api = words.get(str(vn), words.get(vn, []))
        texts = _indopak_word_texts(body, len(api), ch, vn)
        if texts is None:
            failed.append(f"{ch}:{vn}")
            continue
        # reconstruction: undo NBSP folds and join spaces -> original tokens
        rebuilt = " ".join(texts).replace(" ", " ").split()
        if rebuilt != body.split():
            failed.append(f"{ch}:{vn} (reconstruction)")
        for t in texts:
            if any(0xE000 <= ord(c) <= 0xF4FF for c in t):
                e0xx_hits.append(f"{ch}:{vn}")
        if (ch, vn) in ((2, 181), (8, 6), (13, 37), (37, 130), (72, 16)):
            join_checks[(ch, vn)] = [t for t in texts if " " in t.replace(" ", "")]
        if (ch, vn) == (17, 7):
            spot["17:7 w12"] = texts[11]
        if (ch, vn) == (18, 19):
            spot["18:19 w34"] = texts[33]
        if (ch, vn) == (73, 20):
            spot["73:20 w8"] = texts[7]

ok = True

def check(name, cond, detail=""):
    global ok
    status = "PASS" if cond else "FAIL"
    if not cond:
        ok = False
    print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))

print(f"corpus: {total} ayahs")
check("all ayahs align (no fallback)", total == 6236 and not failed,
      f"failed: {failed[:10]}" if failed else "6,236/6,236")
check("no E0xx codepoints in any word", not e0xx_hits,
      f"hits: {e0xx_hits[:5]}" if e0xx_hits else "")
check("5 join ayahs produce a two-token stack",
      all(len(v) == 1 for v in join_checks.values()) and len(join_checks) == 5,
      str({k: v for k, v in join_checks.items()}))
w12 = spot.get("17:7 w12", "")
check("17:7 w12 is verse-encoded",
      "ی" in w12 and "ٗ" in w12
      and not any(0xE000 <= ord(c) <= 0xF8FF for c in w12),
      " ".join(f"{ord(c):04X}" for c in w12))
check("18:19 w34 is U+F658 word glyph", spot.get("18:19 w34") == "")
check("73:20 w8 is U+F666 word glyph", spot.get("73:20 w8") == "")

sys.exit(0 if ok else 1)
