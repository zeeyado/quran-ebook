#!/usr/bin/env python3
"""Reconcile a GitHub release's assets with a local file set, paced and
resumable — the shared uploader behind publish_test_build.py,
publish_test_components.py, and the tag-release path in release.yml.

Why this exists (docs/release_asset_cap_2026-07.md): GitHub caps
content-creating API calls at ~500/hour (secondary rate limit) and releases
at a hard 1000 assets. The roster is 679 EPUBs, so any full publish must
pace across hour boundaries, survive 403s, and resume instead of restarting.

Reconcile semantics:
- compares local files against remote assets by sha256 (the asset API's
  `digest` field vs a local hash — no downloads), uploads only missing or
  changed files, and skips byte-identical ones. Offline builds are
  byte-reproducible, so a re-run after a partial failure resumes where the
  last one died.
- assets left half-uploaded by a killed run (state != "uploaded") are
  deleted and re-uploaded.
- stale deletion is scoped: only remote assets matching MANAGED_SUFFIXES /
  MANAGED_NAMES that have no local counterpart are deleted. Assets outside
  the scope (the test channel's component zips + dicts.json) are never
  touched, so a roster refresh no longer wipes the components.

Pacing: a rolling-window budget (HOURLY_BUDGET content calls per WINDOW
seconds, margin under GitHub's documented 500/hour) — the script sleeps as
needed rather than tripping 403s; a 403 that slips through anyway gets
escalating backoff. Deletes and uploads both count.

Budget guard: refuses to produce a release over MAX_ASSETS assets, and
`--preflight-configs` fails a CI run in seconds if the roster has outgrown
the budget (cap-and-curate decision, owner 2026-07-26).

Usage:
  release_upload.py --tag TAG [--delete-stale] [--dry-run] [--publish
      [--make-latest]] FILE...
  release_upload.py --preflight-configs configs/
"""

import argparse
import collections
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = "zeeyado/quran-ebook"

# GitHub documents ~500 content-creating requests/hour; stay under it.
HOURLY_BUDGET = 450
WINDOW = 3660  # rolling window (s), small margin over one hour

# GitHub hard-caps a release at 1000 assets (HTTP 422 beyond).
MAX_ASSETS = 990
# Preflight ceiling for configs/ — leaves room for ~60 OPDS feeds,
# catalog.json, and the ~40 test-channel component assets.
EPUB_CONFIG_CAP = 900

# Stale-deletion scope: the roster assets this repo's publishers own.
MANAGED_SUFFIXES = (".epub", ".xml")
MANAGED_NAMES = ("catalog.json",)

CONTENT_TYPES = {
    ".epub": "application/epub+zip",
    ".xml": "application/atom+xml",
    ".json": "application/json",
    ".zip": "application/zip",
    ".gz": "application/gzip",
    ".sqlite": "application/octet-stream",
}

BACKOFF = [60, 120, 300, 600, 900, 900, 900, 900]  # s, per-call retries


class Pacer:
    """Rolling-window budget for content-creating API calls."""

    def __init__(self, budget: int = HOURLY_BUDGET, window: int = WINDOW):
        self.budget = budget
        self.window = window
        self.calls: collections.deque[float] = collections.deque()

    def _expire(self) -> None:
        now = time.monotonic()
        while self.calls and now - self.calls[0] >= self.window:
            self.calls.popleft()

    def tick(self) -> None:
        self._expire()
        while len(self.calls) >= self.budget:
            wait = self.window - (time.monotonic() - self.calls[0]) + 2
            if wait > 30:
                print(f"  pacing: {len(self.calls)} content calls in the "
                      f"current window — sleeping {int(wait)}s", flush=True)
            time.sleep(max(wait, 1))
            self._expire()
        self.calls.append(time.monotonic())


