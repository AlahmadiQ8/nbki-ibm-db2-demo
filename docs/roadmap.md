# Roadmap — what this session deliberately did not build

This session's scope was narrow on purpose: **build the dataset that seeds Db2,
plus the CSV drop-in fallback**. That is done and proven.

Everything below is the backlog for follow-up sessions, recorded here so the
research does not have to be re-derived. Where something is a known trap, it is
written down as a trap — the point of this file is that the next session does
not lose a day to something this one already found.

---

## Phase 1 — Stand up Db2 somewhere Fabric can reach it

Local validation used a Docker container on a Mac. That was the right call for
proving the data pipeline, but Fabric cannot reach `localhost`.

- [ ] Provision an Azure VM. **Standard_D4s_v5 (4 vCPU / 16 GiB)** matches the
      Db2 Community Edition entitlement, so a larger VM buys nothing.
- [ ] Install Db2 **11.5.9.0**. Do not take the latest. See "Version pinning".
- [ ] Run `./scripts/04_load.sh` with `DB2_MODE=local`. The script was written
      to work in both modes for exactly this reason.
- [ ] Open port 50000 to the gateway subnet only. Not to the internet.
- [ ] `./scripts/05_verify.sh` must pass 23/23 on the VM before anything else.

### Version pinning — why 11.5.9.0

- Fabric/ADF documents Db2 **LUW 11, 10.5, 10.1** and **Db2 for i 7.3/7.2/7.1**.
  LUW **12.1 is not on that list.**
- Db2 **12.1.4+ "AI Community Edition" is restricted to 1 CPU**, down from 4.
- 11.5.9.0 is in the documented support matrix and runs under emulation on
  arm64, which is how this repo was validated.

---

## Phase 2 — Connectivity, where the day actually gets lost

### The gateway is mandatory

The Fabric Db2 connector **always requires an on-premises data gateway** — even
when Db2 is in Azure, even when it is publicly addressable. There is no
gateway-free path. Budget for it as a real work item, not a checkbox.

- [ ] Gateway VM in the same VNet (or peered).
- [ ] Install the on-premises data gateway (standard mode, not personal).
- [ ] Register it to the Fabric tenant.
- [ ] Create the Db2 connection in Fabric and bind it to the gateway.

### The `-805` package trap

The single most likely thing to burn an hour:

```
SQLSTATE=51002 SQLCODE=-805  package not found
```

Cause: **Power Query defaults `packageCollection` to `NULLID`; the ADF/Fabric
linked service defaults it to `{username}`.** They disagree. So a connection
that works in Power Query fails in a pipeline, or vice versa, with an error that
does not mention the setting at all.

**Set `packageCollection` explicitly on the connection.** Write the value on the
runbook. Do not leave it to a default.

### Driver notes

- The **Microsoft** Db2 driver works with LUW, z/OS **and** IBM i.
- The **IBM .NET** driver does **not** work with IBM i.
- This matters for the "and here's how it maps to your real Equation box"
  conversation, which is Db2 for **i**, not LUW.

### Copy activity is source-only

The Db2 connector supports **read only**. Fabric cannot write back to Db2. If
anyone asks about write-back, the answer is no, and the architecture should not
imply otherwise.

---

## Phase 3 — Medallion build

- [ ] **Bronze** — Copy activity, Db2 → Lakehouse Delta, one table per source
      table, no transformation. Land it exactly as it arrives.
- [ ] **Silver** — conform types, resolve the three date formats, apply the DQ
      rules, quarantine failures rather than dropping them.
- [ ] **Gold** — dimensional model for the semantic layer.
- [ ] **Semantic model** — Direct Lake.
- [ ] **Power BI report** — deliberately rebuild something close to what they
      have today, so the comparison is like-for-like.
- [ ] **Fabric data agent** — needs a paid **F2+** capacity. F8 is available.

The delta batch (`./scripts/06_make_delta.py`) plants twelve business-rule
violations for silver to catch. They are listed in
`db2/delta/delta_manifest.json`. Structural corruption — orphan keys, missing
required fields — is **not** in Db2, because Db2 will not accept it; that class
of error arrives through the CSV path instead. That split is worth making
explicitly during the demo: it is the difference between a governed source and a
spreadsheet.

---

## Phase 4 — Change capture, and the gap to be honest about

### Three patterns, in increasing order of honesty

**1. Full reload.** Simple, defensible at this data volume, and what most
Equation extracts do today anyway. Start here.

**2. Watermark on `ROW CHANGE TIMESTAMP`** — implemented and proven in this
repo. `06_make_delta.py` + `08_apply_delta.sh` demonstrate it moving: 250 new
rows and 50 in-place updates, where **a watermark on the business date would
have missed all 50 updates**.

> **The gap: this does not capture deletes.** A row that is gone cannot carry a
> changed timestamp. Say this out loud before someone in the room says it for
> you — an audience of core banking engineers will spot it immediately, and
> credibility is much cheaper to keep than to recover.
>
> Mitigations: periodic full reconciliation, soft deletes in the source, or (3).

