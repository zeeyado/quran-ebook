#!/usr/bin/env python3
"""One-off: minimal QCF v4 tajweed test EPUB — Surah Al-Fatiha, Arabic only.

For testing COLR v0 font rendering in CREngine PR #654.
"""

import io
import zipfile
from pathlib import Path

import httpx

API = "https://api.quran.com/api/v4"
FONT_URL = "https://verses.quran.foundation/fonts/quran/hafs/v4/colrv1/ttf/p{page}.ttf"
SURAH = 1
OUTPUT = Path("output/test_qcf_fatiha.epub")


def fetch_json(client, url, **params):
    r = client.get(url, params=params)
    r.raise_for_status()
    return r.json()


def main():
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    with httpx.Client(timeout=30, follow_redirects=True) as c:
        data = fetch_json(c, f"{API}/verses/by_chapter/{SURAH}",
                          language="en", words="true",
                          word_fields="code_v2,page_number,text_uthmani",
                          per_page="50")
        verses = data["verses"]

        pages_needed = set()
        for v in verses:
            for w in v.get("words", []):
                if w.get("char_type_name") in ("word", "end"):
                    pages_needed.add(w.get("page_number", 1))

        print(f"Pages needed: {sorted(pages_needed)}")

        fonts = {}
        for pg in sorted(pages_needed):
            print(f"Downloading font p{pg}.ttf ...")
            r = c.get(FONT_URL.format(page=pg))
            r.raise_for_status()
            fonts[pg] = r.content
            print(f"  {len(r.content):,} bytes")

    # --- Build ayah HTML ---
    ayah_html_parts = []
    for v in verses:
        word_spans = []
        for w in v.get("words", []):
            ct = w.get("char_type_name", "word")
            if ct not in ("word", "end"):
                continue
            code = w.get("code_v2", "")
            pg = w.get("page_number", 1)
            if ct == "end":
                word_spans.append(
                    f'\u2060<span class="qcf-word qcf-end qcf-p{pg}">{code}</span>'
                )
            else:
                word_spans.append(
                    f'<span class="qcf-word qcf-p{pg}">{code}</span>'
                )
        ayah_html_parts.append(f'    <p class="ayah-text">{" ".join(word_spans)}</p>')

    ayahs_block = "\n".join(ayah_html_parts)

    # --- Font-face CSS ---
    font_faces = []
    for pg in sorted(pages_needed):
        font_faces.append(
            f'@font-face {{ font-family: "qcf-p{pg}"; '
            f'src: url("fonts/p{pg}.ttf"); }}\n'
            f'.qcf-p{pg} {{ font-family: "qcf-p{pg}"; }}'
        )
    font_css = "\n".join(font_faces)

    css = f"""{font_css}

body {{
    margin: 1em;
    font-size: 1em;
}}
.ayah-text {{
    text-align: center;
    font-size: 1.0em;
    line-height: 2.0em;
    margin: 0.3em 0;
}}
.qcf-word {{
    font-size: 1.0em;
}}
.qcf-end {{
    font-size: 0.85em;
}}
"""

    xhtml = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ar" dir="rtl">
<head>
    <meta charset="utf-8"/>
    <title>Surah Al-Fatiha — QCF Tajweed Test</title>
    <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
{ayahs_block}
</body>
</html>
"""

    nav_xhtml = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head><meta charset="utf-8"/><title>Navigation</title></head>
<body>
<nav epub:type="toc" id="toc"><ol><li><a href="chapter.xhtml">Al-Fatiha</a></li></ol></nav>
</body>
</html>
"""

    font_items = "\n    ".join(
        f'<item id="font-p{pg}" href="fonts/p{pg}.ttf" media-type="font/ttf"/>'
        for pg in sorted(pages_needed)
    )
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-qcf-fatiha-2026</dc:identifier>
    <dc:title>QCF Tajweed Test — Al-Fatiha</dc:title>
    <dc:language>ar</dc:language>
    <meta property="dcterms:modified">2026-03-20T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="style" href="style.css" media-type="text/css"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    {font_items}
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
"""

    container = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zf.writestr("META-INF/container.xml", container)
        zf.writestr("OEBPS/content.opf", opf)
        zf.writestr("OEBPS/nav.xhtml", nav_xhtml)
        zf.writestr("OEBPS/style.css", css)
        zf.writestr("OEBPS/chapter.xhtml", xhtml)
        for pg, data in fonts.items():
            zf.writestr(f"OEBPS/fonts/p{pg}.ttf", data, compress_type=zipfile.ZIP_STORED)

    OUTPUT.write_bytes(buf.getvalue())
    print(f"\nWrote {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
