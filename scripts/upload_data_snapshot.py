#!/usr/bin/env python3
"""Publish the data snapshot as the rolling `data-snapshot` pre-release asset.

Owner-run (repo write; CI only ever DOWNLOADS the snapshot). Flow:

    quran-ebook snapshot make      # pin current .cache → data/snapshot_manifest.json
    git add data/snapshot_manifest.json && git commit ... && git push   # owner
    quran-ebook snapshot pack      # tarball (refuses on manifest mismatch)
    python scripts/upload_data_snapshot.py

The release is created as a PRE-release on first run — it must never
capture `releases/latest` (download-tracking rule: floating latest links
belong to real releases only). The asset is replaced in place on refresh;
the release body records when and what was pinned.

Requires: gh CLI authenticated.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAG = "data-snapshot"
TARBALL = ROOT / "output" / "quran-data-snapshot.tar.gz"
MANIFEST = ROOT / "data" / "snapshot_manifest.json"


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(args)}")
    return subprocess.run(args, check=True, text=True, **kw)


def main() -> None:
    if not TARBALL.exists():
        sys.exit(f"missing {TARBALL} — run `quran-ebook snapshot pack` first")
    if not MANIFEST.exists():
        sys.exit(f"missing {MANIFEST} — run `quran-ebook snapshot make` first")

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    stamp = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    body = (
        f"Rolling data snapshot — the pinned upstream data CI builds from.\n\n"
        f"- entries: {manifest['count']}\n"
        f"- refreshed: {stamp}\n"
        f"- manifest: `data/snapshot_manifest.json` (committed; "
        f"`quran-ebook snapshot verify` checks the unpacked cache against it)\n\n"
        f"Not a release — do not download unless you are reproducing builds."
    )

    exists = subprocess.run(
        ["gh", "release", "view", TAG], capture_output=True, text=True
    ).returncode == 0
    if exists:
        run(["gh", "release", "edit", TAG, "--prerelease", "--notes", body])
    else:
        run(["gh", "release", "create", TAG, "--prerelease",
             "--title", "Data snapshot (rolling)", "--notes", body])
    run(["gh", "release", "upload", TAG, str(TARBALL), "--clobber"])
    print(f"\nUploaded {TARBALL.name} to pre-release '{TAG}'.")


if __name__ == "__main__":
    main()
