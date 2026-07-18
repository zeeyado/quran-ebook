#!/usr/bin/env python
"""Extract Muhammad Asad's The Message of the Qur'an (translation + footnotes)
from the Rahnuma eBooks single-file HTML digitization into the bundled
local-translation format (data/asad/{surah}.json, clearquran shape).

Source: https://ebooks.rahnuma.org/religion/Muhammad_Asad/
        "The Message of The Quran with footnotes.html"
(2016 digitization proofread by Arthur Wendover — the same community
digitization lineage as every other digital Asad; see
docs/data_sources.md "Asad footnotes" for provenance + licensing notes.)

Structure parsed:
  <h2><a name="{S}surah">…</h2>           surah header
  <p>\nS:A\n</p> + following <p> text     verse group starting at ayah A;
                                          later ayahs continue INLINE as
                                          "(S:B)" markers (Asad's print
                                          groups verses — we split back to
                                          per-ayah)
  <sup><a href="#f{N}surah{S}">N</a></sup> footnote marker (per-surah nums)
  footnote sections: notes delimited by  <a name="f{N}surah{S}"> anchors,
  each "&ordm; N …text… return-link"

Output verse shape (clearquran precedent, flows through
_process_translation_text unchanged):
  {"text": "… <sup foot_note=N>N</sup> …", "foot_notes": {"N": "…"}}

Run:  python tools/extract_asad.py <rahnuma.html> [-o data/asad]
"""

import argparse
import html as htmllib
import json
import re
import sys
from pathlib import Path

# Kufan/Hafs ayah counts, surahs 1..114 (the numbering every translation uses)
HAFS_COUNTS = [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128,
    111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73,
    54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60,
    49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52,
    44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19,
    26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3,
    6, 3, 5, 4, 5, 6,
]

# Verified single-character/word defects in the digitization, corrected
# against the print original (cross-checked vs QUL 919 + alim.org — see the
# extraction verification log in docs/data_sources.md). (surah, ayah,
# old, new); old must occur exactly once in that ayah's text.
PATCHES: list[tuple[int, int, str, str]] = [
    (2, 2, "HIS DIVINE WRIT", "THIS DIVINE WRIT"),
    (2, 7, "God; has sealed", "God has sealed"),
    # 3:32's closing sentence dropped by the digitization; restored from
    # the print original (QUL 919 + alim.org corroborate)
    (3, 32, 'unto God and the Apostle."',
     'unto God and the Apostle." And if they turn away — verily, '
     "God does not love those who deny the truth."),
    # OCR-class corruptions found by the 14-locus sample grading vs alim.org
    (2, 23, "what We have, bestowed", "what We have bestowed"),
    (2, 255, "And he alone is truly exalted", "And He alone is truly exalted"),
]

# Same class of corruptions inside FOOTNOTE texts: (surah, note_number,
# old, new); old must occur exactly once in that note.
NOTE_PATCHES: list[tuple[int, int, str, str]] = [
    (19, 24, "that lie would vouchsafe", "that He would vouchsafe"),
    (36, 10, "histoncal", "historical"),
]

# Raw-HTML repairs applied to a surah's region before parsing, for the two
# structural defects in the digitization (each regex must hit exactly once):
# - 23:95's verse header is mistyped "23:96" (the real (23:96) continues
#   inline right after)
# - 18:29's first sentence was dropped entirely; restored from the print
#   original (wording corroborated by QUL 919 + alim.org), injected together
#   with its missing verse marker
REGION_PATCHES: list[tuple[int, str, str]] = [
    # 8:66's verse header is mistyped "8:68" (the real 8:68 follows later)
    (8, r"(<p>\s*)8:68(\s*</p>\s*<p>\s*For the time being)", r"\g<1>8:66\g<2>"),
    # 6:70: malformed footnote sup — number outside the anchor, href number
    # dropped ("#fsurah6")
    (6, r"<sup><a href=\"#fsurah6\"></a>62</sup>",
     '<sup><a href="#f62surah6">62</a></sup>'),
    # 35:40: second sup's href mistyped f25 for f26 (visible number is 26)
    (35, r"href=\"#f25surah35\">26<", 'href="#f26surah35">26<'),
    # 8:40/41: the digitization places the "(8:41)" marker one clause early
    # — "know that God is your Lord Supreme…" belongs to 8:40 (print, QUL,
    # alim agree); relocate the marker to the true verse start
    (8, r"\(8:41\)\s*(?=know that God is your Lord Supreme)", ""),
    (8, r"(?=AND KNOW that whatever booty)", "(8:41) "),
    (23, r"(<p>\s*)23:96(\s*</p>\s*<p>\s*\[Pray thus)", r"\g<1>23:95\g<2>"),
    (18,
     r"(?<=</p>)(\s*<a name=\"39surah18\"></a><a name=\"40surah18\"></a>\s*<p>\s*)"
     r"(?=Verily, for all who sin against themselves)",
     "\\1(18:29) And say: \"The truth [has now come] from your Sustainer: "
     "let, then, him who wills, believe in it, and let him who wills, "
     "reject it.\" "),
]

