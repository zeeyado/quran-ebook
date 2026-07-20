"""Command-line interface for quran-ebook."""

import re
import shutil
import subprocess
import zipfile
from pathlib import Path

import click

from .config.schema import load_config
from .data.cache import cache_clear
from .data.validate import AYAH_COUNTS_HAFS, AYAH_COUNTS_WARSH
from .epub.builder import build_epub

_AYAH_ID_RE = re.compile(r'id="ayah-(\d+)-(\d+)"')
_MIN_COVER_BYTES = 1000  # Cover PNG should be at least 1KB

@click.group()
@click.version_option()
def main():
    """Quran Ebook Generator — build beautiful Quran EPUBs."""


@main.command()
@click.argument("config_paths", nargs=-1, type=click.Path(exists=True))
@click.option(
    "--all",
    "build_all",
    type=click.Path(exists=True, file_okay=False),
    default=None,
    help="Build all .yaml configs in the given directory (recursive).",
)
@click.option(
    "--cached",
    is_flag=True,
    help="Unattended: reuse cached data regardless of age, never prompt.",
)
@click.option(
    "--fresh",
    is_flag=True,
    help="Full data refresh: re-fetch ALL cached data regardless of age, "
    "never prompt (the release-refresh fetch; ~30-60 min for --all).",
)
@click.option(
    "--offline",
    is_flag=True,
    help="Snapshot builds: reuse cache regardless of age; a cache MISS is a "
    "hard error — the build never reaches the network.",
)
def build(
    config_paths: tuple[str, ...],
    build_all: str | None,
    cached: bool,
    fresh: bool,
    offline: bool,
):
    """Build EPUBs from one or more YAML configuration files.

    Pass one or more config paths, or use --all DIR to build every .yaml in DIR.
    """
    if sum((cached, fresh, offline)) > 1:
        click.secho(
            "--cached, --fresh and --offline are mutually exclusive.",
            fg="red", err=True,
        )
        raise SystemExit(1)
    if cached or fresh or offline:
        from .data.cache import set_stale_policy

        set_stale_policy("offline" if offline else "reuse" if cached else "refetch")

    if build_all is not None:
        search_dir = Path(build_all)
        config_paths = tuple(str(p) for p in sorted(search_dir.rglob("*.yaml")))
        if not config_paths:
            click.secho(f"No .yaml files found in {search_dir}/.", fg="red", err=True)
            raise SystemExit(1)

    if not config_paths:
        click.secho("Provide one or more config paths, or use --all.", fg="red", err=True)
        raise SystemExit(1)

    failed = []
    for config_path in config_paths:
        click.echo(f"\nBuilding: {config_path}")
        try:
            config = load_config(config_path)
            for warning in config.warnings:
                click.secho(f"  Warning: {warning}", fg="yellow", err=True)
            output_path = build_epub(config)
            click.secho(f"  Done: {output_path}", fg="green")
        except Exception as e:
            click.secho(f"  Failed: {e}", fg="red", err=True)
            failed.append(config_path)

    if failed:
        click.secho(f"\n{len(failed)} build(s) failed: {', '.join(failed)}", fg="red", err=True)
        raise SystemExit(1)


# One cell per template family / formatting regime — the fast visual
# regression sweep. Born from the centered ayah-popup catch (owner
# 2026-07-19): every rule here covers a distinct CSS/template surface, so a
# formatting break anywhere in the matrix shows up in ~a dozen books.
EYEBALL_SET = [
    "configs/arabic/hafs_inline.yaml",       # flowing Arabic (.surah-text)
    "configs/arabic/hafs_ayah.yaml",         # standalone ayah blocks (right-aligned)
    "configs/arabic/indopak_ayah.yaml",      # Nastaleeq + ayah_marker branch + PUA armor
    "configs/bilingual/en_sahih.yaml",       # bilingual ayah-by-ayah (.bilin)
    "configs/bilingual/en_sahih_warsh.yaml",  # Warsh script + alignment table
    "configs/bilingual-interactive/en_sahih_mukhtasar.yaml",  # grouped tafsir popups
    "configs/interactive/en_sahih.yaml",     # flowing + popup translation
    "configs/interactive/ar_mukhtasar.yaml",  # tafsir-as-text flow
    "configs/ayah-popup/en_sahih.yaml",      # ayah blocks + popup translation
    "configs/wbw/en_indopak.yaml",           # word-by-word + Nastaleeq + 15-line pagemap
    "configs/wbw/en_glosses_only.yaml",      # glosses-only wbw pilot
]

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent


