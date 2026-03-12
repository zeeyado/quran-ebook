95 EPUB files across 42 languages — bilingual, interactive, and Arabic-only.

### New since v0.6.0

**Cover images** — each EPUB now has a generated PNG cover (1200×1600) with calligraphic glyph and variant label showing riwayah, layout, language, and translator.

**Five-font EPUB** — added Me Quran (subsetted 460→5KB) for surah header labels (ترتيبها / آياتها). Now five embedded fonts: KFGQPC (body) + Scheherazade New (symbols) + quran-common (basmala) + Surah Name V2 (calligraphic headers) + Me Quran (header labels).

**Surah name font upgrade** — switched from V4 to V2 (1421H Madani Mushaf edition) for lighter calligraphic strokes in chapter headers.

**Script-aware translation sizing** — translations in Arabic-script, Thai/Khmer, South Indian, Ethiopic, and Myanmar scripts now render at 0.65em (was 0.6em) for better readability on e-ink.

**Page break control** — `break-inside: avoid` prevents ayahs and translations from splitting across pages.

**Fulfulde (Fula)** — 42nd language added. First language sourced exclusively from fawazahmed0/quran-api.

**Grammar dictionary v1.1** — improved e-ink formatting, RTL i'rab alignment, verb-as-pronoun classification fix.
