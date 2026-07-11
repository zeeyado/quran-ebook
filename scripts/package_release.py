#!/usr/bin/env python3
"""Package release ZIPs for plugin and dictionaries.

Usage:
    python scripts/package_release.py plugin
    python scripts/package_release.py dict quran_tafsir_muyassar
    python scripts/package_release.py dict quran_surah_overview_en quran_surah_overview_ur
    python scripts/package_release.py manifest   # regenerate release/dicts.json only

    # Preview without changing anything:
    python scripts/package_release.py plugin --dry-run
    python scripts/package_release.py dict quran_tafsir_muyassar --dry-run

Rules:
    - ZIP filename is versioned: quran_koplugin_v1.5.zip
    - Folder inside ZIP is NOT versioned: quran.koplugin/
    - Internal filenames never change
    - Plugin: version bumped in _meta.lua
    - Dicts: no internal version field (StarDict version= is format, not ours)
    - README links and version text updated automatically
    - Always specify exactly what to package — no batch/all modes
    - Every packaging run regenerates release/dicts.json — the manifest the
      plugin's asset manager fetches (upload it with the release assets)
"""

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASE_DIR = ROOT / "release"
README = ROOT / "README.md"

# --- Plugin config ---
PLUGIN_SOURCE = ROOT / "tools" / "quran.koplugin"
PLUGIN_META = PLUGIN_SOURCE / "_meta.lua"
PLUGIN_ZIP_PREFIX = "quran_koplugin"
PLUGIN_FOLDER_IN_ZIP = "quran.koplugin"

# --- Dict source locations ---
# The .ifo basename (minus extension) becomes both the folder name
# inside the ZIP and the ZIP filename prefix.
DICT_OUTPUT_DIRS = [
    ROOT / "output" / "stardict",
    ROOT / "output" / "surah_overview",
    ROOT / "output" / "tafseer_dictionary",
    ROOT / "output" / "grammar_dictionary",
    # Add new dict output dirs here as needed.
]


DRY_RUN = False

# --- dicts.json manifest ---
# Fetched by the plugin's asset manager (v1.12 Library & assets) from the
# floating release URL, alongside catalog.json for the EPUBs.
MANIFEST_PATH = RELEASE_DIR / "dicts.json"
RELEASE_URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"


def find_current_zip(prefix: str) -> tuple[Path | None, str | None]:
    """Find existing ZIP in release/ matching prefix, return (path, version)."""
    pattern = re.compile(rf"^{re.escape(prefix)}_v(\d+\.\d+)\.zip$")
    for f in sorted(RELEASE_DIR.iterdir()):
        m = pattern.match(f.name)
        if m:
            return f, m.group(1)
    return None, None


def bump_version(version: str) -> str:
    """Bump minor version: 1.4 -> 1.5."""
    major, minor = version.split(".")
    return f"{major}.{int(minor) + 1}"


def update_readme(old_filename: str, new_filename: str, old_version: str, new_version: str):
    """Replace old ZIP filename and version references in README."""
    text = README.read_text("utf-8")
    new_text = text.replace(old_filename, new_filename)
    # Also update standalone version refs like "v1.4" → "v1.5" that appear
    # in link text (e.g. "[v1.1]" or "Plugin v1.4").
    # Only replace in lines that also reference this specific artifact.
    old_v = f"v{old_version}"
    new_v = f"v{new_version}"
    base = old_filename.rsplit("_v", 1)[0]
    lines = new_text.split("\n")
    for i, line in enumerate(lines):
        if base in line:
            lines[i] = line.replace(old_v, new_v)
    new_text = "\n".join(lines)
    if new_text != text:
        if DRY_RUN:
            print(f"  README: would update {old_filename} → {new_filename}")
        else:
            README.write_text(new_text, "utf-8")
            print(f"  README: {old_filename} → {new_filename}")
    else:
        print(f"  README: no references found for {old_filename}")


