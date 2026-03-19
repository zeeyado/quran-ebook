"""Font download and management."""

import io
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


def _download_font(info: FontInfo, dest: Path) -> None:
    """Download a font file from its source."""
    click.echo(f"Downloading font: {info.family}...")

    resp = httpx.get(info.source_url, follow_redirects=True, timeout=120)
    resp.raise_for_status()

    if info.zip_path:
        # Font is inside a zip archive — extract the specific file
        with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
            with zf.open(info.zip_path) as font_file:
                dest.write_bytes(font_file.read())
    else:
        # Direct TTF download
        dest.write_bytes(resp.content)

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
