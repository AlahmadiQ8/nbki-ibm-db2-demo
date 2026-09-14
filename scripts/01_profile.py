#!/usr/bin/env python3
"""
01_profile.py — profile the raw Kaggle files BEFORE writing any DDL.

Why this exists
---------------
We know the *column names* of both datasets from third-party repositories. We do
not know their on-disk *formats*. Writing DDL from remembered column lists is how
you get a LOAD that fails at row four million, or worse, one that succeeds while
silently truncating money.

So this runs first. It reports what is actually in the files, and the DDL is
generated from its output.

Deliberately zero-dependency
----------------------------
Standard library only. The profiler is the step every later step depends on, so
it must not be blocked by a wheel that hasn't been built for a new Python yet.
It streams, so memory stays flat regardless of file size.

Usage
-----
    ./scripts/01_profile.py                    # full scan of everything in data/raw
    ./scripts/01_profile.py --max-rows 500000  # cap rows per file (faster, less exact)
    ./scripts/01_profile.py --out data/profile

Outputs
-------
    data/profile/profile.json  — machine-readable, consumed by the DDL step
    data/profile/profile.md    — human-readable summary
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import unicodedata
from collections import Counter
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RAW = REPO_ROOT / "data" / "raw"
DEFAULT_OUT = REPO_ROOT / "data" / "profile"

# Cap on how many distinct values we track per column. Above this we stop
# counting and just record that cardinality is "high" — we only need distinctness
# to decide dimension-vs-fact and to spot candidate keys.
DISTINCT_CAP = 10_000
SAMPLE_VALUES = 8

# Raise the field-size limit: some of these files carry long free-text fields and
# the csv module's default 128 KB limit raises rather than truncating.
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))


# ---------------------------------------------------------------------------
# Value classification
# ---------------------------------------------------------------------------

RE_INT = re.compile(r"^[+-]?\d+$")
RE_DECIMAL = re.compile(r"^[+-]?\d*\.\d+$")
RE_SCI = re.compile(r"^[+-]?\d*\.?\d+[eE][+-]?\d+$")

# "$123.45", "-$12.00", "($12.00)", "1,234.56", "$1,234.56"
RE_CURRENCY = re.compile(
    r"""^\s*
    (?P<paren_open>\()?
    (?P<sign>[+-])?
    (?P<symbol>[$£€¥])?
    (?P<sign2>[+-])?
    (?P<digits>\d{1,3}(?:,\d{3})*|\d+)
    (?P<frac>\.\d+)?
    (?P<paren_close>\))?
    \s*$""",
    re.VERBOSE,
)

RE_BOOL = re.compile(r"^(true|false|yes|no|y|n|t|f|0|1)$", re.IGNORECASE)

# Ordered most-specific-first. The first that parses wins.
DATE_FORMATS = [
    ("%Y-%m-%d %H:%M:%S", "TIMESTAMP"),
    ("%Y-%m-%dT%H:%M:%S", "TIMESTAMP"),
    ("%Y/%m/%d %H:%M:%S", "TIMESTAMP"),
    ("%Y-%m-%d %H:%M", "TIMESTAMP"),
    ("%Y/%m/%d %H:%M", "TIMESTAMP"),   # the IBM AML set uses this one
    ("%Y-%m-%d", "DATE"),
    ("%Y/%m/%d", "DATE"),
    ("%d/%m/%Y", "DATE"),
    ("%m/%d/%Y", "DATE"),
    ("%d-%m-%Y", "DATE"),
    ("%m/%Y", "MONTH"),      # card expiry / account-open style
    ("%Y-%m", "MONTH"),
]

NULL_TOKENS = {"", "na", "n/a", "null", "none", "nan", "-", "?", "unknown"}


def classify(value: str) -> str:
    """Return a coarse type tag for one raw string value."""
    v = value.strip()
    if v.lower() in NULL_TOKENS:
        return "null"
    if RE_INT.match(v):
        return "int"
    if RE_DECIMAL.match(v) or RE_SCI.match(v):
        return "float"

    m = RE_CURRENCY.match(v)
    if m and (m.group("symbol") or "," in v or m.group("paren_open")):
        # Only call it currency if it carries a symbol, a thousands separator or
        # accounting-style parentheses. A bare "123.45" is just a float.
        return "currency"

    for fmt, tag in DATE_FORMATS:
        try:
            datetime.strptime(v, fmt)
            return tag.lower()
        except ValueError:
            continue

    if RE_BOOL.match(v):
        return "bool"
    return "string"


def parse_currency(value: str) -> float | None:
    """Turn '$1,234.56' / '($12.00)' / '-$5' into a float. None if it won't parse."""
    m = RE_CURRENCY.match(value.strip())
    if not m:
        return None
    digits = m.group("digits").replace(",", "")
    frac = m.group("frac") or ""
    try:
        n = float(digits + frac)
    except ValueError:
        return None
    negative = bool(m.group("sign") == "-" or m.group("sign2") == "-")
    # Accounting convention: parentheses mean negative.
    if m.group("paren_open") and m.group("paren_close"):
        negative = True
    return -n if negative else n