def package_plugin():
    """Package the plugin ZIP and bump version."""
    old_zip, old_version = find_current_zip(PLUGIN_ZIP_PREFIX)
    if not old_zip:
        print(f"ERROR: No existing ZIP matching {PLUGIN_ZIP_PREFIX}_v*.zip in release/")
        sys.exit(1)

    new_version = bump_version(old_version)
    new_filename = f"{PLUGIN_ZIP_PREFIX}_v{new_version}.zip"
    new_zip = RELEASE_DIR / new_filename

    # Bump version in _meta.lua
    meta_text = PLUGIN_META.read_text("utf-8")
    version_line = f'    version = "{new_version}",'
    if "version =" in meta_text:
        meta_text = re.sub(r'    version = ".*",', version_line, meta_text)
    else:
        # Insert version after the name line
        meta_text = meta_text.replace(
            '    name = "quran",',
            f'    name = "quran",\n{version_line}',
        )

    if DRY_RUN:
        print(f"  _meta.lua: would set version = \"{new_version}\"")
        print(f"  ZIP: would create {new_filename}, remove {old_zip.name}")
        update_readme(old_zip.name, new_filename, old_version, new_version)
        print(f"  Plugin: v{old_version} → v{new_version} (dry run)")
        return

    PLUGIN_META.write_text(meta_text, "utf-8")
    print(f"  _meta.lua: version = \"{new_version}\"")

    # Build ZIP
    source_files = sorted(PLUGIN_SOURCE.rglob("*"))
    source_files = [f for f in source_files if f.is_file() and not f.name.startswith(".")]
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.mkdir(PLUGIN_FOLDER_IN_ZIP)
        for f in source_files:
            arcname = f"{PLUGIN_FOLDER_IN_ZIP}/{f.relative_to(PLUGIN_SOURCE)}"
            zf.write(f, arcname)

    old_zip.unlink()
    size_kb = new_zip.stat().st_size / 1024
    print(f"  ZIP: {old_zip.name} → {new_filename} ({size_kb:.0f} KB)")

    update_readme(old_zip.name, new_filename, old_version, new_version)
    print(f"  Plugin packaged: v{old_version} → v{new_version}")


def find_dict_source(dict_name: str) -> Path | None:
    """Find the output folder containing the .ifo file for a dict name."""
    target_ifo = f"{dict_name}.ifo"
    for base_dir in DICT_OUTPUT_DIRS:
        if not base_dir.exists():
            continue
        for ifo in base_dir.rglob(target_ifo):
            return ifo.parent
    return None


def package_dict(dict_name: str):
    """Package a single dictionary ZIP."""
    source_dir = find_dict_source(dict_name)
    if not source_dir:
        print(f"  ERROR: no .ifo found for {dict_name} in output dirs")
        print(f"  Have you built it? Check output/ subfolders.")
        sys.exit(1)

    # For dicts like quran_qpc_en_stardict, the ZIP prefix includes _stardict.
    # Try exact match first, then with _stardict suffix.
    old_zip, old_version = find_current_zip(dict_name)
    zip_prefix = dict_name
    if not old_zip:
        old_zip, old_version = find_current_zip(f"{dict_name}_stardict")
        if old_zip:
            zip_prefix = f"{dict_name}_stardict"

    # First-time packaging (new dict): start at v1.0, nothing to remove.
    new_version = bump_version(old_version) if old_zip else "1.0"
    new_filename = f"{zip_prefix}_v{new_version}.zip"
    new_zip = RELEASE_DIR / new_filename

    # Collect dict files (.dict, .idx, .ifo, .dict.dz)
    dict_files = sorted(
        f for f in source_dir.iterdir()
        if f.is_file() and f.name.startswith(dict_name)
    )
    if not dict_files:
        print(f"  ERROR: no files matching {dict_name}* in {source_dir}")
        sys.exit(1)

    if DRY_RUN:
        print(f"  Source: {source_dir}")
        print(f"  Files: {', '.join(f.name for f in dict_files)}")
        if old_zip:
            print(f"  ZIP: would create {new_filename}, remove {old_zip.name}")
        else:
            print(f"  ZIP: would create {new_filename} (first release)")
        print(f"  Folder in ZIP: {dict_name}/")
        if old_zip:
            update_readme(old_zip.name, new_filename, old_version, new_version)
        return

    # Build ZIP with folder structure
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.mkdir(dict_name)
        for f in dict_files:
            zf.write(f, f"{dict_name}/{f.name}")

    size_kb = new_zip.stat().st_size / 1024
    if old_zip:
        old_zip.unlink()
        print(f"  ZIP: {old_zip.name} → {new_filename} ({size_kb:.0f} KB)")
        update_readme(old_zip.name, new_filename, old_version, new_version)
    else:
        print(f"  ZIP: {new_filename} ({size_kb:.0f} KB, first release)")
        print(f"  README: add a link for {new_filename} manually (new dict)")


