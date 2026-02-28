الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# Quran Ebook

A configurable Quran ebook generator with correct Arabic rendering.

## What This Is

An open-source Python tool that generates valid EPUB3 Quran ebooks from reliable data sources. The key differentiator is **correct script/font pairing** — using the wrong font with certain Quran text encodings produces rendering bugs (broken sukun marks, mangled lam-alif ligatures). This tool handles that automatically via a validated script/font registry.

This program is under development, released so people can try it and also contribute, and the current state is alpha/proof-of-concept with two initial variants. More formats, translations, and qira'at are planned. Feedback and bug reports are welcome.

## Available Ebooks

Pre-built EPUBs will be available from [GitHub Releases](../../releases).

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

Both EPUBs use `font-size: 1em` for Arabic Quran text — no multiplier, so the e-reader's font size slider maps 1:1 to the rendered size. The bilingual EPUB renders the English translation at `0.6em` (smaller than the Arabic, since Latin script is naturally more compact at the same em size). If you find the text too small on first open, increase the font size in your reader's settings — the text will scale cleanly.

## Reader Compatibility

These are standard EPUB3 files and should work in any compliant e-reader. If you encounter issues with a specific reader or device, please [open an issue](../../issues) or [start a discussion](../../discussions).

**Recommended: [KOReader](https://koreader.rocks/)** — open-source, excellent Arabic rendering. Available on Android, Kobo, Kindle (jailbroken), PocketBook, and Linux. This is used for testing.

### KOReader Settings

**Footnote popups** (for the bilingual EPUB):

1. Disable in-page footnotes: Top Menu → Document icon → Style tweaks → In-page Footnotes → uncheck "In-page EPUB footnotes"
2. Enable popup footnotes: Top Menu → Gear icon → Taps and Gestures → Links → check "Show Footnotes in Popup"
3. Optional: check "Allow larger area around links" for easier footnote tapping

**RTL page turns** (swipe left to advance, like a printed mushaf):

The EPUB has `page-progression-direction="rtl"` set, which Kindle, Apple Books, and Kobo respect automatically. KOReader ignores this and needs manual configuration:

1. Top Menu → Gear icon → Taps and Gestures → Page Turns → check **Invert page turn taps and swipes**
2. If your device has physical page-turn buttons: Top Menu → Gear icon → Navigation → Physical Buttons → check **Invert page turn buttons**. This is useful if you read with the buttons in a horizontal (left-right) orientation.

**Madinah Mushaf page numbers** in margins:

1. Top Menu → Bookmark icon (first icon) → Settings → Stable page numbers
2. A circled **P** appears when the publisher has embedded page numbers (these EPUBs do)
3. Check "Use stable page numbers" to use the Mushaf page count in the status bar
4. Check "Show stable page numbers in margin" to see page numbers in the right margin

## Data Sources

- **Arabic text**: [Quran.com API v4](https://quran.com/) — QPC Uthmani Hafs encoding (Riwayat Hafs 'an 'Asim), with Madinah Mushaf (1405 AH / V1) page mapping (604 pages)
- **English translation**: [Quran.com API v4](https://quran.com/) — Sahih International (resource ID 20), including footnotes
- **Primary font**: KFGQPC Uthmanic Script Hafs — from the King Fahd Complex, sourced via [Tarteel CDN](https://qul.tarteel.ai/)
- **Symbol font**: [Scheherazade New](https://software.sil.org/scheherazade/) (SIL International) — used for rub al-hizb markers (۞) and surah header numerals (KFGQPC renders all Arabic-Indic digits as ornate ayah markers)

## Credits

Built on the work of many contributors to the Quranic digital ecosystem, like:

- **[rockneverdies55/quran-epub](https://github.com/rockneverdies55/quran-epub)** — demonstrated the demand for open-source Quran ebooks, but did not release source for any ebook creation tool or update releases to fix errors that were pointed out
- **[bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)** — identified correct script/font pairings and diagnosed rendering bugs
- **[mohd-akram/mushaf](https://github.com/mohd-akram/mushaf)** — clean EPUB3 structure reference
- **[mostafa-khaled775/quran-epub-builder](https://github.com/mostafa-khaled775/quran-epub-builder)** — multi-qiraat approach reference

**Fonts:** Scheherazade New (SIL International, OFL 1.1), KFGQPC Uthmanic Script (King Fahd Complex).

## License

GPL-3.0-or-later

Quran text and translation data sourced from Quran.com API. Font licenses: Scheherazade New (SIL OFL 1.1), KFGQPC Uthmanic Script (use, copy, and distribute permitted; modification not permitted).
