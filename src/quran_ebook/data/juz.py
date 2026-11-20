"""The thirty parts (juz, para): where each starts in a book, and its name.

Three divisions are in the books:

- Hafs books keep the division of the Quran.com API's `juz_number` field,
  which is the Madinah mushaf's (King Fahd Complex).
- Warsh books keep the publisher's own field (`jozz` in the King Fahd
  Complex's Warsh data). Mapped to Hafs numbering with the alignment table,
  it starts at the same places as the Madinah division in 29 parts; part 4
  starts one ayah earlier, at "lan tanalu" (Hafs 3:92, where the Warsh text
  has its hizb sign).
- Books in the IndoPak script take the subcontinent division of the table
  below, not the API's field (the API gives the Madinah division whatever
  the script). It differs from the Madinah division in seven parts.

`juz_division` is the one place that decides which division a book takes,
by its script.

Each part's name is the first words of its first ayah in the book's own
text. Two parts that start with a surah are named after that surah's
second ayah, as they are in use: part 1 after 2:1 ("alif lam mim", not the
Fatiha), and part 14 after 15:2 ("rubama") where it starts at 15:1 (Hafs,
Warsh; IndoPak starts it at 15:2). The link still goes to the part's start.
The number of words is in the tables below, with the name's plain letters
as a check: the build stops when the words it takes do not spell them. The
letters are a check only; a book shows the words as its own text writes
them.
"""

import re
import unicodedata

from ..models import Mushaf

# The IndoPak division: the first ayah of each part, Hafs numbering.
# Sources: the 15-line IndoPak mushaf (Qudratullah, 610 pages; the page
# layout the IndoPak books use, from QUL's mushaf layout 12) and the
# 16-line IndoPak mushaf (548 pages, Quran.com mushaf 7) open every part on
# a new page at these ayahs; Quran.com's division for its two IndoPak
# mushafs (api.qurancdn.com, juzs?mushaf=6 and 7) gives the same 30 starts,
# and so does Dawat-e-Islami's online Quran (dawateislami.net, para 1 to
# 30). The seven that differ from the Madinah division: 3:92, 5:83, 9:94,
# 15:2, 27:60, 29:45, 36:22 (Madinah: 3:93, 5:82, 9:93, 15:1, 27:56,
# 29:46, 36:28). Checked 2026-11-20.
INDOPAK_JUZ_STARTS = (
    (1, 1), (2, 142), (2, 253), (3, 92), (4, 24), (4, 148), (5, 83), (6, 111),
    (7, 88), (8, 41), (9, 94), (11, 6), (12, 53), (15, 2), (17, 1), (18, 75),
    (21, 1), (23, 1), (25, 21), (27, 60), (29, 45), (33, 31), (36, 22), (39, 32),
    (41, 47), (46, 1), (51, 31), (58, 1), (67, 1), (78, 1),
)

# The names: {part: (how many words, their plain letters)}, taken from the
# part's first ayah; or {part: (words, letters, (surah, ayah))}, taken from
# that ayah (in the book's own numbering). The usual names of the
# subcontinent (as Dawat-e-Islami's online Quran lists them), where each
# part starts in the IndoPak division.
_NAMES_INDOPAK = {
    1: (1, "الم", (2, 1)), 2: (1, "سيقول"), 3: (2, "تلك الرسل"), 4: (2, "لن تنالوا"),
    5: (1, "والمحصنت"), 6: (3, "لا يحب الله"), 7: (2, "واذا سمعوا"),
    8: (2, "ولو اننا"), 9: (2, "قال الملا"), 10: (1, "واعلموا"),
    11: (1, "يعتذرون"), 12: (3, "وما من دابة"), 13: (2, "وما ابري"),
    14: (1, "ربما"), 15: (2, "سبحن الذي"), 16: (2, "قال الم"),
    17: (2, "اقترب للناس"), 18: (2, "قد افلح"), 19: (2, "وقال الذين"),
    20: (2, "امن خلق"), 21: (3, "اتل ما اوحي"), 22: (2, "ومن يقنت"),
    23: (2, "وما لي"), 24: (2, "فمن اظلم"), 25: (2, "اليه يرد"), 26: (1, "حم"),
    27: (3, "قال فما خطبكم"), 28: (3, "قد سمع الله"), 29: (2, "تبرك الذي"),
    30: (1, "عم"),
}
# The Madinah division: of the seven parts that start elsewhere, six take
# the first words of their own start (as Arabic Wikipedia's list of the
# parts names them, shortened to one to three words: part 7 is its first
# word alone, "latajidanna", so the name does not cut a phrase in two);
# part 14 starts at 15:1 and is named after 15:2.
_NAMES_MADINAH = {
    **_NAMES_INDOPAK,
    4: (2, "كل الطعام"), 7: (1, "لتجدن"), 11: (2, "انما السبيل"),
    14: (1, "ربما", (15, 2)), 20: (3, "فما كان جواب"), 21: (2, "ولا تجدلوا"),
    23: (2, "وما انزلنا"),
}
# Warsh: the Madinah starts, but part 4 at "lan tanalu" (see above). Its
# 15:2 is Hafs 15:2.
_NAMES_WARSH = {**_NAMES_MADINAH, 4: _NAMES_INDOPAK[4]}