def _zip_root_and_bookname(zip_path: Path) -> tuple[str | None, str | None]:
    """Return (root folder inside ZIP, StarDict bookname from the .ifo)."""
    with zipfile.ZipFile(zip_path) as zf:
        roots = {n.split("/", 1)[0] for n in zf.namelist() if "/" in n}
        root = roots.pop() if len(roots) == 1 else None
        bookname = None
        for n in zf.namelist():
            if n.endswith(".ifo"):
                text = zf.read(n).decode("utf-8", "replace")
                m = re.search(r"^bookname=(.+)$", text, re.MULTILINE)
                if m:
                    bookname = m.group(1).strip()
                break
        return root, bookname


def write_manifest():
    """Regenerate release/dicts.json from the ZIPs actually in release/."""
    zip_pattern = re.compile(r"^(.+)_v(\d+\.\d+)\.zip$")
    plugin = None
    dicts = []
    for f in sorted(RELEASE_DIR.glob("*.zip")):
        m = zip_pattern.match(f.name)
        if not m:
            print(f"  manifest: skipping unrecognized ZIP name {f.name}")
            continue
        prefix, version = m.group(1), m.group(2)
        data = f.read_bytes()
        entry = {
            "version": version,
            "filename": f.name,
            "url": f"{RELEASE_URL_BASE}/{f.name}",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        }
        if prefix == PLUGIN_ZIP_PREFIX:
            plugin = {"name": PLUGIN_FOLDER_IN_ZIP, **entry}
        else:
            # Dict name = the folder inside the ZIP (differs from the ZIP
            # prefix for e.g. quran_qpc_en_stardict → quran_qpc_en).
            root, bookname = _zip_root_and_bookname(f)
            if not root:
                sys.exit(f"ERROR: {f.name} has no single root folder")
            dicts.append({"name": root, "bookname": bookname, **entry})

    manifest = {"schema": 1, "plugin": plugin, "dicts": dicts}
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", "utf-8")
    print(f"  dicts.json: plugin v{plugin['version'] if plugin else '?'}, "
          f"{len(dicts)} dicts -> {MANIFEST_PATH.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser(
        description="Package release ZIPs for plugin and dictionaries.",
        epilog="Always specify exactly what to package. No batch modes.",
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview changes without modifying anything")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("plugin", help="Package quran.koplugin")

    dict_parser = sub.add_parser("dict", help="Package dictionary ZIPs")
    dict_parser.add_argument("names", nargs="+",
                             help="Dict names (e.g. quran_tafsir_muyassar)")

    sub.add_parser("manifest", help="Regenerate release/dicts.json only")

    args = parser.parse_args()

    global DRY_RUN
    DRY_RUN = args.dry_run

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if DRY_RUN:
        print("=== DRY RUN — no files will be modified ===\n")

    if args.command == "plugin":
        print("Packaging plugin...")
        package_plugin()

    elif args.command == "dict":
        for name in args.names:
            print(f"Packaging {name}...")
            package_dict(name)

    if not DRY_RUN:
        write_manifest()

    print("\nDone." if not DRY_RUN else "\nDry run complete.")


if __name__ == "__main__":
    main()
