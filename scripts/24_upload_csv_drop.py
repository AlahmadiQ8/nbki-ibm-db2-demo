#!/usr/bin/env python3
"""
24_upload_csv_drop.py — put the hand-made CSV extracts where Fabric can see them.

The three `Equation_Extract_YYYY-MM.csv` files are the *today* process: a
person's export, with twelve documented defects in it. The Dataflow Gen2 reads
them from `lh_bronze/Files/csv_drop/` and cleans them in Power Query, which is
the single best tool-to-job match in the whole demo.

They land in **bronze**, not silver, because bronze is the raw landing zone for
every source -- Db2 through the Copy job, and this through a file drop. Nothing
transforms them on the way in.

They are **not** merged into the silver fact. They cover transactions that
already exist in Db2, so they are the same data by a worse route. Keeping them
separate is what lets the governed figure and the hand-made figure sit side by
side and differ by $105.80.

Usage:
    .venv/bin/python scripts/24_upload_csv_drop.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _onelake as ol  # noqa: E402
import _fabric as fab  # noqa: E402

SRC = pathlib.Path(__file__).parent.parent / "csv-drop" / "incoming"
DEST = "csv_drop"


def main() -> int:
    files = sorted(SRC.glob("*.csv"))
    if not files:
        print(f"no CSVs in {SRC} — run scripts/07_make_csv_drop.py first",
              file=sys.stderr)
        return 1

    print(f"==> uploading {len(files)} files to lh_bronze/Files/{DEST}/")
    total = 0
    for f in files:
        data = f.read_bytes()
        n = ol.upload_file(fab.WORKSPACE, fab.ITEMS["lh_bronze"],
                           f"{DEST}/{f.name}", data)
        total += n
        print(f"    {f.name:34s} {n / 1e6:7.2f} MB")

    print(f"==> {total / 1e6:.1f} MB uploaded")
    listing = ol.list_dir(fab.WORKSPACE, f"{fab.ITEMS['lh_bronze']}/Files/{DEST}")
    print("    now in OneLake:",
          ", ".join(sorted(e["name"].split("/")[-1] for e in listing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
