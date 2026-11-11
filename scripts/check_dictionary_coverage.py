#!/usr/bin/env python3
"""Check that the word dictionary answers every Quran word of the built books.

A reader long-presses a word, and KOReader looks up the word as its engine
cuts it out of the page. This script cuts the Quran text of every book the
same way and looks each word up in the dictionary's index. One word that is
not a headword fails the check, and so does a book in which no Quran text
was found (the markup changed and this script has to follow).

How the engine cuts (crengine, ldomWordsCollector with lGetCharProps):
inside one text node, letters, combining marks and digits make a word; a
symbol (the hizb sign, the sajdah sign) is a word of its own; everything
else ends a word: spaces, punctuation, format characters, private-use
characters.

Where the Quran text of a book is, by layout:
    <p class="ayah-text ...">       one ayah per paragraph
    <div class="surah-text">        flowing text
    <span class="wbw-arabic">       one word per box (word by word)
The ayah marker, a link, is left out.

Usage:
    python scripts/check_dictionary_coverage.py                # output/*.epub
    python scripts/check_dictionary_coverage.py BOOK.epub ...
    python scripts/check_dictionary_coverage.py --zip FILE.zip BOOK.epub ...
    python scripts/check_dictionary_coverage.py --idx FILE.idx BOOK.epub ...

Without --zip or --idx the dictionary is the one a release attaches (the
zip in release/). Stdlib only.
"""

import argparse
import collections
import html
import multiprocessing
import re
import sys
import unicodedata
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from quran_ebook.release_set import word_dictionary  # noqa: E402

# Unicode categories that the engine keeps inside a word.
WORD_CATEGORIES = {"Lu", "Lt", "Ll", "Lm", "Lo", "Mn", "Me", "Mc", "Sk",
                   "Nd", "Nl", "No"}
LETTERS = {"Lu", "Lt", "Ll", "Lo"}
SOFT_HYPHEN = "­"
# The shortest Quran text among the books (Warsh) has 77,427 words.
MIN_WORDS = 77_000

BLOCKS = [
    re.compile(r'<p class="ayah-text[^"]*"[^>]*>(.*?)</p>', re.S),
    re.compile(r'<div class="surah-text"[^>]*>(.*?)</div>', re.S),
    re.compile(r'<span class="wbw-arabic"[^>]*>(.*?)</span>'
               r'(?=<span class="wbw-gloss|\s*</span>|<)', re.S),
]
MARK_LINK = re.compile(r'<a class="ayah-mark-link".*?</a>', re.S)
TAG = re.compile(r"(<[^>]+>)")

_category: dict[str, str] = {}
_headwords: set[str] = set()


def category(ch: str) -> str:
    cat = _category.get(ch)
    if cat is None:
        cat = _category[ch] = unicodedata.category(ch)
    return cat


def read_index(data: bytes) -> set[str]:
    """The headwords of a StarDict .idx: word, a zero byte, eight bytes."""
    words, i = set(), 0
    while i < len(data):
        j = data.index(b"\0", i)
        words.add(data[i:j].decode("utf-8"))
        i = j + 9
    return words


def load_headwords(zip_path: str | None, idx_path: str | None) -> set[str]:
    if idx_path:
        return read_index(Path(idx_path).read_bytes())
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if n.endswith(".idx")]
        if len(names) != 1:
            sys.exit(f"ERROR: {zip_path}: expected one .idx file, found {names}")
        return read_index(z.read(names[0]))


def engine_words(text: str):
    """The words of one text node, as the engine cuts them."""
    run = []
    for ch in text:
        if category(ch) in WORD_CATEGORIES or ch == SOFT_HYPHEN:
            run.append(ch)
        elif run:
            yield "".join(run)
            run = []
    if run:
        yield "".join(run)


def check_book(book: str) -> tuple[str, int, int, list[tuple[int, str, int]]]:
    """(file name, words, words found, [(surah, word, times)] not found)."""
    total = found = 0
    missing: collections.Counter = collections.Counter()
    with zipfile.ZipFile(book) as z:
        for surah in range(1, 115):
            page = z.read(f"OEBPS/chapter-{surah}.xhtml").decode("utf-8")
            for block in BLOCKS:
                for body in block.findall(page):
                    body = MARK_LINK.sub("<x/>", body)
                    for node in TAG.split(body):
                        if node.startswith("<") or not node.strip():
                            continue
                        for word in engine_words(html.unescape(node)):
                            # a number or a mark standing alone is no word
                            if not any(category(c) in LETTERS for c in word):
                                continue
                            total += 1
                            if word in _headwords:
                                found += 1
                            else:
                                missing[(surah, word)] += 1
    return (Path(book).name, total, found,
            [(s, w, n) for (s, w), n in sorted(missing.items())])


def _start(zip_path: str | None, idx_path: str | None) -> None:
    global _headwords
    _headwords = load_headwords(zip_path, idx_path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("books", nargs="*", help="built books (default: output/*.epub)")
    ap.add_argument("--zip", help="a dictionary zip (default: the one in release/)")
    ap.add_argument("--idx", help="a dictionary index file, instead of a zip")
    args = ap.parse_args()

    zip_path, idx_path = args.zip, args.idx
    if not zip_path and not idx_path:
        try:
            zip_path = str(word_dictionary(ROOT))
        except ValueError as e:
            sys.exit(f"ERROR: {e}")
    books = args.books or sorted(str(p) for p in (ROOT / "output").glob("*.epub"))
    if not books:
        sys.exit("ERROR: no books to check")

    source = idx_path or zip_path
    print(f"dictionary: {Path(source).name}, "
          f"{len(load_headwords(zip_path, idx_path)):,} distinct headwords")
    with multiprocessing.Pool(initializer=_start, initargs=(zip_path, idx_path)) as pool:
        results = pool.map(check_book, books, chunksize=4)

    words = sum(r[1] for r in results)
    bad = [r for r in results if r[2] != r[1] or r[1] < MIN_WORDS]
    for name, total, found, missing in bad:
        if total < MIN_WORDS:
            print(f"FAIL {name}: only {total:,} Quran words found in the book "
                  f"(expected over {MIN_WORDS:,}): the markup is not what this "
                  "check knows")
        if found != total:
            print(f"FAIL {name}: {total - found:,} of {total:,} words are not "
                  "in the dictionary")
            for surah, word, times in missing[:8]:
                points = " ".join(f"{ord(c):04X}" for c in word)
                print(f"       surah {surah}: {word}  [{points}]  x{times}")
    print(f"{len(results)} books, {words:,} words: "
          + ("every word is in the dictionary" if not bad
             else f"{len(bad)} books FAILED"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
