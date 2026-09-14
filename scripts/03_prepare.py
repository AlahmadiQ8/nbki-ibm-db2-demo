#!/usr/bin/env python3
"""
03_prepare.py — turn the raw Kaggle files into files Db2 LOAD will accept.

The rule this script exists to enforce
--------------------------------------
Clean the data in Python; let Db2 LOAD do nothing but load. Fighting LOAD's type
coercion over a 13-million-row file is a bad way to spend an afternoon, and worse,
a partial failure leaves you unsure what landed.

What it fixes
-------------
  - currency strings   "$1,234.56" / "-$12.00" / "($12.00)"  ->  1234.56 / -12.00 / -12.00
  - timestamps         normalised to Db2's expected form
  - CRLF               stripped
  - BOM                stripped
  - NUL bytes          removed (Db2 LOAD rejects the row outright)
  - nested JSON        flattened to two-column tables
  - column order       aligned to the generated DDL, so LOAD needs no column list

Control totals
--------------
Every monetary column is summed before and after cleaning and the two are compared
exactly, using Decimal rather than float. If a total moves by a penny the script
fails. A silent rounding change in a banking demo is the kind of thing that gets
noticed on stage.

Zero third-party dependencies, for the same reason as the profiler: this must not
be blocked by a wheel that has not been built for a new Python yet. It streams, so
memory stays flat on the 13M-row file.

Usage:
    ./scripts/03_prepare.py
    ./scripts/03_prepare.py --limit 100000     # subset, for a quick loop
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterator

REPO_ROOT = Path(__file__).resolve().parent.parent
RAW = REPO_ROOT / "data" / "raw"
PREPARED = REPO_ROOT / "data" / "prepared"
OVERLAY = REPO_ROOT / "db2" / "ddl" / "overlay.json"

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

# Db2's default timestamp form. We emit this so LOAD needs no format modifier.
DB2_TS = "%Y-%m-%d %H:%M:%S"

RE_CURRENCY_CHARS = re.compile(r"[,$£€¥\s]")

IN_FORMATS = [
    "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y/%m/%d %H:%M:%S",
    "%Y-%m-%d %H:%M", "%Y/%m/%d %H:%M", "%Y-%m-%d", "%Y/%m/%d",
    "%m/%d/%Y", "%d/%m/%Y",
]


class PrepareError(Exception):
    pass


# ---------------------------------------------------------------------------
# Value cleaning
# ---------------------------------------------------------------------------


def clean_decimal(raw: str) -> str:
    """'$1,234.56' -> '1234.56'.  '($12.00)' -> '-12.00'.  '' -> ''."""
    v = raw.strip()
    if not v:
        return ""
    negative = False
    if v.startswith("(") and v.endswith(")"):
        negative = True          # accounting convention
        v = v[1:-1]
    v = RE_CURRENCY_CHARS.sub("", v)
    if v.startswith("-"):
        negative = True
        v = v[1:]
    elif v.startswith("+"):
        v = v[1:]
    if not v:
        return ""
    try:
        d = Decimal(v)
    except InvalidOperation as e:
        raise PrepareError(f"cannot parse as a decimal: {raw!r}") from e
    return str(-d if negative else d)


def clean_timestamp(raw: str) -> str:
    v = raw.strip()
    if not v:
        return ""
    for fmt in IN_FORMATS:
        try:
            return datetime.strptime(v, fmt).strftime(DB2_TS)
        except ValueError:
            continue
    raise PrepareError(f"unrecognised timestamp format: {raw!r}")


def clean_text(raw: str) -> str:
    # NUL bytes make Db2 LOAD reject the row; embedded newlines survive because
    # the csv writer re-quotes the field correctly.
    return raw.replace("\x00", "").strip()


def clean_int(raw: str) -> str:
    v = raw.strip()
    if not v:
        return ""
    v = v.replace(",", "")
    try:
        return str(int(Decimal(v)))
    except (InvalidOperation, ValueError) as e:
        raise PrepareError(f"cannot parse as an integer: {raw!r}") from e


PROGRESS_EVERY = 250_000     # rows between progress lines
EARLY_ABORT_AFTER = 50_000   # if nothing has converted by here, the mapping is wrong

RE_FLOAT_INT = re.compile(r"^-?\d+\.0+$")


def clean_numeric_identifier(raw: str) -> str:
    """Undo float formatting on a value that is an identifier, not a quantity.

    transactions_data.csv writes ZIP codes as '58523.0' — the source went
    through something that treated a postcode as a number, which is also why
    leading zeros are already gone upstream (the lowest observed value is 1001,
    i.e. Massachusetts 01001). We cannot recover the leading zero, but storing
    '58523.0' would be wrong twice over.

    Deliberately narrow: it only strips a trailing '.0' from something that is
    otherwise all digits. A blanket rstrip would corrupt legitimate text ending
    in '.0'.
    """
    v = raw.strip()
    if not v:
        return ""
    if RE_FLOAT_INT.match(v):
        return v.split(".")[0]
    return v.replace("\x00", "")


def cleaner_for(db2_type: str, clean_hint: str | None = None):
    if clean_hint:
        try:
            return {"numeric_identifier": (clean_numeric_identifier, False)}[clean_hint]
        except KeyError:
            raise PrepareError(f"unknown \"clean\" directive in overlay: {clean_hint!r}") from None
    base = db2_type.split("(")[0].strip().upper()
    if base == "DECIMAL":
        return clean_decimal, True      # True => it's money, track a control total
    if base == "TIMESTAMP":
        return clean_timestamp, False
    if base == "DATE":
        return clean_timestamp, False
    if base in ("SMALLINT", "INTEGER", "BIGINT"):
        return clean_int, False
    return clean_text, False


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------


def find_source(filename: str) -> Path | None:
    hits = list(RAW.rglob(filename))
    return hits[0] if hits else None


def csv_header_names(header: list[str]) -> list[str]:
    """Disambiguate a CSV header exactly as scripts/01_profile.py does.

    HI-Small_Trans.csv contains the column name 'Account' TWICE. csv.DictReader
    silently collapses duplicates — last one wins — so the first Account would
    be unreachable and the overlay key would resolve to an empty string. That is
    how ACCOUNT_TO ended up blank on a NOT NULL column.

    The naming must stay identical to the profiler's, because the overlay is
    keyed on the names the profiler reports.
    """
    out: list[str] = []
    seen: set[str] = set()
    for h in header:
        name = (h.strip().lstrip("\ufeff") if h else "") or f"_unnamed_{len(out)}"
        if name in seen:
            name = f"{name}_dup{len(out)}"
        seen.add(name)
        out.append(name)
    return out


def read_csv_rows(path: Path) -> Iterator[dict[str, str]]:
    with path.open("rb") as fh:
        first = fh.read(3)
    encoding = "utf-8-sig" if first == b"\xef\xbb\xbf" else "utf-8"
    # newline="" lets csv handle CRLF itself; we strip stray \r per-value below.
    with path.open("r", encoding=encoding, errors="replace", newline="") as fh:
        reader = csv.reader(fh)
        try:
            header = csv_header_names(next(reader))
        except StopIteration:
            return
        for row in reader:
            if not row:
                continue
            yield {
                name: (row[i].replace("\r", "") if i < len(row) and row[i] else "")
                for i, name in enumerate(header)
            }


def read_json_rows(path: Path, nested_under: str | None) -> Iterator[dict[str, str]]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    if nested_under:
        if nested_under not in obj:
            raise PrepareError(
                f"{path.name}: expected a '{nested_under}' wrapper key, found "
                f"{list(obj)[:5]}"
            )
        obj = obj[nested_under]
    for k, v in obj.items():
        yield {"key": str(k), "value": "" if v is None else str(v)}


# ---------------------------------------------------------------------------
# Table preparation
# ---------------------------------------------------------------------------


def _profiled_row_counts() -> dict[str, int]:
    """Map source filename -> rows, from the profiler output if it is present.

    Only used to render a percentage and an ETA. Absence is not an error; the
    progress line just falls back to a running count.
    """
    pf = REPO_ROOT / "data" / "profile" / "profile.json"
    if not pf.exists():
        return {}
    try:
        data = json.loads(pf.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    files = data if isinstance(data, list) else data.get("files", [])
    out = {}
    for f in files:
        name = f.get("file") or f.get("name") or ""
        rows = f.get("rows")
        if name and isinstance(rows, int):
            out[Path(name).name] = rows
    return out


def prepare_table(t: dict, overlay: dict, limit: int | None,
                  row_counts: dict[str, int] | None = None) -> dict[str, Any] | None:
    table = t["table"]
    src_file = t["source_file"]
    total_rows = (row_counts or {}).get(src_file, 0)
    if limit:
        total_rows = min(total_rows, limit) if total_rows else limit
    path = find_source(src_file)

    if path is None:
        if t.get("optional"):
            print(f"  {table:<20} SKIP — {src_file} not downloaded (optional)")
            return None
        raise PrepareError(f"{table}: required source {src_file} not found under {RAW}")

    is_json = t.get("source_kind") in ("flat_map", "nested_map")
    src_map = t.get("json_columns") if is_json else t.get("columns")

    # Column order here is the order the generated DDL declares, which is why the
    # LOAD command needs no explicit column list.
    out_cols, cleaners, money_cols = [], [], []
    required_cols: set[str] = set()
    for src_name, spec in src_map.items():
        db2_name = spec.get("name", src_name.upper().replace(" ", "_").replace(".", "_"))
        db2_type = spec.get("type", "VARCHAR(128)")
        fn, is_money = cleaner_for(db2_type, spec.get("clean"))
        out_cols.append((src_name, db2_name))
        cleaners.append(fn)
        if not spec.get("nullable", True):
            required_cols.add(db2_name)
        if is_money:
            money_cols.append(db2_name)

    PREPARED.mkdir(parents=True, exist_ok=True)
    out_path = PREPARED / f"{table}.csv"

    totals_before = {c: Decimal(0) for c in money_cols}
    totals_after = {c: Decimal(0) for c in money_cols}
    counts = {c: 0 for c in money_cols}

    rows_in = rows_out = rows_skipped = 0
    errors: list[str] = []

    rows = (read_json_rows(path, t.get("nested_under")) if is_json
            else read_csv_rows(path))

    with out_path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
        w.writerow([db2 for _, db2 in out_cols])

        # Progress. These files run to 13.3M rows and a single-threaded Python
        # pass over that takes the better part of an hour; a silent terminal for
        # that long is indistinguishable from a hang, and invites someone to
        # kill a job that was working.
        t0 = time.monotonic()
        next_report = PROGRESS_EVERY

        for row in rows:
            rows_in += 1
            if limit and rows_out >= limit:
                break
            # Fail fast on a mapping error. If nothing at all has survived after
            # this many rows, the overlay is wrong (a renamed or missing source
            # column) and grinding through the remaining millions only delays the
            # same failure. Found the hard way: a bad column key sent a --limit 100
            # run through all 5M rows, because the limit counts OUTPUT rows and
            # there were none.
            if rows_out == 0 and rows_in >= EARLY_ABORT_AFTER:
                raise PrepareError(
                    f"the first {rows_in:,} rows all failed to convert — this is a "
                    f"column mapping problem, not bad data. First error: "
                    f"{errors[0] if errors else 'unknown'}")

            if rows_in >= next_report:
                next_report += PROGRESS_EVERY
                el = time.monotonic() - t0
                rate = rows_in / el if el else 0
                # total_rows is an estimate from the profile; never let it produce
                # 250000% or a negative ETA.
                if total_rows and rows_in <= total_rows:
                    pct = 100.0 * rows_in / total_rows
                    eta = max(0.0, (total_rows - rows_in) / rate) if rate else 0.0
                    print(f"      {table:<18} {rows_in:>12,} / {total_rows:,} "
                          f"({pct:5.1f}%)  {rate:,.0f}/s  ETA {eta/60:4.1f} min",
                          file=sys.stderr, flush=True)
                else:
                    print(f"      {table:<18} {rows_in:>12,} rows  {rate:,.0f}/s",
                          file=sys.stderr, flush=True)
            out: list[str] = []
            bad = False
            # Accumulate this row's contribution separately and merge it only if
            # the row survives. Adding straight into the running totals meant a
            # rejected row still moved the control total, so the total described
            # money that was not in the output file.
            row_before: dict[str, Decimal] = {}
            row_after: dict[str, Decimal] = {}
            row_counts: dict[str, int] = {}
            for (src_name, db2_name), fn in zip(out_cols, cleaners):
                raw = row.get(src_name, "")
                if db2_name in totals_before and raw.strip():
                    # Independent re-parse of the ORIGINAL value, so the "before"
                    # total is not derived from the same code path as the "after".
                    try:
                        row_before[db2_name] = row_before.get(db2_name, Decimal(0)) + Decimal(
                            RE_CURRENCY_CHARS.sub("", raw.strip().replace("(", "-").replace(")", ""))
                        )
                    except InvalidOperation:
                        pass
                try:
                    val = fn(raw)
                except PrepareError as e:
                    if len(errors) < 20:
                        errors.append(f"row {rows_in}, column {src_name}: {e}")
                    bad = True
                    val = ""
                out.append(val)
                # An empty value in a NOT NULL column means the load will fail —
                # or worse, that the column was never mapped at all and every row
                # is blank. Catching it here names the column; catching it in Db2
                # gives you SQL3125W against a row number.
                if db2_name in required_cols and not val:
                    if len(errors) < 20:
                        errors.append(
                            f"row {rows_in}, column {src_name} -> {db2_name}: "
                            f"empty, but the column is declared NOT NULL")
                    bad = True
                if db2_name in totals_after and val:
                    row_after[db2_name] = row_after.get(db2_name, Decimal(0)) + Decimal(val)
                    row_counts[db2_name] = row_counts.get(db2_name, 0) + 1
            # Skip any row that failed to convert. The previous condition was
            # `if bad and not errors`, which never fired: `errors` is non-empty
            # the moment a conversion fails, so broken rows were written out with
            # empty substituted values. The script exited non-zero afterwards,
            # but only after leaving corrupted files and a manifest describing
            # them as good.
            if bad:
                rows_skipped += 1
                continue
            for k, v in row_before.items():
                totals_before[k] += v
            for k, v in row_after.items():
                totals_after[k] += v
            for k, v in row_counts.items():
                counts[k] += v
            w.writerow(out)
            rows_out += 1

    result = {
        "table": table,
        "source": str(path.relative_to(REPO_ROOT)),
        "output": str(out_path.relative_to(REPO_ROOT)),
        "rows_in": rows_in,
        "rows_out": rows_out,
        "rows_skipped": rows_skipped,
        "columns": [db2 for _, db2 in out_cols],
        "control_totals": {c: str(totals_after[c]) for c in money_cols},
        "value_counts": counts,
        "errors": errors,
    }

    # The check that matters: did cleaning move any money?
    drift = []
    for c in money_cols:
        if totals_before[c] != totals_after[c]:
            drift.append(f"{c}: before={totals_before[c]} after={totals_after[c]} "
                         f"delta={totals_after[c] - totals_before[c]}")
    result["control_total_drift"] = drift

    status = "OK" if not drift and not errors else ("DRIFT" if drift else "ERRORS")
    print(f"  {table:<20} {rows_out:>9,} rows  {status}")
    if rows_skipped:
        print(f"      ! {rows_skipped:,} row(s) skipped as unconvertible "
              f"(excluded from the control totals above)")
    for c in money_cols:
        print(f"      {c:<22} sum={totals_after[c]:>20,} n={counts[c]:,}")
    for e in errors[:5]:
        print(f"      ! {e}")
    for d in drift:
        print(f"      !! CONTROL TOTAL MOVED — {d}")

    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=None, help="max rows per table")
    ap.add_argument("--overlay", type=Path, default=OVERLAY)
    args = ap.parse_args()

    if not RAW.exists() or not any(RAW.rglob("*.csv")):
        print(f"ERROR: no source files under {RAW}.", file=sys.stderr)
        print("       Run ./scripts/00_download.sh (real data) or "
              "./scripts/dev_make_fixtures.py (stand-ins).", file=sys.stderr)
        return 1

    overlay = json.loads(args.overlay.read_text(encoding="utf-8"))
    row_counts = _profiled_row_counts()
    print(f"Preparing into {PREPARED.relative_to(REPO_ROOT)}\n")

    results = []
    failed = False
    for t in overlay["tables"]:
        try:
            r = prepare_table(t, overlay, args.limit, row_counts)
        except PrepareError as e:
            print(f"  {t['table']:<20} FAILED — {e}", file=sys.stderr)
            failed = True
            continue
        if r:
            results.append(r)
            if r["control_total_drift"] or r["errors"]:
                failed = True

    manifest = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "row_limit": args.limit,
        "tables": results,
    }
    (PREPARED / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"\nWrote {(PREPARED / 'manifest.json').relative_to(REPO_ROOT)}")
    print("These control totals are what ./scripts/05_verify.sh checks the loaded data against.")

    if failed:
        print("\nFAILED: control totals moved, or rows could not be cleaned. "
              "Do not load this.", file=sys.stderr)
        return 1

    print("\nNext: ./scripts/04_load.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
