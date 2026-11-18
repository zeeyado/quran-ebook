#!/usr/bin/env python3
"""Open pages of built books in a browser engine, as a reading app built on it would.

Most reading apps other than KOReader draw a book with a browser engine:
Chromium (Calibre's viewer, Readest on Windows and Android, Thorium) or
WebKit (Apple Books, Readest on a Mac). This check opens pages of a book in
such an engine, straight from the unzipped EPUB and as XHTML, so a markup
error stops the page as it would stop it in an app.

Pages opened per book: the cover, the contents page, surahs 1, 2 and 114,
and the notes file when the book has one. --chapters all opens every surah
(a whole book takes a minute or two); --chapters 2,18,36 opens those.

Checked on every page:
    parse   the page is well-formed (no parser error)
    files   every file the page asks for arrives (style sheet, fonts, cover)
    font    the Quran text is drawn in a font that the book carries
    rtl     the Quran text runs right to left
    links   every link target (file and id) exists in the book
    fits    nothing a reader can see is wider than the window: the ink of
            each piece of text, tables, images. Spaces at a line end do
            not count.
    marks   no mark stands on another line than its word: the mark that
            ends an ayah and the sajdah sign go with the word before them,
            the hizb sign with the word after it
    sizes   every kind of text has the same size, counted in the page's
            text size, however an app reads the page. Reading apps differ
            in two things the books must not depend on: some read a page
            as plain HTML with no document type (a table then starts at the
            base size again), and some bring a rule of their own for the
            size of a table (KOReader draws one at 80%). The page is
            measured as it is, read the first way, and with such a rule
            laid under the book's stylesheet; a kind of text whose size
            differs between the three fails.

The window is 700 points wide by default (a tablet or a desktop window).
Use --width 360 or 320 for a phone.

What this does not show: how an app pages a book, its own margins and
menus, or its fonts for the translation. A pass here means "the engine
takes the book"; a device test says the rest.

Needs Playwright, which is not a dependency of this project:
    pip install playwright
    python -m playwright install chromium webkit

Usage:
    python scripts/dev_checks/reader_check.py BOOK.epub ...
    python scripts/dev_checks/reader_check.py --engine webkit --width 360 BOOK.epub ...
    python scripts/dev_checks/reader_check.py --chapters all BOOK.epub ...
    python scripts/dev_checks/reader_check.py --shots DIR BOOK.epub ...   # a picture of surah 2 per book

Exit code 1 when a page of a book fails a check.
"""

import argparse
import re
import sys
import tempfile
import zipfile
from pathlib import Path

FRONT = ["cover.xhtml", "toc.xhtml"]
CHAPTERS = [1, 2, 114]
BACK = ["endnotes.xhtml"]

# A reading app's own rule for the size of a table (KOReader's is this one)
APP_TABLE_RULE = "table { font-size: 80%; }"

# Runs inside the page. It waits until every font of the book is loaded and
# the page is laid out with it: measured earlier, a line is as wide as the
# fallback font makes it.
MEASURE = r"""async () => {
  await document.fonts.ready;
  await Promise.all([...document.fonts].map(f => f.load().catch(() => null)));
  await document.fonts.ready;
  await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
  const family = s => s.split(',')[0].trim().replace(/["']/g, '');
  const loaded = [...document.fonts].filter(f => f.status === 'loaded').map(f => family(f.family));
  const failed = [...document.fonts].filter(f => f.status === 'error').map(f => family(f.family));
  const quran = document.querySelector('.ayah-text, .surah-text, .wbw-arabic');
  const style = getComputedStyle(quran || document.body);

  const width = document.documentElement.clientWidth;
  let worst = 0, worstWhat = '';
  const note = (by, what) => { if (by > worst) { worst = by; worstWhat = what; } };
  const blank = /[\s ⁠​]/;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  let node;
  while ((node = walker.nextNode())) {
    const text = node.nodeValue;
    let a = 0, b = text.length;
    while (a < b && blank.test(text[a])) a++;
    while (b > a && blank.test(text[b - 1])) b--;
    if (a === b) continue;
    range.setStart(node, a); range.setEnd(node, b);
    const where = node.parentElement.closest('[id]');
    for (const r of range.getClientRects()) {
      if (r.width > 0 && r.height > 0) {
        note(Math.max(r.right - width, -r.left),
             (where ? where.id + ': ' : '') + text.slice(a, Math.min(b, a + 40)));
      }
    }
  }
  for (const el of document.body.querySelectorAll('table, img, svg')) {
    const r = el.getBoundingClientRect();
    if (r.width > 0) note(Math.max(r.right - width, -r.left), el.tagName);
  }
  return {
    parse: document.getElementsByTagName('parsererror').length === 0,
    hasQuran: !!quran, font: family(style.fontFamily), direction: style.direction,
    loaded, failed,
    links: [...document.querySelectorAll('a[href]')].map(a => a.getAttribute('href')),
    over: Math.round(worst), overWhat: worstWhat,
  };
}"""