@main.command()
@click.option("--fresh", is_flag=True, help="Re-fetch stale data instead of reusing.")
def eyeball(fresh: bool):
    """Build one cell per base type into output/eyeball/ for visual review.

    The folder is cleared on every run, so it only ever holds the current
    sweep. Open the results in KOReader after template/CSS changes — this is
    the quick catch for formatting regressions across the whole matrix.
    """
    from .data.cache import set_stale_policy

    set_stale_policy("refetch" if fresh else "reuse")

    missing = [p for p in EYEBALL_SET if not (_REPO_ROOT / p).exists()]
    if missing:
        click.secho(
            "EYEBALL_SET is stale — missing configs (update the list in cli.py):",
            fg="red", err=True,
        )
        for p in missing:
            click.echo(f"  {p}", err=True)
        raise SystemExit(1)

    out_dir = _REPO_ROOT / "output" / "eyeball"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)

    failed = []
    for rel in EYEBALL_SET:
        click.echo(f"\nBuilding: {rel}")
        try:
            config = load_config(_REPO_ROOT / rel)
            config.output.directory = str(out_dir)
            for warning in config.warnings:
                click.secho(f"  Warning: {warning}", fg="yellow", err=True)
            output_path = build_epub(config)
            click.secho(f"  Done: {output_path}", fg="green")
        except Exception as e:
            click.secho(f"  Failed: {e}", fg="red", err=True)
            failed.append(rel)

    click.echo()
    if failed:
        click.secho(f"{len(failed)} eyeball build(s) failed: {', '.join(failed)}",
                    fg="red", err=True)
        raise SystemExit(1)
    click.secho(f"Eyeball set ready: {len(EYEBALL_SET)} EPUBs in {out_dir}/", fg="green")


@main.command()
@click.argument("configs_dir", default="configs", type=click.Path(exists=True, file_okay=False))
def preflight(configs_dir: str):
    """Probe every endpoint the build will hit BEFORE the 40-minute build.

    Derives the probe matrix from the configs themselves (~2 dozen cheap
    calls with schema checks); prints a full pass/fail table; exits 1 on
    any failure. Run as a release.yml gate and before local full builds.
    """
    from .preflight import run_preflight

    raise SystemExit(run_preflight(configs_dir))


