"""Font download and management."""

import hashlib
import io
import struct
import zipfile
from pathlib import Path

import click
import httpx

from ..config.registry import FONTS, FontInfo
from ..data.cache import get_cache_dir

# QCF per-page font CDN base URLs.
# V4 = COLR v0 tajweed colors; V1 = plain (no color layers).
QCF_CDN_URLS = {
    "qcf_v4": "https://verses.quran.foundation/fonts/quran/hafs/v4/colrv1/ttf/p{page}.ttf",
    "qcf_v1": "https://verses.quran.foundation/fonts/quran/hafs/v1/ttf/p{page}.ttf",
}
QCF_TOTAL_PAGES = 604

# Bundled fonts shipped with the package (CI-deterministic, no download needed)
_ASSETS_FONTS_DIR = Path(__file__).parent.parent / "assets" / "fonts"


def _fonts_dir() -> Path:
    """Get or create the fonts cache directory."""
    d = get_cache_dir() / "fonts"
    d.mkdir(parents=True, exist_ok=True)
    return d


def get_font_path(font_key: str) -> Path:
    """Get the local path for a font.

    Resolution order:
    1. Bundled asset fonts (src/quran_ebook/assets/fonts/)
    2. Local cache (.cache/fonts/)
    3. Download from source URL (saved to cache)

    Args:
        font_key: Key from the font registry (e.g. "amiri_quran").

    Returns:
        Path to the TTF file on disk.

    Raises:
        KeyError: If font_key is not in the registry.
        httpx.HTTPError: If download fails.
    """
    if font_key not in FONTS:
        raise KeyError(
            f"Unknown font '{font_key}'. "
            f"Available: {', '.join(FONTS.keys())}"
        )

    info = FONTS[font_key]

    # 1. Check bundled assets
    bundled = _ASSETS_FONTS_DIR / info.filename
    if bundled.exists():
        return bundled

    # 2. Check download cache
    cached = _fonts_dir() / info.filename
    if cached.exists():
        return cached

    # 3. Download as fallback
    _download_font(info, cached)
    return cached


def get_font_bytes(font_key: str) -> bytes:
    """The bytes of a font as the books carry it.

    The file from its source (get_font_path), checked against the checksum
    the registry gives for it, with the changes the registry declares for
    it. A file that differs stops the build: a font that changed at its
    source must be looked at before it goes into a book.
    """
    info = FONTS[font_key] if font_key in FONTS else None
    path = get_font_path(font_key)
    data = path.read_bytes()
    if info and info.sha256:
        found = hashlib.sha256(data).hexdigest()
        if found != info.sha256:
            raise RuntimeError(
                f"font '{font_key}' ({path}) is not the file the registry "
                f"names (sha256 {found}, expected {info.sha256})")
    if info and info.gpos_lookup_flags:
        data = _set_gpos_lookup_flags(data, info.gpos_lookup_flags, info.filename)
    return data


def _table_checksum(table: bytes) -> int:
    """The checksum of one font table (sum of its 32-bit words)."""
    table += b"\0" * (-len(table) % 4)
    return sum(struct.unpack(f">{len(table) // 4}L", table)) & 0xFFFFFFFF


def _set_gpos_lookup_flags(
    data: bytes, changes: tuple[tuple[int, int, int], ...], name: str
) -> bytes:
    """Change the flag word of lookups in a font's GPOS table, and nothing else.

    Each change is (lookup index, flag expected, new flag). The font file
    keeps its layout: only the flag words, the checksum of the GPOS table
    in the table directory and the file's own checksum adjustment change.
    """
    out = bytearray(data)
    tables = {}
    for i in range(struct.unpack(">H", data[4:6])[0]):
        record = 12 + 16 * i
        tag, _sum, offset, length = struct.unpack(">4sLLL", data[record:record + 16])
        tables[tag] = (record, offset, length)
    if b"GPOS" not in tables or b"head" not in tables:
        raise RuntimeError(f"font {name}: no GPOS or head table")
    record, gpos, length = tables[b"GPOS"]
    lookup_list = gpos + struct.unpack(">H", data[gpos + 8:gpos + 10])[0]
    count = struct.unpack(">H", data[lookup_list:lookup_list + 2])[0]
    for index, expected, new in changes:
        if index >= count:
            raise RuntimeError(f"font {name}: no GPOS lookup {index}")
        at = lookup_list + struct.unpack(
            ">H", data[lookup_list + 2 + 2 * index:lookup_list + 4 + 2 * index])[0] + 2
        found = struct.unpack(">H", data[at:at + 2])[0]
        if found != expected:
            raise RuntimeError(
                f"font {name}: GPOS lookup {index} has flag {found}, expected {expected}")
        out[at:at + 2] = struct.pack(">H", new)
    out[record + 4:record + 8] = struct.pack(
        ">L", _table_checksum(bytes(out[gpos:gpos + length])))
    _record, head, _length = tables[b"head"]
    out[head + 8:head + 12] = b"\0\0\0\0"
    out[head + 8:head + 12] = struct.pack(
        ">L", (0xB1B0AFBA - _table_checksum(bytes(out))) & 0xFFFFFFFF)
    return bytes(out)


