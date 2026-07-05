<!-- v0.11.0 --> <!-- DRAFT — rewrite before tagging; gen_release_body.py refuses to run if this first line doesn't contain the tag being released -->

DRAFT — coordinated release notes (v0.11.0 EPUBs + rebuilt dictionaries + plugin v1.11). To be completed at tag time per docs/production_push_2026-07.md. Planned headline sections:

- **New naming scheme (one-time migration)** — all EPUB filenames move to the structural scheme; old names remain as duplicate download aliases for this release only. **To keep your highlights/progress:** rename the book *inside KOReader's file manager* (it moves the sidecar automatically), or rename both `old.epub → new.epub` AND `old.sdr → new.sdr` before overwriting. Full old→new mapping table below. Note: the old `inline` token (Arabic-only continuous) is now `flow`; `-inline` now means "translation shown under each ayah".
- **New: Arabic-only ayah-by-ayah** (`quran_hafs-uthmani_kfgqpc_ayah_ar.epub`) — each ayah is its own block, pages never split an ayah (#16).
- Surah headers no longer sit flush against the preceding text (top-margin fix).
- Mukhtasar variants parked from this release (returning later — #5).
- **Warsh & IndoPak are BETA — we need your eyes.** These scripts are outside what we can proof ourselves (we read QPC Hafs), and the formatting work they required (ayah-marker spacing/anchoring) could have introduced artifacts. If you read these, please report: text errors, marker oddities (uneven gaps, marker at line start, marker separated from its ayah), line height/spacing issues (too cramped or too loose for Nastaleeq), overlapping or clipped marks, and anything strange at page edges. They graduate out of beta when reader feedback says they're right.
- [dictionary rebuild notes — Lane definitions restored for ~20% of roots, tafsir grouping fix, presentation improvements]
- [plugin v1.11 notes — riwayah-aware navigation, Warsh dictionary gating, hizb in status bar, sidecar auto-migration, settings cleanup]
- [old→new filename mapping table — generated from docs/filename_map_v1.csv]