@main.command()
@click.argument("directory", default="output", type=click.Path(exists=True, file_okay=False))
@click.option("--no-epubcheck", is_flag=True, help="Skip epubcheck, only run content verification.")
def validate(directory: str, no_epubcheck: bool):
    """Validate all EPUB files in DIRECTORY (default: output/).

    Runs two passes:
      1. Content verification — 114 surahs, ayah counts per riwayah, cover image.
      2. epubcheck — EPUB3 structural conformance.

    Use --no-epubcheck to skip the second pass (faster, no Java dependency).
    """
    epub_files = sorted(Path(directory).glob("*.epub"))
    if not epub_files:
        click.secho(f"No .epub files found in {directory}/.", fg="red", err=True)
        raise SystemExit(1)

    total = len(epub_files)

    # Pass 1: Content verification
    click.secho("Content verification...", bold=True)
    content_failed = []
    for i, epub_path in enumerate(epub_files, 1):
        errors = _verify_epub_content(epub_path)
        if errors:
            click.secho(f"[{i}/{total}] FAIL: {epub_path.name}", fg="red")
            for err in errors:
                click.echo(f"  {err}")
            content_failed.append(epub_path.name)
        else:
            click.secho(f"[{i}/{total}] OK: {epub_path.name}", fg="green")

    click.echo()
    if content_failed:
        click.secho(
            f"Content: {len(content_failed)}/{total} failed", fg="red", err=True
        )
    else:
        click.secho(f"Content: all {total} EPUBs OK.", fg="green")

    # Pass 2: epubcheck
    if no_epubcheck:
        click.echo("Skipping epubcheck (--no-epubcheck).")
    else:
        epubcheck_bin = shutil.which("epubcheck")
        if epubcheck_bin is None:
            click.secho(
                "epubcheck not found — skipping. Install with: brew install epubcheck",
                fg="yellow", err=True,
            )
        else:
            click.echo()
            click.secho("Running epubcheck...", bold=True)
            epubcheck_failed = []
            for i, epub_path in enumerate(epub_files, 1):
                result = subprocess.run(
                    [epubcheck_bin, str(epub_path)],
                    capture_output=True, text=True,
                )
                if result.returncode != 0:
                    errs = [l for l in result.stderr.splitlines() if "ERROR" in l or "FATAL" in l]
                    click.secho(f"[{i}/{total}] FAIL ({len(errs)}): {epub_path.name}", fg="red")
                    for err in errs[:5]:
                        click.echo(f"  {err}")
                    if len(errs) > 5:
                        click.echo(f"  ... and {len(errs) - 5} more errors")
                    epubcheck_failed.append(epub_path.name)
                else:
                    click.secho(f"[{i}/{total}] OK: {epub_path.name}", fg="green")

            click.echo()
            if epubcheck_failed:
                click.secho(
                    f"epubcheck: {len(epubcheck_failed)}/{total} failed", fg="red", err=True
                )
                content_failed.extend(epubcheck_failed)
            else:
                click.secho(f"epubcheck: all {total} EPUBs passed.", fg="green")

    if content_failed:
        click.echo()
        click.secho("FAILED:", fg="red", err=True)
        for name in sorted(set(content_failed)):
            click.echo(f"  {name}", err=True)
        raise SystemExit(1)


def _verify_epub_content(epub_path: Path) -> list[str]:
    """Verify EPUB content integrity: chapters, ayah counts, cover image."""
    # Detect riwayah from filename — old scheme `quran_warsh_...` and
    # frozen grammar v1 `quran_warsh-uthmani_...` both start the second
    # token with "warsh".
    is_warsh = "_warsh_" in epub_path.name or "_warsh-" in epub_path.name
    ayah_counts = AYAH_COUNTS_WARSH if is_warsh else AYAH_COUNTS_HAFS
    expected_total = sum(ayah_counts.values())

    errors = []
    try:
        with zipfile.ZipFile(epub_path) as zf:
            names = set(zf.namelist())

            # Check 114 chapter files
            chapter_files = sorted(
                n for n in names if n.startswith("OEBPS/chapter-") and n.endswith(".xhtml")
            )
            if len(chapter_files) != 114:
                errors.append(f"Expected 114 chapter files, found {len(chapter_files)}")

            # Check ayah counts per chapter
            total_ayahs = 0
            for chapter_file in chapter_files:
                content = zf.read(chapter_file).decode("utf-8")
                matches = _AYAH_ID_RE.findall(content)
                surah_num = int(chapter_file.split("chapter-")[1].split(".")[0])
                actual = len(matches)
                total_ayahs += actual
                expected = ayah_counts.get(surah_num)
                if expected is not None and actual != expected:
                    errors.append(
                        f"chapter-{surah_num}: expected {expected} ayahs, got {actual}"
                    )

            if total_ayahs != expected_total:
                errors.append(f"Total ayahs: expected {expected_total}, got {total_ayahs}")

            # Cover image
            if "OEBPS/cover.png" not in names:
                errors.append("Missing cover.png")
            else:
                cover_size = zf.getinfo("OEBPS/cover.png").file_size
                if cover_size < _MIN_COVER_BYTES:
                    errors.append(f"cover.png suspiciously small ({cover_size} bytes)")

    except zipfile.BadZipFile:
        errors.append("Not a valid ZIP file")
    return errors


