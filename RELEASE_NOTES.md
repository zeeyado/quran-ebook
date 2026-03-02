57 EPUB files across 25 languages — bilingual, interactive, and Arabic-only.

### New since v0.3.0

**25 languages** (was 3) — English, French, Turkish, Urdu, Indonesian, Russian, Bengali, Spanish, German, Persian, Malay, Portuguese, Somali, Hausa, Swahili, Bosnian, Chinese, Italian, Hindi, Tamil, Korean, Japanese, Albanian, Pashto, Dutch. Each with bilingual and interactive variants.

**Interactive layout** — new format: Arabic text only, tap any ayah number to see the translation in a popup (KOReader). Per-surah file split (114 XHTML files per EPUB) for faster navigation and progress tracking.

**Calligraphic surah headers** — mushaf-style Arabic calligraphy for all 114 surah names, using the QUL Surah Name V4 ligature font from King Fahd Complex.

**Ornamental basmala** — بسم الله الرحمن الرحيم rendered as a single calligraphic ligature (U+FDFD) via the Quran Common font.

**Font subsetting** — auxiliary fonts stripped to only the glyphs used: Scheherazade New 331 KB → 10 KB, Quran Common 125 KB → 3 KB. Four embedded fonts total: KFGQPC (body text), Scheherazade New (symbols/digits), Quran Common (basmala), Surah Name V4 (headers).

**Build & release automation** — `variants.yaml` manifest drives all 57 builds. Automated versioning from git tags (hatch-vcs). CI caches Quran API data across releases. Every EPUB validated with epubcheck.
