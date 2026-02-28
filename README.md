الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# Quran Ebook

A configurable Quran ebook generator with correct Arabic rendering.

## What This Is

An open-source Python tool that generates valid EPUB3 Quran ebooks from reliable data sources. The key differentiator is **correct script/font pairing** — using the wrong font with certain Quran text encodings produces rendering bugs (broken sukun marks, mangled lam-alif ligatures). This tool handles that automatically via a validated script/font registry.

The project is under active development. The current state is alpha/proof-of-concept with two initial variants. More formats, translations, and qira'at are planned once the base is stable. Feedback, bug reports, and requests are welcome.

## Available Ebooks

Pre-built EPUBs are available from [GitHub Releases](../../releases).

| Variant | Description |
|---------|-------------|
| Arabic inline flowing (Hafs) | Continuous flowing text, QPC Uthmani script, KFGQPC font |
| Arabic + English (Hafs, Sahih International) | Ayah-by-ayah with English translation and footnotes |

Both include Madinah Mushaf (1405 AH) page references (604 pages), juz navigation, and surah headers.

## Build Your Own

```bash
pip install -e ".[dev]"

# Arabic-only inline flowing
quran-ebook build configs/arabic_hafs_inline.yaml

# Bilingual Arabic + English
quran-ebook build configs/bilingual_en_sahih.yaml
```

| Config | Description |
|--------|-------------|
| `arabic_hafs_inline.yaml` | Arabic-only, continuous flowing text |
| `bilingual_en_sahih.yaml` | Arabic + English (Sahih International), ayah-by-ayah |

## Font Size

The base font size is `1.4em` to compensate for the KFGQPC font's compact glyph design (it reserves large vertical space for diacritical marks, so the base letter forms render smaller than typical fonts at the same em value). Arabic Quran text is at `1em` relative to this base; the bilingual EPUB renders the English translation at `0.5em`. All sizing is relative, so the e-reader's font size slider scales everything proportionally.

## Reader Compatibility

Standard EPUB3 files — should work in any compliant e-reader. If you encounter issues with a specific reader or device, please [open an issue](../../issues) or [start a discussion](../../discussions).

**Recommended: [KOReader](https://koreader.rocks/)** — open-source, excellent Arabic rendering. Available on Android, Kobo, Kindle (jailbroken), PocketBook, and Linux.

### KOReader Settings

> **Tip:** When updating to a new release of the same variant (e.g. `quran_hafs_kfgqpc_inline_ar.epub`), overwrite the old file with the same filename — settings, highlights, and reading position are preserved because KOReader stores them separately. Do not delete the book from within KOReader first, as that removes this data. This should apply to most other e-reader programs as well.

**Footnote popups** (for the bilingual EPUB):

1. Disable in-page footnotes: Top Menu → Document icon → Style tweaks → In-page Footnotes → uncheck "In-page EPUB footnotes"
2. Enable popup footnotes: Top Menu → Gear icon → Taps and Gestures → Links → check "Show Footnotes in Popup"
3. Adjust popup font size: In the same Links menu, change "Popup font size" from "Relative (-2)" to an absolute value (e.g. 16) if the default looks too large
4. Recommended: check "Allow larger area around links" for easier footnote tapping

**RTL page turns** (swipe left to advance, like a printed mushaf):

The EPUBs have `page-progression-direction="rtl"` set, which Kindle, Apple Books, and Kobo respect automatically. KOReader ignores this and needs manual configuration:

1. Top Menu → Gear icon → Taps and Gestures → Page Turns → check **Invert page turn taps and swipes**
2. If your device has physical page-turn buttons: Top Menu → Gear icon → Navigation → Physical Buttons → check **Invert page turn buttons**. This is useful if you read with the buttons in a horizontal (left-right) orientation.

**Madinah Mushaf page numbers** in side margins:

1. Top Menu → Bookmark icon (first icon) → Settings → Stable page numbers
2. A circled **P** appears when the publisher has embedded page numbers (these EPUBs do)
3. Check "Use stable page numbers" to use the Mushaf page count in the status bar
4. Check "Show stable page numbers in margin" to see page numbers in the right margin

**Adjusting Margins** to control how much of the screen is used:

Bottom Menu → Crop icon (second icon) → Adjust margins as you like:
- set lower margin to 0 to user more of the bottom of the screen
- increase top margin for symmetry
- etc


## Data Sources

- **Arabic text**: [Quran.com API v4](https://quran.com/) — QPC Uthmani Hafs encoding (Riwayat Hafs 'an 'Asim), Madinah Mushaf V1 (1405 AH) page mapping
- **English translation**: [Quran.com API v4](https://quran.com/) — Sahih International (resource ID 20), including footnotes
- **Primary font**: KFGQPC Uthmanic Script Hafs — from the King Fahd Complex, sourced via [Tarteel CDN](https://qul.tarteel.ai/)
- **Symbol font**: [Scheherazade New](https://software.sil.org/scheherazade/) (SIL International) — for rub al-hizb markers (۞) and surah header numerals (KFGQPC renders all Arabic-Indic digits as ornate ayah markers)

## Credits

Built on the work of many contributors to the Quranic digital ecosystem:

- **[rockneverdies55/quran-epub](https://github.com/rockneverdies55/quran-epub)** — demonstrated the demand for open-source Quran ebooks, but did not release source for any ebook creation tool or update releases to fix errors that were pointed out
- **[bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)** — identified correct script/font pairings and diagnosed rendering bugs
- **[mohd-akram/mushaf](https://github.com/mohd-akram/mushaf)** — clean EPUB3 structure reference
- **[mostafa-khaled775/quran-epub-builder](https://github.com/mostafa-khaled775/quran-epub-builder)** — multi-qiraat approach reference

**Fonts:** Scheherazade New (SIL International, OFL 1.1), KFGQPC Uthmanic Script (King Fahd Complex).

## License

GPL-3.0-or-later

Quran text and translation data sourced from Quran.com API. Font licenses: Scheherazade New (SIL OFL 1.1), KFGQPC Uthmanic Script (use, copy, and distribute permitted; modification not permitted).