# Runs inside a chapter page, after MEASURE. Every mark and the word it
# belongs to: are the two on one line? A mark's place is its own box; a
# word's place is the box of its nearest visible character. On a
# word-by-word page both are word boxes.
MARKS = r"""() => {
  const BLANK = /[\s\u00a0\u2060\u200b\u200c\u200d\u200e\u200f\ufeff]/;
  const range = document.createRange();
  const mid = r => (r.top + r.bottom) / 2;
  const seen = r => r.width > 0 && r.height > 0;
  const pitchOf = el => {
    const cs = getComputedStyle(el), v = parseFloat(cs.lineHeight);
    return isNaN(v) ? 1.2 * parseFloat(cs.fontSize) : v;
  };
  const texts = new Map();
  const textsOf = block => {
    if (!texts.has(block)) {
      const list = [], w = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      let n; while ((n = w.nextNode())) list.push(n);
      texts.set(block, list);
    }
    return texts.get(block);
  };
  // the box of the nearest visible character before (-1) or after (+1) el
  const neighbour = (block, el, dir) => {
    const list = textsOf(block).filter(n => !el.contains(n) && (dir < 0
      ? n.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING
      : n.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING));
    if (dir < 0) list.reverse();
    for (const node of list) {
      const t = node.nodeValue;
      for (let k = 0; k < t.length; k++) {
        const i = dir < 0 ? t.length - 1 - k : k;
        if (BLANK.test(t[i])) continue;
        range.setStart(node, i); range.setEnd(node, i + 1);
        const rs = [...range.getClientRects()].filter(seen);
        if (rs.length) return dir < 0 ? rs[rs.length - 1] : rs[0];
      }
    }
    return null;
  };
  const boxOf = el => {
    const own = el.querySelector('span[dir="rtl"]') || el;      // a font's own mark: its drawing
    const rs = [...own.getClientRects()].filter(seen);
    return rs.length ? rs[0] : null;
  };
  const sibling = (box, dir) => {
    let b = dir < 0 ? box.previousElementSibling : box.nextElementSibling;
    while (b && !b.classList.contains('wbw-word')) b = dir < 0 ? b.previousElementSibling : b.nextElementSibling;
    return b;
  };
  const where = el => {
    const withId = el.closest('[id^="ayah-"]');
    if (withId) return withId.id.slice(5).replace('-', ':');
    const a = el.closest('a[href]'), m = a && a.getAttribute('href').match(/(\d+)-(\d+)$/);
    return m ? m[1] + ':' + m[2] : '?';
  };
  let n = 0;
  const alone = [];
  const judge = (what, el, mark, word, pitch) => {
    if (!mark || !word) return;
    n++;
    if (Math.abs(mid(mark) - mid(word)) > 0.5 * pitch) alone.push(what + ' ' + where(el));
  };
  for (const el of document.querySelectorAll('.ayah-number, .ayah-mark, .hizb-marker')) {
    const hizb = el.classList.contains('hizb-marker');
    const box = el.closest('.wbw-word');
    if (box) {
      const other = sibling(box, hizb ? 1 : -1);
      if (other) {
        const a = box.getBoundingClientRect(), b = other.getBoundingClientRect();
        n++;
        if (Math.abs(a.top - b.top) > 0.5 * b.height) alone.push((hizb ? 'hizb sign' : 'ayah mark') + ' ' + where(el));
      }
      continue;
    }
    const block = el.closest('p, div');
    if (!block) continue;
    judge(hizb ? 'hizb sign' : 'ayah mark', el, boxOf(el),
          neighbour(block, hizb ? el : (el.closest('a') || el), hizb ? 1 : -1), pitchOf(block));
  }
  for (const block of document.querySelectorAll('.ayah-text, .surah-text')) {
    for (const node of textsOf(block)) {
      const t = node.nodeValue;
      for (let i = t.indexOf('\u06e9'); i > 0; i = t.indexOf('\u06e9', i + 1)) {
        range.setStart(node, i); range.setEnd(node, i + 1);
        const sign = [...range.getClientRects()].filter(seen)[0];
        let before = null;
        for (let k = i - 1; k >= 0 && !before; k--) {
          if (BLANK.test(t[k])) continue;
          range.setStart(node, k); range.setEnd(node, k + 1);
          const rs = [...range.getClientRects()].filter(seen);
          if (rs.length) before = rs[rs.length - 1];
        }
        judge('sajdah sign', node.parentElement, sign, before, pitchOf(block));
      }
    }
  }
  return { n, alone };
}"""

