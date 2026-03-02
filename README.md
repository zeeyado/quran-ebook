<div align="center">

الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# Quran Ebook

</div>


Pre-built Quran EPUBs with correct Arabic rendering, in 25 languages. **[Download the latest release](../../releases/latest)** or see the full [download table](#downloads) below.

## Ebook Types

Each translation is available in two formats:

- **Bilingual** — Arabic and translation shown together, ayah by ayah. Best for studying or reading with a translation side by side.
- **Interactive** — Arabic text only, tap any ayah to see the translation in a popup. Best for reading the Arabic with occasional reference to the translation.

There is also an **Arabic-only** EPUB with no translation — continuous flowing text.

All EPUBs use Riwayat Hafs 'an 'Asim, anchored to the Madinah Mushaf (1405 AH / 604 pages).

## Reader Compatibility

Standard EPUB3 — works in any compliant e-reader. Recommended: **[KOReader](https://koreader.rocks/)** (open-source, excellent Arabic rendering, available on Android, Kobo, Kindle, PocketBook, Linux).

The Arabic text uses embedded fonts for correct rendering. Translation text uses your e-reader's built-in serif font. For non-Latin scripts (Urdu, Bengali, Hindi, etc.), make sure your device has fonts for that script installed. KOReader ships with Noto fonts covering most scripts.

See [KOReader Settings](#koreader-settings) for footnote popups, RTL page turns, and mushaf page numbers.

### Updating EPUBs

Overwrite the old file with the new one, keeping the same filename. KOReader (and most e-readers) store your reading position, highlights, and settings separately — they will be preserved. Do **not** delete the book from within KOReader before replacing.

### KOReader Settings

<details><summary>Footnote popups, RTL page turns, page numbers, and more</summary>

**Footnote popups** (bilingual and interactive EPUBs):

1. Disable in-page footnotes: Top Menu → Document icon → Style tweaks → In-page Footnotes → uncheck "In-page EPUB footnotes"
2. Enable popup footnotes: Top Menu → Gear icon → Taps and Gestures → Links → check "Show Footnotes in Popup"
3. Adjust popup font size: In the same Links menu, change "Popup font size" from "Relative (-2)" to an absolute value (e.g. 16) if the default looks too large
4. Recommended: check "Allow larger area around links" for easier footnote tapping

**RTL page turns** (swipe left to advance, like a printed mushaf):

The EPUBs set `page-progression-direction="rtl"`, which Kindle, Apple Books, and Kobo respect automatically. KOReader needs manual setup:

1. Top Menu → Gear icon → Taps and Gestures → Page Turns → check **Invert page turn taps and swipes**
2. Physical buttons: Top Menu → Gear icon → Navigation → Physical Buttons → check **Invert page turn buttons**

**Hide endnotes from page flow** (bilingual and interactive):

1. Top Menu → Bookmark icon → Settings → Hide non-linear fragments
2. Long-press the setting to make it default for all books

**Mushaf page numbers** in margins and status bar:

1. Top Menu → Bookmark icon → Settings → Stable page numbers
2. Check "Use stable page numbers" for the status bar
3. Check "Show stable page numbers in margin" for the right margin

**Font weight** — if the Arabic looks thin (not small, but lacking weight):

Bottom Menu → Contrast icon → Font weight → increase by 0.5–1

**Margins:**

Bottom Menu → Crop icon → Adjust margins to taste

</details>

## Build Your Own

```bash
pip install -e ".[dev]"
quran-ebook build configs/bilingual/en_sahih.yaml
```

Each YAML file in [`configs/`](configs/) defines one EPUB variant. Configs are organized by type: `arabic/`, `bilingual/`, `interactive/`. Build everything with `quran-ebook build --all configs/`.

## Downloads

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_inline_ar.epub`](../../releases/latest/download/quran_hafs_kfgqpc_inline_ar.epub) | Arabic-only, continuous flowing text |
| [`quran_hafs_kfgqpc_bilin_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-sahih.epub) | Arabic + English (Sahih International), with footnotes |
| [`quran_hafs_kfgqpc_bilin_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-haleem.epub) | Arabic + English (Abdel Haleem) |
| [`quran_hafs_kfgqpc_bilin_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-maududi.epub) | Arabic + English (Maududi / Tafhim), with commentary footnotes |
| [`quran_hafs_kfgqpc_interactive_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-sahih.epub) | Arabic, tap for English (Sahih International) |
| [`quran_hafs_kfgqpc_interactive_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-haleem.epub) | Arabic, tap for English (Abdel Haleem) |
| [`quran_hafs_kfgqpc_interactive_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-maududi.epub) | Arabic, tap for English (Maududi / Tafhim) |

<details><summary>French, Turkish, Urdu, Indonesian, Russian, Bengali, Spanish, German</summary>

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub) | Arabic + Français (Hamidullah) |
| [`quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub) | Arabic, tap for Français (Hamidullah) |
| [`quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub) | Arabic + Türkçe (Diyanet İşleri) |
| [`quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub) | Arabic, tap for Türkçe (Diyanet İşleri) |
| [`quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub) | Arabic + اردو (Jalandhari) |
| [`quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub) | Arabic, tap for اردو (Jalandhari) |
| [`quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub) | Arabic + اردو (Maududi / Tafheem), with commentary footnotes |
| [`quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub) | Arabic, tap for اردو (Maududi / Tafheem) |
| [`quran_hafs_kfgqpc_bilin_ar-id-ministry.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-id-ministry.epub) | Arabic + Bahasa Indonesia (Kementerian Agama) |
| [`quran_hafs_kfgqpc_interactive_ar-id-ministry.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-id-ministry.epub) | Arabic, tap for Bahasa Indonesia (Kementerian Agama) |
| [`quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub) | Arabic + Русский (Kuliev) |
| [`quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub) | Arabic, tap for Русский (Kuliev) |
| [`quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub) | Arabic + বাংলা (Taisirul Quran) |
| [`quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub) | Arabic, tap for বাংলা (Taisirul Quran) |
| [`quran_hafs_kfgqpc_bilin_ar-es-garcia.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-es-garcia.epub) | Arabic + Español (Isa Garcia) |
| [`quran_hafs_kfgqpc_interactive_ar-es-garcia.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-es-garcia.epub) | Arabic, tap for Español (Isa Garcia) |
| [`quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub) | Arabic + Deutsch (Bubenheim & Elyas) |
| [`quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub) | Arabic, tap for Deutsch (Bubenheim & Elyas) |

</details>

<details><summary>Persian, Malay, Portuguese, Somali, Hausa, Swahili, Bosnian, Chinese, Italian, Hindi, Tamil, Korean, Japanese, Albanian, Pashto, Dutch</summary>

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_bilin_ar-fa-dari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-fa-dari.epub) | Arabic + فارسی (Taji Kal Dari) |
| [`quran_hafs_kfgqpc_interactive_ar-fa-dari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-fa-dari.epub) | Arabic, tap for فارسی (Taji Kal Dari) |
| [`quran_hafs_kfgqpc_bilin_ar-ms-basmeih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ms-basmeih.epub) | Arabic + Bahasa Melayu (Basmeih) |
| [`quran_hafs_kfgqpc_interactive_ar-ms-basmeih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ms-basmeih.epub) | Arabic, tap for Bahasa Melayu (Basmeih) |
| [`quran_hafs_kfgqpc_bilin_ar-pt-nasr.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-pt-nasr.epub) | Arabic + Português (Helmi Nasr) |
| [`quran_hafs_kfgqpc_interactive_ar-pt-nasr.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-pt-nasr.epub) | Arabic, tap for Português (Helmi Nasr) |
| [`quran_hafs_kfgqpc_bilin_ar-so-abduh.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-so-abduh.epub) | Arabic + Soomaali (Mahmud Muhammad Abduh) |
| [`quran_hafs_kfgqpc_interactive_ar-so-abduh.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-so-abduh.epub) | Arabic, tap for Soomaali (Mahmud Muhammad Abduh) |
| [`quran_hafs_kfgqpc_bilin_ar-ha-gumi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ha-gumi.epub) | Arabic + Hausa (Abubakar Mahmoud Gumi) |
| [`quran_hafs_kfgqpc_interactive_ar-ha-gumi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ha-gumi.epub) | Arabic, tap for Hausa (Abubakar Mahmoud Gumi) |
| [`quran_hafs_kfgqpc_bilin_ar-sw-barwani.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sw-barwani.epub) | Arabic + Kiswahili (Ali Muhsin Al-Barwani) |
| [`quran_hafs_kfgqpc_interactive_ar-sw-barwani.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sw-barwani.epub) | Arabic, tap for Kiswahili (Ali Muhsin Al-Barwani) |
| [`quran_hafs_kfgqpc_bilin_ar-bs-korkut.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-bs-korkut.epub) | Arabic + Bosanski (Besim Korkut) |
| [`quran_hafs_kfgqpc_interactive_ar-bs-korkut.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-bs-korkut.epub) | Arabic, tap for Bosanski (Besim Korkut) |
| [`quran_hafs_kfgqpc_bilin_ar-zh-majian.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-zh-majian.epub) | Arabic + 中文 (Ma Jian) |
| [`quran_hafs_kfgqpc_interactive_ar-zh-majian.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-zh-majian.epub) | Arabic, tap for 中文 (Ma Jian) |
| [`quran_hafs_kfgqpc_bilin_ar-it-piccardo.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-it-piccardo.epub) | Arabic + Italiano (Piccardo) |
| [`quran_hafs_kfgqpc_interactive_ar-it-piccardo.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-it-piccardo.epub) | Arabic, tap for Italiano (Piccardo) |
| [`quran_hafs_kfgqpc_bilin_ar-hi-umari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-hi-umari.epub) | Arabic + हिन्दी (al-Umari) |
| [`quran_hafs_kfgqpc_interactive_ar-hi-umari.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-hi-umari.epub) | Arabic, tap for हिन्दी (al-Umari) |
| [`quran_hafs_kfgqpc_bilin_ar-ta-baqavi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ta-baqavi.epub) | Arabic + தமிழ் (Baqavi) |
| [`quran_hafs_kfgqpc_interactive_ar-ta-baqavi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ta-baqavi.epub) | Arabic, tap for தமிழ் (Baqavi) |
| [`quran_hafs_kfgqpc_bilin_ar-ko-choi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ko-choi.epub) | Arabic + 한국어 (Hamed Choi) |
| [`quran_hafs_kfgqpc_interactive_ar-ko-choi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ko-choi.epub) | Arabic, tap for 한국어 (Hamed Choi) |
| [`quran_hafs_kfgqpc_bilin_ar-ja-sato.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ja-sato.epub) | Arabic + 日本語 (Saeed Sato) |
| [`quran_hafs_kfgqpc_interactive_ar-ja-sato.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ja-sato.epub) | Arabic, tap for 日本語 (Saeed Sato) |
| [`quran_hafs_kfgqpc_bilin_ar-sq-ahmeti.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sq-ahmeti.epub) | Arabic + Shqip (Sherif Ahmeti) |
| [`quran_hafs_kfgqpc_interactive_ar-sq-ahmeti.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sq-ahmeti.epub) | Arabic, tap for Shqip (Sherif Ahmeti) |
| [`quran_hafs_kfgqpc_bilin_ar-ps-abulsalam.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ps-abulsalam.epub) | Arabic + پښتو (Zakaria Abulsalam) |
| [`quran_hafs_kfgqpc_interactive_ar-ps-abulsalam.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ps-abulsalam.epub) | Arabic, tap for پښتو (Zakaria Abulsalam) |
| [`quran_hafs_kfgqpc_bilin_ar-nl-siregar.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-nl-siregar.epub) | Arabic + Nederlands (Sofian S. Siregar) |
| [`quran_hafs_kfgqpc_interactive_ar-nl-siregar.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-nl-siregar.epub) | Arabic, tap for Nederlands (Sofian S. Siregar) |

</details>

## What This Is

An open-source Python tool that generates valid EPUB3 Quran ebooks from reliable data sources. The key differentiator is **correct script/font pairing** — using the wrong font with certain Quran text encodings produces rendering bugs (e.g. broken sukun marks, mangled lam-alif ligatures). This tool handles that automatically via a validated script/font registry.

Feedback and bug reports welcome. You can open a Feature Request for desired content or formats.

## Data Sources

- **Arabic text**: [Quran.com API v4](https://quran.com/) — QPC Uthmani Hafs encoding (Riwayat Hafs 'an 'Asim), Madinah Mushaf V1 (1405 AH) page mapping
- **Translations**: [Quran.com API v4](https://quran.com/) — 25 languages, 28 translators (see [configs/](configs/) for full list)
- **Primary font**: KFGQPC Uthmanic Script Hafs — King Fahd Complex, via [Tarteel CDN](https://qul.tarteel.ai/)
- **Symbol font**: [Scheherazade New](https://software.sil.org/scheherazade/) (SIL International) — rub al-hizb markers and surah header numerals
- **Basmala font**: [Quran Common](https://qul.tarteel.ai/resources/font/459) (QUL / King Fahd Complex) — ornamental bismillah ligature (U+FDFD)
- **Header font**: [Surah Name V4](https://qul.tarteel.ai/resources/font/457) (QUL / King Fahd Complex) — calligraphic surah name glyphs

## Credits

Built on the work of many contributors to the Quranic digital ecosystem:

- **[rockneverdies55/quran-epub](https://github.com/rockneverdies55/quran-epub)** — demonstrated the demand for open-source Quran ebooks
- **[bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)** — identified correct script/font pairings and diagnosed rendering bugs
- **[mohd-akram/mushaf](https://github.com/mohd-akram/mushaf)** — clean EPUB3 structure reference
- **[mostafa-khaled775/quran-epub-builder](https://github.com/mostafa-khaled775/quran-epub-builder)** — multi-qiraat approach reference

**Fonts:** KFGQPC Uthmanic Script, Quran Common, and Surah Name V4 (King Fahd Complex via [QUL](https://qul.tarteel.ai/)), Scheherazade New ([SIL International](https://software.sil.org/scheherazade/), OFL 1.1).

## License

GPL-3.0

Quran text and translation data sourced from Quran.com API. Font licenses: Scheherazade New (SIL OFL 1.1), KFGQPC Uthmanic Script / Quran Common / Surah Name V4 (King Fahd Complex — use, copy, and distribute permitted; modification not permitted).
