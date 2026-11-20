"""The Hafs text as the King Fahd Complex's Hafs data version 2.0 writes it.

The books take the Hafs text from the Quran.com API (its fields
qpc_uthmani_hafs for an ayah and text_qpc_hafs for a word), which is the
King Fahd Complex's text of 2020-21. Measured over all 6,236 ayahs, the
publisher's newer file (King Fahd Complex, Hafs data v2.0, update 13.0)
differs from it in one change of its list: "Modify word (كلا) with (Alif
Madd) to display properly". The old spelling of kallā writes a tatweel
after the kaf, and the books' font draws that form stretched, much wider
than the publisher's own. `hafs_v2_spelling` makes that change and nothing
else (2:6 has one more leading space in the publisher's file); it
is the one home of the rule, for the books and for the dictionary builders.

`HAFS_V2_SHA256` pins the result: the digest of the publisher's v2.0 text in
the plain form of `hafs_v2_digest`. The loader checks the Hafs text against
it every time it loads the text. `tools/hafs_v2_digest.py` derives the value
from the publisher's file, so anyone can check it.
"""

import hashlib
import re
from collections.abc import Iterable

# kallā as the 2020-21 text writes it: kaf, TATWEEL, fatha, lam, shadda,
# fatha, alef (33 places; in some a maddah or a pause sign follows). The
# v2.0 text writes the same without the tatweel. It stands at the start of
# a word in all 33 places, and nowhere else in the text.
_KALLA_OLD = "كـَلَّا"
_KALLA_NEW = "كَلَّا"
_KALLA_OLD_RE = re.compile(r"(?<!\S)" + _KALLA_OLD)

# sha256 of the King Fahd Complex's Hafs data v2.0 (hafsData_v2-0.json in
# its zip UthmanicHafs_v2-0.zip) in the plain form of hafs_v2_digest.
HAFS_V2_SHA256 = "1c3734eb77657df5bfe0cc2b12892e01774bd469943c2f20bea6d1c18ae8cfd5"


def hafs_v2_spelling(text: str) -> str:
    """Hafs text (an ayah or a word) in the spelling of the v2.0 data.

    King Fahd Complex, Hafs data v2.0, update 13.0: "Modify word (كلا)
    with (Alif Madd) to display properly": the tatweel after the kaf of
    kallā is taken out. Text in the v2.0 spelling comes back unchanged.
    """
    return _KALLA_OLD_RE.sub(_KALLA_NEW, text)


def hafs_v2_digest(rows: Iterable[tuple[int, int, str]]) -> str:
    """The digest of a whole Hafs text in its plain form.

    rows: (surah, ayah, text) for every ayah, the text without the ayah
    number that its source writes at its end. The plain form is one line
    "surah|ayah|text" per ayah, in order of surah and ayah, the text without
    white space at either end, each line ended by a newline, in UTF-8.
    """
    h = hashlib.sha256()
    for surah, ayah, text in sorted(rows):
        h.update(f"{surah}|{ayah}|{text.strip()}\n".encode("utf-8"))
    return h.hexdigest()


def check_hafs_v2(rows: Iterable[tuple[int, int, str]]) -> None:
    """Stop when a Hafs text is not the publisher's v2.0 text.

    A change upstream, a cache entry that differs, or a rule that misses a
    place all end here, before any book is made from the text.
    """
    rows = list(rows)
    found = hafs_v2_digest(rows)
    if len(rows) != 6236 or found != HAFS_V2_SHA256:
        raise RuntimeError(
            f"the Hafs text ({len(rows)} ayahs, sha256 {found}) is not the "
            f"King Fahd Complex's Hafs data v2.0 (6236 ayahs, sha256 "
            f"{HAFS_V2_SHA256}); compare the source with that file before "
            "building (tools/hafs_v2_digest.py)")