# Runs inside any page: the size of every kind of text, counted in the size
# of the page's own text. A kind is an element's tag and classes (or, for an
# element without a class, its tag and the kind it stands in); only elements
# that hold text of their own count.
SIZES = r"""async () => {
  await document.fonts.ready;
  const base = parseFloat(getComputedStyle(document.body).fontSize);
  const kind = el => el.classList.length
    ? el.tagName.toLowerCase() + '.' + [...el.classList].sort().join('.')
    : el.tagName.toLowerCase() + ' in ' + (el.parentElement && el !== document.body ? kind(el.parentElement) : 'page');
  const out = {};
  for (const el of document.body.querySelectorAll('*')) {
    let own = false;
    for (const n of el.childNodes) if (n.nodeType === 3 && n.nodeValue.trim()) { own = true; break; }
    if (!own) continue;
    const k = kind(el);
    if (!(k in out)) out[k] = Math.round(parseFloat(getComputedStyle(el).fontSize) / base * 1000) / 1000;
  }
  return out;
}"""


def as_plain_html(page_file: Path) -> Path:
    """A copy of a page that a browser reads as HTML with no document type.

    Same folder, so that the style sheet and the fonts are found. The books'
    pages hold no element that HTML would read differently from XHTML.
    """
    text = page_file.read_text(encoding="utf-8")
    text = re.sub(r"^\s*<\?xml[^>]*\?>\s*", "", text)
    text = re.sub(r"<!DOCTYPE[^>]*>\s*", "", text, count=1)
    copy = page_file.with_name(page_file.stem + ".read_as_html.html")
    copy.write_text(text, encoding="utf-8")
    return copy


def size_problems(browser, page_file: Path, width: int, here: dict[str, float]) -> list[str]:
    """Kinds of text whose size differs when an app reads the page its own way."""
    problems = []
    readings = (
        ("an app that reads the page as plain HTML", as_plain_html(page_file), None),
        ("an app with its own rule for the size of a table", page_file, APP_TABLE_RULE),
    )
    for label, file, rule in readings:
        page = browser.new_page(viewport={"width": width, "height": 800})
        page.goto(file.as_uri(), wait_until="load")
        if rule:
            page.add_style_tag(content=rule)
        there = page.evaluate(SIZES)
        page.close()
        off = sorted(k for k in here if k in there and abs(here[k] - there[k]) > 0.01)
        if off:
            k = off[0]
            problems.append(f"{page_file.name}: {len(off)} kinds of text change size in {label}, "
                            f"e.g. {k}: {here[k]:g} of the text size here, {there[k]:g} there")
    return problems


def ids_in(path: Path) -> set[str] | None:
    if not path.exists():
        return None
    return set(re.findall(r'\bid="([^"]+)"', path.read_text(encoding="utf-8")))