# ---------------------------------------------------------------------------
# Per-column accumulator
# ---------------------------------------------------------------------------


class ColumnProfile:
    def __init__(self, name: str) -> None:
        self.name = name
        self.count = 0
        self.nulls = 0
        self.type_counts: Counter[str] = Counter()
        self.distinct: set[str] = set()
        self.distinct_overflow = False
        self.samples: list[str] = []

        self.num_min: float | None = None
        self.num_max: float | None = None
        # Decimal, not float. Summing 5M values that reach 1.05e12 with six
        # decimal places exceeds float64's ~15-16 significant digits: the float
        # total for HI-Small came out 3.98 short of the exact figure. A profiler
        # that reports control totals has no business reporting drifted ones.
        self.num_sum: Decimal = Decimal(0)
        self.num_count = 0
        self.max_scale = 0          # digits after the decimal point
        self.max_int_digits = 0     # digits before it

        self.str_min_len: int | None = None
        self.str_max_len = 0

        self.lex_min: str | None = None
        self.lex_max: str | None = None

        # Format oddities worth knowing about before writing a LOAD command.
        self.has_leading_space = False
        self.has_trailing_space = False
        self.has_embedded_newline = False
        self.has_embedded_comma = False
        self.has_embedded_quote = False
        self.has_non_ascii = False
        self.has_control_char = False
        self.currency_symbols: set[str] = set()
        self.has_thousands_sep = False
        self.has_paren_negative = False
        self.has_leading_zeros = False
        self.date_formats: Counter[str] = Counter()

    def add(self, raw: str) -> None:
        self.count += 1

        if raw != raw.strip():
            if raw != raw.lstrip():
                self.has_leading_space = True
            if raw != raw.rstrip():
                self.has_trailing_space = True

        if "\n" in raw or "\r" in raw:
            self.has_embedded_newline = True
        if "," in raw:
            self.has_embedded_comma = True
        if '"' in raw:
            self.has_embedded_quote = True
        if any(ord(c) > 127 for c in raw):
            self.has_non_ascii = True
        if any(unicodedata.category(c) == "Cc" for c in raw if c not in "\t\n\r"):
            self.has_control_char = True

        t = classify(raw)
        self.type_counts[t] += 1

        if t == "null":
            self.nulls += 1
            return

        v = raw.strip()

        if not self.distinct_overflow:
            self.distinct.add(v)
            if len(self.distinct) > DISTINCT_CAP:
                self.distinct_overflow = True
                self.distinct.clear()

        if len(self.samples) < SAMPLE_VALUES and v not in self.samples:
            self.samples.append(v)

        # Numeric tracking, including currency strings once decoded.
        n: float | None = None
        if t in ("int", "float"):
            # A zero-padded number is an identifier, not a quantity. Bank codes,
            # sort codes, CVVs and ZIPs all look numeric and all lose meaning the
            # moment you cast them — "016415" becomes 16415 and never comes back.
            if t == "int" and len(v.lstrip("+-")) > 1 and v.lstrip("+-").startswith("0"):
                self.has_leading_zeros = True
            try:
                n = float(v)
            except ValueError:
                n = None
            numeric_text = v.lstrip("+-")
        elif t == "currency":
            n = parse_currency(v)
            for sym in "$£€¥":
                if sym in v:
                    self.currency_symbols.add(sym)
            if "," in v:
                self.has_thousands_sep = True
            if v.startswith("(") and v.endswith(")"):
                self.has_paren_negative = True
            numeric_text = re.sub(r"[^\d.]", "", v)
        else:
            numeric_text = ""

        if n is not None:
            self.num_count += 1
            # Prefer summing the literal text over the float: float(v) has
            # already lost precision, and str(float) would bake that in.
            if t in ("int", "float"):
                exact_text = v.strip().lstrip("+")
            else:
                negative = (v.startswith("(") and v.endswith(")")) or v.lstrip().startswith("-") \
                    or "-" in v.split(".")[0]
                exact_text = ("-" if negative else "") + (numeric_text or "0")
            try:
                self.num_sum += Decimal(exact_text)
            except InvalidOperation:
                self.num_sum += Decimal(str(n))
            self.num_min = n if self.num_min is None else min(self.num_min, n)
            self.num_max = n if self.num_max is None else max(self.num_max, n)
            if "." in numeric_text:
                int_part, _, frac_part = numeric_text.partition(".")
                self.max_scale = max(self.max_scale, len(frac_part))
                self.max_int_digits = max(self.max_int_digits, len(int_part))
            else:
                self.max_int_digits = max(self.max_int_digits, len(numeric_text))

        if t in ("timestamp", "date", "month"):
            for fmt, tag in DATE_FORMATS:
                if tag.lower() == t:
                    try:
                        datetime.strptime(v, fmt)
                        self.date_formats[fmt] += 1
                        break
                    except ValueError:
                        continue

        L = len(v)
        self.str_min_len = L if self.str_min_len is None else min(self.str_min_len, L)
        self.str_max_len = max(self.str_max_len, L)
        self.lex_min = v if self.lex_min is None else min(self.lex_min, v)
        self.lex_max = v if self.lex_max is None else max(self.lex_max, v)

    # -- derived -----------------------------------------------------------

    @property
    def non_null(self) -> int:
        return self.count - self.nulls

    @property
    def dominant_type(self) -> str:
        real = {k: v for k, v in self.type_counts.items() if k != "null"}
        if not real:
            return "null"
        # If anything at all looks like a string, the column has to be treated as
        # one — a single bad value ruins a numeric LOAD.
        if "string" in real and real["string"] > 0:
            numeric_ish = sum(
                v for k, v in real.items() if k in ("int", "float", "currency")
            )
            if numeric_ish > real["string"] * 20:
                return "mixed_mostly_numeric"
            return "string"
        return max(real.items(), key=lambda kv: kv[1])[0]

    def is_unique(self) -> bool | None:
        if self.distinct_overflow:
            return None  # can't tell without tracking every value
        return len(self.distinct) == self.non_null and self.non_null > 0

    def suggest_db2_type(self) -> tuple[str, str]:
        """Return (db2_type, reasoning)."""
        t = self.dominant_type

        if t == "null":
            return "VARCHAR(1)", "column is entirely empty in the sampled rows"

        # Checked before the numeric branches on purpose: this overrides them.
        if self.has_leading_zeros and t in ("int", "float"):
            return (
                f"VARCHAR({self._varchar_len()})",
                "ZERO-PADDED IDENTIFIER — looks numeric but casting destroys the "
                "padding (e.g. '016415' -> 16415). Keep as text.",
            )

        if t == "currency":
            precision = max(self.max_int_digits + self.max_scale, 1) + 4
            scale = max(self.max_scale, 2)
            return (
                f"DECIMAL({min(precision, 31)},{scale})",
                "currency strings — strip symbol/separators in prepare, never load as float",
            )

        if t == "int":
            lo = self.num_min if self.num_min is not None else 0
            hi = self.num_max if self.num_max is not None else 0
            if lo >= -32768 and hi <= 32767:
                return "SMALLINT", f"integer range [{lo:.0f}, {hi:.0f}]"
            if lo >= -2147483648 and hi <= 2147483647:
                return "INTEGER", f"integer range [{lo:.0f}, {hi:.0f}]"
            return "BIGINT", f"integer range [{lo:.0f}, {hi:.0f}]"

        if t == "float":
            precision = min(self.max_int_digits + self.max_scale + 4, 31)
            scale = max(self.max_scale, 2)
            return (
                f"DECIMAL({precision},{scale})",
                "decimal, not float — this is banking data and totals must tie exactly",
            )

        if t == "timestamp":
            return "TIMESTAMP", "parsed as a full timestamp"

        if t == "date":
            return "DATE", "parsed as a date with no time component"

        if t == "month":
            return (
                "VARCHAR(7)",
                "MM/YYYY style — no day component, so DATE would invent one. "
                "Keep as text, or normalise to the first of the month in prepare.",
            )

        if t == "bool":
            return "SMALLINT", "boolean-like; normalise to 0/1 in prepare"

        if t == "mixed_mostly_numeric":
            return (
                f"VARCHAR({self._varchar_len()})",
                "MOSTLY numeric but contains non-numeric values — inspect before casting",
            )

        return f"VARCHAR({self._varchar_len()})", f"text, max observed length {self.str_max_len}"

    def _varchar_len(self) -> int:
        # Round up with headroom so a slightly longer value in unseen data doesn't
        # break the load, but stay tight enough to be meaningful.
        n = max(self.str_max_len, 1)
        for cap in (8, 16, 32, 64, 128, 256, 512, 1024, 2048):
            if n <= cap:
                return cap
        return 4000

    def oddities(self) -> list[str]:
        out = []
        if self.has_leading_zeros:
            out.append("ZERO-PADDED IDENTIFIER — must not be cast to a number")
        if self.has_leading_space or self.has_trailing_space:
            out.append("padded with whitespace")
        if self.has_embedded_newline:
            out.append("EMBEDDED NEWLINE — will break a naive LOAD")
        if self.has_embedded_comma:
            out.append("embedded comma (field must stay quoted)")
        if self.has_embedded_quote:
            out.append("embedded double-quote")
        if self.has_non_ascii:
            out.append("non-ASCII characters (check CCSID/encoding)")
        if self.has_control_char:
            out.append("CONTROL CHARACTERS present")
        if self.currency_symbols:
            out.append(f"currency symbol(s) {''.join(sorted(self.currency_symbols))}")
        if self.has_thousands_sep:
            out.append("thousands separators")
        if self.has_paren_negative:
            out.append("accounting-style (parenthesised) negatives")
        if len(self.date_formats) > 1:
            out.append(f"MIXED date formats: {dict(self.date_formats)}")
        mixed = {k for k in self.type_counts if k != "null"}
        if len(mixed) > 1:
            out.append(f"mixed value types {sorted(mixed)}")
        return out

    def to_dict(self) -> dict[str, Any]:
        db2_type, reasoning = self.suggest_db2_type()
        return {
            "name": self.name,
            "rows": self.count,
            "nulls": self.nulls,
            "null_pct": round(100 * self.nulls / self.count, 4) if self.count else 0.0,
            "dominant_type": self.dominant_type,
            "type_counts": dict(self.type_counts),
            "distinct": None if self.distinct_overflow else len(self.distinct),
            "distinct_capped_at": DISTINCT_CAP if self.distinct_overflow else None,
            "is_unique": self.is_unique(),
            "min": self.num_min,
            "max": self.num_max,
            # Serialised as a string: JSON floats would reintroduce exactly the
            # precision loss this is here to avoid.
            "sum": str(self.num_sum) if self.num_count else None,
            "numeric_values": self.num_count,
            "max_int_digits": self.max_int_digits,
            "max_scale": self.max_scale,
            "str_min_len": self.str_min_len,
            "str_max_len": self.str_max_len,
            "lex_min": self.lex_min,
            "lex_max": self.lex_max,
            "date_formats": dict(self.date_formats),
            "has_leading_zeros": self.has_leading_zeros,
            "samples": self.samples,
            "suggested_db2_type": db2_type,
            "suggestion_reasoning": reasoning,
            "oddities": self.oddities(),
        }