@main.command()
def clear_cache():
    """Clear all cached data and fonts."""
    count = cache_clear()
    click.echo(f"Cleared {count} cached files.")


@main.group()
def snapshot():
    """Pin, verify and pack the upstream data a release builds from.

    Flow: `build --fresh` (or targeted builds) refreshes .cache → `snapshot
    diff` reviews what changed upstream → `snapshot make` commits the pin →
    `snapshot pack` + scripts/upload_data_snapshot.py publish the tarball.
    CI unpacks the tarball, runs `snapshot verify`, then builds --offline.
    """


@snapshot.command("make")
def snapshot_make():
    """Write data/snapshot_manifest.json from the current .cache contents."""
    from .data.snapshot import scan_cache, write_manifest

    entries, corrupt = scan_cache()
    if corrupt:
        click.secho(f"{len(corrupt)} corrupt cache entries — refusing to pin:",
                    fg="red", err=True)
        for k in corrupt[:20]:
            click.echo(f"  {k}", err=True)
        raise SystemExit(1)
    if not entries:
        click.secho("Cache is empty — nothing to pin.", fg="red", err=True)
        raise SystemExit(1)
    path = write_manifest(entries)
    click.secho(f"Pinned {len(entries)} cache entries → {path}", fg="green")


@snapshot.command("verify")
def snapshot_verify():
    """Check local .cache against the committed manifest (CI gate)."""
    from .data.snapshot import by_category, compare, load_manifest, scan_cache

    manifest = load_manifest()
    entries, corrupt = scan_cache()
    d = compare(entries, manifest)
    ok = not (d["changed"] or d["missing"] or corrupt)
    for label, keys in (("changed", d["changed"]), ("missing", d["missing"]),
                        ("corrupt", corrupt)):
        if keys:
            click.secho(f"{label}: {len(keys)} entries", fg="red")
            for cat, n in sorted(by_category(keys).items()):
                click.echo(f"  {cat} ×{n}")
    if d["extra"]:
        click.secho(f"extra (unpinned, ignored): {len(d['extra'])} entries",
                    fg="yellow")
    if not ok:
        click.secho("Snapshot verify FAILED — cache does not match the "
                    "committed manifest.", fg="red", err=True)
        raise SystemExit(1)
    click.secho(f"Snapshot verified: {len(manifest)} pinned entries match.",
                fg="green")


@snapshot.command("diff")
@click.option("--only-cached", is_flag=True,
              help="Compare only keys present locally (canary drift checks).")
@click.option("--fail-on-change", is_flag=True,
              help="Exit 3 when any pinned entry changed (drift-check gate).")
def snapshot_diff(only_cached: bool, fail_on_change: bool):
    """Report upstream drift: current .cache vs the committed manifest."""
    from .data.snapshot import by_category, compare, load_manifest, scan_cache

    manifest = load_manifest()
    entries, _ = scan_cache()
    d = compare(entries, manifest, only_cached=only_cached)
    if not (d["changed"] or d["missing"] or d["extra"]):
        click.secho("No drift — cache matches the committed manifest.", fg="green")
        return
    for label, keys in d.items():
        if keys:
            click.secho(f"{label}: {len(keys)} entries", bold=True)
            for cat, n in sorted(by_category(keys).items()):
                click.echo(f"  {cat} ×{n}")
    if fail_on_change and (d["changed"] or d["missing"]):
        raise SystemExit(3)


@snapshot.command("content-diff")
@click.option("--old", "old_path", default="output/quran-data-snapshot.tar.gz",
              show_default=True,
              help="Previous snapshot tarball to diff against (download from "
                   "the data-snapshot release if you re-packed already).")
@click.option("--out", "out_path", default="output/snapshot_content_diff.md",
              show_default=True)
@click.option("--max-lines", default=200, show_default=True,
              help="Per-entry diff cap in the report (truncation is marked).")
