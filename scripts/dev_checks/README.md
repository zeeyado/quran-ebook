# Dev verification checks

Byte-level checks that validated the 2026-07 production-push work (there are
no automated tests in this repo — these scripts are the reproducible record
of what was verified and how). Run from the repo root, inside the `clarify`
conda env. They read the local `.cache/` and `output/` artifacts, so run the
relevant build first.

| Script | Verifies | Needs |
|---|---|---|
| `check_indopak_markers.py` | Every one of the 6,236 ayah-marker clusters splits (loader regex), no PUA residue, dict word alignment (6 known-unalignable verses) | `.cache/dictionary/{qpc,indopak_nast}_ch*.json` |
| `check_word_dict.py` | Lane hamza fix (الله entry), IndoPak synonym lookups (الْاَرْضِ), presentation fixes (Occurrences, passive, Form XII, truncation) | `output/stardict/quran_qpc_en.*` (build: `python tools/build_dictionary.py --instance --eqtb PATH/Quranic.csv -o output/stardict`) |
| `check_tafsir_dicts.py` | Export-style classification of all 20 tafsirs (9 per-ayah / 6 text-on-first / 5 text-on-last) + ground-truth attribution spot checks | `.cache/tafseer/*/ch*.json` + built dicts in `output/tafseer_dictionary/` |
| `check_grammar_dicts.py` | kana/inna rendering, exl/state labels, lemma normalization in the built grammar dict | `output/grammar_dictionary/combined/*` (build: `python tools/build_grammar_dictionary.py --variant combined --eqtb PATH/Quranic.csv`) |
| ~~`check_plugin_helpers.lua`~~ | MOVED 2026-07-25 to the plugin repo, [quran.koplugin](https://github.com/zeeyado/quran.koplugin): `dev/check_plugin_helpers.lua` (with `norm_fixture.lua`). Run from that repo's root; it finds this repo as `../quran-ebook` for the real-db sections. Its CI runs the same harness on stock LuaJIT | plugin repo |
| `check_warsh_alignment.py` | Hafs↔Warsh alignment table invariants (6,236 mapped, monotone, full Warsh coverage, 59 divergent surahs incl. 9 equal-count) + spot prints | `data/hafs_warsh_alignment.json` (build: `python tools/build_warsh_alignment.py`) |

| `reader_check.py` | Opens pages of built books in a browser engine (Chromium or WebKit, the engines most reading apps other than KOReader are built on): each page parses, its files arrive, the Quran text uses the book's font and runs right to left, no link is broken, nothing sticks out of the window (`--width 360` for a phone) | built books; Playwright (`pip install playwright`, then `python -m playwright install chromium webkit`) |

Each script ends with exit code 0 on success and 1 on failure, and names
what failed.

The word dictionary has its own check in `scripts/check_dictionary_coverage.py`
(it is part of the release workflow): every Quran word of every built book,
cut the way KOReader cuts a word, must be a headword.
