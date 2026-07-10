#!/usr/bin/env python3
"""Verify the IndoPak ayah-marker split + dict word alignment corpus-wide.

Expected: 6,236/6,236 ayahs split with non-empty markers, 0 bad bodies,
and 0 dict-alignment mismatches — since the 2026-07-10 repair,
extract_indopak_words takes (surah, ayah) and with align_qpc_words the
QPC/IndoPak/API axes agree for every verse (whole-word PUA glyphs 18:19 +
73:20, join tables for 2:181/8:6/13:37/37:130/72:16, splits for
15:7/27:20/36:22).

Note: mid-verse PUA waqf marks legitimately remain in ayah bodies (~700
occurrences); only the trailing marker cluster is split off.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "src"))

from build_dictionary import (  # noqa: E402
    CACHE_DIR,
    align_qpc_words,
    cache_get,
    extract_indopak_words,
    extract_qpc_words,
)
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
        s_num, a_num = (int(x) for x in vk.split(":"))
        nw = extract_indopak_words(t, s_num, a_num)
        qw = align_qpc_words(extract_qpc_words(qpc.get(vk, "")), s_num, a_num)
        if len(nw) != len(qw):
            align_bad.append(vk)

print(f"total={total} unsplit={unsplit} bad_body={bad_body}")
print(f"alignment mismatches ({len(align_bad)}):", ", ".join(align_bad))
ok = total == 6236 and unsplit == 0 and bad_body == 0 and len(align_bad) == 0
print("PASS" if ok else "FAIL — compare against docs/production_push_2026-07.md §0a")
sys.exit(0 if ok else 1)
