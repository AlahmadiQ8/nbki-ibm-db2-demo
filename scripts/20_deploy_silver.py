#!/usr/bin/env python3
"""
20_deploy_silver.py — build the silver notebook, upload it, and run it.

The notebook's source of truth is `fabric/notebooks/nb_silver.py`, a plain
Python file with `# MD ---` / `# CELL ---` markers. That file is reviewable in a
pull request; an .ipynb is not. This script turns it into a notebook and pushes
it, so the portal copy is always generated and never hand-edited.

Usage:
    .venv/bin/python scripts/20_deploy_silver.py            # deploy and run
    .venv/bin/python scripts/20_deploy_silver.py --no-run   # deploy only
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _fabric as fab  # noqa: E402

SRC = pathlib.Path(__file__).parent.parent / "fabric" / "notebooks" / "nb_silver.py"
NAME = "nb_silver"


def parse_cells(text: str) -> list[tuple[str, str]]:
    """Split the source on `# MD ---` / `# CELL ---` markers.

    Markdown cells are stored as comments in the .py so the file stays valid
    Python; the leading `# ` is stripped on the way into the notebook.
    """
    cells: list[tuple[str, str]] = []
    kind: str | None = None
    buf: list[str] = []

    def flush():
        if kind and buf:
            body = "\n".join(buf).strip("\n")
            if body.strip():
                cells.append((kind, body))

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("# MD ---"):
            flush()
            kind, buf = "md", []
            continue
        if stripped.startswith("# CELL ---"):
            flush()
            # `# CELL --- parameters` marks the parameters cell. Fabric only
            # detects parameters declared in a cell tagged this way; a plain
            # assignment in cell one is invisible to a pipeline.
            kind = "params" if stripped.endswith("parameters") else "code"
            buf = []
            continue
        if kind == "md":
            # Markdown lives behind '# '. Preserve blank comment lines as blanks.
            buf.append(line[2:] if line.startswith("# ") else
                       ("" if stripped == "#" else line))
        elif kind in ("code", "params"):
            buf.append(line)
    flush()
    return cells


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-run", action="store_true", help="deploy without running")
    args = ap.parse_args()

    cells = parse_cells(SRC.read_text())
    kinds = [k for k, _ in cells]
    if "params" not in kinds:
        print("!! no parameters cell found — a pipeline could not override anything",
              file=sys.stderr)
        return 1
    n_md = kinds.count("md")
    print(f"==> {SRC.name}: {len(cells) - n_md} code cells "
          f"(1 tagged parameters), {n_md} markdown cells")

    # The default lakehouse is silver: it is what the notebook writes. Bronze is
    # read by explicit abfss path, so it needs no binding.
    ipynb = fab.build_ipynb(
        cells,
        language="python",
        lakehouse={
            "default_lakehouse": fab.ITEMS["lh_silver"],
            "default_lakehouse_name": "lh_silver",
            "default_lakehouse_workspace_id": fab.WORKSPACE,
        },
    )

    print("==> uploading")
    nb_id = fab.deploy_notebook(
        NAME, ipynb,
        description="Silver: conform, validate, quarantine. Generated from "
                    "fabric/notebooks/nb_silver.py — do not edit in the portal.",
    )
    print(f"    notebook {nb_id}")

    if args.no_run:
        print("==> --no-run, stopping here")
        return 0

    print("==> running (Runtime 1.3, Starter Pool — first run pays session start)")
    t0 = time.time()
    fab.run_notebook(nb_id, timeout_s=5400)
    print(f"==> completed in {time.time() - t0:.0f}s")
    print("    verify with: .venv/bin/python scripts/21_verify_silver.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
