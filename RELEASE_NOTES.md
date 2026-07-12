<!-- v0.11.0 --> <!-- DRAFT — remove the DRAFT token from this line at tag time; gen_release_body.py refuses to run while it is present -->

## ⚠ One-time filename migration — read this first

Every EPUB in this release has a **new, permanent filename** (a structural naming
scheme: riwayah-orthography, font, layout, translation — see the table at the
bottom). Old names keep working as duplicate downloads **for this release only**.

**To keep your highlights and reading progress** when updating a book:

1. **Easiest — rename inside KOReader's file manager**: long-press the old book →
   Rename → give it the new name. KOReader moves your data automatically. Then
   overwrite the file with the new download.
2. **Or let the plugin do it** (v1.11+): replace the old file with the new
   download, open the book, and confirm when asked "Restore book data?" — or run
   *Quran → Restore book data after update* on the whole folder.
3. **Or rename on your computer**: rename BOTH `old.epub → new.epub` AND the
   matching `old.sdr → new.sdr` folder, then overwrite the epub.

Deleting the old book and downloading the new one **without one of the above
loses your highlights/progress** for that book.

Naming note: the old `inline` token meant "Arabic-only continuous text" — that is
now `flow`. In new names, `-inline` means "translation shown under each ayah".
Machine-readable map: `catalog.json` (attached below) carries `old_filename` for
every variant.

## New

