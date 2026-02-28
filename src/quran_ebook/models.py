"""Data models for Quran text."""

from pydantic import BaseModel


class Footnote(BaseModel):
    """A footnote attached to a translation."""

    id: int
    number: int  # Display number within the verse
    text: str


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


class Surah(BaseModel):
    """A chapter of the Quran."""

    number: int
    name_arabic: str
    name_transliteration: str
    revelation_type: str  # "meccan" or "medinan"
    ayah_count: int
    ayahs: list[Ayah]

    @property
    def has_bismillah(self) -> bool:
        """All surahs have bismillah except At-Tawbah (9)."""
        return self.number != 9

    @property
    def bismillah_is_first_ayah(self) -> bool:
        """In Al-Fatiha (1), the bismillah IS ayah 1."""
        return self.number == 1


class Mushaf(BaseModel):
    """A complete Quran text in a specific script."""

    surahs: list[Surah]
    script: str
    metadata: dict = {}
    bismillah_text: str = "بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ"