**3. Journal / log-based CDC.** The real answer for production, and what Db2 for
i gives you via journals. Out of scope for the demo but the right thing to point
at as the target state.

### Fabric CDC support — verify, do not assume

- There is **no CDC support for Db2** in Fabric today.
- There is **no native Mirroring** for Db2.
- Two Microsoft doc pages **conflict** on whether Copy job supports
  watermark-based incremental for Db2. **Test it in the tenant** before showing
  it. Do not put it on a slide on the strength of the docs.

### Db2 LUW vs Db2 for i — the delta that matters to NBKI

Equation runs on **Db2 for i** (IBM i / AS400), not Db2 LUW. The demo uses LUW
because that is what Community Edition is. Be upfront about this; then show the
mapping:

| | Db2 LUW (this demo) | Db2 for i (their Equation) |
|---|---|---|
| Port | 50000 | **446** or **448** |
| Container | schema | **library** |
| Catalog | `SYSCAT.TABLES` | **`QSYS2.SYSTABLES`** |
| Packages | implicit | may need **`CRTSQLPKG`** |
| Change capture | `ROW CHANGE TIMESTAMP` | **journals** (better) |
| Driver | either | **Microsoft driver only** — not IBM .NET |

The architecture, the medallion, and everything downstream are identical. The
connector and the change-capture mechanism are what differ.

---

## Phase 5 — Governance, and the rehearsal

- [ ] Purview / Fabric domain lineage: source → bronze → silver → gold → report.
- [ ] Sensitivity labels — this is a bank; PII handling should be visible, not
      assumed.
- [ ] Row-level security on the semantic model.
- [ ] The audit story: *who changed this number, when, and from what*. This is
      the one today's CSV process cannot answer at all, and for a UK-regulated
      entity it is not a nice-to-have.

### Rehearse the failure, not just the demo

- [ ] Run the whole thing end to end, twice.
- [ ] **Rehearse the fallback specifically.** Practise switching to the CSV drop
      mid-flight. Run `./scripts/09_reconcile.sh` beforehand so you can state,
      truthfully and without hedging, that the numbers do not move.
- [ ] Time it. Know which sections to cut if connectivity eats twenty minutes.

---

## Open questions for the customer

**G2 — Is cross-geo AI processing acceptable to NBKI compliance?**
This gates the Fabric data agent. NBKI International is UK-regulated; if AI
processing outside the UK/EU is not acceptable, the data agent comes out of the
demo. **Ask before building it**, not after.

**G3 — Who is in the room?**
The demo should be materially different for each:
- *IBM i / infrastructure engineers* — lead with connectivity, the gateway, the
  port-446 mapping, journals, and the deletes gap. They will test you on it.
- *Data / BI / business* — lead with the wrong total in the CSV footer, then
  show it becoming impossible. Skip the connector detail entirely.

---

## Known limits of what was built

- **Scale is now measured, not assumed.** The full chain has run against the
  real data: 13.3M transactions, 5.1M AML rows, 8.9M fraud labels. Peak RSS
  during profiling stayed at ~12 MB, confirming the streaming refactor. Prepare
  runs at ~57k rows/s (4m20s); profiling is the slow step at ~4k rows/s (~70
  min) and is the obvious candidate if that ever becomes painful.
- **`SET INTEGRITY` and `LOAD` are checked for errors, `RUNSTATS` is not fatal.**
  A RUNSTATS failure only makes queries slow; it warns rather than stops.
- **The CSV extracts predate the delta.** If you regenerate one, regenerate both
  and re-run `./scripts/09_reconcile.sh`.
- **Rollback is partial by design.** `08_apply_delta.sh --rollback` removes the
  inserted rows but cannot restore the original values of the updated ones. For
  a clean slate, re-run `04_load.sh`.

## Still outstanding in this repo

- [ ] **Download the real Kaggle data.** Everything so far is proven against
      generated fixtures — see the README. Needs `~/.kaggle/kaggle.json`.
- [ ] Re-run `00_download.sh` → `01_profile.py` → `02_generate_ddl.py` and
      **expect the profiler to report differences** from the fixture
      assumptions. That is what it is for.
- [ ] Regenerate the CSV drop and the delta from real data, and re-reconcile.
- [ ] Decide the final demo volume. `HI-Small` for AML; **never `Large`** — Db2
      Community Edition is 4 cores and 16 GB.

---

## Two things that must never reach a customer deck

1. **`CUSMAS` / `ACCMAS` are not verified Equation file names.** A web search
   produced them; they could not be corroborated anywhere. They may well be
   hallucinated. Do not put them in front of a customer who runs Equation and
   would know.

2. **"Regeneration strips the original licence" is wrong** and was withdrawn
   during this work as legally unsafe. Synthetic data derived from a licensed
   dataset does not automatically escape that licence. If licensing becomes a
   real question, it goes to legal, not to an architect's judgement.
   Dataset licences are recorded in `docs/dataset-selection.md`.
