<div align="center">

الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# Quran Ebook

</div>


Pre-built and reproducible Quran EPUBs with correct Arabic rendering, in 41 languages. **[Download from the latest release](../../releases/latest)** or see the full **[download table](#downloads)** below. Best used in **[KOReader](https://koreader.rocks/)**. See [KOReader Settings](#koreader-settings) for ***essential*** setup. Offline [dictionary](#dictionary) also available.

This tool uses validated script/font pairing to avoid the rendering bugs (broken sukun marks, mangled ligatures) common in other Quran EPUBs. Feedback and bug reports welcome — open a Feature Request for desired content or formats.

## Ebook Types

Each translation is available in two formats:

- **Bilingual** — Arabic and translation shown together, ayah by ayah. Best for studying or reading with a translation side by side.
- **Interactive** — Arabic text only, tap any ayah to see the translation in a footnote popup. Best for reading the Arabic with occasional reference to the translation.

There is also an **Arabic-only** EPUB with no translation — continuous flowing text. It is identical to the interactive version in visual layout.

Currently, all EPUBs use Riwayat Hafs 'an 'Asim, anchored to the Madinah Mushaf (1405 AH / 604 pages). More Riwayat coming إن شاء الله

## Reader Compatibility

These EPUBs use embedded Arabic fonts and EPUB3 features that most proprietary e-reader software does not handle well. In those cases, **[KOReader](https://koreader.rocks/)** is highly recommended — open-source, excellent Arabic rendering, runs on Android, Kobo, Kindle, PocketBook, and Linux.

See [KOReader Settings](#koreader-settings) for essential setup — footnote popups, word gap, font weight, RTL page turns, mushaf page numbers, and more.

- **Kobo:** Native reader struggles with Arabic. Install KOReader — no jailbreak needed.
- **Kindle:** Stock Kindle does not render Arabic EPUBs correctly. Requires [jailbreaking](https://kindlemodding.org/jailbreaking/) + KOReader.
- **Other e-readers:** Proprietary readers will likely have rendering errors. Use KOReader where possible.
- **Apple Books:** Mostly works well on iOS and macOS, no changes needed.
- **Android e-readers:** Here you have many options that may work fine in additon to KOReader.
- **Windows/Mac/Linux**: You can also use the Calibre ereader, which mostly works fine.

NB: Translation text uses your e-reader's built-in serif font. For non-Latin scripts (Urdu, Bengali, Hindi, etc.), make sure your device has fonts for that script installed. KOReader ships with Noto fonts covering most scripts. The Quranic fonts are embedded in the EPUB itself.

### Updating EPUBs

Overwrite the old file with the new one, keeping the same filename. KOReader (and most e-readers) store your reading position, highlights, and settings separately — they will be preserved. Do **not** delete the book from within KOReader before replacing, as this will delete your data. 

### KOReader Settings
Essential Settings for a good reading experience. Footnote popups, RTL page turns, page numbers, and more

<details><summary> (Click to expand/collapse) </summary>
  
### **Important: Footnote popups** 
Bilingual and interactive EPUBs — KOReader shows footnotes inline (on the page) by default, which breaks the layout of most EPUBs in this collection. Enable popups instead:

1. Disable in-page footnotes: Top Menu → Document icon → Style tweaks → In-page Footnotes → uncheck "In-page EPUB footnotes" (hold to disable for all books)
2. Enable popup footnotes: Top Menu → Gear icon → Taps and Gestures → Links → check "Show Footnotes in Popup"
3. Adjust popup font size: In the same Links menu, in Footnote popup settings, in "Footnote popup font size", lower the relative font size (e.g. -10) or use an absolute value (e.g. 16) if the default looks too large (because it is set relative to 1em, while the translation itself has been set lower)
4. Tip: check "Allow larger area around links" for easier footnote tapping

### **Word spacing** 
Makes justified full page content look denser and better (Interactive and Monolungual EPUBS):

Bottom Menu → Letter icon → Word Spacing → Small (recommended), or Dot Menu → Change Scaling and Reduction for even denser appearance

### **Font weight** 
KOReader does not add wight by default. If the Arabic looks thin (not small, but lacking weight):

Bottom Menu → Contrast icon → Font weight → increase by 0.5–1. 0-0.5 is recommended.

### **Hide endnotes from page flow** 
Bilingual and interactive — without this, the endnotes section appears as regular pages at the end of the book:

1. Top Menu → Bookmark icon → Settings → Hide non-linear fragments
2. Long-press the setting (after enabling it) to make it default for all books

### **Mushaf page numbers** 
Shows the traditional 604-page Madinah Mushaf pagination in margins and/or status bar:

1. Top Menu → Bookmark icon → Settings → Stable page numbers
2. Check "Use stable page numbers" for the status bar
3. Check "Show stable page numbers in margin" for the right margin
4. Default settings for new books → Pick the same settings as you picked above for Use stable page number and Show stable page numbers

### **RTL page turns** 
KOReader does not auto-detect RTL page direction from the EPUB. Without this, swiping goes the wrong way:

1. Top Menu → Gear icon → Taps and Gestures → Page Turns → check **Invert page turn taps and swipes**
2. Physical buttons: Top Menu → Gear icon → Navigation → Physical Buttons → check **Invert page turn buttons**

### **Line heights:**

Top Menu → Document icon → Style tweaks → Text → Line heights

Here you can override the EPUB's line heights to your liking

### **Margins:**

Bottom Menu → Crop icon → Adjust margins to taste

</details>

## Build Your Own

```bash
pip install -e ".[dev]"
quran-ebook build configs/bilingual/en_sahih.yaml
```

Each YAML file in [`configs/`](configs/) defines one EPUB variant. Configs are organized by type: `arabic/`, `bilingual/`, `interactive/`. Build everything with `quran-ebook build --all configs/`.

PRs or FRs are welcome.

## Downloads

| | |
|---|---|
| [Dictionary zip](release/) | KOReader word-by-word dictionary ([details](#dictionary)) |
| [Arabic-only epub](../../releases/latest/download/quran_hafs_kfgqpc_inline_ar.epub) | Continuous flowing text, no translation |

### English

| Translator | Bilingual | Interactive |
|-----------|:---------:|:-----------:|
| Sahih International | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-sahih.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-sahih.epub) |
| Abdel Haleem | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-haleem.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-haleem.epub) |
| Maududi / Tafhim ^fn^ | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-maududi.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-maududi.epub) |
| Dr. Mustafa Khattab / The Clear Quran | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-khattab.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-khattab.epub) |
| Dr. Mustafa Khattab / The Clear Quran ^fn^ | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-khattab-fn.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-khattab-fn.epub) |

<details><summary>Français, Deutsch, Español, Türkçe, اردو — Urdu, Bahasa Indonesia, Русский, বাংলা — Bengali</summary>

| Language | Translator | Bilingual | Interactive |
|----------|-----------|:---------:|:-----------:|
| Français | Hamidullah | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-fr-hamidullah.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-fr-hamidullah.epub) |
| Deutsch | Bubenheim & Elyas | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-de-bubenheim.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-de-bubenheim.epub) |
| Español | Isa Garcia | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-es-garcia.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-es-garcia.epub) |
| Türkçe | Diyanet İşleri | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tr-diyanet.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tr-diyanet.epub) |
| اردو — Urdu | Jalandhari | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-jalandhari.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-jalandhari.epub) |
| اردو — Urdu | Maududi / Tafheem ^fn^ | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ur-maududi.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ur-maududi.epub) |
| Bahasa Indonesia | Kementerian Agama | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-id-ministry.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-id-ministry.epub) |
| Русский | Kuliev | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ru-kuliev.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ru-kuliev.epub) |
| বাংলা — Bengali | Taisirul Quran | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-bn-taisirul.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-bn-taisirul.epub) |

