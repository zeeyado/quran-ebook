"""Pre-build endpoint & config health checks (`quran-ebook preflight`).

The release build makes ~7,300 live API calls over ~40 minutes; a dead or
drifted endpoint should fail in SECONDS, not mid-run. This module derives
its probe matrix FROM the configs — walk every YAML, collect exactly the
scripts/resources/editions/gloss-languages/fonts the build will fetch —
so preflight can never drift from reality. ~2 dozen cheap probes with
schema-sanity assertions, full pass/fail table (no fail-fast: the whole
table is the point), exit 1 on any failure.

Design: docs/production_push_2026-07.md Wave 2 (from the ci_fetch
assessment in docs/production_push_reports/).
"""

import time
from pathlib import Path

import click
import httpx

from .config.schema import _VARIANT_STRUCT, BuildConfig, load_config
from .data.kfgqpc import _CDN_BASE, _RIWAYAH_FILES
from .data.quran_api import BASE_URL
from .fonts.manager import get_font_path

_FAWAZ_CDN = "https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1"
_QUL_BASE = "https://qul.tarteel.ai/api/v1"
_TIMEOUT = 30.0


class _Report:
    def __init__(self):
        self.rows: list[tuple[str, bool, str]] = []

    def add(self, name: str, ok: bool, detail: str = ""):
        self.rows.append((name, ok, detail))

    @property
    def failed(self) -> list[tuple[str, bool, str]]:
        return [r for r in self.rows if not r[1]]

    def print(self):
        width = max((len(r[0]) for r in self.rows), default=20)
        for name, ok, detail in self.rows:
            mark = click.style("PASS", fg="green") if ok else click.style("FAIL", fg="red")
            line = f"  {name:<{width}}  {mark}"
            if detail:
                line += f"  {detail}"
            click.echo(line)


def _collect(config_paths: list[Path], report: _Report) -> dict:
    """Load every config and collect the exact upstream requirements."""
    req = {
        "api_scripts": set(),      # quran.script values fetched from api.quran.com
        "resource_ids": set(),     # quran_api translation resource ids
        "editions": set(),         # fawazahmed0 edition keys
        "qul_translations": set(), # qul translation resource ids
        "qul_tafsirs": set(),      # qul_tafsir resource ids (translation-slot or tafsir-slot)
        "gloss_langs": set(),      # WBW word-fetch languages
        "kfgqpc_riwayat": set(),   # kfgqpc CDN riwayah keys
        "local_editions": set(),   # bundled repo-data editions (source=local)
        "fonts": set(),
        "configs": [],
    }
    bad_structures, load_errors, bad_translations = [], [], []
    for path in config_paths:
        try:
            cfg: BuildConfig = load_config(str(path))
        except Exception as e:  # noqa: BLE001 — report, don't crash the table
            load_errors.append(f"{path}: {e}")
            continue
        req["configs"].append((path, cfg))
        if cfg.layout.structure not in _VARIANT_STRUCT:
            bad_structures.append(f"{path}: {cfg.layout.structure!r}")
        req["fonts"].add(cfg.font.arabic)
        if cfg.quran.source == "quran_api":
            req["api_scripts"].add(cfg.quran.script)
        elif cfg.quran.source == "kfgqpc":
            # kfgqpc script keys look like qpc_uthmani_warsh → riwayah "warsh"
            req["kfgqpc_riwayat"].add(cfg.quran.script.rsplit("_", 1)[-1])
        if cfg.translation:
            src = cfg.translation.source
            if src == "quran_api":
                if cfg.translation.resource_id is None:
                    bad_translations.append(f"{path}: quran_api translation without resource_id")
                else:
                    req["resource_ids"].add(cfg.translation.resource_id)
            elif src == "fawazahmed0":
                if not cfg.translation.edition:
                    bad_translations.append(f"{path}: fawazahmed0 translation without edition")
                else:
                    req["editions"].add(cfg.translation.edition)
            elif src == "qul":
                req["qul_translations"].add(cfg.translation.resource_id)
            elif src == "qul_tafsir":
                req["qul_tafsirs"].add(cfg.translation.resource_id)
            elif src == "local":
                # The loader REQUIRES a non-empty edition (quran_api.py:517);
                # an empty one silently drops the translation at build time.
                if not cfg.translation.edition:
                    bad_translations.append(f"{path}: source=local requires translation.edition")
                else:
                    req["local_editions"].add(cfg.translation.edition)
        if cfg.tafsir:
            # source "qul" resources are served by /translations/by_range,
            # "qul_tafsir" by /tafsirs/by_range — probe the right endpoint
            if cfg.tafsir.source == "qul":
                req["qul_translations"].add(cfg.tafsir.resource_id)
            else:
                req["qul_tafsirs"].add(cfg.tafsir.resource_id)
        if cfg.layout.structure == "wbw":
            gloss = cfg.layout.wbw_gloss_language or (
                cfg.translation.language if cfg.translation else "en"
            )
            req["gloss_langs"].add(gloss)

    report.add(
        f"configs load ({len(config_paths)} files)",
        not load_errors,
        "; ".join(load_errors[:3]),
    )
    report.add(
        "layout.structure whitelist (kills silent by_surah fallback)",
        not bad_structures,
        "; ".join(bad_structures[:3]),
    )
    report.add(
        "translation source fields complete",
        not bad_translations,
        "; ".join(bad_translations[:3]),
    )
    return req


