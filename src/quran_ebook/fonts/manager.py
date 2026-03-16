"""Font download and management."""

import io
import zipfile
from pathlib import Path

import click
import httpx

from ..config.registry import FONTS, FontInfo
from ..data.cache import get_cache_dir

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
