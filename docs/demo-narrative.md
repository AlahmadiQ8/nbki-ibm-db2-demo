# Demo narrative — the opening segment

What to say **before** anything runs live: the architecture, the scenario, what
good looks like, and what this demo actually buys NBK International.

This file is slide content plus speaker notes. It is not a script to read aloud.

> **The live portion is storyboarded in [`docs/feasibility.md` §7](feasibility.md),
> which is now partly superseded.** It opens with "trigger the incremental" —
> and Fabric's incremental read from Db2 was tested and **fails**. Read the
> warning box in that section before using it, and see *What is proven, what is
> not* on Slide 3 below. The full landing replaces that beat: 27.3M rows in
> 10m31s, reconciled 77/77.

**Audience assumed: mixed** — data/BI leadership plus IBM i and infrastructure
engineers. The slides carry the value story; the speaker notes carry the
technical beats. The engineers in the room will test the claims, so every figure
on a slide is traceable to something in this repo that has been run.

---

## Slide 0 — The architecture

**Asset:** `docs/architecture/db2-to-fabric.drawio.png` (already built — use it
full-bleed, it is legible at that size). Nothing to add to the slide itself.

### Speaker notes — walk it left to right, four beats

1. **Source.** Db2 LUW 11.5.9 on an Azure VM is the demo source. Underneath it,
   greyed out, is Db2 for i on ports 446/448 — *your* production core. Say this
   now, not at the end: we are standing in for Equation, not impersonating it.
   The mapping slide comes at the close.
2. **Connectivity.** The gateway is **mandatory**. Not a design preference — the
   Fabric Db2 connector requires an on-premises data gateway whether Db2 sits in
   your datacentre or in Azure. There is no gateway-free path. Db2's port is open
   to the gateway subnet only.
3. **Medallion.** Bronze lands it exactly as it arrives, one table per source
   table, no transformation. Silver conforms types, applies the data-quality
   rules, and **quarantines** failures rather than dropping them. Gold is the
   dimensional model. This is where "land once" becomes concrete.
4. **Serve.** One Direct Lake semantic model feeds Power BI, the SQL analytics
   endpoint, Excel and — if it is in scope — the Fabric data agent. One set of
   measures, therefore one number, in every one of those surfaces.

Then the dotted line at the bottom: **the CSV extract, the process today.** It
is still there, still wired in. It is the fallback if connectivity fails on the
day, and it is Slide 1.

### Three caveats to state now, unprompted

Say these in the first two minutes. An audience of core banking engineers will
find all three, and credibility is far cheaper to keep than to recover.

| Caveat | The plain version |
|---|---|
| **Db2 in Fabric is read-only** | No write-back, no Mirroring, no CDC. Every option — Copy activity, Dataflow Gen2, Copy job — is source-only, and every one goes through the gateway. |
| **Incremental here is a watermark, not CDC** | It catches inserts and in-place updates. **It does not catch deletes** — a row that is gone cannot carry a changed timestamp. Mitigation is periodic full reconciliation, or journals on Db2 for i with a replication product. |
| **LUW is standing in for Db2 for i** | The medallion and everything to the right of it are identical. The connector and the change-capture mechanism are not. |

---

## Slide 1 — The scenario: where NBKI is today

> ### From a hand-built extract to a governed foundation
>
> **Equation on Db2 for i → somebody's CSV export → Power BI**
>
> Four control weaknesses, not four inconveniences:
>
> | | Today |
> |---|---|
> | **Manual** | A person runs the extract. If they are away, the report is late. |
> | **Error-prone** | Nothing checks that the file is complete, current, or correct. |
> | **Unauditable** | No record of who produced this number, when, or from what. |
> | **No single truth** | Finance, risk and the board reconcile by hand. |
>
> **The October extract in this demo reports $4,990,409.68.**
> **The real figure is $4,990,303.88.**
>
> One transaction is present twice. Nothing in the file says so, no error is
> raised, the report renders, and the number is wrong.

### Speaker notes

