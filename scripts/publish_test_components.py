#!/usr/bin/env python
"""Publish the NON-EPUB components to the rolling `test-build` pre-release.

The test channel (plugin "Asset source" = test build) mirrors a real release
from the plugin's perspective: catalog.json + feeds + EPUBs come from
`publish_test_build.py` (CI publish_test); THIS script supplies the rest —
dicts.json, dictionary ZIPs, data-package ZIPs, and the plugin ZIP — built
from the CURRENT working tree, so the owner (and testers) can exercise the
full asset pipeline (install / update / plugin self-update) before anything
is officially released.

ONE COMMAND, run it whenever you want the plugin to see your latest work:

    python scripts/publish_test_components.py

It stages every component, compares each one against what is CURRENTLY
PUBLISHED, and only bumps the ones whose content actually changed.

Change detection (owner 2026-07-26 — "just upload the changed content"):
- Versions are per-ASSET, not per-run. Each staged ZIP is sha256'd against
  the live dicts.json on the release: identical bytes KEEP their published
  version (the plugin leaves them alone), changed/new ones get the new
  stamp (the plugin flags exactly those as updates). Before this, one
  stamp covered the whole run, forcing a choice between "changed content
  ships but reads as current" and "all ~38 packages show a bogus update".
- ZIPs are byte-reproducible: every entry is written at a FIXED timestamp
  (ZIP_EPOCH) so identical content hashes identically no matter when it
  was built or copied. Without this the plugin ZIP could never match —
  its _meta.lua is rewritten on every run — and any rebuilt dict would
  look changed on mtime alone.
- The stamp is auto-picked: `9.MMDDN` with N the next free run-of-day,
  read off the live manifest. `--run` / `--version` override it.
- Nothing here is BUILT. Dictionaries and data packages must already be
  built/copied; the freshness section warns about the ways that silently
  goes stale (uncopied explorer export, builder newer than its output,
  dict falling back to its release/ ZIP).

Test-channel rules (packaging policy stays intact):
- Nothing here touches release/ or bumps any repo version. Zips are
  throwaway, staged under output/test_components/, named `<name>_test.zip`
  (constant names — reconcile replaces in place, nothing lingers).
- Test stamps `9.x` outrank every real version (1.x) so update states
  trigger on the test channel. CAVEAT at release time: installs recorded
  from the test channel will read as "current" against official 1.x
  versions — reinstall those items once from the official channel (or
  clear settings/quran_assets.lua records).
- Dicts without a fresh build under output/ fall back to their release/
  ZIPs (uploaded under the release filename, release version — honest
  "current" state for unchanged content).
- Uploads go through release_upload.py (paced, sha256-reconciled).
  publish_test_build.py reconciles the EPUB roster in place and never
  touches component assets, so the two publishers are independent.

Usage:
  python scripts/publish_test_components.py             # stage, diff, upload
  python scripts/publish_test_components.py --dry-run   # full plan, no upload
  python scripts/publish_test_components.py --run 3     # force run-of-day digit
"""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from package_release import DATA_ASSETS, DICT_OUTPUT_DIRS, PLUGIN_SOURCE  # noqa: E402
from release_upload import reconcile  # noqa: E402

RELEASE_MANIFEST = ROOT / "release" / "dicts.json"
STAGING = ROOT / "output" / "test_components"
REPO = "zeeyado/quran-ebook"
TAG = "test-build"
URL_BASE = "https://github.com/zeeyado/quran-ebook/releases/latest/download"
# official-shaped URLs on purpose: the plugin's resolveUrl re-bases them
# onto test-build in test mode — the exact path a real release exercises.

# First-time dicts that release/dicts.json does not carry yet.
EXTRA_DICTS = ["quran_asbab_wahidi"]

# Fixed timestamp for every ZIP entry, so a ZIP is a pure function of its
# contents (the DOS epoch ZIP uses for "no meaningful date").
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)

