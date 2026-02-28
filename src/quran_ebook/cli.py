"""Command-line interface for quran-ebook."""

import click

from .config.schema import load_config
from .data.cache import cache_clear
from .epub.builder import build_epub


@click.group()
@click.version_option()
def main():
    """Quran Ebook Generator — build beautiful Quran EPUBs."""


@main.command()
@click.argument("config_path", type=click.Path(exists=True))
def build(config_path: str):
    """Build an EPUB from a YAML configuration file."""
    config = load_config(config_path)

    # Show any script/font pairing warnings
    for warning in config.warnings:
        click.secho(f"Warning: {warning}", fg="yellow", err=True)

    output_path = build_epub(config)
    click.secho(f"Done: {output_path}", fg="green")


@main.command()
def clear_cache():
    """Clear all cached data and fonts."""
    count = cache_clear()
    click.echo(f"Cleared {count} cached files.")


if __name__ == "__main__":
    main()
