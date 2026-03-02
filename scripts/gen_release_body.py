#!/usr/bin/env python3
"""Generate GitHub release body from variants.yaml manifest."""

import sys
from pathlib import Path

import yaml

# Add project root to path so we can import the config module
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from quran_ebook.config.schema import load_config


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_release_body.py <tag>", file=sys.stderr)
        sys.exit(1)

    tag = sys.argv[1]
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = repo_root / "variants.yaml"
    configs_dir = repo_root / "configs"

    with manifest_path.open() as f:
        manifest = yaml.safe_load(f)

    base_url = f"../../releases/download/{tag}"

    # Prepend release notes if present
    release_notes_path = repo_root / "RELEASE_NOTES.md"
    if release_notes_path.exists():
        print(release_notes_path.read_text().strip())
        print()

    lines = [
        "## Downloads",
        "",
        "| File | Description |",
        "|------|-------------|",
    ]

    for variant in manifest["variants"]:
        config_path = configs_dir / variant["config"]
        cfg = load_config(config_path)
        filename = f"{cfg.auto_filename}.epub"
        desc = variant["description"]
        lines.append(f"| [`{filename}`]({base_url}/{filename}) | {desc} |")

    lines.extend([
        "",
        f"See [README](../../blob/{tag}/README.md#koreader-settings) for KOReader setup tips (footnote popups, RTL page turns, mushaf page numbers).",
    ])

    print("\n".join(lines))


if __name__ == "__main__":
    main()