</details>

<details><summary>فارسی — Persian, Bahasa Melayu, Português, Italiano, Nederlands, Norsk, Svenska, Bosanski, Soomaali, Hausa, Kiswahili</summary>

| Language | Translator | Bilingual | Interactive |
|----------|-----------|:---------:|:-----------:|
| فارسی — Persian | Taji Kal Dari | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-fa-dari.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-fa-dari.epub) |
| Bahasa Melayu | Basmeih | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ms-basmeih.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ms-basmeih.epub) |
| Português | Helmi Nasr | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-pt-nasr.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-pt-nasr.epub) |
| Italiano | Piccardo | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-it-piccardo.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-it-piccardo.epub) |
| Nederlands | Sofian S. Siregar | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-nl-siregar.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-nl-siregar.epub) |
| Norsk | Einar Berg | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-no-berg.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-no-berg.epub) |
| Svenska | Knut Bernström | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sv-bernstrom.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sv-bernstrom.epub) |
| Bosanski | Besim Korkut | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-bs-korkut.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-bs-korkut.epub) |
| Soomaali | Mahmud Muhammad Abduh | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-so-abduh.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-so-abduh.epub) |
| Hausa | Abubakar Mahmoud Gumi | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ha-gumi.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ha-gumi.epub) |
| Kiswahili | Ali Muhsin Al-Barwani | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sw-barwani.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sw-barwani.epub) |

</details>

