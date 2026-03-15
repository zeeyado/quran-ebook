#!/usr/bin/env python3
"""Populate native_name in translation configs from Quran.com API.

For each bilingual/interactive/wbw config, queries the API with the
translation's own language to get the translator name in native script.
Only writes native_name when it differs from the English name (i.e.,
there's an actual script difference like Latin → Arabic/Urdu).

Usage:
    python scripts/populate_native_names.py          # dry-run (default)
    python scripts/populate_native_names.py --write  # write to config files
"""

import argparse
import json
import urllib.request
from pathlib import Path

import yaml

CONFIGS_DIR = Path(__file__).parent.parent / "configs"
API_BASE = "https://api.quran.com/api/v4"
HEADERS = {"User-Agent": "quran-ebook/1.0"}

# Languages where API returns useful native-script names.
# Other languages return the same romanized name — skip them.
NATIVE_SCRIPT_LANGS = {"ur", "fa", "ps", "ku", "ug", "sd"}


def fetch_translations(language: str) -> list[dict]:
    """Fetch translation metadata from Quran.com API for a given language."""
    url = f"{API_BASE}/resources/translations?language={language}"
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["translations"]


def find_native_name(translations: list[dict], resource_id: int) -> str | None:
    """Find the translated_name for a specific resource_id."""
    for t in translations:
        if t["id"] == resource_id:
            tn = t.get("translated_name", {})
            native = tn.get("name", "")
            english = t.get("name", "")
            # Only return if it's actually different (script change)
            if native and native != english:
                return native
    return None


def process_configs(write: bool = False) -> None:
    """Scan all configs and populate native_name where possible."""
    # Cache API results by language
    api_cache: dict[str, list[dict]] = {}

    updated = 0
    skipped = 0
    no_match = 0

    for config_path in sorted(CONFIGS_DIR.rglob("*.yaml")):
        with config_path.open() as f:
            raw = yaml.safe_load(f)
        if not raw or "translation" not in raw:
            continue

        tr = raw["translation"]
        lang = tr.get("language", "")
        resource_id = tr.get("resource_id")
        name = tr.get("name", "")
        existing_native = tr.get("native_name", "")

        if not resource_id:
            continue

        # Skip languages where API won't give us native-script names
        if lang not in NATIVE_SCRIPT_LANGS:
            skipped += 1
            continue

        # Skip if already populated
        if existing_native:
            print(f"  SKIP {config_path.relative_to(CONFIGS_DIR)} — already has native_name: {existing_native}")
            skipped += 1
            continue

        # Fetch from API (cached)
        if lang not in api_cache:
            print(f"  Fetching API translations for language={lang}...")
            api_cache[lang] = fetch_translations(lang)

        native = find_native_name(api_cache[lang], resource_id)
        if not native:
            print(f"  MISS {config_path.relative_to(CONFIGS_DIR)} — id={resource_id} not found or same name")
            no_match += 1
            continue

        rel = config_path.relative_to(CONFIGS_DIR)
        print(f"  FOUND {rel}: {name} → {native}")
        updated += 1

        if write:
            # Insert native_name after name in the YAML file
            text = config_path.read_text()
            # Insert native_name line after the name line
            name_line = f'  name: "{name}"'
            if name_line in text:
                new_line = f'{name_line}\n  native_name: "{native}"'
                text = text.replace(name_line, new_line)
                config_path.write_text(text)
                print(f"    WROTE {rel}")

    print(f"\nSummary: {updated} found, {skipped} skipped, {no_match} no match")
    if updated and not write:
        print("Run with --write to apply changes.")


def main():
    parser = argparse.ArgumentParser(description="Populate native_name in translation configs")
    parser.add_argument("--write", action="store_true", help="Write changes to config files")
    args = parser.parse_args()
    process_configs(write=args.write)


if __name__ == "__main__":
    main()
