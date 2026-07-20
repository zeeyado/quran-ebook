#!/usr/bin/env python3
"""Refresh the rolling `test-build` pre-release with the current output/.

Run by CI on a workflow_dispatch with publish_test=true (or locally by the
owner). The release is deleted and recreated each time so stale assets from
removed/renamed variants never linger. It is ALWAYS a pre-release — it must
never capture `releases/latest`, and its README framing is "latest test
builds, not an official release".

Requires: gh CLI authenticated (GITHUB_TOKEN in CI), EPUBs + catalog.json
in output/.

Usage:
    python scripts/publish_test_build.py <git-sha-or-ref>
"""

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAG = "test-build"
BATCH = 50  # assets per gh upload call (argv-length safety)
# Explicit-tag download base: these URLs exist as soon as the assets are
# uploaded, so the test OPDS feed is fully browsable AND downloadable in
# KOReader before any release exists.
TEST_URL_BASE = f"https://github.com/zeeyado/quran-ebook/releases/download/{TAG}"


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(args[:6])}{' …' if len(args) > 6 else ''}")
    return subprocess.run(args, check=check, text=True)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: publish_test_build.py <git-sha-or-ref>")
    ref = sys.argv[1]

    assets = sorted((ROOT / "output").glob("*.epub"))
    catalog = ROOT / "output" / "catalog.json"
    if not assets:
        sys.exit("no EPUBs in output/ — build first")
    if not catalog.exists():
        sys.exit("no output/catalog.json — run gen_catalog.py first")

    # Test OPDS feed: same generator as the release feed, with both the
    # feed-hosting base and the EPUB links pointed at THIS pre-release's
    # explicit-tag URLs.
    run([sys.executable, "scripts/gen_opds.py",
         "--out-dir", "output/opds-test",
         "--base-url", TEST_URL_BASE, "--asset-base", TEST_URL_BASE])
    feeds = sorted((ROOT / "output" / "opds-test").glob("*.xml"))

    stamp = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    body = (
        f"**Unofficial test build** — full asset set from an untagged CI run, "
        f"for testing only.\n\n- built: {stamp}\n- source: `{ref}`\n"
        f"- EPUBs: {len(assets)}\n"
        f"- KOReader OPDS (test): `{TEST_URL_BASE}/root.xml`\n\n"
        f"Official releases: see [latest release](../../releases/latest)."
    )

    # Delete release + tag so removed variants' assets don't linger.
    run(["gh", "release", "delete", TAG, "--cleanup-tag", "--yes"], check=False)
    run(["gh", "release", "create", TAG, "--prerelease", "--target", ref,
         "--title", f"Test build ({stamp})", "--notes", body])

    files = [str(catalog)] + [str(f) for f in feeds] + [str(a) for a in assets]
    for i in range(0, len(files), BATCH):
        run(["gh", "release", "upload", TAG, *files[i:i + BATCH], "--clobber"])
    print(f"\nPublished {len(assets)} EPUBs + catalog.json + {len(feeds)} OPDS "
          f"feeds to pre-release '{TAG}'.\nKOReader OPDS URL: {TEST_URL_BASE}/root.xml")


if __name__ == "__main__":
    main()
