#!/usr/bin/env python3
"""The digest of the King Fahd Complex's Hafs data v2.0, as the loader pins it.

The books' Hafs text, after the one rule of src/quran_ebook/data/hafs_v2.py,
must be the publisher's Hafs data v2.0 letter for letter. The loader checks
that against a pinned sha256 (HAFS_V2_SHA256 there). This tool computes the
same digest from the publisher's own file, so the pinned value can be
derived again by anyone who has the file.

Usage:
    python tools/hafs_v2_digest.py PATH/hafsData_v2-0.json

The file is the member "UthmanicHafs_v2-0 data/hafsData_v2-0.json" of the
publisher's zip UthmanicHafs_v2-0.zip (not kept in this repo). The plain
form: hafs_v2_digest's docstring; the ayah number at the end of each ayah:
kfgqpc.strip_v2_ayah_number.
"""

import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from quran_ebook.data.hafs_v2 import HAFS_V2_SHA256, hafs_v2_digest  # noqa: E402
from quran_ebook.data.kfgqpc import strip_v2_ayah_number  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    rows = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    plain = [(r["sura_no"], r["aya_no"], strip_v2_ayah_number(r["aya_text"], r["aya_no"]))
             for r in rows]
    digest = hafs_v2_digest(plain)
    print(f"ayahs: {len(plain)}")
    print(f"sha256: {digest}")
    same = digest == HAFS_V2_SHA256
    print("equal to the pinned value" if same else f"NOT the pinned value {HAFS_V2_SHA256}")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