- **Lead with the number, not the architecture.** The $105.80 gap is the business
  case. An architecture diagram is not.
- The file holds 117,375 data rows and 117,374 real transactions. The duplicate
  is byte-for-byte identical in every field, so there is no technical key to
  dedupe on. This is not a contrived defect — it is what a hand-made export
  produces.
- If pressed for the full picture: the extracts carry **twelve** documented
  defects, every one of them real. Three date formats in one column is the
  dangerous one — `03/04/2019` is 3 April in London and 4 March in Redmond, and
  nothing in the file says which. For a UK-regulated entity, reporting on the
  wrong month is a reportable event, and it is silent. Full list in
  [`csv-drop/README.md`](../csv-drop/README.md).
- **The ZIP codes are the slide-stealer if you have a data-literate room.** In
  the source data the leading zeros are already gone — the value arrives as
  `58523.0` and the lowest ZIP present is 1001, which is Massachusetts 01001. No
  downstream process can recover them. That is what happens when an identifier is
  moved through something that treats it as a number, and it happened *before*
  the file was written. Sort codes, account numbers, CVVs and PANs are all
  identifiers that happen to be digits.
- **Say it plainly: this is the same shape as your process, and it is not a
  criticism.** Every bank that grew its reporting organically has this. The point
  is that it cannot be audited, so it cannot be defended to a regulator.

### The business challenge, in one line if you need it

> Data is spread across domains, teams and platforms. Analytics needs a reliable
> foundation, business users need access to governed data in their own language,
> and leaders need faster sales and finance insight without rebuilding the
> plumbing every time.

---

## Slide 2 — What good looks like

> ### One foundation, built once, reused everywhere
>
> **Land once**
> Data lands a single time in OneLake. No duplicated copies, no egress, open
> table formats. Bronze is the only place raw Db2 data arrives.
>
> **Govern once**
> One governance model across the estate — OneLake Catalog and Purview govern
> data *and* AI together. Lineage from source to report, sensitivity labels,
> row-level security, applied once and honoured everywhere.
>
> **Reusable everywhere**
> The same foundation serves engineering, warehousing, real-time, BI and AI
> without rebuilding. Power BI, Excel, the SQL endpoint and a natural-language
> agent all read the same governed measures.

### Speaker notes

- Map each principle to the diagram they just saw, so this does not float free:
  - *Land once* → the single Bronze lakehouse. Every consumer downstream reads
    Delta from OneLake. Nobody gets their own copy, because nobody needs one.
  - *Govern once* → lineage source → bronze → silver → gold → report; one
    sensitivity label; RLS on the semantic model, verified to behave identically
    in Power BI, in Excel and in the agent.
  - *Reusable everywhere* → the Serve column. Adding the next use case does not
    mean another extract.
- **The audit line is the one that matters to a UK-regulated entity.** *Who
  changed this number, when, and from what?* Today's process cannot answer that
  at all. The governed path answers it by construction — every bronze row carries
  a load ID, an extraction window and a pipeline run ID.
- The contrast to name explicitly is **the fragmentation tax**: fragmented
  estates across clouds and data types, disconnected pipelines and duplicated
  storage, inconsistent semantic definitions, and — increasingly — agent sprawl
  with no unified identity, observability or cost control. Every one of those is
  a cost line, not an architecture preference.
- **Both datasets in this demo are fully synthetic.** Say so early; it removes
  most of the objection surface for a bank.

---

## Slide 3 — What this demo proves, and what it is worth

> ### Today versus the governed foundation
>
> | | Today | With Fabric |
> |---|---|---|
> | **Getting the data** | A person exports a file | One job, on demand or scheduled — 27.3M rows in **10m31s** |
> | **Knowing it is right** | Footer total, believed | Row counts and monetary control totals, compared and **tied to the penny** |
> | **Bad records** | Silently included | Quarantined with the rule and batch that rejected them |
> | **Running it twice** | Duplicates | Deterministic — the run replaces the table, so the totals do not move |
> | **Proving provenance** | Not possible | Row-level ingestion metadata, then lineage across the medallion |
> | **One number** | Reconciled by hand | One Direct Lake model — identical in Power BI, Excel and the agent |
>
> **Proven, by running it:** 27,307,478 rows landed from Db2 into the Fabric
> bronze lakehouse in **10 minutes 31 seconds**, and **77 of 77** verification
> checks pass — every row count, every control total exact, including an AML
> total that ties to **six decimal places**.

