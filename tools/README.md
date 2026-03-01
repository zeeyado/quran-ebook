# Tools

Development and build tools for the Quran Ebook project.

## [compare/](compare/) — Script & Font Comparison

Interactive React app for comparing how 29 Arabic fonts render 11 Quran.com script encodings side-by-side. Includes rasm conversion, tajweed CSS, and a basmala font comparison view.

```bash
cd tools/compare && npm install && npm run dev
```

## [build_dictionary.py](build_dictionary.py) — Enhanced StarDict Dictionary

Builds a Quran word-by-word StarDict dictionary for KOReader from three data sources:

- **Quran.com API** — QPC Uthmani Hafs word text (headwords), English translations, Latin transliterations
- **mustafa0x/quran-morphology** — root, lemma, POS, verb form (130K morphemes, GPL-3.0)
- **aliozdenisik/quran-arabic-roots-lane-lexicon** — Lane's Lexicon root definitions (1,651 roots)

### Output

22,163 entries (19,497 canonical + 2,666 pause mark variants). Each entry includes:

- Deduplicated English translations across all Quranic occurrences
- Latin transliteration
- Morphological analysis (part of speech, verb form, lemma, root)
- Lane's Lexicon root definition summary
- Verse references with occurrence count

### Usage

```bash
# Prerequisites: download morphology data and Lane's Lexicon (cached)
python tools/build_dictionary.py

# Output: output/dictionary/quran_qpc_en.{dict,idx,ifo}
# Copy all three files to your KOReader dictionaries folder
```

### KOReader Installation

| Platform | Dictionary path |
|---|---|
| Kobo | `.adds/koreader/data/dict/` |
| Kindle | `koreader/data/dict/` |
| Android | `/sdcard/koreader/data/dict/` |
| Linux | `~/.config/koreader/data/dict/` |

After copying, long-press any Arabic word in the Quran EPUB to look it up. Tap the dictionary name in the popup to set it as the default for the book.
