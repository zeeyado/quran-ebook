#!/usr/bin/env python3
"""Open pages of built books in a browser engine, as a reading app built on it would.

Most reading apps other than KOReader draw a book with a browser engine:
Chromium (Calibre's viewer, Readest on Windows and Android, Thorium) or
WebKit (Apple Books, Readest on a Mac). This check opens pages of a book in
such an engine, straight from the unzipped EPUB and as XHTML, so a markup
error stops the page as it would stop it in an app.

Pages opened per book: the cover, the contents page, surahs 1, 2 and 114,
and the notes file when the book has one.

Checked on every page:
    parse   the page is well-formed (no parser error)
    files   every file the page asks for arrives (style sheet, fonts, cover)
    font    the Quran text is drawn in a font that the book carries
    rtl     the Quran text runs right to left
    links   every link target (file and id) exists in the book
    fits    nothing a reader can see is wider than the window: the ink of
            each piece of text, tables, images. Spaces at a line end do
            not count.

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
    python scripts/dev_checks/reader_check.py --shots DIR BOOK.epub ...   # a picture of surah 2 per book

Exit code 1 when a page of a book fails a check.
"""

import argparse
import re
import sys
import tempfile
import zipfile
from pathlib import Path

PAGES = ["cover.xhtml", "toc.xhtml", "chapter-1.xhtml", "chapter-2.xhtml",
         "chapter-114.xhtml", "endnotes.xhtml"]

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


def ids_in(path: Path) -> set[str] | None:
    if not path.exists():
        return None
    return set(re.findall(r'\bid="([^"]+)"', path.read_text(encoding="utf-8")))


def check_book(browser, book: Path, work: Path, width: int, shots: Path | None) -> list[str]:
    """The problems of one book, one line each. Empty when all pages pass."""
    root = work / book.stem
    with zipfile.ZipFile(book) as z:
        z.extractall(root)
    pages_dir = root / "OEBPS"
    ids: dict[str, set[str] | None] = {}
    problems = []
    for name in PAGES:
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
    ap.add_argument("--shots", type=Path, help="folder for one picture of surah 2 per book")
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.exit("ERROR: Playwright is not installed. See the top of this file.")

    failed = 0
    with tempfile.TemporaryDirectory() as work, sync_playwright() as p:
        browser = getattr(p, args.engine).launch()
        print(f"engine: {args.engine} {browser.version}, window {args.width} points wide")
        for book in args.books:
            problems = check_book(browser, book, Path(work), args.width, args.shots)
            print(("OK    " if not problems else "CHECK ") + book.name)
            for line in problems:
                print(f"        {line}")
            failed += bool(problems)
        browser.close()
    print(f"{len(args.books) - failed} of {len(args.books)} books pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
