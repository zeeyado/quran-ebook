#!/usr/bin/env python3
"""Verify the IndoPak ayah-marker split + dict word alignment corpus-wide.

Expected (2026-07-06 data): 6,236/6,236 ayahs split with non-empty markers,
0 bad bodies, exactly 6 dict-alignment mismatches (15:7, 18:19, 27:20,
36:22, 72:16, 73:20 — IndoPak segments words differently there).

Note: mid-verse PUA waqf marks legitimately remain in ayah bodies (~700
occurrences); only the trailing marker cluster is split off.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "src"))

from build_dictionary import cache_get, CACHE_DIR, extract_indopak_words, extract_qpc_words  # noqa: E402
from quran_ebook.data.quran_api import _split_indopak_marker  # noqa: E402

total = unsplit = bad_body = 0
align_bad = []
for ch in range(1, 115):
    qpc = {v["verse_key"]: v.get("qpc_uthmani_hafs", "")
           for v in cache_get(CACHE_DIR, f"qpc_ch{ch}") or []}
    for v in cache_get(CACHE_DIR, f"indopak_nast_ch{ch}") or []:
        vk = v["verse_key"]
        t = v.get("text_indopak_nastaleeq", "")
        if not t:
            continue
        total += 1
        body, marker = _split_indopak_marker(t)
        if not marker:
            unsplit += 1
            print("UNSPLIT:", vk, [hex(ord(c)) for c in t[-10:]])
            continue
        if body.endswith(" ") or not body:
            bad_body += 1
            print("BAD BODY:", vk)
        nw = extract_indopak_words(t)
        qw = extract_qpc_words(qpc.get(vk, ""))
        if len(nw) != len(qw):
            align_bad.append(vk)

print(f"total={total} unsplit={unsplit} bad_body={bad_body}")
print(f"alignment mismatches ({len(align_bad)}):", ", ".join(align_bad))
ok = total == 6236 and unsplit == 0 and bad_body == 0 and len(align_bad) == 6
print("PASS" if ok else "FAIL — compare against docs/production_push_2026-07.md §0a")
sys.exit(0 if ok else 1)
