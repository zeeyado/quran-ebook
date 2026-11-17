"""What a reader can reach from inside an entry of the word dictionary.

In KOReader a reader can pick a word inside the dictionary popup and look it
up, and can tap a link that an entry carries. Both must open an entry of this
dictionary. When a picked word is not a headword, KOReader's fuzzy search
opens the nearest spelling, which is a wrong word; a link whose word is not a
headword opens nothing.

Two rules follow, and entry_problems() checks them:

- every Arabic word that an entry shows is a headword;
- every link (bword://WORD) names a headword, letter for letter. KOReader
  looks a link's word up as written, in this dictionary only, with no fuzzy
  search.

Stdlib only: the dictionary builder and the release check share this file.
"""

import html as html_module
import re

LINK_PREFIX = "bword://"

_GENERAL_PUNCTUATION = re.compile("[ -⃿]")
_ASCII_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
_TAG = re.compile(r"<!--.*?-->|<[^>]+>", re.S)
_ARABIC_LETTER = re.compile("[ء-يٱ-ۓ]")
_LINK = re.compile(r'<a\b[^>]*\bhref="([^"]*)"', re.I)


def popup_lookup_form(shown: str) -> str:
    """The text KOReader looks up when this word is picked inside the popup.

    Follows ReaderDictionary:cleanSelection for text that does not come from
    the book page: the general punctuation block (it holds the direction
    marks) is removed everywhere, ASCII punctuation at both ends.
    """
    text = _GENERAL_PUNCTUATION.sub("", shown.replace(" ", " ")).strip()
    for ch in ("·", "|", "↑", "ˈ", "ˌ"):
        text = text.replace(ch, "")
    return text.strip(_ASCII_PUNCTUATION).strip()


def shown_arabic_words(entry_html: str) -> set[str]:
    """The Arabic words of one entry, cut the way the popup cuts them."""
    words = set()
    for raw in html_module.unescape(_TAG.sub(" ", entry_html)).split():
        word = popup_lookup_form(raw)
        if word and _ARABIC_LETTER.search(word):
            words.add(word)
    return words


def link_words(entry_html: str) -> set[str]:
    """The words that the links of one entry look up."""
    words = set()
    for href in _LINK.findall(entry_html):
        href = html_module.unescape(href)
        if href.startswith(LINK_PREFIX):
            words.add(href[len(LINK_PREFIX):])
        elif "://" not in href:
            words.add(href)  # KOReader takes a bare href as the word
    return words


def link_to(word: str) -> str | None:
    """A link target for a word shown in an entry, or None if it cannot be one.

    A word with a space in it is two words to the popup, and a quote or an
    angle bracket would break the markup: such a word stays plain text.
    """
    target = popup_lookup_form(word)
    if not target or re.search(r'[\s"<>&]', target):
        return None
    return LINK_PREFIX + target


def entry_problems(headwords, definitions) -> tuple[set[str], set[str]]:
    """(shown words that are not headwords, link words that are not headwords).

    headwords: every headword of the dictionary. definitions: the HTML of its
    entries (a repeated definition is read once).
    """
    headwords = set(headwords)
    unexplained: set[str] = set()
    dead_links: set[str] = set()
    for entry_html in set(definitions):
        unexplained |= shown_arabic_words(entry_html) - headwords
        dead_links |= link_words(entry_html) - headwords
    return unexplained, dead_links
