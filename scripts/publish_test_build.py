#!/usr/bin/env python3
"""Refresh the rolling `test-build` pre-release with the current output/.

Run by CI on a workflow_dispatch with publish_test=true (or locally by the
owner). Since 2026-07-26 this RECONCILES the release in place through
release_upload.py (paced under GitHub's ~500/hour content-call limit,
resumable, sha256-compared) instead of delete-and-recreating it:

- only missing/changed assets upload; byte-identical ones are skipped
  (offline builds are byte-reproducible, so a re-run resumes a failure);
- stale assets from removed/renamed variants are still deleted, but the
  scope is *.epub / *.xml / catalog.json only — the component assets from
  publish_test_components.py (zips + dicts.json) survive a refresh now;
- EPUBs upload first, feeds + catalog last, so the advertised links flip
  only once the files behind them are up;
- the git tag stays where it was first created; the release body carries
  the true source sha. A full refresh from a new commit re-uploads
  everything (the generator stamp changes every EPUB) and paces across
  ~3 hourly windows — expect a long but unattended step.

Requires: gh CLI authenticated (GITHUB_TOKEN in CI), EPUBs + catalog.json
in output/.

Usage:
    python scripts/publish_test_build.py <git-sha-or-ref> [--dry-run]
"""

import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from release_upload import get_release, reconcile  # noqa: E402

TAG = "test-build"
# Explicit-tag download base: these URLs exist as soon as the assets are
# uploaded, so the test OPDS feed is fully browsable AND downloadable in
# KOReader before any release exists.
TEST_URL_BASE = f"https://github.com/zeeyado/quran-ebook/releases/download/{TAG}"


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(args[:6])}{' …' if len(args) > 6 else ''}")
    return subprocess.run(args, check=check, text=True)


def main() -> None:
    argv = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    if len(argv) != 1:
        sys.exit("usage: publish_test_build.py <git-sha-or-ref> [--dry-run]")
    ref = argv[0]

    assets = sorted((ROOT / "output").glob("*.epub"))
    catalog = ROOT / "output" / "catalog.json"
    if not assets:
        sys.exit("no EPUBs in output/ — build first")
    if not catalog.exists():
        sys.exit("no output/catalog.json — run gen_catalog.py first")

    # Test OPDS feed: same generator as the release feed, with both the
    # feed-hosting base and the EPUB links pointed at THIS pre-release's
    # explicit-tag URLs. LEVEL-1 XML ONLY (--no-facets --no-json,
    # DA-6(b) 2026-07-27): test feeds are RELEASE ASSETS under the
    # 1000-asset hard cap, so the ~640 facet-pair + JSON files stay a
    # gh-pages (stable channel) feature.
    run([sys.executable, "scripts/gen_opds.py",
         "--out-dir", "output/opds-test", "--no-facets", "--no-json",
         "--base-url", TEST_URL_BASE, "--asset-base", TEST_URL_BASE])
    feeds = sorted((ROOT / "output" / "opds-test").glob("*.xml"))

    stamp = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    epubcheck_note = (
        "SKIPPED this run (unvalidated test assets)"
        if os.environ.get("EPUBCHECK_SKIPPED") == "true" else "passed"
    )
    body = (
        f"**Unofficial test build** — full asset set from an untagged CI run, "
        f"for testing only.\n\n- built: {stamp}\n- source: `{ref}`\n"
        f"- EPUBs: {len(assets)}\n"
        f"- epubcheck: {epubcheck_note}\n"
        f"- KOReader OPDS (test): `{TEST_URL_BASE}/root.xml`\n\n"
        f"Assets are reconciled in place (the tag may point at an older "
        f"commit; `source` above is authoritative).\n"
        f"Official releases: see [latest release](../../releases/latest)."
    )
    title = f"Test build ({stamp})"

    # EPUBs first, feeds + catalog last (links go live only once the
    # files behind them are up).
    files = assets + feeds + [catalog]

    if get_release(TAG) is None:
        if dry_run:
            print(f"dry run: would create pre-release '{TAG}' and upload "
                  f"{len(files)} assets")
            return
        run(["gh", "release", "create", TAG, "--prerelease",
             "--target", ref, "--title", title, "--notes", body])
    elif not dry_run:
        run(["gh", "release", "edit", TAG, "--title", title, "--notes", body])

    reconcile(TAG, files, delete_stale=True, dry_run=dry_run)
    print(f"\nTest channel '{TAG}' reconciled: {len(assets)} EPUBs + "
          f"catalog.json + {len(feeds)} OPDS feeds.\n"
          f"KOReader OPDS URL: {TEST_URL_BASE}/root.xml")


if __name__ == "__main__":
    main()
