"""Command-line interface for quran-ebook."""

from pathlib import Path

import click

from .config.schema import load_config
from .data.cache import cache_clear
from .epub.builder import build_epub

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
    help="Build all .yaml configs in the given directory.",
)
def build(config_paths: tuple[str, ...], build_all: str | None):
    """Build EPUBs from one or more YAML configuration files.

    Pass one or more config paths, or use --all DIR to build every .yaml in DIR.
    """
    if build_all is not None:
        search_dir = Path(build_all)
        config_paths = tuple(str(p) for p in sorted(search_dir.glob("*.yaml")))
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
def clear_cache():
    """Clear all cached data and fonts."""
    count = cache_clear()
    click.echo(f"Cleared {count} cached files.")


if __name__ == "__main__":
    main()
