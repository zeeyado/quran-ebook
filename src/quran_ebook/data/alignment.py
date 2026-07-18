"""Hafs↔Warsh ayah alignment — attach Hafs-keyed translations to Warsh mushafs.

All translations/tafsirs are keyed by Hafs/Kufan ayah numbers; the Warsh
(Madani) numbering differs in 59 surahs (50 by count, 9 by boundary only).
`data/hafs_warsh_alignment.json` maps each Hafs ayah to the range of Warsh
ayahs its text occupies (generated + machine-verified — see
docs/warsh_alignment_design.md). Here we invert it: each Warsh ayah shows
the translation(s) of every Hafs ayah covering it.

Rendering decisions (owner-tuned 2026-07-10, beta):
- A Warsh ayah covered by SEVERAL Hafs ayahs (merge, e.g. Warsh 2:1 = Hafs
  2:1+2:2) concatenates their translations, each prefixed "(H)" with its
  Hafs number — the only place the prefix appears; two translations under
  one ayah need the boundary marked.
- Simple SHIFTS (most divergent ayahs) and SPLITS show the translation
  plain — the owner found per-ayah "(H)" prefixes noisy; the Hafs keying
  is documented in the beta notes instead.
- Footnotes are processed per Hafs ayah (ids stay unique) and concatenated.
"""

import json
from pathlib import Path

import click
import httpx

from ..models import Mushaf
from .qul_api import fetch_qul_tafsir, fetch_qul_translation
from .quran_api import (
    _fetch_fawazahmed0_translation,
    _fetch_translation,
    _load_local_translation,
    _process_translation_text,
)

_ALIGNMENT_PATH = (
    Path(__file__).resolve().parent.parent.parent.parent
    / "data" / "hafs_warsh_alignment.json"
)


def load_alignment() -> dict[int, list[list[int]]]:
    """{surah: [[w_first, w_last], ...]} — list index i = Hafs ayah i+1."""
    data = json.loads(_ALIGNMENT_PATH.read_text(encoding="utf-8"))
    return {int(s): v for s, v in data["hafs_to_warsh"].items()}


def attach_translations_via_alignment(
    mushaf: Mushaf,
    resource_id: int | None,
    source: str = "quran_api",
    edition: str = "",
) -> None:
    """Fetch a Hafs-keyed translation and attach it to a Warsh mushaf in place.

    Dispatches on the translation source exactly like the Hafs loader
    (quran_api.py) — every source is Hafs-keyed, so the alignment step
    is identical downstream.
    """
    alignment = load_alignment()
    click.echo("  Attaching Hafs-keyed translation via alignment table...")

    with httpx.Client(timeout=30) as client:
        for surah in mushaf.surahs:
            s = surah.number
            h2w = alignment[s]
            if source == "local":
                trans, _ = _load_local_translation(s, edition)
            elif source == "fawazahmed0":
                trans, _ = _fetch_fawazahmed0_translation(client, s, edition)
            elif source == "qul":
                trans, _ = fetch_qul_translation(client, s, resource_id, len(h2w))
            elif source == "qul_tafsir":
                trans, _ = fetch_qul_tafsir(client, s, resource_id, len(h2w))
            else:
                trans, _ = _fetch_translation(client, s, resource_id)
            if len(trans) != len(h2w):
                raise ValueError(
                    f"surah {s}: translation has {len(trans)} ayahs, "
                    f"alignment expects {len(h2w)} (Hafs count)"
                )

            # Invert: warsh ayah -> list of Hafs ayah numbers covering it
            covering: dict[int, list[int]] = {}
            for h_idx, (w_first, w_last) in enumerate(h2w):
                for w in range(w_first, w_last + 1):
                    covering.setdefault(w, []).append(h_idx + 1)

            for ayah in surah.ayahs:
                hafs_list = covering.get(ayah.ayah_number, [])
                parts = []
                footnotes = []
                for h in hafs_list:
                    td = trans[h - 1]
                    text, notes = _process_translation_text(
                        td["text"], td.get("foot_notes", {}), s
                    )
                    if not text:
                        continue
                    # "(H)" prefix only when this ayah carries MULTIPLE
                    # translations (merge) — the boundary must be marked.
                    if len(hafs_list) > 1:
                        parts.append(f"({h}) {text}")
                    else:
                        parts.append(text)
                    footnotes.extend(notes)
                if parts:
                    ayah.translation = " ".join(parts)
                    ayah.footnotes = footnotes
