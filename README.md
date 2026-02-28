الحمد لله رب العالمين، والصلاة والسلام على سيدنا محمد خاتم النبيين وإمام المرسلين

# quran-ebook

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

Both include Madina Mushaf page references (604 pages), juz navigation, and surah headers.

## Build Your Own

```bash
pip install -e ".[dev]"

# Arabic-only inline flowing
quran-ebook build configs/arabic_hafs_inline.yaml

# Bilingual Arabic + English
quran-ebook build configs/bilingual_en_sahih.yaml
```

Available configs:

| Config | Script | Font | Translation |
|--------|--------|------|-------------|
| `arabic_hafs.yaml` | QPC Uthmani Hafs | KFGQPC Hafs | — |
| `arabic_hafs_inline.yaml` | QPC Uthmani Hafs | KFGQPC Hafs | — |
| `arabic_uthmani_amiri.yaml` | Standard Uthmani | Amiri Quran | — |
| `bilingual_en_sahih.yaml` | QPC Uthmani Hafs | KFGQPC Hafs | Sahih International |

## Font Size

The CSS uses `font-size: 1em` (i.e., no multiplier) for all Quran text. This means the e-reader's font size slider maps 1:1 to the actual rendered size, giving you full granular control. If you find the text too small on first open, increase the font size in your reader's settings — the text will scale cleanly because it isn't fighting a hidden CSS multiplier.

## Recommended Reader

**[KOReader](https://koreader.rocks/)** — open-source, excellent Arabic rendering. Available on Android, Kobo, Kindle (jailbroken), PocketBook, and Linux.

For the bilingual EPUB with footnotes, configure KOReader to show footnote popups:

1. Disable in-page footnotes: Settings → Document → In-page Footnotes → off
2. Enable popup footnotes: Settings → Taps and Gestures → Links → Show Footnotes in Popup

To display Madina Mushaf page numbers in the margins:

1. Enable stable page numbers: Settings → Document → Page Map → Use reference page numbers
2. Show in margins: Settings → Document → Page Map → Show in margins

## Data Sources

- **[Quran.com API v4](https://quran.com/)** — primary source for Arabic text and translations, 11 script encodings, no auth required
- **[Tanzil.net](https://tanzil.net/)** — fallback source, standard Uthmani text (CC-BY 3.0)

Fonts are sourced from the King Fahd Glorious Quran Printing Complex (KFGQPC) via the [Tarteel/QUL CDN](https://qul.tarteel.ai/).

## Credits

Built on the work of many contributors to the Quranic digital ecosystem:

- **[rockneverdies55/quran-epub](https://github.com/rockneverdies55/quran-epub)** — demonstrated the demand for open-source Quran ebooks, but did not release source for the compiler tool or update releases with demonstrated errors
- **[bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)** — identified correct script/font pairings and diagnosed rendering bugs
- **[mohd-akram/mushaf](https://github.com/mohd-akram/mushaf)** — clean EPUB3 structure reference
- **[mostafa-khaled775/quran-epub-builder](https://github.com/mostafa-khaled775/quran-epub-builder)** — multi-qiraat approach reference

**Fonts:** Amiri Quran (Khaled Hosny, OFL 1.1), Scheherazade New (SIL International, OFL 1.1), KFGQPC Uthmanic Script (King Fahd Complex).

## License

GPL-3.0-or-later

Quran text data: Tanzil.net (CC-BY 3.0), Quran.com API. Font licenses: see individual font entries above. The KFGQPC font permits use, copying, and distribution but not modification.
