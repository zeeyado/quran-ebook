#!/usr/bin/env python
"""Publish the NON-EPUB components to the rolling `test-build` pre-release.

The test channel (plugin "Asset source" = test build) mirrors a real release
from the plugin's perspective: catalog.json + feeds + EPUBs come from
`publish_test_build.py` (CI publish_test); THIS script supplies the rest —
dicts.json, dictionary ZIPs, data-package ZIPs, and the plugin ZIP — built
from the CURRENT working tree, so the owner (and testers) can exercise the
full asset pipeline (install / update / plugin self-update) before anything
is officially released.

Test-channel rules (packaging policy stays intact):
- Nothing here touches release/ or bumps any repo version. Zips are
  throwaway, staged under output/test_components/, named `<name>_test.zip`
  (constant names — `--clobber` replaces in place, nothing lingers).
- Versions are rolling test stamps `9.MMDDN` (MMDD = date, N = run-of-day),
  chosen to outrank every real version (1.x) so update states trigger on
  the test channel. CAVEAT at release time: installs recorded from the
  test channel (9.x) will read as "current" against official 1.x versions
  — reinstall those items once from the official channel (or clear
  settings/quran_assets.lua records).
- Dicts without a fresh build under output/ fall back to their release/
  ZIPs (uploaded under the release filename, release version — honest
  "current" state for unchanged content).
- `publish_test_build.py` DELETE+RECREATES the test-build release on every
  run — re-run THIS script after every publish_test refresh.

Usage:
  python scripts/publish_test_components.py            # stamp 9.MMDD0, upload
  python scripts/publish_test_components.py --run 1    # same-day re-push
  python scripts/publish_test_components.py --dry-run  # stage + report only
"""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from package_release import DATA_ASSETS, DICT_OUTPUT_DIRS, PLUGIN_SOURCE  # noqa: E402

RELEASE_MANIFEST = ROOT / "release" / "dicts.json"
STAGING = ROOT / "output" / "test_components"
REPO = "zeeyado/quran-ebook"
TAG = "test-build"
URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"
# official-shaped URLs on purpose: the plugin's resolveUrl re-bases them
# onto test-build in test mode — the exact path a real release exercises.

# First-time dicts that release/dicts.json does not carry yet.
EXTRA_DICTS = ["quran_asbab_wahidi"]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_dir(src: Path, dest: Path, root_name: str):
    files = sorted(p for p in src.rglob("*")
                   if p.is_file() and not p.name.startswith(".")
                   and not p.name.endswith(".idx.oft"))
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            zf.write(f, f"{root_name}/{f.relative_to(src)}")


def zip_files(files, dest: Path, root_name: str):
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            zf.write(f, f"{root_name}/{f.name}")


def find_dict_dir(name: str):
    for base in DICT_OUTPUT_DIRS:
        if base.exists():
            for ifo in base.rglob(f"{name}.ifo"):
                return ifo.parent
    return None


def ifo_bookname(ifo: Path) -> str:
    m = re.search(r"^bookname=(.+)$", ifo.read_text("utf-8"), re.M)
    return m.group(1).strip() if m else ifo.stem


def entry_for(name, bookname, filename, version, path):
    e = {"name": name, "version": version, "filename": filename,
         "url": f"{URL_BASE}/{filename}",
         "sha256": sha256(path), "size": path.stat().st_size}
    if bookname:
        e = {"name": name, "bookname": bookname, **{k: v for k, v in e.items() if k != "name"}}
    return e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int, default=0, help="run-of-day digit (same-day re-push)")
    ap.add_argument("--version", help="override the full test version stamp")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ver = args.version or "9.{}{}".format(
        datetime.date.today().strftime("%m%d"), args.run)
    print(f"test version stamp: {ver}")

    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)
    manifest = json.loads(RELEASE_MANIFEST.read_text("utf-8"))
    uploads = []

    # --- plugin (patched _meta version must match the manifest entry:
    # installPlugin verifies the extracted version) ---
    pstage = STAGING / "quran.koplugin"
    shutil.copytree(PLUGIN_SOURCE, pstage,
                    ignore=shutil.ignore_patterns(".*", "dev"))
    meta = pstage / "_meta.lua"
    meta.write_text(re.sub(r'(    version = ")[^"]*(",)',
                           rf"\g<1>{ver}\g<2>",
                           meta.read_text("utf-8")), "utf-8")
    pzip = STAGING / "quran_koplugin_test.zip"
    zip_dir(pstage, pzip, "quran.koplugin")
    shutil.rmtree(pstage)
    manifest["plugin"] = entry_for("quran.koplugin", None,
                                   pzip.name, ver, pzip)
    uploads.append(pzip)
    print(f"  plugin: {pzip.name} v{ver} ({pzip.stat().st_size // 1024} KB)")

    # --- dicts: fresh output builds preferred, release/ zip fallback ---
    dicts_out, fresh, fell_back = [], 0, []
    names = [d["name"] for d in manifest["dicts"]] + EXTRA_DICTS
    booknames = {d["name"]: d.get("bookname") for d in manifest["dicts"]}
    old_versions = {d["name"]: d["version"] for d in manifest["dicts"]}
    for name in names:
        src = find_dict_dir(name)
        if src:
            z = STAGING / f"{name}_test.zip"
            zip_dir(src, z, name)
            bn = booknames.get(name) or ifo_bookname(src / f"{name}.ifo")
            dicts_out.append(entry_for(name, bn, z.name, ver, z))
            uploads.append(z)
            fresh += 1
        else:
            fallback = sorted((ROOT / "release").glob(f"{name}_v*.zip"))
            if not fallback:
                print(f"  WARN: no output and no release zip for {name} — skipped")
                continue
            z = fallback[-1]
            dicts_out.append(entry_for(name, booknames.get(name), z.name,
                                       old_versions.get(name, "1.0"), z))
            uploads.append(z)
            fell_back.append(name)
    manifest["dicts"] = dicts_out
    print(f"  dicts: {fresh} fresh, {len(fell_back)} release-zip fallback"
          + (f" ({', '.join(fell_back)})" if fell_back else ""))

    # --- data packages (all registry entries, current data/ files) ---
    data_out = []
    for name, files in DATA_ASSETS.items():
        missing = [f for f in files if not f.exists()]
        if missing:
            print(f"  WARN: {name} missing {missing} — skipped")
            continue
        z = STAGING / f"{name}_test.zip"
        zip_files(files, z, name)
        data_out.append(entry_for(name, None, z.name, ver, z))
        uploads.append(z)
    manifest["data"] = data_out
    print(f"  data: {len(data_out)} packages")

    mpath = STAGING / "dicts.json"
    mpath.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n",
                     "utf-8")
    uploads.append(mpath)
    total_mb = sum(u.stat().st_size for u in uploads) / (1 << 20)
    print(f"  staged {len(uploads)} assets, {total_mb:.0f} MB -> {STAGING}")

    if args.dry_run:
        print("dry run — nothing uploaded")
        return

    # stale experiment asset from the first update-flow proof, if present
    subprocess.run(["gh", "release", "delete-asset", TAG,
                    "quran_koplugin_v99.0-test.zip", "-y", "--repo", REPO],
                   capture_output=True)
    cmd = ["gh", "release", "upload", TAG, *map(str, uploads),
           "--clobber", "--repo", REPO]
    subprocess.run(cmd, check=True)
    print(f"uploaded to {TAG}. Reminder: publish_test wipes this release — "
          "re-run this script after every publish_test refresh.")


if __name__ == "__main__":
    main()
