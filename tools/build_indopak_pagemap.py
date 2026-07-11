"""Build the IndoPak 15-line mushaf page map from the QUL layout export.

Input:  data/qudratullah-indopak-15-lines.db — QUL Mushaf Layout #12
        "Indopak 15 lines (Qudratullah)", 610 pages
        (qul.tarteel.ai/resources/mushaf-layout/12; requires a free QUL
        login to download, so the export is kept in the repo).
Output: data/indopak_15_qudratullah_pages.json — {"S:A": first_page}
        for all 6,236 ayahs (tracked; consumed by
        quran_ebook.data.indopak_pages at build time).

Word-id model (verified 2026-07-11, re-asserted on every run):
the db's `pages` table references word ids that are globally sequential
in reading order. Each ayah spans (api_word_count + 1) ids — the +1 is
the end-of-ayah marker, which the QUL words table stores as a word row —
EXCEPT 2:181, 8:6 and 13:37, where QUL splits the joined pair بَعْدَ مَا
into two words (one extra id each; the same three verses behind
_QPC_API_JOINS in tools/build_dictionary.py). Total: 77,429 words +
6,236 markers + 3 splits = 83,668 ids, matching the db exactly.

Per-ayah API word counts come from the cached word fetches (any
`quran_api_words_*` language works — counts are language-independent),
so run any WBW build first if the cache is cold.
"""

import bisect
import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "data" / "qudratullah-indopak-15-lines.db"
OUT_PATH = ROOT / "data" / "indopak_15_qudratullah_pages.json"
CACHE = ROOT / ".cache"

TOTAL_PAGES = 610
TOTAL_WORD_IDS = 83668

# (surah, ayah) -> extra word ids beyond api_word_count + 1 (see module doc).
EXTRA_IDS = {(2, 181): 1, (8, 6): 1, (13, 37): 1}


def _load_word_counts() -> dict[tuple[int, int], int]:
    """Per-ayah API word counts from any cached words fetch."""
    counts: dict[tuple[int, int], int] = {}
    for ch in range(1, 115):
        candidates = sorted(CACHE.glob(f"quran_api_words_*ch{ch}.json"))
        # Glob matches ch1 -> ch1, ch10, ch100...; filter to the exact chapter.
        candidates = [
            p for p in candidates
            if p.stem.rsplit("ch", 1)[-1] == str(ch)
        ]
        if not candidates:
            sys.exit(
                f"No cached words data for surah {ch} "
                f"(.cache/quran_api_words_*_ch{ch}.json) — run a WBW build first."
            )
        data = json.load(open(candidates[0]))["value"]
        for verse_num, words in data.items():
            counts[(ch, int(verse_num))] = len(words)
    return counts


def main() -> None:
    if not DB_PATH.exists():
        sys.exit(f"Missing {DB_PATH} — download QUL mushaf layout #12 export.")

    counts = _load_word_counts()
    assert len(counts) == 6236, len(counts)
    assert sum(counts.values()) == 77429, sum(counts.values())

    # Global first-word id per ayah under the verified id model.
    first_id: dict[tuple[int, int], int] = {}
    g = 1
    for ch in range(1, 115):
        a = 1
        while (ch, a) in counts:
            first_id[(ch, a)] = g
            g += counts[(ch, a)] + 1 + EXTRA_IDS.get((ch, a), 0)
            a += 1
    assert g - 1 == TOTAL_WORD_IDS, f"id model drift: {g - 1} != {TOTAL_WORD_IDS}"

    con = sqlite3.connect(DB_PATH)
    lines = con.execute(
        "SELECT first_word_id, last_word_id, page_number FROM pages "
        "WHERE line_type='ayah' ORDER BY first_word_id"
    ).fetchall()

    # The db's ayah lines must tile 1..TOTAL_WORD_IDS with no gaps/overlaps.
    prev_last = 0
    for fw, lw, _ in lines:
        assert fw == prev_last + 1, f"id gap: {prev_last} -> {fw}"
        prev_last = lw
    assert prev_last == TOTAL_WORD_IDS, prev_last

    # Surah starts: the model's first id per surah must land exactly on the
    # first ayah line following each surah_name header row.
    rows = con.execute(
        "SELECT page_number, line_number, line_type, first_word_id, surah_number"
        " FROM pages ORDER BY page_number, line_number"
    ).fetchall()
    pending = None
    for _, _, ltype, fw, surah in rows:
        if ltype == "surah_name":
            pending = surah
        elif ltype == "ayah" and pending is not None:
            assert first_id[(pending, 1)] == fw, (
                f"surah {pending} start: model {first_id[(pending, 1)]}, db {fw}"
            )
            pending = None

    starts = [l[0] for l in lines]

    def page_of(gid: int) -> int:
        i = bisect.bisect_right(starts, gid) - 1
        fw, lw, page = lines[i]
        assert fw <= gid <= lw
        return page

    ayah_page = {k: page_of(v) for k, v in first_id.items()}

    pages = [ayah_page[k] for k in sorted(ayah_page)]
    assert all(b >= a for a, b in zip(pages, pages[1:])), "non-monotone pages"
    assert set(pages) == set(range(1, TOTAL_PAGES + 1)), "page coverage hole"

    OUT_PATH.write_text(json.dumps(
        {f"{s}:{a}": p for (s, a), p in sorted(ayah_page.items())},
        indent=0,
    ) + "\n")
    print(f"OK: wrote {OUT_PATH} ({len(ayah_page)} ayahs, pages 1..{TOTAL_PAGES})")
    print(f"    spot: 1:1 p{ayah_page[(1, 1)]} · 2:142 p{ayah_page[(2, 142)]}"
          f" · 18:1 p{ayah_page[(18, 1)]} · 114:6 p{ayah_page[(114, 6)]}")


if __name__ == "__main__":
    main()