# ---------------------------------------------------------------------------
# File-level profiling
# ---------------------------------------------------------------------------


def rel_path(path: Path) -> str:
    """Repo-relative when possible, absolute otherwise.

    Path.relative_to raises for anything outside the repo, which made
    --raw /somewhere/else fail with 'is not in the subpath of ...' — an error
    about display formatting, reported as if the data were unreadable.
    """
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sniff_file(path: Path) -> dict[str, Any]:
    """Inspect raw bytes for BOM, line endings and encoding before parsing."""
    info: dict[str, Any] = {}
    with path.open("rb") as fh:
        head = fh.read(65536)

    info["bom"] = head.startswith(b"\xef\xbb\xbf")
    crlf = head.count(b"\r\n")
    lf = head.count(b"\n") - crlf
    info["line_ending"] = "CRLF" if crlf > lf else ("LF" if lf else "unknown")
    info["has_nul_bytes"] = b"\x00" in head

    try:
        head.decode("utf-8")
        info["encoding"] = "utf-8"
    except UnicodeDecodeError:
        try:
            head.decode("latin-1")
            info["encoding"] = "latin-1 (or another 8-bit codepage) — NOT valid UTF-8"
        except UnicodeDecodeError:
            info["encoding"] = "unknown"

    try:
        sample = head.decode("utf-8", errors="replace")
        dialect = csv.Sniffer().sniff(sample[:8192], delimiters=",;\t|")
        info["delimiter"] = dialect.delimiter
        info["quotechar"] = dialect.quotechar
    except Exception:
        info["delimiter"] = ","
        info["quotechar"] = '"'
    return info