def check_book(browser, book: Path, work: Path, width: int, shots: Path | None,
               chapters: list[int] | None) -> list[str]:
    """The problems of one book, one line each. Empty when all pages pass."""
    root = work / book.stem
    with zipfile.ZipFile(book) as z:
        z.extractall(root)
    pages_dir = root / "OEBPS"
    ids: dict[str, set[str] | None] = {}
    problems = []
    if chapters is None:
        chapters = sorted(int(f.stem.split("-")[1]) for f in pages_dir.glob("chapter-*.xhtml"))
    sized = {"cover.xhtml", "toc.xhtml", "endnotes.xhtml", f"chapter-{chapters[min(1, len(chapters) - 1)]}.xhtml"}
    for name in FRONT + [f"chapter-{n}.xhtml" for n in chapters] + BACK:
        if not (pages_dir / name).exists():
            continue
        page = browser.new_page(viewport={"width": width, "height": 1000 if width >= 600 else 740})
        missing: list[str] = []
        page.on("requestfailed", lambda r: missing.append(r.url.rsplit("/", 1)[-1]))
        page.on("response", lambda r: missing.append(r.url.rsplit("/", 1)[-1])
                if r.status >= 400 else None)
        page.goto((pages_dir / name).as_uri(), wait_until="load")
        seen = page.evaluate(MEASURE)

        broken = 0
        for href in seen["links"]:
            if href.startswith(("http:", "https:", "mailto:")):
                continue
            target, _, fragment = href.partition("#")
            target = target or name
            if target not in ids:
                ids[target] = ids_in(pages_dir / target)
            if ids[target] is None or (fragment and fragment not in ids[target]):
                broken += 1

        if not seen["parse"]:
            problems.append(f"{name}: the page does not parse")
        if missing:
            problems.append(f"{name}: files did not arrive: {sorted(set(missing))[:4]}")
        if seen["failed"]:
            problems.append(f"{name}: fonts failed to load: {sorted(set(seen['failed']))}")
        if seen["hasQuran"] and seen["font"] not in seen["loaded"]:
            problems.append(f"{name}: the Quran text is drawn in '{seen['font']}', "
                            "which is not a font of the book")
        if seen["hasQuran"] and seen["direction"] != "rtl":
            problems.append(f"{name}: the Quran text does not run right to left")
        if broken:
            problems.append(f"{name}: {broken} broken links")
        if seen["over"] > 1:
            problems.append(f"{name}: sticks out of a {width}-point window by "
                            f"{seen['over']} points ({seen['overWhat']})")
        if name.startswith("chapter-"):
            marks = page.evaluate(MARKS)
            if marks["alone"]:
                problems.append(f"{name}: {len(marks['alone'])} of {marks['n']} marks stand on another "
                                f"line than their word (first: {marks['alone'][0]})")
        if name in sized:
            problems += size_problems(browser, pages_dir / name, width, page.evaluate(SIZES))
        if shots and name == "chapter-2.xhtml":
            shots.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(shots / f"{browser.browser_type.name}_{width}_{book.stem}.png"))
        page.close()
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("books", nargs="+", type=Path)
    ap.add_argument("--engine", choices=["chromium", "webkit", "firefox"], default="chromium")
    ap.add_argument("--width", type=int, default=700, help="window width in points")
    ap.add_argument("--chapters", default=",".join(str(n) for n in CHAPTERS),
                    help="the surahs to open: numbers with commas, or 'all'")
    ap.add_argument("--shots", type=Path, help="folder for one picture of surah 2 per book")
    args = ap.parse_args()
    chapters = None if args.chapters == "all" else [int(n) for n in args.chapters.split(",")]

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.exit("ERROR: Playwright is not installed. See the top of this file.")

    failed = 0
    with tempfile.TemporaryDirectory() as work, sync_playwright() as p:
        browser = getattr(p, args.engine).launch()
        print(f"engine: {args.engine} {browser.version}, window {args.width} points wide")
        for book in args.books:
            problems = check_book(browser, book, Path(work), args.width, args.shots, chapters)
            print(("OK    " if not problems else "CHECK ") + book.name)
            for line in problems:
                print(f"        {line}")
            failed += bool(problems)
        browser.close()
    print(f"{len(args.books) - failed} of {len(args.books)} books pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