# Footnote markers dropped from the verse text by the digitization:
# (surah, ayah, phrase, note_number) — the marker is re-inserted right
# after the phrase (positions verified against alim.org).
MARKER_RESTORATIONS: list[tuple[int, int, str, int]] = [
    (10, 100, "upon those who will not use their reason?", 124),
]

# Notes absent from the digitization entirely (no anchor, no text),
# restored from the print original (fetched + verified against alim.org's
# independent digitization).
NOTE_RESTORATIONS: dict[tuple[int, int], str] = {
    (39, 37): (
        'In this instance, the "inventing of lies about God" alludes to the '
        "attribution of a share in His divinity to anyone or anything beside "
        "Him, whether it be a belief in a plurality of deities, or in an "
        'imaginary "incarnation" of God in human form, or in saints '
        "allegedly endowed with semi-divine powers."
    ),
}

# Dropped inline verse markers: the digitization omits "(S:A)" at these
# verse starts (systematically after muqatta'at verses, plus scattered
# singles). Boundary phrases are the verse-opening words, generated from
# the QUL 919 text (same digitization lineage) and required to match
# case-insensitively EXACTLY ONCE in the verse group at split time.
SPLIT_FIXES: dict[tuple[int, int], str] = {
    (7, 2): "A DIVINE WRIT has been bestowed from on",
    (7, 10): "YEA, INDEED, [O men,] We have given you",
    (7, 40): "VERILY, unto those who give the lie to",
    (7, 54): "VERILY, your Sustainer is God, who has created",
    (8, 72): "BEHOLD, as for those who have attained to",
    (12, 69): "AND WHEN [the sons of Jacob] presented themselves",
    (15, 63): 'They answered: "Nay, but we have come unto',
    (18, 9): "[AND SINCE the life of this world is",
    (19, 2): "AN ACCOUNT of the grace which thy Sustainer",
    (21, 12): "And [every time,] as soon as they began",
    (21, 15): "And that cry of theirs did not cease",
    (21, 36): "But [thus it is:] whenever they who are",
    (21, 37): "Man is a creature of haste; [but in",
    (21, 42): 'Say: "Who could protect you, by night or',
    (21, 47): "But We shall set up just balance-scales on",
    (21, 54): 'Said he: "Indeed, you and your forefathers have',
    (21, 55): 'They asked: "Hast thou come unto us [with',
    (21, 56): 'He answered: "Nay, but your [true] Sustainer is',
    (26, 2): "THESE ARE MESSAGES of the divine writ, clear",
    (26, 63): "Thereupon We inspired Moses thus:",
    (26, 111): 'They answered: "Shall we place our faith in',
    (26, 170): "Thereupon We saved him and all his household",
    (27, 33): 'They answered: "We are endowed with power and',
    (28, 2): "These are messages of a divine writ clear",
    (29, 2): "DO MEN THINK that on their [mere] saying,",
    (30, 2): "Defeated have been the Byzantines",
    (31, 2): "THESE ARE MESSAGES of the divine writ, full",
    (32, 2): "The bestowal from on high of this divine",
    (33, 50): "O PROPHET! Behold, We have made lawful to",
    (36, 2): "Consider this Qur'an full of wisdom:",
    (36, 14): "Lo! We sent unto them two [apostles],",
    (37, 101): "whereupon We gave him the glad tiding of",
    (38, 61): "[And] they will pray:",
    (40, 2): "THE BESTOWAL from on high of this divine",
    (41, 2): "THE BESTOWAL from on high [of this revelation]",
    (43, 2): "CONSIDER this divine writ, clear in itself and",
    (44, 2): "CONSIDER this divine writ, clear in itself and",
    (45, 2): "THE BESTOWAL from on high of this divine",
    (46, 2): "THE BESTOWAL from on high of this divine",
    (46, 10): 'Say: "Have you given thought [to how you',
    (52, 18): "rejoicing in all that their Sustainer will have",
    (52, 23): "and in that [paradise] they shall pass on",
    (58, 15): "God has readied for them suffering severe [in",
    (75, 34): "[And yet, O man, thine end comes hourly]",
    (75, 35): "and ever nearer unto thee, and nearer!",
}