# SFNT magic bytes: TTF (0x00010000 / 'true'), OTF ('OTTO'), collection
# ('ttcf'). WOFF/WOFF2 deliberately absent — KOReader is TTF-only.
_FONT_MAGIC = (b"\x00\x01\x00\x00", b"true", b"OTTO", b"ttcf")


def _check_font_bytes(data: bytes, source: str) -> None:
    """Fail fast when a 'font' download isn't one (e.g. an HTML page —
    CDN error pages and resource-page URLs both return 200)."""
    if not data.startswith(_FONT_MAGIC):
        head = data[:64].decode("utf-8", "replace")
        raise RuntimeError(
            f"Downloaded data from {source} is not a TTF/OTF font "
            f"(starts with {head!r})")


def _download_font(info: FontInfo, dest: Path) -> None:
    """Download a font file from its source (with retry + validation)."""
    click.echo(f"Downloading font: {info.family}...")

    resp = None
    for attempt in range(3):
        try:
            resp = httpx.get(info.source_url, follow_redirects=True, timeout=120)
            resp.raise_for_status()
            break
        except (httpx.TransportError, httpx.HTTPStatusError) as e:
            if (isinstance(e, httpx.HTTPStatusError)
                    and e.response.status_code < 500):
                raise
            if attempt == 2:
                raise
            click.echo(f"  Retry {attempt + 1}/3 after network error...")
            import time
            time.sleep(2 * (attempt + 1))

    if info.zip_path:
        # Font is inside a zip archive — extract the specific file
        with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
            with zf.open(info.zip_path) as font_file:
                data = font_file.read()
    else:
        # Direct TTF download
        data = resp.content

    _check_font_bytes(data, info.source_url)
    dest.write_bytes(data)
    click.echo(f"  Saved to {dest} ({dest.stat().st_size:,} bytes)")


def get_qcf_font_paths(font_key: str) -> dict[int, Path]:
    """Download and cache all 604 QCF per-page fonts.

    Args:
        font_key: "qcf_v4" (COLR tajweed) or "qcf_v1" (plain).

    Returns:
        Dict mapping page number (1-604) to local TTF path.
    """
    if font_key not in QCF_CDN_URLS:
        raise KeyError(f"Unknown QCF font key '{font_key}'. Available: {list(QCF_CDN_URLS)}")

    url_template = QCF_CDN_URLS[font_key]
    cache_dir = _fonts_dir() / font_key
    cache_dir.mkdir(parents=True, exist_ok=True)

    paths: dict[int, Path] = {}
    to_download: list[int] = []

    for page in range(1, QCF_TOTAL_PAGES + 1):
        dest = cache_dir / f"p{page}.ttf"
        if dest.exists() and dest.stat().st_size > 0:
            paths[page] = dest
        else:
            to_download.append(page)

    if not to_download:
        click.echo(f"  QCF fonts ({font_key}): all {QCF_TOTAL_PAGES} cached")
        return {p: cache_dir / f"p{p}.ttf" for p in range(1, QCF_TOTAL_PAGES + 1)}

    click.echo(f"  Downloading {len(to_download)} QCF fonts ({font_key})...")
    with httpx.Client(timeout=30, follow_redirects=True) as client:
        for i, page in enumerate(to_download):
            url = url_template.format(page=page)
            dest = cache_dir / f"p{page}.ttf"
            resp = client.get(url)
            resp.raise_for_status()
            dest.write_bytes(resp.content)
            paths[page] = dest
            if (i + 1) % 50 == 0 or (i + 1) == len(to_download):
                click.echo(f"    {i + 1}/{len(to_download)} fonts downloaded")

    total_size = sum((cache_dir / f"p{p}.ttf").stat().st_size for p in range(1, QCF_TOTAL_PAGES + 1))
    click.echo(f"  QCF fonts: {QCF_TOTAL_PAGES} files, {total_size / 1024 / 1024:.1f} MB total")
    return {p: cache_dir / f"p{p}.ttf" for p in range(1, QCF_TOTAL_PAGES + 1)}