def snapshot_content_diff(old_path: str, out_path: str, max_lines: int):
    """What actually CHANGED inside the data: current .cache vs the old tarball.

    The release-refresh review tool: after `build --fresh`, run this to read
    the real text differences (upstream fixes, edits, removals) before
    re-pinning. Writes a markdown report; prints the category summary.
    """
    import difflib

    from .data.snapshot import (
        _cache_category, get_cache_dir, iter_tarball_entries,
        load_cache_value, render_value,
    )

    old = Path(old_path)
    if not old.exists():
        click.secho(
            f"No old tarball at {old} — download it first:\n"
            f"  gh release download data-snapshot -p quran-data-snapshot.tar.gz "
            f"--dir output", fg="red", err=True)
        raise SystemExit(1)

    cache_dir = get_cache_dir()
    local_keys = {f.stem for f in cache_dir.glob("*.json")}

    changed: dict[str, list[str]] = {}
    removed: list[str] = []
    seen_keys: set[str] = set()
    for key, old_value in iter_tarball_entries(old):
        seen_keys.add(key)
        if key not in local_keys:
            removed.append(key)
            continue
        new_value = load_cache_value(key, cache_dir)
        if new_value == old_value:
            continue
        diff = list(difflib.unified_diff(
            render_value(old_value), render_value(new_value),
            fromfile=f"{key} (old snapshot)", tofile=f"{key} (current cache)",
            lineterm="", n=2,
        ))
        changed[key] = diff
    added = sorted(local_keys - seen_keys)

    def cat_counts(keys) -> str:
        counts: dict[str, int] = {}
        for k in keys:
            c = _cache_category(k)
            counts[c] = counts.get(c, 0) + 1
        return ", ".join(f"{c} ×{n}" for c, n in sorted(counts.items()))

    lines = ["# Snapshot content diff", "",
             f"old: `{old}`  ·  current: `{cache_dir}`", "",
             f"- changed: {len(changed)} entries"
             + (f" ({cat_counts(changed)})" if changed else ""),
             f"- added (not in old snapshot): {len(added)}"
             + (f" ({cat_counts(added)})" if added else ""),
             f"- removed (gone locally): {len(removed)}"
             + (f" ({cat_counts(removed)})" if removed else ""), ""]
    for key in sorted(changed):
        diff = changed[key]
        lines += [f"## {key}", "", "```diff"]
        lines += diff[:max_lines]
        if len(diff) > max_lines:
            lines.append(f"… truncated: {len(diff) - max_lines} more diff lines")
        lines += ["```", ""]
    if added:
        lines += ["## Added entries", ""] + [f"- {k}" for k in added] + [""]
    if removed:
        lines += ["## Removed entries", ""] + [f"- {k}" for k in removed] + [""]

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    if not (changed or added or removed):
        click.secho("No content differences — cache matches the old snapshot.",
                    fg="green")
        return
    click.secho(f"changed: {len(changed)}  added: {len(added)}  "
                f"removed: {len(removed)}", bold=True)
    if changed:
        click.echo(f"  changed by category: {cat_counts(changed)}")
    click.secho(f"Report: {out}", fg="green")


@snapshot.command("pack")
@click.option("--output", "out",
              default="output/quran-data-snapshot.tar.gz", show_default=True)
def snapshot_pack(out: str):
    """Tar .cache into the snapshot tarball (refuses on manifest mismatch)."""
    from .data.snapshot import compare, load_manifest, pack, scan_cache

    manifest = load_manifest()
    entries, corrupt = scan_cache()
    d = compare(entries, manifest)
    if d["changed"] or d["missing"] or corrupt:
        click.secho(
            "Cache does not match the committed manifest — run `snapshot "
            "verify` for details, and `snapshot make` if the change is "
            "intended. A packed snapshot must always match the pin.",
            fg="red", err=True,
        )
        raise SystemExit(1)
    dest = pack(Path(out))
    size_mb = dest.stat().st_size / 1024 / 1024
    click.secho(f"Packed {len(entries)} entries → {dest} ({size_mb:.0f} MB)",
                fg="green")


if __name__ == "__main__":
    main()
