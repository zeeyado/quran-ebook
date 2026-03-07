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
3. Adjust popup font size: In the same Links menu, in Footnote popup settings, in "Footnote popup font size", lower the relative font size (e.g. -10) or use an absolute value (e.g. 16) if the default looks too large
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

| Download | Description |
|----------|-------------|
| [`quran_qpc_en_stardict.zip`](../../releases/latest/download/quran_qpc_en_stardict.zip) | KOReader dictionary — English word-by-word with morphology ([details](#dictionary)) |
| [`quran_hafs_kfgqpc_inline_ar.epub`](../../releases/latest/download/quran_hafs_kfgqpc_inline_ar.epub) | Arabic-only, continuous flowing text |
| [`quran_hafs_kfgqpc_bilin_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-sahih.epub) | Arabic + English (Sahih International), with footnotes |
| [`quran_hafs_kfgqpc_bilin_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-haleem.epub) | Arabic + English (Abdel Haleem) |
| [`quran_hafs_kfgqpc_bilin_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-maududi.epub) | Arabic + English (Maududi / Tafhim), with commentary footnotes |
| [`quran_hafs_kfgqpc_bilin_ar-en-khattab.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-khattab.epub) | Arabic + English (Dr. Mustafa Khattab / The Clear Quran) |
| [`quran_hafs_kfgqpc_bilin_ar-en-khattab-fn.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-en-khattab-fn.epub) | Arabic + English (Dr. Mustafa Khattab / The Clear Quran, Annotated), with footnotes |
| [`quran_hafs_kfgqpc_interactive_ar-en-sahih.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-sahih.epub) | Arabic, tap for English (Sahih International) |
| [`quran_hafs_kfgqpc_interactive_ar-en-haleem.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-haleem.epub) | Arabic, tap for English (Abdel Haleem) |
| [`quran_hafs_kfgqpc_interactive_ar-en-maududi.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-maududi.epub) | Arabic, tap for English (Maududi / Tafhim) |
| [`quran_hafs_kfgqpc_interactive_ar-en-khattab.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-khattab.epub) | Arabic, tap for English (Dr. Mustafa Khattab / The Clear Quran) |
| [`quran_hafs_kfgqpc_interactive_ar-en-khattab-fn.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-en-khattab-fn.epub) | Arabic, tap for English (Dr. Mustafa Khattab / The Clear Quran, Annotated) |

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

<details><summary>Persian, Malay, Portuguese, Somali, Hausa, Swahili, Bosnian, Chinese, Italian, Hindi, Tamil, Korean, Japanese, Albanian, Pashto, Dutch, Norwegian, Swedish</summary>

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
| [`quran_hafs_kfgqpc_bilin_ar-no-berg.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-no-berg.epub) | Arabic + Norsk (Einar Berg) |
| [`quran_hafs_kfgqpc_interactive_ar-no-berg.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-no-berg.epub) | Arabic, tap for Norsk (Einar Berg) |
| [`quran_hafs_kfgqpc_bilin_ar-sv-bernstrom.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-sv-bernstrom.epub) | Arabic + Svenska (Knut Bernström) |
| [`quran_hafs_kfgqpc_interactive_ar-sv-bernstrom.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-sv-bernstrom.epub) | Arabic, tap for Svenska (Knut Bernström) |

</details>

<details><summary>Azerbaijani, Uzbek, Tajik, Kazakh, Kurdish, Uyghur, Malayalam, Thai, Vietnamese, Tagalog, Amharic, Yoruba, Polish, Ukrainian</summary>

| Download | Description |
|----------|-------------|
| [`quran_hafs_kfgqpc_bilin_ar-az-musayev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-az-musayev.epub) | Arabic + Azərbaycanca (Alikhan Musayev) |
| [`quran_hafs_kfgqpc_interactive_ar-az-musayev.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-az-musayev.epub) | Arabic, tap for Azərbaycanca (Alikhan Musayev) |
| [`quran_hafs_kfgqpc_bilin_ar-uz-yusuf.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-uz-yusuf.epub) | Arabic + Oʻzbekcha (Muhammad Sodiq Muhammad Yusuf) |
| [`quran_hafs_kfgqpc_interactive_ar-uz-yusuf.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-uz-yusuf.epub) | Arabic, tap for Oʻzbekcha (Muhammad Sodiq Muhammad Yusuf) |
| [`quran_hafs_kfgqpc_bilin_ar-tg-mirof.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tg-mirof.epub) | Arabic + Тоҷикӣ (Khawaja Mirof & Khawaja Mir) |
| [`quran_hafs_kfgqpc_interactive_ar-tg-mirof.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tg-mirof.epub) | Arabic, tap for Тоҷикӣ (Khawaja Mirof & Khawaja Mir) |
| [`quran_hafs_kfgqpc_bilin_ar-kk-altay.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-kk-altay.epub) | Arabic + Қазақша (Khalifa Altay) |
| [`quran_hafs_kfgqpc_interactive_ar-kk-altay.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-kk-altay.epub) | Arabic, tap for Қазақша (Khalifa Altay) |
| [`quran_hafs_kfgqpc_bilin_ar-ku-bamoki.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ku-bamoki.epub) | Arabic + کوردی (Muhammad Saleh Bamoki) |
| [`quran_hafs_kfgqpc_interactive_ar-ku-bamoki.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ku-bamoki.epub) | Arabic, tap for کوردی (Muhammad Saleh Bamoki) |
| [`quran_hafs_kfgqpc_bilin_ar-ug-saleh.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ug-saleh.epub) | Arabic + ئۇيغۇرچە (Muhammad Saleh) |
| [`quran_hafs_kfgqpc_interactive_ar-ug-saleh.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ug-saleh.epub) | Arabic, tap for ئۇيغۇرچە (Muhammad Saleh) |
| [`quran_hafs_kfgqpc_bilin_ar-ml-hameed.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-ml-hameed.epub) | Arabic + മലയാളം (Abdul Hameed & Kunhi Mohammed) |
| [`quran_hafs_kfgqpc_interactive_ar-ml-hameed.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-ml-hameed.epub) | Arabic, tap for മലയാളം (Abdul Hameed & Kunhi Mohammed) |
| [`quran_hafs_kfgqpc_bilin_ar-th-fahad.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-th-fahad.epub) | Arabic + ไทย (King Fahad Quran Complex) |
| [`quran_hafs_kfgqpc_interactive_ar-th-fahad.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-th-fahad.epub) | Arabic, tap for ไทย (King Fahad Quran Complex) |
| [`quran_hafs_kfgqpc_bilin_ar-vi-ruwwad.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-vi-ruwwad.epub) | Arabic + Tiếng Việt (Ruwwad Center) |
| [`quran_hafs_kfgqpc_interactive_ar-vi-ruwwad.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-vi-ruwwad.epub) | Arabic, tap for Tiếng Việt (Ruwwad Center) |
| [`quran_hafs_kfgqpc_bilin_ar-tl-darsalam.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-tl-darsalam.epub) | Arabic + Filipino (Dar Al-Salam Center) |
| [`quran_hafs_kfgqpc_interactive_ar-tl-darsalam.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-tl-darsalam.epub) | Arabic, tap for Filipino (Dar Al-Salam Center) |
| [`quran_hafs_kfgqpc_bilin_ar-am-sadiq.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-am-sadiq.epub) | Arabic + አማርኛ (Sadiq and Sani) |
| [`quran_hafs_kfgqpc_interactive_ar-am-sadiq.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-am-sadiq.epub) | Arabic, tap for አማርኛ (Sadiq and Sani) |
| [`quran_hafs_kfgqpc_bilin_ar-yo-mikael.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-yo-mikael.epub) | Arabic + Yorùbá (Shaykh Abu Rahimah Mikael Aykyuni) |
| [`quran_hafs_kfgqpc_interactive_ar-yo-mikael.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-yo-mikael.epub) | Arabic, tap for Yorùbá (Shaykh Abu Rahimah Mikael Aykyuni) |
| [`quran_hafs_kfgqpc_bilin_ar-pl-bielawski.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-pl-bielawski.epub) | Arabic + Polski (Józef Bielawski) |
| [`quran_hafs_kfgqpc_interactive_ar-pl-bielawski.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-pl-bielawski.epub) | Arabic, tap for Polski (Józef Bielawski) |
| [`quran_hafs_kfgqpc_bilin_ar-uk-yaqubovic.epub`](../../releases/latest/download/quran_hafs_kfgqpc_bilin_ar-uk-yaqubovic.epub) | Arabic + Українська (Dr. Mikhailo Yaqubovic) |
| [`quran_hafs_kfgqpc_interactive_ar-uk-yaqubovic.epub`](../../releases/latest/download/quran_hafs_kfgqpc_interactive_ar-uk-yaqubovic.epub) | Arabic, tap for Українська (Dr. Mikhailo Yaqubovic) |

</details>

## Dictionary

Optional English word-by-word StarDict dictionary for KOReader. Long-press any word while reading to see its translation, transliteration, morphological analysis (root, lemma, part of speech), and Lane's Lexicon root definition. 22,000+ entries. Work in progress.

Headwords use QPC Uthmani Hafs encoding — the same script as the EPUBs above. Other Quran text encodings will not match.

**Install:** Unzip `quran_qpc_en_stardict.zip` into KOReader's `data/dict/` folder. The dictionary will appear automatically in KOReader's dictionary lookup.

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