### What is proven, what is not — keep these apart

The engineers in the room will push on this, and the honest split is stronger
than the polished one.

| Status | Claim |
|---|---|
| **Proven, on this data** | Six-table Db2 → bronze landing; 77/77 reconciliation; 27.3M rows in 10m31s; decimals and timestamps preserved exactly |
| **Available, not applied** | Row-level audit columns — Copy job supports them and they are exactly the provenance this deck promises, but they are **not configured here**. The JSON shape is unpublished and a guessed one was rejected; it needs a portal pass. Do not show a provenance column that does not exist |
| **Tested and does NOT work** | Fabric Copy job **incremental** from Db2 (see below) |
| **Not built** | Silver, quarantine, gold, Direct Lake model, RLS, Purview lineage, Excel/agent consistency |

> **Do not say "scheduled pipeline, incremental, on a watermark".** Say: *a full
> extract that runs in ten and a half minutes, which is faster than the manual
> one and repeatable.* That is both true and, for a bank doing a full extract
> today, the like-for-like comparison anyway.

### Speaker notes

- **The incremental beat has to change, and the honest version still lands.**
  Two separate claims were previously blurred into one sentence; keep them apart:
  - **Db2's side works, and is verified on 13.3M real rows.** `ROW CHANGE
    TIMESTAMP` is set on insert and advanced on update, so a watermark on it
    finds the 250 inserts *and* the 50 in-place updates. A watermark on the
    business date would find the 250 and miss all 50, silently. That is a real
    data-modelling point about their Equation extract, and it stands.
  - **Fabric's side does not.** Copy job's incremental read from Db2 **fails** in
    this tenant — tested, with a 109-row minimal reproduction. The snapshot leg
    is what is proven, at 27.3M rows.
- **So do not demo an incremental run.** Demo the full landing and its
  reconciliation, and describe change capture as design and roadmap, not as
  something on the screen.
- **Then state the limit that would have applied anyway:** a watermark does not
  capture deletes. Do not wait to be asked.
- **If someone asks why not use CDC:** Db2 is not a CDC source for Copy job at
  all — it is absent from that connector list. Journals on Db2 for i with a
  separately licensed replication product are the production answer.
- The data-quality story is deliberately split, and it is worth saying why:
  - **Db2 delta** carries twelve *business-rule* violations that are
    structurally legal — zero amounts, implausible values, future dates,
    inconsistent casing, a duplicated business key.
  - **CSV drop** carries the *structural* corruption, because that is how it
    reaches a bank in reality: not from the database, but from a hand-made
    extract.
  - Db2 enforces its foreign keys and NOT NULL constraints, so structurally
    broken rows cannot be inserted — and we did not disable that to stage a
    demo. **That difference is the difference between a governed source and a
    spreadsheet.**
- **The value, in their language, not ours:**
  - *Auditable by construction* — the question a regulator asks has an answer.
  - *Analyst time returned* — the days currently spent producing and reconciling
    extracts go back to analysis.
  - *One number* — finance, risk and the board stop reconciling each other.
  - *Built once* — the next use case is a new report on the same foundation, not
    a new extract.
- **The close:** the one-slide Db2 LUW → Db2 for i mapping (port 446/448,
  library not schema, `QSYS2.SYSTABLES`, journals instead of row-change
  timestamp, Microsoft driver only), then the ask — a short, separately scoped
  connectivity spike against a non-production LPAR or a reporting replica. The
  table is in [`docs/roadmap.md`](roadmap.md) Phase 4.

---

## Lines not to cross

Carried from [`docs/roadmap.md`](roadmap.md) and
[`docs/feasibility.md`](feasibility.md). These are not stylistic.

| Do not | Why |
|---|---|
| Name Equation physical files (e.g. `CUSMAS`, `ACCMAS`) | They could not be corroborated anywhere and may be fabricated. The room runs Equation and would know. |
| Show the Fabric data agent without a decision on **G2** | Cross-geo AI processing must be acceptable to NBKI compliance. If it is not, the agent comes out of the demo — find out beforehand, not mid-presentation. |
| Say Fabric does incremental from Db2 | The connector matrix now says it is supported. **It was tested and it fails** — a minimal 109-row reproduction is in `docs/roadmap.md` Phase 4. Show the full load instead. |
| Call any of this CDC | Db2 is **not** a CDC source for Copy job. What is configured is a watermark, and a watermark never captures deletes. |
| Say "end-to-end lineage" about audit columns | Audit columns give row-level *ingestion* provenance. Lineage across silver, gold, model and report is Phase 5 and is not built. |
| Quote a throughput number other than the measured one | 27,307,478 rows in 10m31s, one gateway, no auto-partitioning (Copy job does not offer it for Db2). |
| Imply Fabric can write back to Db2 | The connector is source-only. The architecture must not suggest otherwise. |
| Imply journal-based CDC is a configuration toggle | It is a separately licensed IBM replication product. |
| Present the watermark as complete change capture | It does not capture deletes. |

### Figures, and where they come from

Everything quoted on these slides is from this repo and has been run:

| Figure | Source |
|---|---|
| $4,990,409.68 shown vs $4,990,303.88 true; 117,375 rows vs 117,374 transactions | [`csv-drop/manifest.json`](../csv-drop/manifest.json) — authoritative, regenerated with the real data |
| ZIP arrives as `58523.0`, lowest value 1001 | [`README.md`](../README.md), profiling the real dataset |
| 27.3M rows, 0 rejected, 23/23 verification | [`README.md`](../README.md) / `scripts/05_verify.sh` — all six tables, Db2 aggregates |
| 21/21 CSV reconciliation | `scripts/09_reconcile.sh` — **7 checks × 3 monthly extracts, `TRANSACTIONS` only.** Do not cite it as an all-table figure |
| **27,307,478 rows landed in bronze in 10m31s (~43k rows/s)** | Copy job run, 2026-09-16. One gateway, no auto-partitioning (Copy job does not offer it for Db2) |
| **77/77 bronze verification** | `scripts/17_verify_bronze.py` — counts, exact control totals, types, key uniqueness, null profiles, string content on the small tables |
| AML total ties to six decimal places: `30412817094323.869350` | `scripts/17_verify_bronze.py`; `DECIMAL(23,6)` survives as Delta `decimal(23,6)`, not a double |
| Timestamps preserved exactly (`…08.18.10.189024`) | 109-row probe run before the full load |
| Fraud labels: No = 8,901,631 / Yes = 13,332 | `scripts/17_verify_bronze.py` |
| 250 inserts + 50 in-place updates | `scripts/06_make_delta.py`, `scripts/08_apply_delta.sh` — **the delta is unspent**, `18_assert_pristine.sh` 3/3. Db2's watermark behaviour is verified; Fabric cannot consume it incrementally |
| Twelve CSV defects; twelve Db2 business-rule violations | [`csv-drop/README.md`](../csv-drop/README.md), `db2/delta/delta_manifest.json` |

> The corporate platform figures — 200+ OneLake connectors, 11,000+ models in
> Foundry, Microsoft IQ reasoning across 1,400+ systems, Foundry IQ's 36% answer
> quality improvement, up to 70% savings on AI inference, Power BI ranked #1 in
> the Gartner Magic Quadrant — are **not** verified by this repo. Use them if the
> deck calls for them, but re-verify against current Microsoft material first,
> and do not mix them into the same visual block as the demo figures above. The
> demo figures are checkable live; those are not.
