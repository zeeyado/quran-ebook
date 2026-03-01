# Compare Quran Scripts & Fonts

A development tool for comparing Quranic script encodings and font renderings side-by-side. Uses the [Quran.com API (v4)](https://quran.api-docs.io/v4) to fetch verse data in all available script fields.

**Originally by [bilalsaci](https://github.com/bilalsaci/compare-quran-scripts-and-fonts).** Copied into this repo and extended with additional fonts (29 total), rasm (consonantal skeleton) conversion, and tajweed CSS rules.

## Running

```bash
cd tools/compare
npm install
npm run dev
```

## What It Shows

- **11 script fields** from the Quran.com API (Uthmani, QPC Hafs, Indopak, Nastaleeq, Imlaei, Tajweed)
- **29 fonts** switchable in real-time (KFGQPC variants, Amiri, Scheherazade, Noto, Kufi, Nastaleeq, etc.)
- **Computed rasm** (dotless consonantal skeleton) from both Uthmani and QPC text
- **Tajweed CSS colors** from alquran.cloud applied to `text_uthmani_tajweed`
- **Basmala comparison** — toggle to see U+FDFD (﷽) ornamental ligature + QPC/Uthmani text rendered in all 29 fonts side-by-side

## Acknowledgements

- **Original tool**: [bilalsaci/compare-quran-scripts-and-fonts](https://github.com/bilalsaci/compare-quran-scripts-and-fonts)
- **Data**: [Quran.com API v4](https://quran.com)
- **Fonts**: CDNs — [Quran Foundation](https://verses.quran.foundation), [fontsource](https://fontsource.org), [fawazahmed0/quran-api](https://github.com/fawazahmed0/quran-api)
- **Rasm mapping**: Derived from [rasmipy](https://github.com/TELOTA/rasmipy) (TELOTA) and [rasmifize](https://github.com/AhmedBaset/rasmifize)