def profile_csv(path: Path, max_rows: int | None) -> dict[str, Any]:
    meta = sniff_file(path)
    encoding = "utf-8-sig" if meta["bom"] else "utf-8"

    cols: dict[str, ColumnProfile] = {}
    order: list[str] = []
    rows = 0
    ragged = 0
    blank_lines = 0

    with path.open("r", encoding=encoding, errors="replace", newline="") as fh:
        reader = csv.reader(fh, delimiter=meta["delimiter"], quotechar=meta["quotechar"])
        try:
            header = next(reader)
        except StopIteration:
            return {"file": path.name, "error": "file is empty", **meta}

        header = [h.strip().lstrip("\ufeff") for h in header]
        for h in header:
            name = h if h else f"_unnamed_{len(order)}"
            # Duplicate header names do occur; make them addressable.
            if name in cols:
                name = f"{name}_dup{len(order)}"
            order.append(name)
            cols[name] = ColumnProfile(name)

        width = len(order)
        for row in reader:
            if not row:
                blank_lines += 1
                continue
            if len(row) != width:
                ragged += 1
                # Still profile what we can rather than discarding the row.
            for i, name in enumerate(order):
                cols[name].add(row[i] if i < len(row) else "")
            rows += 1
            if max_rows and rows >= max_rows:
                break

    return {
        "file": path.name,
        "path": rel_path(path),
        "size_bytes": path.stat().st_size,
        "kind": "csv",
        "rows_profiled": rows,
        "truncated": bool(max_rows and rows >= max_rows),
        "ragged_rows": ragged,
        "blank_lines": blank_lines,
        "column_count": width,
        **meta,
        "columns": [cols[n].to_dict() for n in order],
    }