# --- Freshness advisories (the ways a component silently ships stale) ---
# The five KB-derived sqlite packages are BUILT in quran-explorer and
# copied into data/; a rebuild there that never gets copied here would
# publish the old bytes without a word.
EXPLORER_EXPORTS = Path.home() / "adm" / "projects" / "quran-explorer" / "kb" / "build"
# quran_text is deliberately NOT a straight copy: build_text_translations.py
# adds the extra English editions on top of the explorer export, so it
# always differs from kb/build. Comparing it would cry wolf every run.
LOCALLY_ENRICHED = {"quran_text"}
# Data packages built in THIS repo: source builder -> its output.
LOCAL_BUILDERS = {
    "quran_qul": (ROOT / "tools" / "build_qul_data.py",
                  ROOT / "output" / "qul_data" / "qul-v1.sqlite"),
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _add(zf: zipfile.ZipFile, src: Path, arcname: str):
    """Add one file at a fixed timestamp/mode — see ZIP_EPOCH."""
    info = zipfile.ZipInfo(arcname, date_time=ZIP_EPOCH)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    with open(src, "rb") as fsrc, zf.open(info, "w") as fdst:
        shutil.copyfileobj(fsrc, fdst, 1 << 20)


def zip_dir(src: Path, dest: Path, root_name: str):
    files = sorted(p for p in src.rglob("*")
                   if p.is_file() and not p.name.startswith(".")
                   and not p.name.endswith(".idx.oft"))
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            _add(zf, f, f"{root_name}/{f.relative_to(src)}")


def zip_files(files, dest: Path, root_name: str):
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            _add(zf, f, f"{root_name}/{f.name}")


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


# ---------------------------------------------------------------------
# What is live right now
# ---------------------------------------------------------------------

def fetch_live_manifest():
    """The dicts.json currently on the release, or None (first publish)."""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "dicts.json"
        proc = subprocess.run(
            ["gh", "release", "download", TAG, "--repo", REPO,
             "--pattern", "dicts.json", "--output", str(p), "--clobber"],
            capture_output=True, text=True)
        if proc.returncode != 0 or not p.exists():
            return None
        try:
            return json.loads(p.read_text("utf-8"))
        except json.JSONDecodeError:
            return None


def flatten(manifest):
    """{'plugin:x'|'dict:x'|'data:x' -> entry} for sha/version lookup."""
    out = {}
    if not manifest:
        return out
    if manifest.get("plugin"):
        out["plugin:" + manifest["plugin"]["name"]] = manifest["plugin"]
    for e in manifest.get("dicts") or []:
        out["dict:" + e["name"]] = e
    for e in manifest.get("data") or []:
        out["data:" + e["name"]] = e
    return out


def next_stamp(live_flat, run_override=None) -> str:
    """`9.MMDDN`, N = next free run-of-day across the live manifest."""
    today = datetime.date.today().strftime("%m%d")
    if run_override is not None:
        return f"9.{today}{run_override}"
    used = [int(m.group(1)) for m in
            (re.fullmatch(rf"9\.{today}(\d+)", str(e.get("version", "")))
             for e in live_flat.values()) if m]
    return f"9.{today}{max(used) + 1 if used else 0}"


def decide(key, path, new_ver, live_flat):
    """(version, changed) — identical bytes keep their published version."""
    prev = live_flat.get(key)
    if prev and prev.get("sha256") == sha256(path):
        return prev["version"], False
    return new_ver, True


# ---------------------------------------------------------------------
# Freshness: the ways a component silently ships stale
# ---------------------------------------------------------------------

def freshness_notes():
    notes = []
    for name, files in DATA_ASSETS.items():
        for f in files:
            up = EXPLORER_EXPORTS / f.name
            if not f.exists() or not up.exists():
                continue
            same = sha256(f) == sha256(up)
            if name in LOCALLY_ENRICHED:
                # Inverted test: this one is SUPPOSED to differ. Matching the
                # raw export means a re-copy clobbered the enrichment.
                if same:
                    notes.append(
                        f"{name}: data/{f.name} is byte-identical to the raw "
                        f"explorer export — the extra translations are GONE. "
                        f"Re-run tools/build_text_translations.py before publishing")
            elif not same:
                notes.append(
                    f"{name}: data/{f.name} differs from the explorer export "
                    f"({up}) — copy the new export in if that is the fresher one")
    for name, (builder, out) in LOCAL_BUILDERS.items():
        if builder.exists() and out.exists() \
                and builder.stat().st_mtime > out.stat().st_mtime:
            notes.append(
                f"{name}: {builder.relative_to(ROOT)} is newer than "
                f"{out.relative_to(ROOT)} — re-run the builder?")
    return notes


def main():
    ap = argparse.ArgumentParser(
        description="Publish changed non-EPUB components to the test build.")
    ap.add_argument("--run", type=int, help="force the run-of-day digit")
    ap.add_argument("--version", help="override the full test version stamp")
    ap.add_argument("--dry-run", action="store_true",
                    help="stage, diff and show the upload plan; upload nothing")
    args = ap.parse_args()

    live_flat = flatten(fetch_live_manifest())
    print(f"live on {TAG}: {len(live_flat)} components"
          if live_flat else f"live on {TAG}: nothing yet (first publish)")
    ver = args.version or next_stamp(live_flat, args.run)
    print(f"stamp for changed components: {ver}\n")

    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)
    manifest = json.loads(RELEASE_MANIFEST.read_text("utf-8"))
    uploads, changed, unchanged = [], [], []

    def note(label, entry_version, is_changed, path):
        (changed if is_changed else unchanged).append(
            (label, entry_version, path.stat().st_size))

    # --- plugin ---------------------------------------------------------
    # The version lives IN the zipped _meta.lua, so the bytes depend on it:
    # build at the published version first and keep it when nothing moved,
    # restamp only on a real change. (installPlugin verifies the extracted
    # _meta version against the manifest, so the two must agree.)
    pzip = STAGING / "quran_koplugin_test.zip"

    def build_plugin(v):
        stage = STAGING / "quran.koplugin"
        if stage.exists():
            shutil.rmtree(stage)
        shutil.copytree(PLUGIN_SOURCE, stage,
                        ignore=shutil.ignore_patterns(".*", "dev"))
        meta = stage / "_meta.lua"
        meta.write_text(re.sub(r'(    version = ")[^"]*(",)', rf"\g<1>{v}\g<2>",
                               meta.read_text("utf-8")), "utf-8")
        zip_dir(stage, pzip, "quran.koplugin")
        shutil.rmtree(stage)

    prev_plugin = live_flat.get("plugin:quran.koplugin")
    pver, pchanged = ver, True
    if prev_plugin:
        build_plugin(prev_plugin["version"])
        if sha256(pzip) == prev_plugin["sha256"]:
            pver, pchanged = prev_plugin["version"], False
    if pchanged:
        build_plugin(ver)
    manifest["plugin"] = entry_for("quran.koplugin", None, pzip.name, pver, pzip)
    uploads.append(pzip)
    note("plugin", pver, pchanged, pzip)

    # --- dicts: fresh output builds preferred, release/ zip fallback -----
    dicts_out, fell_back = [], []
    names = [d["name"] for d in manifest["dicts"]] + EXTRA_DICTS
    booknames = {d["name"]: d.get("bookname") for d in manifest["dicts"]}
    old_versions = {d["name"]: d["version"] for d in manifest["dicts"]}
    for name in names:
        src = find_dict_dir(name)
        key = "dict:" + name
        if src:
            z = STAGING / f"{name}_test.zip"
            zip_dir(src, z, name)
            dver, dchanged = decide(key, z, ver, live_flat)
            bn = booknames.get(name) or ifo_bookname(src / f"{name}.ifo")
            dicts_out.append(entry_for(name, bn, z.name, dver, z))
        else:
            fallback = sorted((ROOT / "release").glob(f"{name}_v*.zip"))
            if not fallback:
                print(f"  WARN: no output and no release zip for {name} — skipped")
                continue
            z = fallback[-1]
            # A release ZIP carries its version in its own filename; it never
            # takes a test stamp.
            dver = old_versions.get(name, "1.0")
            prev = live_flat.get(key)
            dchanged = not (prev and prev.get("sha256") == sha256(z))
            dicts_out.append(entry_for(name, booknames.get(name), z.name, dver, z))
            fell_back.append(name)
        uploads.append(z)
        note(f"dict {name}", dver, dchanged, z)
    manifest["dicts"] = dicts_out

    # --- data packages (all registry entries, current data/ files) -------
    data_out = []
    for name, files in DATA_ASSETS.items():
        missing = [f for f in files if not f.exists()]
        if missing:
            print(f"  WARN: {name} missing {missing} — skipped")
            continue
        z = STAGING / f"{name}_test.zip"
        zip_files(files, z, name)
        dver, dchanged = decide("data:" + name, z, ver, live_flat)
        data_out.append(entry_for(name, None, z.name, dver, z))
        uploads.append(z)
        note(f"data {name}", dver, dchanged, z)
    manifest["data"] = data_out

    mpath = STAGING / "dicts.json"
    mpath.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n",
                     "utf-8")
    uploads.append(mpath)

    # --- report ---------------------------------------------------------
    if changed:
        mb = sum(s for _l, _v, s in changed) / (1 << 20)
        print(f"CHANGED ({len(changed)}, {mb:.0f} MB) — these get v{ver} and "
              f"show as updates in the plugin:")
        for label, v, size in changed:
            print(f"  {label:<34} v{v}  {size / (1 << 20):6.1f} MB")
    else:
        print("CHANGED (0) — every component is byte-identical to what is live.")
    print(f"UNCHANGED ({len(unchanged)}) — keep their published version, "
          f"no re-download for testers.")
    if fell_back:
        print(f"\nNOT BUILT LOCALLY ({len(fell_back)}) — shipping the release/ "
              f"ZIP, so any newer content you have is NOT going up:")
        for name in fell_back:
            print(f"  {name}")
    notes = freshness_notes()
    if notes:
        print("\nFRESHNESS WARNINGS:")
        for n in notes:
            print(f"  ! {n}")

    total_mb = sum(u.stat().st_size for u in uploads) / (1 << 20)
    print(f"\nstaged {len(uploads)} assets, {total_mb:.0f} MB -> {STAGING}")

    # stale experiment asset from the first update-flow proof, if present
    if not args.dry_run:
        subprocess.run(["gh", "release", "delete-asset", TAG,
                        "quran_koplugin_v99.0-test.zip", "-y", "--repo", REPO],
                       capture_output=True)
    reconcile(TAG, uploads, repo=REPO, delete_stale=False, dry_run=args.dry_run)
    if not args.dry_run:
        print(f"components reconciled onto {TAG}. In the plugin: Library & "
              f"assets -> Refresh catalogs, then Content & features.")


if __name__ == "__main__":
    main()