<details><summary>हिन्दी — Hindi, தமிழ் — Tamil, മലയാളം — Malayalam, پښتو — Pashto, کوردی — Kurdish, ئۇيغۇرچە — Uyghur, 中文, 한국어, 日本語, ไทย, Tiếng Việt, Filipino</summary>

| Language | Translator | Bilingual | Interactive |
|----------|-----------|:---------:|:-----------:|
| हिन्दी — Hindi | al-Umari | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-hi-umari.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-hi-umari.epub) |
| தமிழ் — Tamil | Baqavi | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ta-baqavi.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ta-baqavi.epub) |
| മലയാളം — Malayalam | Abdul Hameed & Kunhi Mohammed | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ml-hameed.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ml-hameed.epub) |
| پښتو — Pashto | Zakaria Abulsalam | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ps-abulsalam.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ps-abulsalam.epub) |
| کوردی — Kurdish | Muhammad Saleh Bamoki | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ku-bamoki.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ku-bamoki.epub) |
| ئۇيغۇرچە — Uyghur | Muhammad Saleh | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ug-saleh.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ug-saleh.epub) |
| 中文 — Chinese | Ma Jian | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-zh-majian.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-zh-majian.epub) |
| 한국어 — Korean | Hamed Choi | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ko-choi.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ko-choi.epub) |
| 日本語 — Japanese | Saeed Sato | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ja-sato.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ja-sato.epub) |
| ไทย — Thai | King Fahad Quran Complex | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-th-fahad.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-th-fahad.epub) |
| Tiếng Việt | Ruwwad Center | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-vi-ruwwad.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-vi-ruwwad.epub) |
| Filipino | Dar Al-Salam Center | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tl-darsalam.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tl-darsalam.epub) |

</details>

<details><summary>Azərbaycanca, Oʻzbekcha, Тоҷикӣ — Tajik, Қазақша — Kazakh, Shqip — Albanian, Polski, Українська — Ukrainian, አማርኛ — Amharic, Yorùbá</summary>

| Language | Translator | Bilingual | Interactive |
|----------|-----------|:---------:|:-----------:|
| Azərbaycanca | Alikhan Musayev | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-az-musayev.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-az-musayev.epub) |
| Oʻzbekcha | Muhammad Sodiq Muhammad Yusuf | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-uz-yusuf.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-uz-yusuf.epub) |
| Тоҷикӣ — Tajik | Khawaja Mirof & Khawaja Mir | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tg-mirof.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tg-mirof.epub) |
| Қазақша — Kazakh | Khalifa Altay | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-kk-altay.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-kk-altay.epub) |
| Shqip — Albanian | Sherif Ahmeti | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sq-ahmeti.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sq-ahmeti.epub) |
| Polski | Józef Bielawski | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-pl-bielawski.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-pl-bielawski.epub) |
| Українська — Ukrainian | Dr. Mikhailo Yaqubovic | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-uk-yaqubovic.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-uk-yaqubovic.epub) |
| አማርኛ — Amharic | Sadiq and Sani | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-am-sadiq.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-am-sadiq.epub) |
| Yorùbá | Shaykh Abu Rahimah Mikael Aykyuni | [epub](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-yo-mikael.epub) | [epub](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-yo-mikael.epub) |

</details>

^fn^ = includes footnotes

## Dictionary

Optional English word-by-word StarDict dictionary for KOReader. Long-press any Quranic word while reading to see:

- **Translation** — English word meaning (from Quran.com word-by-word data)
- **Transliteration** — Latin script pronunciation
- **Morphology** — part of speech (Arabic + English), grammatical case/mood, gender/number/person, verb form and pattern (wazn)
- **Lemma and root** — dictionary form and Arabic root letters
- **Root definition** — Lane's Lexicon summary for the root

22,000+ entries covering every word in the Quran. Headwords use QPC Uthmani Hafs encoding — the same script as the EPUBs above. Other Quran text encodings will not match.

**Install:** Download the dictionary zip from [`release/`](release/), unzip into KOReader's `data/dict/` folder. The dictionary will appear automatically in KOReader's dictionary lookup.

**Build your own:** `python tools/build_dictionary.py` (requires cached data from Quran.com API, morphology corpus, and Lane's Lexicon — see script for details).

## Data Sources

- **Arabic text**: [Quran.com API v4](https://quran.com/) — QPC Uthmani Hafs encoding (Riwayat Hafs 'an 'Asim), Madinah Mushaf V1 (1405 AH) page mapping
- **Translations**: [Quran.com API v4](https://quran.com/) + [fawazahmed0/quran-api](https://github.com/fawazahmed0/quran-api) — 41 languages, 45 translators (see [configs/](configs/) for full list)
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