def describe_json_shape(obj: Any, depth: int = 0) -> str:
    if isinstance(obj, dict):
        if not obj:
            return "empty object"
        first_key = next(iter(obj))
        first_val = obj[first_key]
        if isinstance(first_val, (dict, list)):
            return f"object[{len(obj)} keys] -> {describe_json_shape(first_val, depth + 1)}"
        return f"flat map[{len(obj)} keys] of {type(first_val).__name__}"
    if isinstance(obj, list):
        if not obj:
            return "empty array"
        return f"array[{len(obj)}] of {describe_json_shape(obj[0], depth + 1)}"
    return type(obj).__name__


def profile_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            obj = json.load(fh)
    except json.JSONDecodeError as e:
        # Might be JSON Lines rather than a single document.
        return {
            "file": path.name,
            "kind": "json",
            "error": f"not a single JSON document ({e}); may be JSON Lines",
            "size_bytes": path.stat().st_size,
        }

    result: dict[str, Any] = {
        "file": path.name,
        "path": rel_path(path),
        "size_bytes": path.stat().st_size,
        "kind": "json",
        "shape": describe_json_shape(obj),
    }

    # The two shapes we care about:
    #   mcc_codes.json          -> {"5812": "Eating Places"}            flat map
    #   train_fraud_labels.json -> {"target": {"<id>": "Yes"}}          nested map
    if isinstance(obj, dict):
        result["top_level_keys"] = list(obj.keys())[:20]
        result["top_level_key_count"] = len(obj)
        first_key = next(iter(obj), None)
        if first_key is not None:
            inner = obj[first_key]
            if isinstance(inner, dict):
                result["nested"] = True
                result["wrapper_key"] = first_key
                result["inner_key_count"] = len(inner)
                result["inner_sample"] = dict(list(inner.items())[:5])
                result["inner_value_distinct"] = list(
                    {str(v) for v in list(inner.values())[:100_000]}
                )[:20]
                result["flatten_to"] = (
                    f"two columns: key, value — unwrap the '{first_key}' wrapper first"
                )
            else:
                result["nested"] = False
                result["sample"] = dict(list(obj.items())[:5])
                result["value_types"] = list({type(v).__name__ for v in obj.values()})
                result["flatten_to"] = "two columns: key, value — already a flat map"
    return result


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def fmt_bytes(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if f < 1024:
            return f"{f:.1f} {unit}"
        f /= 1024
    return f"{f:.1f} TB"


def render_markdown(profiles: list[dict[str, Any]]) -> str:
    L: list[str] = []
    L.append("# Raw data profile\n")
    L.append(
        f"_Generated {datetime.now().isoformat(timespec='seconds')} by "
        "`scripts/01_profile.py`. Regenerate rather than editing by hand._\n"
    )
    L.append(
        "This is the evidence the Db2 DDL is written from. Column names were known "
        "in advance; formats were not.\n"
    )

    warnings: list[str] = []

    for p in profiles:
        L.append(f"\n---\n\n## `{p['file']}`\n")
        if "error" in p:
            L.append(f"> **ERROR:** {p['error']}\n")
            warnings.append(f"`{p['file']}`: {p['error']}")
            continue

        L.append(f"- Size: **{fmt_bytes(p['size_bytes'])}**")

        if p["kind"] == "json":
            L.append(f"- Shape: `{p['shape']}`")
            if p.get("nested"):
                L.append(
                    f"- **Nested** under wrapper key `{p['wrapper_key']}` "
                    f"with {p['inner_key_count']:,} inner keys"
                )
                L.append(f"- Inner sample: `{p['inner_sample']}`")
                L.append(f"- Distinct inner values (first 20): `{p['inner_value_distinct']}`")
            else:
                L.append(f"- Top-level keys: {p.get('top_level_key_count', 0):,}")
                L.append(f"- Sample: `{p.get('sample')}`")
            L.append(f"- **Flatten to:** {p.get('flatten_to', 'n/a')}")
            L.append("")
            continue

        L.append(f"- Rows profiled: **{p['rows_profiled']:,}**" + (" _(truncated)_" if p["truncated"] else ""))
        L.append(f"- Columns: {p['column_count']}")
        L.append(f"- Delimiter: `{p['delimiter']}` · Quote: `{p['quotechar']}` · Line endings: {p['line_ending']}")
        L.append(f"- Encoding: {p['encoding']}" + (" · **BOM present**" if p["bom"] else ""))
        if p["ragged_rows"]:
            L.append(f"- ⚠️ **Ragged rows: {p['ragged_rows']:,}** (column count differs from header)")
            warnings.append(f"`{p['file']}`: {p['ragged_rows']:,} ragged rows")
        if p["has_nul_bytes"]:
            L.append("- 🔴 **NUL bytes in the first 64 KB — Db2 LOAD will reject these**")
            warnings.append(f"`{p['file']}`: NUL bytes present")
        if p["line_ending"] == "CRLF":
            warnings.append(f"`{p['file']}`: CRLF line endings — strip \\r in prepare")
        if "NOT valid UTF-8" in str(p["encoding"]):
            warnings.append(f"`{p['file']}`: not valid UTF-8 — {p['encoding']}")

        L.append("\n| Column | Type seen | Suggested Db2 type | Null % | Distinct | Min | Max | Samples |")
        L.append("|---|---|---|---:|---:|---|---|---|")
        for c in p["columns"]:
            distinct = "—" if c["distinct"] is None else f"{c['distinct']:,}"
            if c["is_unique"]:
                distinct += " 🔑"
            # Only show numeric min/max when the column really is numeric. A text
            # column that happens to contain some all-digit values would otherwise
            # report a nonsensical numeric range.
            numeric_col = c["dominant_type"] in ("int", "float", "currency") and not c.get(
                "has_leading_zeros"
            )
            if numeric_col and c["min"] is not None:
                mn, mx = f"{c['min']:,.4g}", f"{c['max']:,.4g}"
            elif c["lex_min"] is not None:
                mn, mx = f"`{c['lex_min'][:18]}`", f"`{c['lex_max'][:18]}`"
            else:
                mn = mx = ""
            samples = ", ".join(f"`{s[:20]}`" for s in c["samples"][:3])
            L.append(
                f"| `{c['name']}` | {c['dominant_type']} | **{c['suggested_db2_type']}** | "
                f"{c['null_pct']:.2f} | {distinct} | {mn} | {mx} | {samples} |"
            )

        odd = [(c["name"], c["oddities"]) for c in p["columns"] if c["oddities"]]
        if odd:
            L.append("\n**Format oddities**\n")
            for name, items in odd:
                L.append(f"- `{name}`: {'; '.join(items)}")
                for item in items:
                    if ("EMBEDDED" in item or "CONTROL" in item or "MIXED" in item
                            or "ZERO-PADDED" in item):
                        warnings.append(f"`{p['file']}`.`{name}`: {item}")

        money = [c for c in p["columns"] if c["dominant_type"] == "currency" or (
            c["sum"] is not None and c["max_scale"] >= 2 and c["numeric_values"] > 0)]
        if money:
            L.append("\n**Control totals** (compare against these after the prepare step — "
                     "if a sum moves, the cleaning lost money)\n")
            L.append("| Column | Non-null values | Sum |")
            L.append("|---|---:|---:|")
            for c in money:
                # Full precision, not .2f: the sub-cent digits are the whole
                # reason the AML amount columns need scale 6.
                _sum = Decimal(str(c["sum"]))
                L.append(f"| `{c['name']}` | {c['numeric_values']:,} | {_sum:,f} |")
        L.append("")

    if warnings:
        head = ["\n---\n\n## ⚠️ Things to handle in the prepare step\n"]
        head += [f"- {w}" for w in dict.fromkeys(warnings)]
        # Splice in immediately before the first file section, so the warnings
        # are read first without being injected into the middle of one.
        cut = next((i for i, line in enumerate(L) if line.startswith("\n---\n\n## `")), len(L))
        L = L[:cut] + head + L[cut:]

    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", type=Path, default=DEFAULT_RAW, help="directory of raw files")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output directory")
    ap.add_argument("--max-rows", type=int, default=None,
                    help="cap rows profiled per file (faster, but min/max and control totals "
                         "become estimates)")
    args = ap.parse_args()

    if not args.raw.exists():
        print(f"ERROR: {args.raw} does not exist. Run ./scripts/00_download.sh first.", file=sys.stderr)
        return 1

    files = sorted(
        [p for p in args.raw.rglob("*") if p.suffix.lower() in (".csv", ".json") and p.is_file()]
    )
    if not files:
        print(f"ERROR: no .csv or .json files under {args.raw}. Run ./scripts/00_download.sh first.",
              file=sys.stderr)
        return 1

    print(f"Profiling {len(files)} file(s) from {args.raw}\n")
    profiles = []
    for path in files:
        print(f"  {path.name} ({fmt_bytes(path.stat().st_size)}) ... ", end="", flush=True)
        try:
            p = profile_csv(path, args.max_rows) if path.suffix.lower() == ".csv" else profile_json(path)
        except Exception as e:  # a bad file must not kill the whole run
            p = {"file": path.name, "error": f"{type(e).__name__}: {e}", "kind": path.suffix[1:]}
            print("FAILED")
        else:
            n = p.get("rows_profiled")
            print(f"{n:,} rows" if n is not None else "ok")
        profiles.append(p)

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "profile.json").write_text(json.dumps(profiles, indent=2, default=str), encoding="utf-8")
    (args.out / "profile.md").write_text(render_markdown(profiles), encoding="utf-8")

    print(f"\nWrote {args.out / 'profile.json'}")
    print(f"Wrote {args.out / 'profile.md'}")
    print("\nRead profile.md before trusting any DDL. Next: ./scripts/02_prepare.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
