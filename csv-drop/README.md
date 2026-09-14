# csv-drop — the fallback, and the "before" picture

This folder holds CSV extracts of the same transactions that are in Db2. It
exists for two reasons that pull in opposite directions, and both matter.

## 1. It is the safety net

If the Db2 VM will not start on the day, or the on-premises data gateway cannot
reach it from the demo network, or the tenant has a bad morning — the demo still
runs. Drop `incoming/*.csv` into a Lakehouse `Files/` folder and the medallion
story proceeds unchanged from bronze onward. Bronze, silver, gold, the semantic
model, and the data agent are all downstream of the ingest and do not care where
the bytes came from.

The figures reconcile **exactly** with Db2. `./scripts/09_reconcile.sh` proves
it, and it proves it properly: it parses the physical files, undoes every defect
below, and checks three legs — file → manifest → Db2. It fails if a file is
missing, edited, truncated, or if an undeclared extract from an earlier run is
sitting in `incoming/`. That is the whole point: switching sources mid-demo must not move a single
number on a slide. A fallback that produced different totals would not be a
fallback, it would be a second, contradictory demo.

## 2. It is the argument

This is also what NBKI does today. Somebody exports from the core banking system
into a spreadsheet, and Power BI is built on top of that spreadsheet.

So these files are deliberately, specifically bad — and every defect in them is
one a human export actually produces, not one invented to make a point. Read the
file. Then look at what the Db2 path makes impossible by construction.

### The planted defects

| # | Defect | Why it matters |
|---|--------|----------------|
| 1 | Three preamble lines above the header | Any reader that assumes row 1 is the header gets a single-column file of garbage. Fabric needs `skipRows: 3` — set by hand, per file, by someone who knew to look. |
| 2 | **Three date formats in one column** — `02/10/2019`, `2019-10-06`, `07-Oct-2019` | The dangerous one. `03/04/2019` is 3 April in London and 4 March in Redmond, and **nothing in the file says which**. A UK-regulated bank reporting on the wrong month is a reportable event, and it is silent. |
| 3 | Thousands separators and currency symbols — `$791.19`, `USD 1,204.50` | The amount column arrives as text. Either the load fails, or worse, it succeeds and everything downstream is a string. |
| 4 | Accounting negatives — `(250.00)` | Parses as text, or as a positive. A refund becomes a payment. |
| 5 | A `TOTAL` row at the foot | Ingested blindly, the month double-counts. |
| 6 | A blank line before the total | Lazy parsers stop reading here and silently truncate. |
| 7 | Inconsistent state values — `ca`, `` NY``, `OH ` | `GROUP BY` produces three Californias. |
| 8 | **One transaction present twice**, identical in every field | There is no technical key to dedupe on — the rows are indistinguishable. This is why each file's footer total is wrong: see below. |
| 9 | Three spellings of missing — `''`, `N/A`, `NULL` | Three different nulls, none of which is null. |
| 10 | CRLF line endings | A stray `\r` rides along on the last column of every row. |
| 11 | `End of Report` trailing line | More junk after the data. |
| 12 | The as-at date is **in the filename**, not in the data | `Equation_Extract_2019-10.csv`. Rename the file and the lineage is gone. There is no other record of what period this is or when it was run. |

### The number that proves the point

Each file's footer total — what a person reads off the bottom of the
spreadsheet, and what a `SUM()` in Excel returns — is **wrong**:

| File | Footer says | Truth | Over-reported by |
|------|------------:|------:|-----------------:|
| `Equation_Extract_2019-10.csv` | 13,102.78 | 12,706.36 | **396.42** |
| `Equation_Extract_2019-11.csv` | 19,483.91 | 18,869.76 | **614.15** |
| `Equation_Extract_2019-12.csv` | 12,906.42 | 12,619.11 | **287.31** |

*(Figures above are from the current fixture data; regenerating against the real
dataset will change them. `manifest.json` is always authoritative.)*

The cause is defect 8 — a duplicated row. Nothing in the file reveals it. No
error is raised. The report renders, the numbers look plausible, and they are
wrong.

**That gap is the business case.** Not the architecture diagram — this. Today
that number ships, and nobody in the chain is able to see that it is wrong.

## What is in here

```
incoming/        generated extracts — regenerate with ./scripts/07_make_csv_drop.py
samples/         a committed 15-line sample, so the shape is visible in the repo
manifest.json    the TRUE counts and totals, plus the SQL to prove them
```

`manifest.json` is the source of truth for what these files *should* say. Each
entry carries `rows_to_skip_before_header`, `footer_rows_to_discard`, the real
row count, the real total, and the reconciliation SQL.

## Regenerating

```bash
./scripts/07_make_csv_drop.py                              # last three months
./scripts/07_make_csv_drop.py --months 2019-10 2019-11     # specific months
./scripts/07_make_csv_drop.py --clean                      # also emit clean copies
./scripts/09_reconcile.sh                                  # prove it ties to Db2
```

The row selection is deterministic — a fixed date window, no sampling — so the
same months always produce the same files. The mess is applied to how values are
*presented*, never to the values themselves. The one exception is the duplicated
row, which is counted and declared in the manifest.

## Using it as the fallback on the day

1. Upload `incoming/*.csv` to the Lakehouse `Files/csv-drop/` folder.
2. Point the bronze notebook or dataflow at that folder instead of the Db2 copy
   activity. Everything downstream is unchanged.
3. Set `skipRows: 3` and discard the last three rows.
4. Run `./scripts/09_reconcile.sh` beforehand so you can say, truthfully, that
   the figures are identical either way.

One caveat worth knowing before you rely on it: these extracts are cut from the
initial load, so they predate the delta batch
(`./scripts/06_make_delta.py`). `09_reconcile.sh` detects this and excludes the
delta by its exact ID range — not by "anything newer", which would also have
hidden genuine base rows and let a mismatch pass. If you fall back to CSV, you lose the incremental
watermark story — the CSV path has no change tracking at all, which is itself
rather the point.