PACER = Pacer()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _gh_json_lines(url: str) -> list[dict]:
    """Paginated GET returning one object per line (--jq '.[]')."""
    proc = subprocess.run(
        ["gh", "api", url, "--paginate", "--jq", ".[]"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"gh api {url} failed:\n{proc.stderr.strip()}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line]


def get_release(tag: str, repo: str = REPO) -> dict | None:
    """Find a release by tag, drafts included (the tags/ endpoint hides
    drafts, so list and match)."""
    for rel in _gh_json_lines(f"repos/{repo}/releases?per_page=100"):
        if rel.get("tag_name") == tag:
            return rel
    return None


def list_assets(release_id: int, repo: str = REPO) -> list[dict]:
    return _gh_json_lines(
        f"repos/{repo}/releases/{release_id}/assets?per_page=100")


def _content_call(args: list[str]) -> subprocess.CompletedProcess:
    PACER.tick()
    return subprocess.run(args, capture_output=True, text=True)


def _delete_asset(asset_id: int, repo: str) -> None:
    proc = _content_call(["gh", "api", "--method", "DELETE",
                          f"repos/{repo}/releases/assets/{asset_id}"])
    if proc.returncode != 0 and "HTTP 404" not in proc.stderr:
        sys.exit(f"asset delete {asset_id} failed:\n{proc.stderr.strip()}")


def _upload_asset(upload_url: str, path: Path, release_id: int,
                  repo: str) -> None:
    """Upload one file, retrying with backoff; cleans up half-uploaded
    ('starter') assets between attempts."""
    ctype = CONTENT_TYPES.get(path.suffix, "application/octet-stream")
    url = f"{upload_url}?name={path.name}"
    for attempt, backoff in enumerate(BACKOFF, 1):
        proc = _content_call(["gh", "api", "--method", "POST", url,
                              "-H", f"Content-Type: {ctype}",
                              "--input", str(path)])
        if proc.returncode == 0:
            state = json.loads(proc.stdout).get("state")
            if state == "uploaded":
                return
        err = proc.stderr.strip().splitlines()[-1] if proc.stderr else "?"
        print(f"  upload {path.name} attempt {attempt} failed ({err}) — "
              f"backoff {backoff}s", flush=True)
        # A failed POST can leave a broken asset that 422s the retry.
        for a in list_assets(release_id, repo):
            if a["name"] == path.name:
                _delete_asset(a["id"], repo)
        time.sleep(backoff)
    sys.exit(f"upload {path.name} failed after {len(BACKOFF)} attempts — "
             f"re-run to resume (already-uploaded assets are skipped)")


def _is_managed(name: str) -> bool:
    return name.endswith(MANAGED_SUFFIXES) or name in MANAGED_NAMES


def reconcile(tag: str, files: list[Path], repo: str = REPO,
              delete_stale: bool = False, dry_run: bool = False) -> None:
    """Bring the release's assets in line with `files` (order preserved:
    callers put catalog/feeds last so links flip only once EPUBs are up)."""
    release = get_release(tag, repo)
    if release is None:
        sys.exit(f"release '{tag}' not found — create it first")
    upload_url = release["upload_url"].split("{")[0]
    remote = {a["name"]: a for a in list_assets(release["id"], repo)}

    local = {p.name: p for p in files}
    if len(local) != len(files):
        sys.exit("duplicate asset names in the local file set")

    broken = [a for a in remote.values() if a.get("state") != "uploaded"]
    to_add, to_replace, skipped = [], [], 0
    for p in files:
        a = remote.get(p.name)
        if a is None or a.get("state") != "uploaded":
            to_add.append(p)
        elif (a.get("digest") or "") == f"sha256:{sha256_file(p)}":
            skipped += 1
        else:
            to_replace.append(p)
    stale = [a for n, a in remote.items()
             if delete_stale and _is_managed(n) and n not in local]

    gone = {a["name"] for a in stale} | {a["name"] for a in broken}
    final_count = len(local) + sum(
        1 for n in remote if n not in local and n not in gone)
    if final_count > MAX_ASSETS:
        sys.exit(f"refusing: release would hold {final_count} assets "
                 f"(GitHub cap 1000, guard {MAX_ASSETS}) — curate the "
                 f"roster (docs/release_asset_cap_2026-07.md)")

    calls = len(broken) + len(to_add) + 2 * len(to_replace) + len(stale)
    print(f"reconcile '{tag}': {len(to_add)} new, {len(to_replace)} changed, "
          f"{skipped} unchanged, {len(stale)} stale, {len(broken)} broken — "
          f"~{calls} content calls "
          f"(~{max(1, -(-calls // HOURLY_BUDGET))}h window(s))", flush=True)
    if dry_run:
        for p in to_add:
            print(f"  ADD     {p.name}")
        for p in to_replace:
            print(f"  REPLACE {p.name}")
        for a in stale:
            print(f"  DELETE  {a['name']}")
        print("dry run — nothing touched")
        return

    for a in broken:
        print(f"  deleting broken upload {a['name']}", flush=True)
        _delete_asset(a["id"], repo)

    add_names = {p.name for p in to_add}
    replace_names = {p.name for p in to_replace}
    done = 0
    for p in files:
        if p.name in replace_names:
            _delete_asset(remote[p.name]["id"], repo)
        if p.name in replace_names or p.name in add_names:
            _upload_asset(upload_url, p, release["id"], repo)
            done += 1
            if done % 50 == 0:
                print(f"  {done}/{len(to_add) + len(to_replace)} uploaded",
                      flush=True)

    for a in stale:
        print(f"  deleting stale {a['name']}", flush=True)
        _delete_asset(a["id"], repo)

    print(f"reconcile done: {done} uploaded, {skipped} skipped, "
          f"{len(stale)} stale removed")


def publish(tag: str, repo: str = REPO, make_latest: bool = False) -> None:
    """Flip a draft release public (atomic go-live after all assets are up)."""
    release = get_release(tag, repo)
    if release is None:
        sys.exit(f"release '{tag}' not found")
    if not release.get("draft"):
        print(f"release '{tag}' already public")
        return
    args = ["gh", "api", "--method", "PATCH",
            f"repos/{repo}/releases/{release['id']}",
            "-F", "draft=false"]
    if make_latest:
        args += ["-f", "make_latest=true"]
    proc = _content_call(args)
    if proc.returncode != 0:
        sys.exit(f"publish failed:\n{proc.stderr.strip()}")
    print(f"release '{tag}' published" + (" (latest)" if make_latest else ""))


def preflight_configs(configs_dir: Path) -> None:
    n = len(list(configs_dir.glob("*/*.yaml")))
    print(f"asset budget preflight: {n} configs "
          f"(cap {EPUB_CONFIG_CAP}; release hard cap 1000 assets incl. "
          f"~60 feeds + catalog + components)")
    if n > EPUB_CONFIG_CAP:
        sys.exit(f"FAIL: {n} configs exceeds the {EPUB_CONFIG_CAP} cap — "
                 f"the published roster must shrink before this builds "
                 f"(cap-and-curate, docs/release_asset_cap_2026-07.md)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--tag")
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--delete-stale", action="store_true",
                    help="delete managed remote assets (*.epub, *.xml, "
                         "catalog.json) with no local counterpart")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--publish", action="store_true",
                    help="flip the draft release public after reconciling")
    ap.add_argument("--make-latest", action="store_true")
    ap.add_argument("--preflight-configs", type=Path, metavar="DIR")
    args = ap.parse_args()

    if args.preflight_configs:
        preflight_configs(args.preflight_configs)
        return
    if not args.tag:
        ap.error("--tag is required (unless --preflight-configs)")
    if args.files:
        missing = [str(p) for p in args.files if not p.is_file()]
        if missing:
            sys.exit(f"missing local files: {missing[:5]}")
        reconcile(args.tag, args.files, repo=args.repo,
                  delete_stale=args.delete_stale, dry_run=args.dry_run)
    if args.publish and not args.dry_run:
        publish(args.tag, repo=args.repo, make_latest=args.make_latest)


if __name__ == "__main__":
    main()