def _offline_checks(req: dict, report: _Report):
    # Fonts resolve (bundled asset, cache, or downloadable registry entry)
    missing = []
    for key in sorted(req["fonts"]):
        try:
            get_font_path(key)
        except Exception as e:  # noqa: BLE001
            missing.append(f"{key}: {e}")
    report.add(f"fonts resolve ({len(req['fonts'])})", not missing, "; ".join(missing))

    # Bundled repo data for source=local configs — mirror the loader's own
    # resolution (quran_api._load_local_translation: repo-root data/{edition}/)
    for edition in sorted(req["local_editions"]):
        bundled = Path(__file__).resolve().parent.parent.parent / "data" / edition / "1.json"
        report.add(f"bundled data/{edition} (source=local)", bundled.exists(),
                   "" if bundled.exists() else f"missing {bundled}")


def _get(client: httpx.Client, url: str, **kw) -> httpx.Response:
    """Probe fetch, at least as fault-tolerant as the build's _api_get.

    Retries TransportError (timeout/connect/reset) and 5xx up to 3 attempts
    with short backoff — a gate flakier than the build it gates would kill
    releases on transient blips. Persistent failure still surfaces as FAIL.
    """
    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            r = client.get(url, **kw)
            if r.status_code >= 500 and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            return r
        except httpx.TransportError as e:
            last_exc = e
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
    raise last_exc  # type: ignore[misc]