def _clean_text(s: str) -> str:
    """HTML fragment -> plain text, keeping only our <sup foot_note=…> tags."""
    s = s.replace("\r", "")
    # protect our converted sup markers before stripping tags
    s = re.sub(r"<br\s*/?>", " ", s)
    s = re.sub(r"<(?!sup foot_note=|/sup)[^>]+>", " ", s)
    s = htmllib.unescape(s)
    s = s.replace(" ", " ")
    # the digitization's double-hyphen em-dashes; guard the spaced variant too
    s = re.sub(r"\s*--\s*", "—", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def _convert_sups(seg: str, surah: int) -> str:
    """<sup><a href="#f{N}surah{S}">N</a></sup> -> <sup foot_note=GID>N</sup>.

    The foot_note attr becomes the endnote anchor id and MUST be unique
    across the whole book (the builder emits one endnotes.xhtml; the
    clearquran precedent uses book-global ids). Asad's numbering restarts
    per surah, so the id is surah*1000+N while the VISIBLE label stays
    the faithful per-surah number.
    """
    def repl(m):
        n, s = int(m.group(1)), int(m.group(2))
        if s != surah:
            raise ValueError(f"sup for surah {s} inside surah {surah}")
        return f"<sup foot_note={surah * 1000 + n}>{n}</sup>"
    return re.sub(
        r"<sup><a href=\"#f(\d+)surah(\d+)\">\d+</a></sup>", repl, seg
    )


def parse_notes(doc: str) -> dict[tuple[int, int], str]:
    """All footnotes, keyed (surah, number).

    Notes are delimited by <a name="f{N}surah{S}"> anchors; the note body
    runs from its anchor to the next anchor (or a section boundary), and
    carries an "&ordm; N" prefix plus a trailing return-link.
    """
    anchors = [
        (m.start(), int(m.group(1)), int(m.group(2)))
        for m in re.finditer(r"<a name=\"f(\d+)surah(\d+)\"[^>]*>\s*</a>", doc)
    ]
    notes: dict[tuple[int, int], str] = {}
    for i, (pos, n, s) in enumerate(anchors):
        end = anchors[i + 1][0] if i + 1 < len(anchors) else pos + 20000
        chunk = doc[pos:end]
        # note marker: "&ordm; N" (sometimes "&ordm;N", "&ordm; N."); a few
        # notes lost the &ordm; entirely — accept a bare number right after
        # a paragraph break or the section-opening <blockquote>. The
        # digitization confuses 1 with l/I ("&ordm; l3", "I See Appendix"),
        # so digit 1 matches those too.
        alt = str(n).replace("1", "[1lI]")
        m = (re.search(rf"&ordm;\s*{alt}\s*\.?\s+(.*)", chunk, re.S)
             or re.search(rf"<br>\s*<br>\s*{alt}\s*\.?\s+(.*)", chunk, re.S)
             or re.search(rf"<blockquote>\s*{alt}\s*\.?\s+(.*)", chunk, re.S))
        if not m:
            continue
        body = m.group(1)
        # the body ends at ITS return backlink (always "…>return</a>")
        body = re.split(r"(?:&nbsp;|\s)*<a href=\"#\d+surah\d+\">\s*return\s*</a>",
                        body)[0]
        text = _clean_text(body)
        if text:
            notes[(s, n)] = text
    for s, n, old, new in NOTE_PATCHES:
        cur = notes.get((s, n), "")
        if cur.count(old) != 1:
            raise ValueError(f"note patch miss {s}#{n}: {old!r}")
        notes[(s, n)] = cur.replace(old, new)
    return notes


_SURAH_H2 = re.compile(
    r"<h2>(?:<a[^>]*>\s*</a>)*\s*The .{0,60}? Surah--.*?</h2>"
)


def surah_regions(doc: str) -> list[str]:
    """The 114 surah regions, located by the h2 title sequence.

    The name/id anchors are unreliable (surah 105 is anchored bare "105",
    108 is mis-anchored as a second "107surah") — the ordered h2 titles
    are the ground truth. Ends at the appendix block after surah 114.
    """
    heads = list(_SURAH_H2.finditer(doc))
    if len(heads) != 114:
        raise ValueError(f"expected 114 surah headers, found {len(heads)}")
    regions = []
    for i, h in enumerate(heads):
        if i + 1 < len(heads):
            end = heads[i + 1].start()
        else:
            m = re.search(r"<h2>(?:<a[^>]*>\s*</a>)*\s*Appendix", doc[h.end():])
            end = h.end() + m.start() if m else len(doc)
        regions.append(doc[h.start():end])
    return regions


def parse_surah(regions: list[str], surah: int) -> list[dict]:
    """Per-ayah [{'text':…, 'foot_notes':{…}}] for one surah."""
    region = regions[surah - 1]
    for s, pat, repl in REGION_PATCHES:
        if s == surah:
            region, n = re.subn(pat, repl, region)
            if n != 1:
                raise ValueError(f"surah {surah}: region patch hit {n} times")
    # verse area stops at the first footnote-section anchor. Section header
    # markup is wildly inconsistent (h2/h3/h4, "Footnotes Surah 2",
    # "Fotenotes Surah 3", "The Fifth Surah footnotes", …) but every
    # section carries <a name="fNsurahS"> / <a name="surahSfoot"> anchors,
    # and those name-forms never occur in verse areas (verse return-targets
    # are name="NsurahS", sups are href="#f…").
    m = re.search(r"<a name=\"(?:f\d+surah\d+|surah\d+foot)\"", region)
    if m:
        region = region[: m.start()]

    # verse-group headers: "S:A" at paragraph start — usually a standalone
    # <p>S:A</p>, occasionally with the verse text in the SAME paragraph
    # (e.g. 19:30). Tolerates embedded timestamp comments and stray empty
    # anchors; the monotonic filter drops any stray in-text false positive.
    junk = r"(?:\s|<!--.*?-->|<a [^>]*>\s*</a>)*"
    raw_headers = list(re.finditer(rf"<p>{junk}{surah}:(\d+)(?=[\s<])", region))
    headers, last = [], 0
    for h in raw_headers:
        n = int(h.group(1))
        if n > last:
            headers.append(h)
            last = n
    if not headers:
        raise ValueError(f"surah {surah}: no verse headers")

    count = HAFS_COUNTS[surah - 1]
    ayahs: dict[int, str] = {}

    def put(a: int, t: str) -> None:
        # The digitization occasionally covers one ayah twice (an inline
        # "(S:A)" fragment AND a later redundant "S:A" header, e.g. 14:15)
        # — the fragments concatenate in document order.
        t = t.strip()
        if t:
            ayahs[a] = f"{ayahs[a]} {t}" if ayahs.get(a) else t

    for i, h in enumerate(headers):
        first = int(h.group(1))
        seg_end = headers[i + 1].start() if i + 1 < len(headers) else len(region)
        seg = region[h.end():seg_end]
        seg = _convert_sups(seg, surah)
        text = _clean_text(seg)
        # split the group back into individual ayahs on "(S:next)" markers;
        # the digitization occasionally drops the surah prefix ("(28)" for
        # "(5:28)") — accept the bare form only when the full one is absent
        cur = first
        while True:
            nxt = cur + 1
            # inline continuation marker "(S:A)" — tolerating the
            # digitization's stray "}" closers ("(21:58}") and dropped
            # surah prefixes ("(28)")
            m2 = (re.search(rf"\(\s*{surah}\s*:\s*{nxt}\s*[)}}]", text)
                  or re.search(rf"\(\s*{nxt}\s*[)}}]", text))
            idx, mlen = (m2.start(), len(m2.group(0))) if m2 else (-1, 0)
            if idx < 0 and (surah, nxt) in SPLIT_FIXES:
                phrase = SPLIT_FIXES[(surah, nxt)]
                hits = [m.start() for m in
                        re.finditer(re.escape(phrase), text, re.I)]
                if len(hits) == 1:
                    idx, mlen = hits[0], 0
            if idx < 0:
                break
            put(cur, text[:idx])
            text = text[idx + mlen:]
            cur = nxt
        put(cur, text)

    missing = [a for a in range(1, count + 1) if not ayahs.get(a)]
    if missing:
        raise ValueError(f"surah {surah}: missing/empty ayahs {missing[:10]}"
                         f" (have {len(ayahs)}, want {count})")
    extra = sorted(set(ayahs) - set(range(1, count + 1)))
    if extra:
        raise ValueError(f"surah {surah}: unexpected ayah numbers {extra[:10]}")
    return [{"text": ayahs[a], "foot_notes": {}} for a in range(1, count + 1)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("html", help="path to the downloaded rahnuma HTML")
    ap.add_argument("-o", "--out", default="data/asad")
    args = ap.parse_args()

    doc = Path(args.html).read_text(encoding="utf-8", errors="replace")
    notes = parse_notes(doc)
    print(f"parsed {len(notes)} footnotes")
    regions = surah_regions(doc)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    total_ayahs = total_markers = matched_notes = 0
    problems: list[str] = []
    for s in range(1, 115):
        verses = parse_surah(regions, s)
        for a, v in enumerate(verses, 1):
            for old, new in [(p[2], p[3]) for p in PATCHES if p[0] == s and p[1] == a]:
                if v["text"].count(old) != 1:
                    problems.append(f"patch miss {s}:{a} {old!r}")
                else:
                    v["text"] = v["text"].replace(old, new)
            for _s, _a, phr, n in MARKER_RESTORATIONS:
                if (_s, _a) == (s, a):
                    if v["text"].count(phr) != 1:
                        problems.append(f"marker-restore miss {s}:{a}")
                    else:
                        v["text"] = v["text"].replace(
                            phr,
                            f"{phr}<sup foot_note={s * 1000 + n}>{n}</sup>", 1)
            marks = [int(g) for g in re.findall(r"<sup foot_note=(\d+)>", v["text"])]
            total_markers += len(marks)
            for gid in marks:
                if gid // 1000 != s:
                    problems.append(f"foreign note id {gid} in surah {s}")
                    continue
                n = gid % 1000
                note = notes.get((s, n)) or NOTE_RESTORATIONS.get((s, n))
                if note is None:
                    problems.append(f"missing note {s} #{n} (ayah {a})")
                else:
                    v["foot_notes"][str(gid)] = note
                    matched_notes += 1
        total_ayahs += len(verses)
        (out_dir / f"{s}.json").write_text(
            json.dumps(verses, ensure_ascii=False, indent=1), encoding="utf-8"
        )

    print(f"ayahs: {total_ayahs} (want 6236)")
    print(f"markers: {total_markers}, resolved: {matched_notes}")
    orphan = {k for k in notes} - {
        (s, int(g) % 1000)
        for s in range(1, 115)
        for f in [json.loads((out_dir / f"{s}.json").read_text())]
        for v in f for g in v["foot_notes"]
    }
    print(f"parsed notes never referenced: {len(orphan)}")
    for p in problems[:20]:
        print("PROBLEM:", p)
    if problems or total_ayahs != 6236:
        print(f"FAILED ({len(problems)} problems)")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
