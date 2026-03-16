"""Command-line interface for quran-ebook."""

import re
import shutil
import subprocess
import zipfile
from pathlib import Path

import click

from .config.schema import load_config
from .data.cache import cache_clear
from .data.validate import AYAH_COUNTS_HAFS, AYAH_COUNTS_WARSH
from .epub.builder import build_epub

_AYAH_ID_RE = re.compile(r'id="ayah-(\d+)-(\d+)"')
_MIN_COVER_BYTES = 1000  # Cover PNG should be at least 1KB

@click.group()
@click.version_option()
def main():
    """Quran Ebook Generator — build beautiful Quran EPUBs."""


@main.command()
@click.argument("config_paths", nargs=-1, type=click.Path(exists=True))
@click.option(
    "--all",
    "build_all",
    type=click.Path(exists=True, file_okay=False),
    default=None,
    help="Build all .yaml configs in the given directory (recursive).",
)
def build(config_paths: tuple[str, ...], build_all: str | None):
    """Build EPUBs from one or more YAML configuration files.

    Pass one or more config paths, or use --all DIR to build every .yaml in DIR.
    """
    if build_all is not None:
        search_dir = Path(build_all)
        config_paths = tuple(str(p) for p in sorted(search_dir.rglob("*.yaml")))
        if not config_paths:
            click.secho(f"No .yaml files found in {search_dir}/.", fg="red", err=True)
            raise SystemExit(1)

    if not config_paths:
        click.secho("Provide one or more config paths, or use --all.", fg="red", err=True)
        raise SystemExit(1)

    failed = []
    for config_path in config_paths:
        click.echo(f"\nBuilding: {config_path}")
        try:
            config = load_config(config_path)
            for warning in config.warnings:
                click.secho(f"  Warning: {warning}", fg="yellow", err=True)
            output_path = build_epub(config)
            click.secho(f"  Done: {output_path}", fg="green")
        except Exception as e:
            click.secho(f"  Failed: {e}", fg="red", err=True)
            failed.append(config_path)

    if failed:
        click.secho(f"\n{len(failed)} build(s) failed: {', '.join(failed)}", fg="red", err=True)
        raise SystemExit(1)


@main.command()
@click.argument("directory", default="output", type=click.Path(exists=True, file_okay=False))
@click.option("--no-epubcheck", is_flag=True, help="Skip epubcheck, only run content verification.")
def validate(directory: str, no_epubcheck: bool):
    """Validate all EPUB files in DIRECTORY (default: output/).

    Runs two passes:
      1. Content verification — 114 surahs, ayah counts per riwayah, cover image.
      2. epubcheck — EPUB3 structural conformance.

    Use --no-epubcheck to skip the second pass (faster, no Java dependency).
    """
    epub_files = sorted(Path(directory).glob("*.epub"))
    if not epub_files:
        click.secho(f"No .epub files found in {directory}/.", fg="red", err=True)
        raise SystemExit(1)

    total = len(epub_files)

    # Pass 1: Content verification
    click.secho("Content verification...", bold=True)
    content_failed = []
    for i, epub_path in enumerate(epub_files, 1):
        errors = _verify_epub_content(epub_path)
        if errors:
            click.secho(f"[{i}/{total}] FAIL: {epub_path.name}", fg="red")
            for err in errors:
                click.echo(f"  {err}")
            content_failed.append(epub_path.name)
        else:
            click.secho(f"[{i}/{total}] OK: {epub_path.name}", fg="green")

    click.echo()
    if content_failed:
        click.secho(
            f"Content: {len(content_failed)}/{total} failed", fg="red", err=True
        )
    else:
        click.secho(f"Content: all {total} EPUBs OK.", fg="green")

    # Pass 2: epubcheck
    if no_epubcheck:
        click.echo("Skipping epubcheck (--no-epubcheck).")
    else:
        epubcheck_bin = shutil.which("epubcheck")
        if epubcheck_bin is None:
            click.secho(
                "epubcheck not found — skipping. Install with: brew install epubcheck",
                fg="yellow", err=True,
            )
        else:
            click.echo()
            click.secho("Running epubcheck...", bold=True)
            epubcheck_failed = []
            for i, epub_path in enumerate(epub_files, 1):
                result = subprocess.run(
                    [epubcheck_bin, str(epub_path)],
                    capture_output=True, text=True,
                )
                if result.returncode != 0:
                    errs = [l for l in result.stderr.splitlines() if "ERROR" in l or "FATAL" in l]
                    click.secho(f"[{i}/{total}] FAIL ({len(errs)}): {epub_path.name}", fg="red")
                    for err in errs[:5]:
                        click.echo(f"  {err}")
                    if len(errs) > 5:
                        click.echo(f"  ... and {len(errs) - 5} more errors")
                    epubcheck_failed.append(epub_path.name)
                else:
                    click.secho(f"[{i}/{total}] OK: {epub_path.name}", fg="green")

            click.echo()
            if epubcheck_failed:
                click.secho(
                    f"epubcheck: {len(epubcheck_failed)}/{total} failed", fg="red", err=True
                )
                content_failed.extend(epubcheck_failed)
            else:
                click.secho(f"epubcheck: all {total} EPUBs passed.", fg="green")

    if content_failed:
        click.echo()
        click.secho("FAILED:", fg="red", err=True)
        for name in sorted(set(content_failed)):
            click.echo(f"  {name}", err=True)
        raise SystemExit(1)


def _verify_epub_content(epub_path: Path) -> list[str]:
    """Verify EPUB content integrity: chapters, ayah counts, cover image."""
    # Detect riwayah from filename (e.g. quran_warsh_... → warsh)
    is_warsh = "_warsh_" in epub_path.name
    ayah_counts = AYAH_COUNTS_WARSH if is_warsh else AYAH_COUNTS_HAFS
    expected_total = sum(ayah_counts.values())

    errors = []
    try:
        with zipfile.ZipFile(epub_path) as zf:
            names = set(zf.namelist())

            # Check 114 chapter files
            chapter_files = sorted(
                n for n in names if n.startswith("OEBPS/chapter-") and n.endswith(".xhtml")
            )
            if len(chapter_files) != 114:
                errors.append(f"Expected 114 chapter files, found {len(chapter_files)}")

            # Check ayah counts per chapter
            total_ayahs = 0
            for chapter_file in chapter_files:
                content = zf.read(chapter_file).decode("utf-8")
                matches = _AYAH_ID_RE.findall(content)
                surah_num = int(chapter_file.split("chapter-")[1].split(".")[0])
                actual = len(matches)
                total_ayahs += actual
                expected = ayah_counts.get(surah_num)
                if expected is not None and actual != expected:
                    errors.append(
                        f"chapter-{surah_num}: expected {expected} ayahs, got {actual}"
                    )

            if total_ayahs != expected_total:
                errors.append(f"Total ayahs: expected {expected_total}, got {total_ayahs}")

            # Cover image
            if "OEBPS/cover.png" not in names:
                errors.append("Missing cover.png")
            else:
                cover_size = zf.getinfo("OEBPS/cover.png").file_size
                if cover_size < _MIN_COVER_BYTES:
                    errors.append(f"cover.png suspiciously small ({cover_size} bytes)")

    except zipfile.BadZipFile:
        errors.append("Not a valid ZIP file")
    return errors


@main.command()
def clear_cache():
    """Clear all cached data and fonts."""
    count = cache_clear()
    click.echo(f"Cleared {count} cached files.")


if __name__ == "__main__":
    main()
