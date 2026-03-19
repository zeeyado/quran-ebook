151 EPUB files across 42 languages — bilingual, interactive, word-by-word, and Arabic-only.

### New since v0.9.0

**Translation font fix** — translation and Latin text no longer inherits the Quranic body font (KFGQPC). Elements now use `font-family: initial`, so the reader's configured font is used for non-Arabic text instead of partially matching KFGQPC glyphs with mixed-weight fallback.

**Data cleanup** — fixed upstream data corruption in some translations (e.g. Maududi English) where replacement characters (U+FFFD) appeared instead of em-dashes. Suppressed duplicate surah name translations where the API returned a transliteration identical to the surah name (e.g. "Al-A'raf" for Al-A'raf).

**Spacing and typography** — tightened surah header padding and basmala line-height for a more compact layout. Unified cover separator to middle dot (·) across all languages, and went back to the classic surah header glyphs.

**KOReader plugin v1.6** — the plugin now detects whether the current book is a Quran EPUB (via dc:subject metadata or juz TOC entries) and skips juz/surah status bar injection for non-Quran books.

KOReader addons: [plugin](../../#install) · [word dictionary](../../#dictionary) · [grammar & i'rab](../../#grammar-dictionary-lookup) · [tafsir](../../#tafsir-commentary-lookup) · [surah overview](../../#surah-overview-lookup) · [setup tips](../../#koreader-settings)
