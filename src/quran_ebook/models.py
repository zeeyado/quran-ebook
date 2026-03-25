"""Data models for Quran text."""

from pydantic import BaseModel


class Footnote(BaseModel):
    """A footnote attached to a translation."""

    id: int
    number: int  # Display number within the verse
    text: str


class Word(BaseModel):
    """A single word from the Quran with word-level translation/transliteration."""

    position: int
    text: str  # Arabic text (same encoding as ayah text)
    translation: str = ""  # Word-level gloss (e.g. "In (the) name")
    transliteration: str = ""  # Romanized pronunciation (e.g. "bis'mi")
    code_v2: str = ""  # QCF V2/V4 glyph code (for per-page glyph fonts)
    page_number: int | None = None  # Mushaf page (for QCF per-page font selection)
    line_number: int | None = None  # Mushaf line within page (1-15, for fixed layout)
    char_type: str = "word"  # "word" or "end" (ayah-end marker glyph)


class Ayah(BaseModel):
    """A single verse of the Quran."""

    surah_number: int
    ayah_number: int
    text: str
    page_number: int | None = None
    juz_number: int | None = None
    hizb_quarter: int | None = None
    sajdah: bool = False
    hizb_marker: bool = False
    page_marker: int | None = None  # Set when this ayah starts a new mushaf page
    translation: str | None = None  # Translation text (footnote refs already replaced)
    footnotes: list[Footnote] = []  # Footnotes referenced by this ayah's translation
    tafsir: str | None = None  # Tafsir/mukhtasar text (shown in popup for bilingual+interactive)
    tafsir_footnotes: list[Footnote] = []  # Footnotes from tafsir content
    words: list[Word] = []  # Word-level data (populated when words=true)


class Surah(BaseModel):
    """A chapter of the Quran."""

    number: int
    name_arabic: str
    name_transliteration: str
    name_translation: str = ""  # Translated meaning (e.g. "The Cow") — set for bilingual builds
    revelation_type: str  # "meccan" or "medinan"
    ayah_count: int
    ayahs: list[Ayah]
    basmala_is_first_ayah: bool = True  # Hafs: 1:1 IS the basmala; Warsh: it is NOT

    @property
    def has_bismillah(self) -> bool:
        """All surahs have bismillah except At-Tawbah (9)."""
        return self.number != 9

    @property
    def bismillah_is_first_ayah(self) -> bool:
        """In Hafs, Al-Fatiha (1) ayah 1 IS the bismillah.

        In Warsh and other riwayat, the basmala is unnumbered — 1:1 starts
        with "Al-Hamdu lillahi...".  The ``basmala_is_first_ayah`` field
        controls this per-riwayah.
        """
        return self.number == 1 and self.basmala_is_first_ayah


class Mushaf(BaseModel):
    """A complete Quran text in a specific script."""

    surahs: list[Surah]
    script: str
    metadata: dict = {}
    bismillah_text: str  # Extracted from Al-Fatiha 1:1 at load time (encoding-specific)