- **IndoPak (Nastaleeq) family** — Arabic continuous, ayah-by-ayah with English
  or Urdu translation, tap-translation (Urdu), and **word-by-word with English
  glosses**. With **real 15-line subcontinent mushaf pagination** (610 pages,
  Qudratullah layout) — page references in KOReader match a physical IndoPak
  mushaf. *(Beta — see below.)* (#15)
- **Warsh translated builds** — ayah-by-ayah English via a verified Hafs↔Warsh
  ayah alignment (merged ayahs show each covered Hafs ayah as "(H) …"). Warsh
  pages were already the true Warsh 604-page layout. *(Beta.)*
- **OPDS catalog** — add
  `https://zeeyado.github.io/quran-ebook/opds/root.xml`
  to KOReader's OPDS catalogs and browse/download everything from the device.
- **`catalog.json`** — machine-readable variant manifest (id, axes, URL, sha256,
  old name, tier) for tooling and the upcoming in-plugin asset manager.

## Fixed — dictionaries (rebuilt zips)

- **5 tafsir dictionaries had systematically misattributed content** (As-Saʿdi
  ru, Fathul Majid, Bayan-ul-Quran, Tazkiru-l-Quran ur/en): entries that span an
  ayah range were attached to the wrong ayahs. All 20 tafsirs rebuilt with
  style-aware grouping; genuinely-missing ayahs no longer inherit a neighbor's
  text.
- **Word dictionary: 7 verses had glosses and grammar shifted by one word**
  (2:181, 8:6, 13:37, 37:130, 15:7, 27:20, 36:22 — a tokenization mismatch
  between the written text and the word database). Repaired and locked with
  regression checks; every one of the 77,429 word positions is now covered
  exactly once.
- **Lane's Lexicon layer replaced** — the previous root glosses came from a
  truncated upstream export (some were flatly wrong); the dictionary now carries
  properly extracted Lane senses per root, ranked by Quranic relevance.
- **New: "Quran usage" line per root** — each root's lemma families ranked by
  Quranic frequency with their dominant gloss (e.g. ع-ذ-ب ×373: عَذَاب
  "punishment" ×322 … عَذْب "palatable" ×2). Generated mechanically from
  morphology + word-by-word data — no editorial/AI summarization.
- IndoPak lookups: word stacks and dictionary headwords now share the exact
  verse encoding, and partially-selected ligature fragments resolve to the right
  word (e.g. لِاَنْفُسِكُمْ found from either visual half).
- Grammar dictionaries: precise Arabic relation labels (اسم كان style), dead
  "exclamation" label removed, passive voice shown, Form XI/XII names.

## Fixed — EPUBs

- **IndoPak ayah markers**: 213 ayahs shipped with unanchored/unsplit marker
  clusters (PUA waqf signs, rare combining marks); all 6,236 markers are now
  split, anchored, and tappable in every IndoPak layout.
- Arabic titles: grammatical separators (القرآن الکریم · الرسم الهندي · …);
  translator names moved out of titles (they live in the author field).
- Surah headers no longer sit flush against the preceding text.
- Mukhtasar variants parked from this release (returning later — #5).

## Plugin v1.11

- **Sidecar auto-migration** for the rename (see migration box) — batch restore
  from the menu + on-open detection.
- **Quick panel** — a one-tap hub for the current ayah: tafsir/asbab/i'rab
  buttons for whatever dictionaries you have installed, surah overview,
  header/footer toggles. Assignable to a gesture (Dispatcher: "Quran: quick
  panel"), plus separate gesture actions for ayah lookup, overview, toggles.
- **Quran browser** — a full-screen window (gesture: "Quran: browser"):
  navigate by surah (all 114, with per-ayah resource access) or juz, see the
  current position's resources, and browse the new root explorer.
- **Root explorer** (early version) — browse Arabic roots letter-by-letter or
  jump from any long-pressed word via the popup's new "Root explorer" button:
  every Lane's Lexicon headword for the root, ranked context (×N Quran
  frequency), full entry text. Needs the **Quran root data** package
  (`quran_lane`), installable from the browser's Library & assets.
- **Library & assets** — install and update dictionaries, data packages, and
  books directly from GitHub releases (sha256-verified downloads), update this
  plugin, and update the open book in place.
- **Tafsir group navigation** — in grouped tafsirs (e.g. Bayan ul Quran,
  Fi Zilal), the popup's next/prev now skips to the next commentary block
  instead of re-showing the same entry ayah by ayah (needs the updated
  dictionary ZIPs from this release).
- **QUL connections** — browse Quranic themes, a 2,500-topic thematic tree,
  similar ayahs, and resemblant passages (mutashabihat) in the Quran browser,
  each linked back to its ayahs. Needs the **Quran connections data** package
  (`quran_qul`), installable from Library & assets.
- **Exact ayah detection** — the quick panel, footer, and browser now identify
  the exact first ayah visible on the page (previously the detected ayah could
  be off by one, or fall back to the chapter start in some layouts).
- **Header overlay bar** (surah/juz at the top of the page) with auto top-margin
  so it never overlaps text; default header/footer font size now 13.
- Warsh books: popup navigation and ayah-keyed dictionaries now work in Hafs
  numbering via the alignment table (reaches merged ayahs' entries).
- IndoPak: long-press an ayah medallion to open that ayah; plain surah headers
  (Warsh/IndoPak) trigger the surah overview like glyph headers do.
- Hizb display is **temporarily disabled** (a page-resolution bug on large
  books) — juz display is unaffected; hizb returns in a future release.

## Dictionaries & data packages

- **New: Asbab al-Nuzul (al-Wahidi, Arabic)** — occasions of revelation as an
  ayah-keyed dictionary (329 narrations covering 398 ayahs; sparse by nature —
  most ayahs have no recorded occasion).
- **All 21 tafsir dictionaries updated** with entry-range metadata — this is
  what powers the plugin's group navigation; re-download them to get it.
- **New: Quran root data (`quran_lane`)** — Lane's Lexicon per-root database
  for the plugin's root explorer (public-domain Perseus text; 26,040 headwords,
  1,631 roots). Install from the plugin (Library & assets) or download the ZIP.
- **New: Quran connections data (`quran_qul`)** — themes, topic tree,
  similar-ayah, and mutashabihat data for the plugin's browser (sourced from
  Tarteel's Quranic Universal Library). Install from the plugin or download
  the ZIP.

## Beta — Warsh & IndoPak: we need your eyes

These scripts are outside what we can proof ourselves (we read QPC Hafs), and
the formatting work they required (marker splitting, spacing control, Nastaleeq
line metrics) may have introduced artifacts. If you read these, please open an
issue reporting: **text errors** (wrong/missing marks, qirāʾah-specific
spellings) · **ayah-marker artifacts** (gaps, wrong-side placement, markers
starting a line) · **line height/spacing** (cramped or excessive leading) ·
**overlapping marks or clipped ascenders/descenders** · anything odd at page
boundaries. They graduate from beta when reader feedback says they're right.

## Full filename map (old → new)

<details>
<summary>All 152 renamed files</summary>

| v0.10.0 name | new name |
|---|---|
| `quran_hafs_kfgqpc_bilin_ar-am-sadiq.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-am-sadiq.epub` |
| `quran_hafs_kfgqpc_bilin_ar-az-musayev.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-az-musayev.epub` |
| `quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-bn-taisirul.epub` |
| `quran_hafs_kfgqpc_bilin_ar-bs-korkut.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-bs-korkut.epub` |
| `quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-de-bubenheim.epub` |
| `quran_hafs_kfgqpc_bilin_ar-en-haleem.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-haleem.epub` |
| `quran_hafs_kfgqpc_bilin_ar-en-khattab-fn.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-khattab-fn.epub` |
| `quran_hafs_kfgqpc_bilin_ar-en-khattab.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-khattab.epub` |
| `quran_hafs_kfgqpc_bilin_ar-en-maududi.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-maududi.epub` |
| `quran_hafs_kfgqpc_bilin_ar-en-sahih.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-en-sahih.epub` |
| `quran_hafs_kfgqpc_bilin_ar-es-garcia.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-es-garcia.epub` |
| `quran_hafs_kfgqpc_bilin_ar-fa-dari.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-fa-dari.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ff-ruwwad.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ff-ruwwad.epub` |
| `quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-fr-hamidullah.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ha-gumi.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ha-gumi.epub` |
| `quran_hafs_kfgqpc_bilin_ar-hi-umari.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-hi-umari.epub` |
| `quran_hafs_kfgqpc_bilin_ar-id-ministry.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-id-ministry.epub` |
| `quran_hafs_kfgqpc_bilin_ar-it-piccardo.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-it-piccardo.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ja-sato.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ja-sato.epub` |
| `quran_hafs_kfgqpc_bilin_ar-kk-altay.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-kk-altay.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ko-choi.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ko-choi.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ku-bamoki.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ku-bamoki.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ml-hameed.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ml-hameed.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ms-basmeih.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ms-basmeih.epub` |
| `quran_hafs_kfgqpc_bilin_ar-nl-siregar.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-nl-siregar.epub` |
| `quran_hafs_kfgqpc_bilin_ar-no-berg.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-no-berg.epub` |
| `quran_hafs_kfgqpc_bilin_ar-pl-bielawski.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-pl-bielawski.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ps-abulsalam.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ps-abulsalam.epub` |
| `quran_hafs_kfgqpc_bilin_ar-pt-nasr.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-pt-nasr.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ru-kuliev.epub` |
| `quran_hafs_kfgqpc_bilin_ar-so-abduh.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-so-abduh.epub` |
| `quran_hafs_kfgqpc_bilin_ar-sq-ahmeti.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-sq-ahmeti.epub` |
| `quran_hafs_kfgqpc_bilin_ar-sv-bernstrom.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-sv-bernstrom.epub` |
| `quran_hafs_kfgqpc_bilin_ar-sw-barwani.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-sw-barwani.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ta-baqavi.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ta-baqavi.epub` |
| `quran_hafs_kfgqpc_bilin_ar-tg-mirof.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-tg-mirof.epub` |
| `quran_hafs_kfgqpc_bilin_ar-th-fahad.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-th-fahad.epub` |
| `quran_hafs_kfgqpc_bilin_ar-tl-darsalam.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-tl-darsalam.epub` |
| `quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-tr-diyanet.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ug-saleh.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ug-saleh.epub` |
| `quran_hafs_kfgqpc_bilin_ar-uk-yaqubovic.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-uk-yaqubovic.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ur-jalandhari.epub` |
| `quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-ur-maududi.epub` |
| `quran_hafs_kfgqpc_bilin_ar-uz-yusuf.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-uz-yusuf.epub` |
| `quran_hafs_kfgqpc_bilin_ar-vi-ruwwad.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-vi-ruwwad.epub` |
| `quran_hafs_kfgqpc_bilin_ar-yo-mikael.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-yo-mikael.epub` |
| `quran_hafs_kfgqpc_bilin_ar-zh-majian.epub` | `quran_hafs-uthmani_kfgqpc_ayah-inline_ar-zh-majian.epub` |
| `quran_hafs_kfgqpc_inline_ar.epub` | `quran_hafs-uthmani_kfgqpc_flow_ar.epub` |
| `quran_hafs_kfgqpc_interactive_ar-am-sadiq.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-am-sadiq.epub` |
| `quran_hafs_kfgqpc_interactive_ar-az-musayev.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-az-musayev.epub` |
| `quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-bn-taisirul.epub` |
| `quran_hafs_kfgqpc_interactive_ar-bs-korkut.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-bs-korkut.epub` |
| `quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-de-bubenheim.epub` |
| `quran_hafs_kfgqpc_interactive_ar-en-haleem.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-en-haleem.epub` |
| `quran_hafs_kfgqpc_interactive_ar-en-khattab-fn.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-en-khattab-fn.epub` |
| `quran_hafs_kfgqpc_interactive_ar-en-khattab.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-en-khattab.epub` |
| `quran_hafs_kfgqpc_interactive_ar-en-maududi.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-en-maududi.epub` |
| `quran_hafs_kfgqpc_interactive_ar-en-sahih.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-en-sahih.epub` |
| `quran_hafs_kfgqpc_interactive_ar-es-garcia.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-es-garcia.epub` |
| `quran_hafs_kfgqpc_interactive_ar-fa-dari.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-fa-dari.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ff-ruwwad.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ff-ruwwad.epub` |
| `quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-fr-hamidullah.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ha-gumi.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ha-gumi.epub` |
| `quran_hafs_kfgqpc_interactive_ar-hi-umari.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-hi-umari.epub` |
| `quran_hafs_kfgqpc_interactive_ar-id-ministry.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-id-ministry.epub` |
| `quran_hafs_kfgqpc_interactive_ar-it-piccardo.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-it-piccardo.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ja-sato.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ja-sato.epub` |
| `quran_hafs_kfgqpc_interactive_ar-kk-altay.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-kk-altay.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ko-choi.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ko-choi.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ku-bamoki.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ku-bamoki.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ml-hameed.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ml-hameed.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ms-basmeih.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ms-basmeih.epub` |
| `quran_hafs_kfgqpc_interactive_ar-nl-siregar.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-nl-siregar.epub` |
| `quran_hafs_kfgqpc_interactive_ar-no-berg.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-no-berg.epub` |
| `quran_hafs_kfgqpc_interactive_ar-pl-bielawski.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-pl-bielawski.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ps-abulsalam.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ps-abulsalam.epub` |
| `quran_hafs_kfgqpc_interactive_ar-pt-nasr.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-pt-nasr.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ru-kuliev.epub` |
| `quran_hafs_kfgqpc_interactive_ar-so-abduh.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-so-abduh.epub` |
| `quran_hafs_kfgqpc_interactive_ar-sq-ahmeti.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-sq-ahmeti.epub` |
| `quran_hafs_kfgqpc_interactive_ar-sv-bernstrom.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-sv-bernstrom.epub` |
| `quran_hafs_kfgqpc_interactive_ar-sw-barwani.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-sw-barwani.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ta-baqavi.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ta-baqavi.epub` |
| `quran_hafs_kfgqpc_interactive_ar-tg-mirof.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-tg-mirof.epub` |
| `quran_hafs_kfgqpc_interactive_ar-th-fahad.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-th-fahad.epub` |
| `quran_hafs_kfgqpc_interactive_ar-tl-darsalam.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-tl-darsalam.epub` |
| `quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-tr-diyanet.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ug-saleh.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ug-saleh.epub` |
| `quran_hafs_kfgqpc_interactive_ar-uk-yaqubovic.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-uk-yaqubovic.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ur-jalandhari.epub` |
| `quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-ur-maududi.epub` |
| `quran_hafs_kfgqpc_interactive_ar-uz-yusuf.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-uz-yusuf.epub` |
| `quran_hafs_kfgqpc_interactive_ar-vi-ruwwad.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-vi-ruwwad.epub` |
| `quran_hafs_kfgqpc_interactive_ar-yo-mikael.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-yo-mikael.epub` |
| `quran_hafs_kfgqpc_interactive_ar-zh-majian.epub` | `quran_hafs-uthmani_kfgqpc_flow-popup_ar-zh-majian.epub` |
| `quran_hafs_kfgqpc_wbw_ar-am-sadiq_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-am-sadiq_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-az-musayev_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-az-musayev_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-bn-taisirul.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-bn-taisirul.epub` |
| `quran_hafs_kfgqpc_wbw_ar-bn-taisirul_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-bn-taisirul_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-bs-korkut_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-bs-korkut_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-de-bubenheim_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-de-bubenheim_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-en-haleem.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-en-haleem.epub` |
| `quran_hafs_kfgqpc_wbw_ar-en-khattab-fn.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-en-khattab-fn.epub` |
| `quran_hafs_kfgqpc_wbw_ar-en-khattab.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-en-khattab.epub` |
| `quran_hafs_kfgqpc_wbw_ar-en-maududi.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-en-maududi.epub` |
| `quran_hafs_kfgqpc_wbw_ar-en-sahih.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-en-sahih.epub` |
| `quran_hafs_kfgqpc_wbw_ar-es-garcia_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-es-garcia_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-fa-dari.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-fa-dari.epub` |
| `quran_hafs_kfgqpc_wbw_ar-fa-dari_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-fa-dari_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ff-ruwwad_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ff-ruwwad_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-fr-hamidullah_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-fr-hamidullah_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ha-gumi_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ha-gumi_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-hi-umari.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-hi-umari.epub` |
| `quran_hafs_kfgqpc_wbw_ar-hi-umari_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-hi-umari_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-id-ministry.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-id-ministry.epub` |
| `quran_hafs_kfgqpc_wbw_ar-id-ministry_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-id-ministry_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-it-piccardo_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-it-piccardo_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ja-sato_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ja-sato_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-kk-altay_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-kk-altay_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ko-choi_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ko-choi_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ku-bamoki_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ku-bamoki_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ml-hameed_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ml-hameed_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ms-basmeih_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ms-basmeih_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ms-basmeih_idwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ms-basmeih_gloss-id.epub` |
| `quran_hafs_kfgqpc_wbw_ar-nl-siregar_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-nl-siregar_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-no-berg_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-no-berg_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-pl-bielawski_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-pl-bielawski_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ps-abulsalam_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ps-abulsalam_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-pt-nasr_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-pt-nasr_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ru-kuliev_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ru-kuliev_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-so-abduh_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-so-abduh_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-sq-ahmeti_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-sq-ahmeti_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-sv-bernstrom_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-sv-bernstrom_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-sw-barwani_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-sw-barwani_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ta-baqavi.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ta-baqavi.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ta-baqavi_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ta-baqavi_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-tg-mirof_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-tg-mirof_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-th-fahad_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-th-fahad_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-tl-darsalam_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-tl-darsalam_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-tr-diyanet.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-tr-diyanet.epub` |
| `quran_hafs_kfgqpc_wbw_ar-tr-diyanet_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-tr-diyanet_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ug-saleh_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ug-saleh_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-uk-yaqubovic_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-uk-yaqubovic_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ur-jalandhari.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ur-jalandhari.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ur-jalandhari_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ur-jalandhari_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ur-maududi.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ur-maududi.epub` |
| `quran_hafs_kfgqpc_wbw_ar-ur-maududi_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-ur-maududi_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-uz-yusuf_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-uz-yusuf_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-vi-ruwwad_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-vi-ruwwad_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-yo-mikael_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-yo-mikael_gloss-en.epub` |
| `quran_hafs_kfgqpc_wbw_ar-zh-majian_enwbw.epub` | `quran_hafs-uthmani_kfgqpc_word-inline_ar-zh-majian_gloss-en.epub` |
| `quran_warsh_kfgqpc_inline_ar.epub` | `quran_warsh-uthmani_kfgqpc_flow_ar.epub` |

</details>
