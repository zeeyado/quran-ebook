الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# Quran Ebook

A configurable Quran ebook generator with correct Arabic rendering.

## What This Is

An open-source Python tool that generates valid EPUB3 Quran ebooks from reliable data sources. The key differentiator is **correct script/font pairing** — using the wrong font with certain Quran text encodings produces rendering bugs (e.g. broken sukun marks, mangled lam-alif ligatures, etc.). This tool handles that automatically via a validated script/font registry.

The project is under active development. More formats, translations, and qira'at are planned. Feedback and bug reports are welcome. 

## Available Ebooks

Pre-built EPUBs are available from [GitHub Releases](../../releases). See the full [download table](#downloads) below, or go straight to the [latest release](../../releases/latest). See [Updating EPUBs](#updating-epubs) to preserve your reading position and highlights.

**Current status** — Arabic-only, bilingual (ayah-by-ayah), and interactive (press ayah to see translation) EPUBs in 9 languages. Riwayat Hafs 'an 'Asim, anchored to the Madinah Mushaf (1405 AH / 604 pages).

**In progress** — Warsh, more riwayat, more languages, and additional translations.

You can open a Feature Request to request desired content/formats, even very detailed or specific things.

## Build Your Own

```bash
pip install -e ".[dev]"
quran-ebook build configs/bilingual/en_sahih.yaml
```

Each YAML file in [`configs/`](configs/) defines one EPUB variant (script, font, layout, translation). Configs are organized by type: `arabic/`, `bilingual/`, `interactive/`. Pass any config to `quran-ebook build`, or build everything with `quran-ebook build --all configs/`.

## Font Size

The base font size is `1.4em` to compensate for the KFGQPC font's compact glyph design (it reserves large vertical space for diacritical marks, so the base letter forms render smaller than typical fonts at the same em value). Arabic Quran text is at `1em` relative to this base; the bilingual and interactive EPUBs render the translation at `0.5em`. All sizing is relative, so the e-reader's font size slider scales everything proportionally.

## Reader Compatibility

Standard EPUB3 files — should work in any compliant e-reader. If you encounter issues with a specific reader or device, please [open an issue](../../issues) or [start a discussion](../../discussions).

**Recommended: [KOReader](https://koreader.rocks/)** — open-source, excellent Arabic rendering. Available on Android, Kobo, Kindle (jailbroken), PocketBook, Linux, and more.

**Translation fonts:** The Arabic Quran text uses embedded fonts for guaranteed correct rendering. Translation text uses the e-reader's built-in serif font — this works well for Latin-script languages (English, French, etc.) out of the box. For non-Latin translations (Urdu, Bengali, Russian), make sure your device has fonts for those scripts installed. KOReader ships with Noto fonts that cover most scripts.

### Updating EPUBs

When a new release is available, simply overwrite the old file on your device with the new one, keeping the same filename. Your reading position, highlights, and settings are preserved — KOReader (and most other e-reader apps) store this data separately from the book file itself.

Do **not** delete the book from within KOReader before replacing the file, as that removes your saved data along with it.

### KOReader Settings

**Footnote popups** (for bilingual and interactive EPUBs):

1. Disable in-page footnotes: Top Menu → Document icon → Style tweaks → In-page Footnotes → uncheck "In-page EPUB footnotes"
2. Enable popup footnotes: Top Menu → Gear icon → Taps and Gestures → Links → check "Show Footnotes in Popup"
3. Adjust popup font size: In the same Links menu, change "Popup font size" from "Relative (-2)" to an absolute value (e.g. 16) if the default looks too large
4. Recommended: check "Allow larger area around links" for easier footnote tapping

**RTL page turns** (swipe left to advance, like a printed mushaf):

The EPUBs have `page-progression-direction="rtl"` set, which Kindle, Apple Books, and Kobo respect automatically. KOReader ignores this and needs manual configuration:

1. Top Menu → Gear icon → Taps and Gestures → Page Turns → check **Invert page turn taps and swipes**
2. If your device has physical page-turn buttons: Top Menu → Gear icon → Navigation → Physical Buttons → check **Invert page turn buttons** if you read with the buttons in a horizontal (left-right) orientation.

**Hide endnotes from page flow** (for EPUBs with translations/footnotes):

The bilingual and interactive EPUBs mark endnotes as non-linear, but KOReader shows them by default. To hide them so they're only accessible through the footnote links:

1. Top Menu → Bookmark icon (first icon) → Settings → Hide non-linear fragments
2. Long-press the setting (after enabling) to make it your default for all books

**Mushaf page numbers** in side margins and/or status bar:

1. Top Menu → Bookmark icon (first icon) → Settings → Stable page numbers
2. A circled **P** appears when the publisher has embedded page numbers (these EPUBs do)
3. Check "Use stable page numbers" to use the Mushaf page count in the status bar
4. Check "Show stable page numbers in margin" to see page numbers in the right margin

**Font weight** — if the Arabic text looks light or thin (not small, but lacking weight):

KOReader renders fonts without any synthetic boldening, so text can appear thinner than in other e-reader apps. To add weight:

Bottom Menu → Contrast icon → Font weight → increase by 0.5–1

This doesn't change the font size — it thickens the strokes for better readability.

**Adjusting Margins** to control how much of the screen is used:

Bottom Menu → Crop icon (second icon) → Adjust margins as you like:
- set lower margin to 0 to use more of the bottom of the screen
- increase top margin for symmetry
- etc


## Data Sources

- **Arabic text**: [Quran.com API v4](https://quran.com/) — QPC Uthmani Hafs encoding (Riwayat Hafs 'an 'Asim), Madinah Mushaf V1 (1405 AH) page mapping
- **Translations**: [Quran.com API v4](https://quran.com/) — English (Sahih International, Abdel Haleem, Maududi), French (Hamidullah), Turkish (Diyanet İşleri), Urdu (Jalandhari, Maududi/Tafheem), Indonesian (Kementerian Agama), Russian (Kuliev), Bengali (Taisirul Quran), Spanish (Isa Garcia), German (Bubenheim & Elyas)
- **Primary font**: KFGQPC Uthmanic Script Hafs — from the King Fahd Complex, sourced via [Tarteel CDN](https://qul.tarteel.ai/)
- **Symbol font**: [Scheherazade New](https://software.sil.org/scheherazade/) (SIL International) — for rub al-hizb markers (۞) and surah header numerals (KFGQPC renders all Arabic-Indic digits as ornate ayah markers)

## Credits

Built on the work of many contributors to the Quranic digital ecosystem:

- **[rockneverdies55/quran-epub](https://github.com/rockneverdies55/quran-epub)** — demonstrated the demand for open-source Quran ebooks, but did not release source for any ebook creation tool or update releases to fix errors that were pointed out
- **[bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)** — identified correct script/font pairings and diagnosed rendering bugs
- **[mohd-akram/mushaf](https://github.com/mohd-akram/mushaf)** — clean EPUB3 structure reference
- **[mostafa-khaled775/quran-epub-builder](https://github.com/mostafa-khaled775/quran-epub-builder)** — multi-qiraat approach reference

**Fonts:** Scheherazade New (SIL International, OFL 1.1), KFGQPC Uthmanic Script (King Fahd Complex).

## Downloads

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_inline_ar.epub`](../../releases/latest/download/quran_hafs_kfgqpc_inline_ar.epub) | Arabic-only, continuous flowing text (Hafs) |
| [`quran_hafs_kfgqpc_bilin_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-sahih.epub) | Arabic + English (Sahih International), ayah-by-ayah with footnotes |
| [`quran_hafs_kfgqpc_bilin_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-haleem.epub) | Arabic + English (Abdel Haleem), ayah-by-ayah |
| [`quran_hafs_kfgqpc_bilin_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-maududi.epub) | Arabic + English (Maududi / Tafhim ul-Quran), with commentary footnotes |
| [`quran_hafs_kfgqpc_interactive_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-sahih.epub) | Arabic + English (Sahih International), tap ayah for translation |
| [`quran_hafs_kfgqpc_interactive_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-haleem.epub) | Arabic + English (Abdel Haleem), tap ayah for translation |
| [`quran_hafs_kfgqpc_interactive_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-maududi.epub) | Arabic + English (Maududi / Tafhim), tap ayah for translation |

<details><summary>More languages (French, Turkish, Urdu, Indonesian, Russian, Bengali, Spanish, German)</summary>

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub) | Arabic + Français (Hamidullah) |
| [`quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub) | Arabic + Français (Hamidullah), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub) | Arabic + Türkçe (Diyanet İşleri) |
| [`quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub) | Arabic + Türkçe (Diyanet İşleri), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub) | Arabic + اردو (Jalandhari) |
| [`quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub) | Arabic + اردو (Jalandhari), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub) | Arabic + اردو (Maududi / Tafheem-ul-Quran), with commentary footnotes |
| [`quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub) | Arabic + اردو (Maududi / Tafheem), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-id-ministry.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-id-ministry.epub) | Arabic + Bahasa Indonesia (Kementerian Agama) |
| [`quran_hafs_kfgqpc_interactive_ar-id-ministry.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-id-ministry.epub) | Arabic + Bahasa Indonesia (Kementerian Agama), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub) | Arabic + Русский (Kuliev) |
| [`quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub) | Arabic + Русский (Kuliev), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub) | Arabic + বাংলা (Taisirul Quran) |
| [`quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub) | Arabic + বাংলা (Taisirul Quran), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-es-garcia.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-es-garcia.epub) | Arabic + Español (Isa Garcia) |
| [`quran_hafs_kfgqpc_interactive_ar-es-garcia.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-es-garcia.epub) | Arabic + Español (Isa Garcia), tap ayah for translation |
| [`quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub) | Arabic + Deutsch (Bubenheim & Elyas) |
| [`quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub) | Arabic + Deutsch (Bubenheim & Elyas), tap ayah for translation |

</details>

## License

GPL-3.0

Quran text and translation data sourced from Quran.com API. Font licenses: Scheherazade New (SIL OFL 1.1), KFGQPC Uthmanic Script (use, copy, and distribute permitted; modification not permitted).