_NAMES = {"indopak": _NAMES_INDOPAK, "madinah": _NAMES_MADINAH, "warsh": _NAMES_WARSH}

# Scripts whose text the names are taken from. A book in another script
# (the per-page glyph codes of the QCF fonts, the tajweed text) shows the
# numbers alone.
_NAMED_SCRIPTS = {"qpc_uthmani_hafs", "qpc_uthmani_warsh", "text_indopak", "text_indopak_nastaleeq"}


def juz_division(script: str) -> str:
    """Which division of the thirty parts a book in this script takes."""
    if script.startswith("text_indopak"):
        return "indopak"
    if script == "qpc_uthmani_warsh":
        return "warsh"
    return "madinah"


def apply_juz_division(mushaf: Mushaf) -> None:
    """Give every ayah the part it has in the book's division (in place).

    Books in the IndoPak script take the table above; every other book keeps
    the field its source gave. Either way the parts must run 1 to 30 in
    order, each starting once.
    """
    if juz_division(mushaf.script) == "indopak":
        starts = {key: n for n, key in enumerate(INDOPAK_JUZ_STARTS, 1)}
        juz = 0
        for surah in mushaf.surahs:
            for ayah in surah.ayahs:
                juz = starts.get((surah.number, ayah.ayah_number), juz)
                ayah.juz_number = juz
    seen = []
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.juz_number is None:
                return  # a source without the field: the book has no juz page
            if not seen or ayah.juz_number != seen[-1]:
                seen.append(ayah.juz_number)
    if seen != list(range(1, 31)):
        raise ValueError(f"the parts of this book do not run 1 to 30 in order: {seen}")


# The pause signs of the Hafs and Warsh texts, written on the last letter
# of a word (U+06D6 to U+06DB). In the IndoPak text a pause sign is a token
# of its own, glued to its word by a no-break space (the loader).
_PAUSE_SIGNS_RE = re.compile("[\u06D6-\u06DB]")
_LETTER_RE = re.compile("[\u0621-\u064A\u066E-\u066F\u0671-\u06D3]")
_PRIVATE_USE_RE = re.compile("[\uE000-\uF8FF]")


def juz_name(ayah_text: str, words: int) -> str:
    """The first `words` words of an ayah as the book's text writes them.

    Markup is left out, and so is a pause sign: a sign glued on by a
    no-break space (IndoPak), a sign token of its own, or a sign written on
    the word's last letter (Hafs, Warsh).
    """
    found = []
    for token in re.sub(r"<[^>]*>", "", ayah_text).split(" "):
        token = _PAUSE_SIGNS_RE.sub("", token.split(" ")[0])
        if _LETTER_RE.search(token):
            found.append(token)
        if len(found) == words:
            break
    name = " ".join(found)
    if _PRIVATE_USE_RE.search(name):
        raise ValueError(f"a juz name holds a character of the font's own: {name!r}")
    return name


# Letter forms that one text writes one way and another text another way
_FOLD = str.maketrans({
    "ٱ": "ا", "أ": "ا", "إ": "ا", "آ": "ا",
    "ی": "ي", "ى": "ي", "ے": "ي", "ۓ": "ي",
    "ئ": "ي", "ؤ": "و", "ک": "ك", "ہ": "ه",
})


def plain_letters(text: str) -> str:
    """The letters of a text, for the check: no marks, one form per letter."""
    out = []
    for ch in unicodedata.normalize("NFC", text).translate(_FOLD):
        if ch == " ":
            out.append(" ")
        elif _LETTER_RE.match(ch):
            out.append(ch)
    return " ".join("".join(out).split())


def juz_names(mushaf: Mushaf) -> dict[int, str]:
    """{part: its name in this book}, or {} for a script the names are not taken from.

    Stops the build when a name does not spell the letters the table expects.
    """
    if mushaf.script not in _NAMED_SCRIPTS:
        return {}
    table = _NAMES[juz_division(mushaf.script)]
    first: dict[int, tuple[int, int, str]] = {}
    texts: dict[tuple[int, int], str] = {}
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.juz_number is None:
                return {}
            texts[(surah.number, ayah.ayah_number)] = ayah.text
            if ayah.juz_number not in first:
                first[ayah.juz_number] = (surah.number, ayah.ayah_number, ayah.text)
    names = {}
    for juz, (surah, ayah, text) in sorted(first.items()):
        words, letters, *other = table[juz]
        if other:
            # named after another ayah than its start (part 1, part 14)
            surah, ayah = other[0]
            text = texts[(surah, ayah)]
        name = juz_name(text, words)
        if plain_letters(name) != letters:
            raise ValueError(
                f"juz {juz} (starts {surah}:{ayah}): its name from the text is "
                f"{name!r}, letters {plain_letters(name)!r}, expected {letters!r}"
            )
        names[juz] = name
    return names