def _online_checks(req: dict, report: _Report):
    with httpx.Client(timeout=_TIMEOUT, follow_redirects=True) as client:
        # 1. api.quran.com core: exactly 114 chapters
        try:
            r = _get(client, f"{BASE_URL}/chapters")
            chapters = r.json().get("chapters", [])
            report.add("api.quran.com /chapters == 114", r.status_code == 200 and len(chapters) == 114,
                       f"status={r.status_code} count={len(chapters)}")
        except Exception as e:  # noqa: BLE001
            report.add("api.quran.com /chapters == 114", False, repr(e)[:100])

        # 2. Verse text per script actually used
        for script in sorted(req["api_scripts"]):
            name = f"verses field {script} (1:1-7 non-empty)"
            try:
                r = _get(client, f"{BASE_URL}/verses/by_chapter/1",
                         params={"fields": script, "per_page": 10})
                verses = r.json().get("verses", [])
                ok = len(verses) == 7 and all(v.get(script) for v in verses)
                report.add(name, ok, f"count={len(verses)}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

        # 3. Translation catalog ⊇ every configured resource_id — the
        #    highest-value probe: a renumbered/removed resource becomes a
        #    2-second failure instead of a 404 at call ~3,000.
        if req["resource_ids"]:
            name = f"translation catalog covers {len(req['resource_ids'])} resource_ids"
            try:
                r = _get(client, f"{BASE_URL}/resources/translations")
                have = {t["id"] for t in r.json().get("translations", [])}
                missing = sorted(req["resource_ids"] - have)
                report.add(name, not missing, f"missing={missing}" if missing else "")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

            # 4. Deep-probe the dominant endpoint's shape with one id
            rid = sorted(req["resource_ids"])[0]
            name = f"translation {rid} ch1 non-empty (+footnotes shape)"
            try:
                r = _get(client, f"{BASE_URL}/quran/translations/{rid}",
                         params={"chapter_number": 1, "foot_notes": "true"})
                trs = r.json().get("translations", [])
                ok = len(trs) == 7 and all(t.get("text") for t in trs)
                report.add(name, ok, f"count={len(trs)}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

        # 4b. /resources/languages — fetched by every translation-bearing build
        if req["resource_ids"] or req["editions"] or req["gloss_langs"]:
            try:
                r = _get(client, f"{BASE_URL}/resources/languages")
                langs = r.json().get("languages", [])
                ok = bool(langs) and any(l.get("iso_code") == "en" for l in langs)
                report.add("resources/languages shape", ok, f"count={len(langs)}")
            except Exception as e:  # noqa: BLE001
                report.add("resources/languages shape", False, repr(e)[:100])

        # 5. Surah-name translation shape (English-fallback path guard)
        try:
            r = _get(client, f"{BASE_URL}/chapters", params={"language": "fr"})
            ch1 = r.json().get("chapters", [{}])[0]
            ok = bool(ch1.get("translated_name", {}).get("name"))
            report.add("chapters?language= shape (translated_name)", ok)
        except Exception as e:  # noqa: BLE001
            report.add("chapters?language= shape (translated_name)", False, repr(e)[:100])

        # 6. WBW words per configured gloss language (silent-truncation guard)
        for lang in sorted(req["gloss_langs"]):
            name = f"WBW words lang={lang} (translation objects present)"
            try:
                r = _get(client, f"{BASE_URL}/verses/by_chapter/1",
                         params={"words": "true", "word_fields": "text_qpc_hafs",
                                 "language": lang, "per_page": 10})
                verses = r.json().get("verses", [])
                words = verses[0].get("words", []) if verses else []
                ok = bool(words) and all("translation" in w for w in words)
                report.add(name, ok, f"words={len(words)}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

        # 7. fawazahmed0 editions on jsDelivr
        for edition in sorted(req["editions"]):
            name = f"fawazahmed0 edition {edition}"
            try:
                r = _get(client, f"{_FAWAZ_CDN}/editions/{edition}/1.json")
                ok = r.status_code == 200 and len(r.json().get("chapter", [])) == 7
                report.add(name, ok, f"status={r.status_code}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

        # 8. KFGQPC CDN per configured riwayah (the only no-retry fetch in
        #    the text path — HEAD keeps the probe cheap, the file is ~10MB)
        for riwayah in sorted(req["kfgqpc_riwayat"]):
            name = f"kfgqpc CDN {riwayah}"
            try:
                json_path = _RIWAYAH_FILES[riwayah][0]
                r = client.head(f"{_CDN_BASE}/{json_path}")
                report.add(name, r.status_code == 200, f"status={r.status_code}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])

        # 9. QUL by_range NON-EMPTY (defends the silent-empty parse path in
        #    qul_api._parse_qul_response) — only if any config uses QUL
        for rid in sorted(req["qul_tafsirs"]):
            name = f"QUL tafsir {rid} by_range 1:1-1:7 non-empty"
            try:
                r = _get(client, f"{_QUL_BASE}/tafsirs/{rid}/by_range",
                         params={"from": "1:1", "to": "1:7"})
                entries = r.json().get("tafsirs", r.json().get("data", []))
                ok = bool(entries) and any(
                    (e.get("text") or "").strip() for e in entries if isinstance(e, dict)
                )
                report.add(name, ok, f"entries={len(entries) if entries else 0}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])
        for rid in sorted(req["qul_translations"]):
            name = f"QUL translation {rid} by_range 1:1-1:7 non-empty"
            try:
                r = _get(client, f"{_QUL_BASE}/translations/{rid}/by_range",
                         params={"from": "1:1", "to": "1:7"})
                entries = r.json().get("translations", r.json().get("data", []))
                ok = bool(entries) and any(
                    (e.get("text") or "").strip() for e in entries if isinstance(e, dict)
                )
                report.add(name, ok, f"entries={len(entries) if entries else 0}")
            except Exception as e:  # noqa: BLE001
                report.add(name, False, repr(e)[:100])


def run_preflight(configs_dir: str) -> int:
    """Run all checks; return process exit code (0 = all green)."""
    config_paths = sorted(Path(configs_dir).rglob("*.yaml"))
    if not config_paths:
        click.secho(f"No configs found under {configs_dir}/", fg="red")
        return 1
    report = _Report()
    req = _collect(config_paths, report)
    _offline_checks(req, report)
    _online_checks(req, report)
    report.print()
    n_fail = len(report.failed)
    total = len(report.rows)
    if n_fail:
        click.secho(f"\npreflight: {n_fail}/{total} checks FAILED — do not start the build.", fg="red")
        return 1
    click.secho(f"\npreflight: all {total} checks passed.", fg="green")
    return 0
