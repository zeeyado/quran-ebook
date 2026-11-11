<!-- v0.11.0 --> <!-- DRAFT: take the word DRAFT out of this line when tagging. The release workflow refuses notes that still carry it. -->

## New file names: read this first

Every book has a new, permanent file name. The name now says what the book is: riwayah and script, font, layout, translation. The old names are gone. `renamed-files.csv` (below) lists the old and the new name of every book.

To keep your highlights and your place in KOReader when you replace a book:

1. In KOReader's file browser, long-press the old book, choose **Rename**, and give it the new name. KOReader moves your data with it. Then copy the new file over it.
2. Or on a computer: rename both `old.epub` and its folder `old.sdr` to the new name, then replace the EPUB.

If you delete the old book and add the new one without one of these, the highlights and the reading position of that book are lost.

## New

- **IndoPak script (Nastaleeq).** The Arabic text alone, with a translation under each ayah in 42 languages, and word by word with English glosses. Page numbers follow a 15-line subcontinent mushaf (610 pages). Beta. (#15)
- **Warsh with translations.** A translation under each ayah in 42 languages. Where Warsh joins or splits ayahs, the translation follows. Beta.
- **Arabic with one ayah per paragraph**, in all three scripts. (#16)
- **Al-Mukhtasar** as a second text under each ayah, in English and in Arabic, and in a popup beside the Sahih International translation. (#5)
- **An OPDS catalog**: browse and download the books inside KOReader. (#10)
- **The word dictionary answers all three scripts.** A long-press on a word in an IndoPak or a Warsh book now finds it too. The dictionary is one of the files of this release (see below); the README says how to install it.
- **269 books** in this release. Every other combination of script, layout and translation builds with one command: see "Build Your Own EPUBs" in the README.

## Fixed

- The Turkish, Hausa and Russian books showed `&quot;` where quotation marks belong.
- Four ayahs arrived damaged from the source and are repaired: German (Bubenheim and Elyas) 26:63 and English (Hilali and Khan) 27:1 were cut off; French (Hamidullah) 42:3 and 42:4 carried a repeated sentence.
- Arabic tafsir text was laid out left to right, so each full stop sat at the wrong end of its line.
- One note in the Maududi translation was cut short, and two were broken across lines.
- Every book now names its own sources in its metadata: where its Quran text, its translation and its fonts come from. Until now each book named one source, which was wrong for the Warsh books and for a few translations.

## Beta: Warsh and IndoPak need your eyes

We read the Hafs text in the Uthmani script and cannot proofread these two ourselves. If you read them, please open an issue when you see wrong or missing marks, an ayah marker in the wrong place or at the start of a line, cramped or loose lines, or clipped letters. They leave beta when readers say they are right.
