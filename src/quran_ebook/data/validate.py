"""Post-load validation for Quran data integrity.

Runs structural checks on a loaded Mushaf to catch data loading bugs,
API anomalies, and pipeline corruption before EPUB assembly.
"""

import click

from ..models import Mushaf

# Canonical ayah counts per surah (Hafs reading, 6236 total).
# This is a fixed property of the Quran — if the API disagrees, the API is wrong.
AYAH_COUNTS = {
    1: 7, 2: 286, 3: 200, 4: 176, 5: 120, 6: 165, 7: 206, 8: 75,
    9: 129, 10: 109, 11: 123, 12: 111, 13: 43, 14: 52, 15: 99,
    16: 128, 17: 111, 18: 110, 19: 98, 20: 135, 21: 112, 22: 78,
    23: 118, 24: 64, 25: 77, 26: 227, 27: 93, 28: 88, 29: 69,
    30: 60, 31: 34, 32: 30, 33: 73, 34: 54, 35: 45, 36: 83,
    37: 182, 38: 88, 39: 75, 40: 85, 41: 54, 42: 53, 43: 89,
    44: 59, 45: 37, 46: 35, 47: 38, 48: 29, 49: 18, 50: 45,
    51: 60, 52: 49, 53: 62, 54: 55, 55: 78, 56: 96, 57: 29,
    58: 22, 59: 24, 60: 13, 61: 14, 62: 11, 63: 11, 64: 18,
    65: 12, 66: 12, 67: 30, 68: 52, 69: 52, 70: 44, 71: 28,
    72: 28, 73: 20, 74: 56, 75: 40, 76: 31, 77: 50, 78: 40,
    79: 46, 80: 42, 81: 29, 82: 19, 83: 36, 84: 25, 85: 22,
    86: 17, 87: 19, 88: 26, 89: 30, 90: 20, 91: 15, 92: 21,
    93: 11, 94: 8, 95: 8, 96: 19, 97: 5, 98: 8, 99: 8,
    100: 11, 101: 11, 102: 8, 103: 3, 104: 9, 105: 5, 106: 4,
    107: 7, 108: 3, 109: 6, 110: 3, 111: 5, 112: 4, 113: 5, 114: 6,
}

# Codepoints that should never appear in processed QPC text.
# Their presence indicates a pipeline bug or data corruption.
_FORBIDDEN_IN_QPC = {
    0x06DE: "RUB AL-HIZB MARK (should be stripped by pipeline)",
}

# Madinah Mushaf page range
_MIN_PAGE = 1
_MAX_PAGE = 604


def validate_mushaf(mushaf: Mushaf) -> list[str]:
    """Run all structural validation checks on a loaded Mushaf.

    Returns a list of error messages. Empty list = all checks passed.
    """
    errors = []
    errors.extend(_check_surah_count(mushaf))
    errors.extend(_check_surah_ordering(mushaf))
    errors.extend(_check_ayah_counts(mushaf))
    errors.extend(_check_ayah_sequencing(mushaf))
    errors.extend(_check_empty_text(mushaf))
    errors.extend(_check_page_numbers(mushaf))
    errors.extend(_check_bismillah(mushaf))

    is_qpc = mushaf.script.startswith("qpc_") or mushaf.script.startswith("text_qpc_")
    if is_qpc:
        errors.extend(_check_forbidden_codepoints(mushaf))

    return errors


def _check_surah_count(mushaf: Mushaf) -> list[str]:
    if len(mushaf.surahs) != 114:
        return [f"Expected 114 surahs, got {len(mushaf.surahs)}"]
    return []


def _check_surah_ordering(mushaf: Mushaf) -> list[str]:
    errors = []
    for i, surah in enumerate(mushaf.surahs):
        if surah.number != i + 1:
            errors.append(f"Surah at index {i} has number {surah.number}, expected {i + 1}")
    return errors


def _check_ayah_counts(mushaf: Mushaf) -> list[str]:
    errors = []
    total = 0
    for surah in mushaf.surahs:
        expected = AYAH_COUNTS.get(surah.number)
        actual = len(surah.ayahs)
        total += actual

        if expected is not None and actual != expected:
            errors.append(
                f"Surah {surah.number} ({surah.name_transliteration}): "
                f"expected {expected} ayahs, got {actual}"
            )
        if actual != surah.ayah_count:
            errors.append(
                f"Surah {surah.number}: ayah_count field ({surah.ayah_count}) "
                f"disagrees with actual ayahs ({actual})"
            )

    if total != 6236:
        errors.append(f"Total ayahs: expected 6236, got {total}")
    return errors


def _check_ayah_sequencing(mushaf: Mushaf) -> list[str]:
    """Verify ayah numbers are sequential 1..N within each surah."""
    errors = []
    for surah in mushaf.surahs:
        for i, ayah in enumerate(surah.ayahs):
            expected = i + 1
            if ayah.ayah_number != expected:
                errors.append(
                    f"Surah {surah.number} ayah at index {i}: "
                    f"expected number {expected}, got {ayah.ayah_number}"
                )
                break  # One error per surah is enough
    return errors


def _check_empty_text(mushaf: Mushaf) -> list[str]:
    errors = []
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            stripped = ayah.text.strip()
            if not stripped:
                errors.append(f"Surah {surah.number}:{ayah.ayah_number} has empty text")
    return errors


def _check_page_numbers(mushaf: Mushaf) -> list[str]:
    """Validate page numbers are in range and monotonically non-decreasing."""
    errors = []
    prev_page = 0
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            if ayah.page_number is None:
                continue
            if not (_MIN_PAGE <= ayah.page_number <= _MAX_PAGE):
                errors.append(
                    f"{surah.number}:{ayah.ayah_number} has page_number "
                    f"{ayah.page_number} (expected {_MIN_PAGE}-{_MAX_PAGE})"
                )
            if ayah.page_number < prev_page:
                errors.append(
                    f"Page number decreased: {prev_page} -> {ayah.page_number} "
                    f"at {surah.number}:{ayah.ayah_number}"
                )
            prev_page = ayah.page_number
    return errors


def _check_bismillah(mushaf: Mushaf) -> list[str]:
    errors = []
    if not mushaf.bismillah_text or len(mushaf.bismillah_text) < 10:
        errors.append("Basmala text is missing or suspiciously short")
    if mushaf.surahs and mushaf.surahs[0].ayahs:
        if mushaf.surahs[0].ayahs[0].text != mushaf.bismillah_text:
            errors.append("Basmala text doesn't match Al-Fatiha 1:1")
    return errors


def _check_forbidden_codepoints(mushaf: Mushaf) -> list[str]:
    """Check for codepoints that should have been stripped by the pipeline."""
    errors = []
    for surah in mushaf.surahs:
        for ayah in surah.ayahs:
            for cp, desc in _FORBIDDEN_IN_QPC.items():
                if chr(cp) in ayah.text:
                    errors.append(
                        f"{surah.number}:{ayah.ayah_number} contains "
                        f"U+{cp:04X} {desc}"
                    )
    return errors


def validate_and_report(mushaf: Mushaf) -> None:
    """Run validation and print results. Raises on critical errors."""
    errors = validate_mushaf(mushaf)
    if errors:
        click.secho("Validation errors:", fg="red", err=True)
        for err in errors:
            click.secho(f"  - {err}", fg="red", err=True)
        raise click.Abort()
    click.secho("Validation passed (114 surahs, 6236 ayahs)", fg="green", err=True)
