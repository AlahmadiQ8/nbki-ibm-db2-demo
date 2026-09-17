# NBKI — IBM Db2 → Microsoft Fabric demo: seed data

Seed data for a demo showing **IBM Db2 → Microsoft Fabric** ingestion in a
medallion architecture, built for **NBK International**, who run **Finastra
Equation** core banking and today extract to CSV by hand to build Power BI
reports.

This repository holds the data that seeds Db2, a CSV drop-in fallback for when
the live path fails, and the infrastructure that stands the whole thing up on
Azure: the Db2 VM, the on-premises data gateway, and the network that connects
them to Fabric. The medallion build itself — bronze/silver/gold, the semantic
model, the report — is still deliberately out of scope; see
[`docs/roadmap.md`](docs/roadmap.md).

---

> **Picking this up in a new session?** Start with
> [`docs/session-handoff.md`](docs/session-handoff.md) — it is the current-state
> snapshot: live resource IDs, the network posture (everything is locked to a
> VPN), the single remaining task, and the traps that have already cost time.

## Read this first

**The pipeline has been run end to end against the real Kaggle data.**
27.3 million rows are loaded into Db2, verified 23/23, with control totals
tying exactly.

| | |
|---|---|
| CUSTOMERS | 2,000 |
| CARDS | 6,146 |
| TRANSACTIONS | 13,305,915 |
| FRAUD_LABELS | 8,914,963 |
| AML_TRANSACTIONS | 5,078,345 |
| Rows rejected by Db2 LOAD | **0** |

Timings on an arm64 Mac with Db2 under Rosetta: download ~6 min, profile ~70
min, prepare 4m20s, load ~9 min.

### It now also runs on Azure

The same 27.3 million rows are loaded into **Db2 11.5.9.0 on an Azure VM**
(Sweden Central, Standard_D4s_v5, x86_64), verified **23/23** with control totals
tying exactly, and the CSV fallback reconciles **21/21** against it. A SQL client
on the workstation reaches it **over TLS on port 50001**, as a least-privileged
`FABRICRO` account, and returns all six counts exactly — `scripts/15_client_test.py`
asserts that rather than asking you to eyeball it.

**Db2 is not on the public internet.** A point-to-site VPN gateway puts the
workstation inside the VNet, and `./infra/deploy.sh --lock-to-vpn` then removes
every internet-sourced inbound rule. Verified: public 22 and 50001 both refuse
connections, while the private addresses answer over the VPN. Azure Bastion
remains as break-glass.

**The ingestion path is proven.** A Fabric Copy job reads Db2 through the
on-premises gateway and lands `CUSTOMERS` in a Lakehouse — 2,000 rows, confirmed
from the Delta log and the Parquet footer. One finding worth carrying into any
design discussion: **the pipeline Copy path does not negotiate TLS**, while the
Power Query path does, so Copy needs a cleartext connection whose reachability is
confined by NSG to the gateway NIC alone. See
[`docs/session-handoff.md`](docs/session-handoff.md).

The on-premises data gateway is installed and running on a second VM, with the
Db2 certificate in its trust store and connectivity to `10.20.1.4:50001` proven.
What is left is the gateway's **cluster registration**, which Microsoft documents
as impossible to automate — it needs one interactive sign-in. See
[`docs/runbook-phase1.md`](docs/runbook-phase1.md).

Cleartext Db2 is not exposed anywhere: port 50000 is bound to the container
host's loopback, and only the TLS listener is reachable.

### What profiling the real data changed

The fixtures were a reasonable guess. They were also wrong in four ways, and
every one of them would have shipped:

| Assumption | Reality | Consequence if unfixed |
|---|---|---|
| AML duplicate column is `Account.1` (pandas convention) | The header contains **`Account` twice, literally** | `csv.DictReader` silently keeps the last one. `ACCOUNT_TO` loaded **blank** on a NOT NULL column |
| AML amounts are `DECIMAL(19,2)` | **148,151 rows** carry up to 6 decimal places (down to 0.000001) | Db2 **rounds silently** — no error, no rejected row, control totals stop tying |
| `merchant_state` is a 2-letter code, `VARCHAR(16)` | Mixes US states with country names; longest is `Saint Vincent and the Grenadines` (32) | Truncation |
| `zip` is clean text | Arrives float-formatted: `58523.0` | ZIP stored as `"58523.0"` |

The ZIP column is worth showing the customer: the leading zeros were **already
destroyed upstream** before the file was written (the lowest value present is
1001, i.e. Massachusetts 01001). No downstream process can recover them. That is
the cost of moving banking data through something that treats an identifier as a
number, and it is the argument for the governed path in one example.

Three of those four were caught automatically. The `DECIMAL` scale problem was
not — the generator checked column *width* but never *scale*, so silent rounding
would have passed review. That check now exists and is negative-tested in both
directions.

### Re-running from scratch

```bash
./scripts/00_download.sh        # ~1.8 GB, validates the token first
./scripts/01_profile.py         # ~70 min; read data/profile/profile.md
./scripts/02_generate_ddl.py    # must end with "No warnings"
./scripts/03_prepare.py         # ~4 min, streams
./scripts/04_load.sh
./scripts/05_verify.sh          # must be 23/23
```

`data/raw/.provenance` records whether the files are real or fixtures. Both
directions are guarded: `00_download.sh` refuses to download over fixtures, and
`dev_make_fixtures.py` refuses to overwrite a real download. Neither can quietly
destroy the other.

Never paste a Kaggle token into a chat window, a commit, or a deck. It is a
bearer credential for the whole account.

Validation was also done under **Rosetta emulation on an arm64 Mac**, against
**Db2 11.5.9.0 Community Edition in Docker** — not on the Azure VM the demo will
use. The scripts run in both modes (`DB2_MODE=docker|local`) specifically so the
proven code is the code that ships.

---

## What is here

```
scripts/
  db2_up.sh              start the local Db2 container, wait until it answers SQL
  00_download.sh         fetch the datasets from Kaggle  (needs credentials)
  01_profile.py          profile the raw files BEFORE writing any DDL
  02_generate_ddl.py     profile + overlay -> DDL, so schema cannot drift
  03_prepare.py          clean, normalise, and compute control totals
  04_load.sh             create schema, LOAD, SET INTEGRITY, RUNSTATS
  05_verify.sh           prove what is in Db2 matches what we prepared  (23 checks, delta-aware)
  06_make_delta.py       generate the second batch that moves the watermark
  07_make_csv_drop.py    generate the messy CSV fallback
  08_apply_delta.sh      apply the delta and show the watermark move
  09_reconcile.sh        prove file -> manifest -> Db2 all agree  (21 checks)
  11_sync_to_vm.sh       push the repo and the prepared data to the Azure VM
  12_gateway_install.ps1 install the on-premises data gateway, unattended
  13_gateway_register.ps1  register the cluster  (the one interactive step)
  14_create_fabricro.sh  create the read-only principal Fabric connects as
  15_client_test.py      connect from your workstation over TLS and assert every count
  16_fabric_pipeline.sh  list/export/create/run Fabric Copy jobs and pipelines
                         (--verify-restore proves a committed definition restores;
                          --reland is delete + recreate + run, see its comments)
  17_verify_bronze.py    prove the Fabric bronze lakehouse matches the source  (77 checks)
  18_assert_pristine.sh  prove the delta is UNSPENT  (catches what 05_verify.sh cannot)
  19_make_bronze_copyjob.py  generate the six-table bronze Copy job definition
  csv_check.py           parse the messy extracts and report what they REALLY hold
  _db2_lib.sh            shared Db2 transport  (read the comments before editing)
                         DB2_MODE=azure talks over az vm run-command -- no VPN needed
  _onelake.py            read Delta tables out of OneLake over HTTP range requests
  dev_make_fixtures.py   synthetic stand-ins, with the quirks of the real thing

db2/
  ddl/overlay.json       hand-authored design decisions — the only file to edit
  ddl/*.sql              GENERATED. Do not edit; change the overlay and regenerate
  delta/                 GENERATED delta batch + its expected results

csv-drop/                the fallback, and the "before" picture.  See its README
infra/
  main.bicep             the Azure footprint: VNet, NSGs, two VMs, Bastion, P2S VPN
  deploy.sh              provision, and generate secrets into ~/.nbki-demo
                         (--lock-to-vpn drops every internet-sourced inbound rule)
  vpn_client_profile.sh  fetch the Azure VPN Client profile for this Mac
  _ensure_ssh_access.sh  re-assert the SSH rule the tenant keeps deleting
  bootstrap_db2.sh       Docker + operator account on the Db2 VM
  start_db2.sh           start the container and configure the TLS listener
  trust_cert_on_gateway.sh   make the gateway trust the Db2 certificate
  start.sh / stop.sh     deallocate and bring back up  (start.sh also restarts Db2)
  teardown.sh            delete the resource group
docs/
  session-handoff.md     CURRENT STATE — read this first in a new session
  demo-narrative.md      the opening slides and speaker notes, with what may NOT be claimed
  feasibility.md         the original feasibility analysis
  dataset-selection.md   which datasets, why, licences, and what was rejected
  runbook-phase1.md      how to operate the Azure environment
  roadmap.md             everything deferred to follow-up sessions
fabric/
  copyjob_bronze_customers.json  the original portal-built Copy job — the reference shape
  cj_bronze_db2.json             GENERATED six-table bronze Copy job (19_make_bronze_copyjob.py)
```

## Running it

```bash
./scripts/db2_up.sh              # ~4-5 min on first start under emulation
./scripts/dev_make_fixtures.py   # or ./scripts/00_download.sh for real data
./scripts/01_profile.py
./scripts/02_generate_ddl.py
./scripts/03_prepare.py
./scripts/04_load.sh
./scripts/05_verify.sh           # must be 23/23 (before or after the delta)

./scripts/06_make_delta.py       # build the incremental batch
./scripts/07_make_csv_drop.py    # build the fallback
./scripts/09_reconcile.sh        # prove both paths agree

# during the demo, after the first Fabric read:
./scripts/08_apply_delta.sh
```

Overridable by environment variable: `DB2_MODE`, `DB2_CONTAINER`,
`DB2_DATABASE`, `DB2_INSTANCE`, `DB2_BIND`. Defaults target the local container,
bound to loopback.

`DB2_SCHEMA` is **not** freely overridable. The schema has one source of truth —
`"schema"` in `db2/ddl/overlay.json` — because that is what the DDL generator
uses. Setting the variable to something else would create objects in one schema
and load into another, so the scripts refuse to run on a mismatch. Change the
overlay and regenerate.

No third-party Python packages are required. The profiler and the prepare step
are stdlib-only, on purpose: a missing wheel on a very new Python must not be
what stops a customer demo.

The one exception is `scripts/15_client_test.py`, which needs `ibm_db` to open a
real DRDA connection to the Azure VM. That is a client-side acceptance test
rather than part of the seed pipeline, so it cannot break the demo by failing to
install — and it is the only honest way to prove the wire end to end.

---

## The parts that carry the argument

### The watermark, and what it misses

`TRANSACTIONS` and `AML_TRANSACTIONS` carry:

```sql
LAST_UPDATED_TS TIMESTAMP NOT NULL
  GENERATED ALWAYS FOR EACH ROW ON UPDATE AS ROW CHANGE TIMESTAMP
```

Verified behaviour: set on insert, advanced on update, untouched rows left
alone. `08_apply_delta.sh` demonstrates it — 250 new rows and **50 updated in
place**, where a watermark on the business date would have found the 250 and
missed all 50.

> **It does not capture deletes.** A row that is gone cannot carry a changed
> timestamp. State this before the audience does; see `docs/roadmap.md` for the
> mitigations.

### The CSV fallback is also the pitch

`csv-drop/` is a working fallback if Db2 or the gateway fails on the day — the
figures reconcile with Db2 **exactly**, which `09_reconcile.sh` proves, so
switching sources will not move a number on any slide.

It is also deliberately, specifically broken in twelve documented ways, each one
a real defect of hand-made extracts. The sharpest: **every file's footer total
is wrong**, by a few hundred dollars, because of a duplicated row that nothing
in the file reveals. No error, no warning, a plausible-looking report.

That silent gap is the business case. See
[`csv-drop/README.md`](csv-drop/README.md).

### Data quality is split across the two paths, on purpose

Db2 enforces its foreign keys and NOT NULL constraints, so structurally broken
rows **cannot** be inserted, and we did not disable that to stage a demo.

- **Db2 delta** carries twelve *business-rule* violations that are structurally
  legal: zero amounts, implausible values, future dates, inconsistent casing, a
  duplicated business key.
- **CSV drop** carries the structural corruption, which is how it reaches a bank
  in reality: not from the database, but from a hand-made extract.

Worth saying out loud during the demo. It is the difference between a governed
source and a spreadsheet.

---

## Design decisions worth knowing

**Profile before DDL.** Column *names* were verified from third-party
repositories; *formats* were not. The DDL is generated from the profile plus a
hand-authored overlay, so the schema cannot drift from the data. Edit
`db2/ddl/overlay.json`, never the generated SQL.

**Deliberate divergence is recorded, not silent.** The overlay's
`override_reason` field distinguishes an intentional decision from a surprise.
The generator warns on the latter and merely notes the former.

**Zero-padded identifiers stay text.** `"016415"` becomes `VARCHAR`, not
`SMALLINT`. Sort codes, CVVs, ZIP codes and PANs are all identifiers that happen
to be digits, and this is a genuine banking-data trap.

**Money is `DECIMAL(15,2)`, never float**, and control totals are compared with
`Decimal` and must tie **exactly**. `05_verify.sh` fails on a penny of drift.

`05_verify.sh` is **delta-aware**. The manifest describes the table as it was
loaded, so once `08_apply_delta.sh` has run the table legitimately no longer
matches it. Rather than let that print *"Verification FAILED. Do not demo from
this data"* at the worst possible moment, verify detects the delta and folds it
into the expected figures. It recognises three states, and only one of them is
silent:

| State in Db2 | Reported as | Result |
|---|---|---|
| No delta rows present | `not applied` | 23/23 against the load manifest |
| All 250 delta rows present | `applied (250 rows, 20105257.92)` | 23/23 against manifest + delta |
| Some present, some not | `PARTIAL — n of 250` | **FAIL** — never absorbed |

That last row is the point. A half-applied delta is a real fault, so it is
raised rather than quietly folded into the arithmetic.

---

## What a review round changed

The first working version of this pipeline passed all its own checks and was
still wrong in ways worth recording, because most of them are the kind that only
surface in front of the customer:

- **`09_reconcile.sh` never opened a CSV file.** It compared the manifest with
  Db2, so a missing, stale, truncated or edited extract still reconciled
  cleanly. It now parses the physical files (`csv_check.py`), undoes each
  planted defect, and checks file → manifest → Db2. There are negative tests for
  tampered, missing and stray files.
- **`00_download.sh` would have silently kept the fixtures.** The fixture
  generator writes the same filenames, so "already present, skipping" would have
  left synthetic data in place while appearing to have fetched the real thing.
  A `.provenance` marker now makes that impossible, and the check requires all
  five files rather than one.
- **The delta's "idempotent" delete was `WHERE TRANSACTION_ID > max_id`** —
  which means "delete everything added since the snapshot", not "delete this
  delta". It is now scoped to an exact ID range.
- **The planted "duplicate business key" rows were not duplicates.** They shared
  an amount and a timestamp but had different customers, cards and merchants, so
  no sensible dedupe rule would have caught them. They are now identical apart
  from the primary key.
- **`04_load.sh` swallowed load and `SET INTEGRITY` failures** and printed "Load
  complete" regardless. It now fails on any error or rejected row.
- **`03_prepare.py` wrote malformed rows.** The guard `if bad and not errors`
  never fired, because `errors` is non-empty as soon as anything fails. Rows that
  failed conversion were written with empty values. Related and not in the review:
  those rows had already contributed to the control totals, so the totals
  described money that was not in the output.
- **Both generators loaded the whole transaction file into memory** — fine for a
  5,000-row fixture, several gigabytes for the real 13 million. Both now stream,
  the delta using reservoir sampling to pick its update targets in one pass.

## Db2 sharp edges found during this build

Recorded so nobody pays for them twice. The full detail is in the comments of
`scripts/_db2_lib.sh`.

| Symptom | Cause |
|---|---|
| Bare `DB21005E`, no explanation | `mktemp` creates 0600; `docker cp` preserves the mode, so the instance owner cannot read the file |
| `SQL0104N` on a generated `LOAD` | BSD `seq -s ', '` emits a **trailing** separator; GNU `seq` does not — platform-divergent, would have behaved differently on the VM |
| Script dies on the success path | `set -e` plus `cmd \| grep … && { … }` exits when grep finds nothing |
| No way to skip a CSV header on LOAD | Db2 has no `SKIPROWS` for DEL files. Only `ROWCOUNT`. Strip the header first |
| `SQL0668N` reason 1 after a clean load | `LOAD` leaves FK tables in check-pending until `SET INTEGRITY … IMMEDIATE CHECKED` |
| Query results polluted by banners | `db2 -x` drops column headings but **not** the CONNECT banner or trailing `DB20000I`. Fence output with `ECHO` markers |
| `db2` exits 1 on a working script | The CLP exit code is not a boolean: 0 ok, **1 = no rows found**, 2 warning, 4 error, 8 CLP error |

Found only by running against the real 27M rows — none of these appear at
fixture scale:

| Symptom | Cause |
|---|---|
| A NOT NULL column loads **blank on every row** | `csv.DictReader` silently collapses duplicate header names, last one wins. `HI-Small_Trans.csv` has `Account` twice. Read with `csv.reader` and disambiguate positionally |
| Profiler control total disagrees with the prepare step by 3.98 | The profiler summed in **float**; at 3x10^13 with 6 decimals that exceeds float64's ~16 significant digits. Now sums in `Decimal` and serialises as a string, because a JSON float would reintroduce the same loss |
| `--limit 100` reads all 5M rows | The limit counted **output** rows. When every row fails conversion, nothing is ever output, so the limit never trips. Now aborts early with a mapping diagnosis |
| `--raw /some/path` fails with "is not in the subpath of" | `Path.relative_to` raises outside the repo — a *display* concern reported as if the data were unreadable |

And one from the same family, in a different tool:

| Symptom | Cause |
|---|---|
| Kaggle download fails *after* the credential check passed | The Kaggle CLI **exits 0 even when authentication fails**. Worse, most read endpoints work anonymously, and `datasets list --mine` returns "No datasets found" on a rejected token — indistinguishable from an empty account. `00_download.sh` probes `competitions list` and reads its **output**, not its exit code |

## Azure and gateway sharp edges

Found while standing the demo up on a real VM. Three of these were latent bugs in
code that had passed every check on the Mac. Full detail in
[`docs/runbook-phase1.md`](docs/runbook-phase1.md).

| Symptom | Cause |
|---|---|
| `db2_up.sh`: "unexpected container state" | Docker 29 prints an **empty line to stdout** *and* exits non-zero for a missing container, so `docker inspect … \|\| echo absent` yields `"\nabsent"`. Older Docker printed nothing, hiding it |
| `db2_up.sh` waits the full 900s against a database that started in four minutes | `db2_prep_stage` ran *after* the readiness loop, but the probe ships SQL in via `docker cp` **into that directory**. On a fresh container it does not exist, so every probe fails. Reproduces only on a brand-new container — the demo machine, not the developer's |
| `rsync: unrecognized option --info=progress2` | macOS ships rsync 2.6.9; `--info` arrived in 3.1. Use `--progress` |
| `az storage` / `az keyvault` data plane returns `AuthorizationFailure` | **Not RBAC** — the role assignment was correct. An `ASC DataProtection` policy sets `publicNetworkAccess: Disabled` on new storage accounts and vaults within a minute of creation, and disables shared-key auth. Re-enabling it is accepted and silently reverted |
| Copy job / pipeline Copy fails, but the connection tests green | **The Fabric Copy engine does not speak TLS to Db2**, while the Power Query path does — same connection object. `db2diag.log` shows `GSK_ERROR_BAD_MESSAGE`; the client reports `EUSRIDNWPWD SQLCODE=-1040`, which looks like an auth failure and is not. Needs a second, cleartext connection reachable only from the gateway NIC |
| Redeploy fails with `OperationNotAllowed ... storage account type` | A governance automation downgrades idle OS disks from Premium to Standard while the VM is deallocated. A template that asserts the disk SKU breaks the first time the environment is stopped overnight; do not assert it |
| Fabric cannot reach Db2 after a VM stop/start, every setting looks correct | **`DB2COMM` reverted to `TCPIP`.** The Db2 CE image's entrypoint resets it on every container start, dropping SSL. Keystore, `SSL_SVCENAME`, `SSL_SVR_LABEL` and the published port all survive, so nothing looks wrong — but nothing listens on the TLS port. `infra/start.sh` re-asserts it |
| SSH or RDP stops working with no config change | The tenant deletes any NSG rule exposing 22 or 3389 to the internet, even pinned to a `/32`. Use the P2S VPN, or Azure Bastion (Developer SKU is free). NSGs are stateful, so an in-flight transfer survives; only new connections are refused |
| P2S VPN needed for a Mac, Basic SKU won't do | Basic supports only SSTP, which is Windows-only. IKEv2/OpenVPN starts at **VpnGw1AZ**. A VPN gateway also cannot be deallocated, so it bills until deleted |
| Entra-auth VPN docs tell you to register an app and grant consent | That applies to the older, manually-registered audience values. With the Microsoft-registered app ID `c632b3df-fb67-4d84-bdcf-b95ad541b5c8` neither is needed |
| `Install-DataGateway -AcceptConditions` fails | "Login first with Login-DataGatewayServiceAccount" — the cmdlet needs an authenticated session just to fetch the installer. Run the vendor installer directly with `-q -norestart` instead; that *is* silent |
| `Add-DataGatewayCluster` rejects a service principal | Documented: "must be run with a user based credential". Registration cannot be automated. Budget one RDP |
| Gateway registers but Fabric cannot use it | `-RegionKey` was pinned. "For Power BI, it can only be used in the default tenant region." Omit it |
| `Install-PackageProvider -Name NuGet` fails on PowerShell 7 | That is 5.1 advice; PowerShellGet 2.x already has what it needs |
| "Copy job for Db2 is full-load only" | **Effectively true, for the opposite reason to the documented one.** The matrix now says watermark incremental is supported, and the UI accepts `SnapshotPlusIncremental` on `LAST_UPDATED_TS`. But it **fails at runtime**: initial snapshot Completed, then a single touched row makes the next run Fail. Same with `Upsert` and `Append`, so it is the read, not the merge. 109-row reproduction in `docs/roadmap.md` Phase 4. This row has now been wrong in both directions — run it, do not read it |
| A Copy job succeeds once, then fails forever | CDC mode runs the initial snapshot on the **first** run only; every later run takes the broken incremental path. Recreating the item resets it. `16_fabric_pipeline.sh --reland` does delete → recreate → run |
| `jobMode: Batch` fails instantly with a `checkpointName` expression error | The runtime needs a `checkpointName` per activity, which CDC mode derives from `changeDataSettings`. **`--export` does not emit one**, and the published Copy job definition schema never mentions it — so an exported definition cannot simply be edited into Batch mode. Export is not lossless |
| Creating any Fabric item returns a bare **HTTP 404** | The capacity is **paused**. The body says `CapacityNotActive`, but `curl -f` hides it, so it reads like a wrong workspace id or a dead token. Resume the F-SKU and retry |
| Recreating an item you just deleted returns **HTTP 409** | `ItemDisplayNameNotAvailableYet` — Fabric holds a deleted item's display name for a few minutes. It is retriable; wait and repeat |
| Both VMs deallocated and the capacity paused, overnight, unasked | An automated tenant identity does this — observed at 21:47 UTC. `az vm run-command` then reports `OperationNotAllowed`. Recover with `./infra/start.sh` (add `--via-azure` if the VPN is down); it resumes the capacity, starts the container and re-asserts TLS. The environment does not stay up by itself |
| `05_verify.sh` reports 22 of 23 checks failed with **empty** values | Db2 was unreachable, not wrong. Every query returned nothing and each check compared against blank. It now calls `db2_require_running` first and fails with one clear message |
| A verified-green Db2 can still be a spent demo | `05_verify.sh` detects the delta only by its 250 inserted IDs. A **rollback** removes those but cannot restore the 50 in-place updates, and they move no control total — so a half-spent delta passes 23/23. Use `18_assert_pristine.sh` |
| `SQL30081N` protocol error `60` from a SQL client | The VPN dropped. It reads like Db2 being down. `DB2_MODE=azure` routes SQL over `az vm run-command` instead and needs no VPN at all |
| A Copy job audit-column block is rejected with HTTP 400 | The audit-column JSON shape is **unpublished** — it is not in the Copy job definition schema, and a plausible shape found online is wrong. Configure audit columns in the portal, then export |
| Copy job fails `EUSRIDNWPWD SQLCODE=-1040`, credentials are correct | Not an auth fault. The **pipeline Copy path does not negotiate TLS** while the Power Query path does, so it sent cleartext DRDA at the TLS port and Db2 answered `GSK_ERROR_BAD_MESSAGE`. Copy needs a separate cleartext connection; the hop is confined by NSG to the gateway NIC |
| A JDBC SQL client rejects `db2cert.arm` | The IBM Db2 VS Code extension and other JDBC clients need a **JKS truststore + password**, not a PEM. `start_db2.sh` builds `~/.nbki-demo/db2-truststore.jks` |
| `PATCH /v1/connections/{id}` "succeeds" but nothing changes | It returns HTTP 200 and **silently ignores `displayName`** for on-premises gateway connections |
| Fabric auth fails after a container rebuild | `FABRICRO` is an OS user in the container's `/etc/passwd`, which is an image layer, not the `/database` volume. The GRANTs survive and point at a user that no longer exists |

---

## Status

| | |
|---|---|
| Kaggle CLI installed (`.venv`) + auth preflight | done |
| **Real Kaggle data downloaded (1.8 GB)** | **done** |
| **Real data profiled (18.4M rows scanned)** | **done — 4 assumptions corrected** |
| Db2 Community Edition 11.5.9.0 running | done (Docker, arm64 under emulation) |
| `ROW CHANGE TIMESTAMP` watermark verified | done, on 13.3M real rows |
| Profiler, DDL generator, prepare step | done |
| **Load: 6 tables, 27.3M rows, 0 rejected** | **done** |
| Verification: 23 checks | done, 23/23 on real data |
| Delta batch, watermark movement proven | done, IDs 23,761,875-23,762,124 |
| CSV fallback, reconciled against Db2 | done, 21/21 on real data |
| Negative tests: tampered / missing / stray files | done, all correctly rejected |
| **Azure VM, Db2 11.5.9.0 + TLS, gateway installed** | **done — `docs/runbook-phase1.md`** |
| **Gateway registered and Online, Fabric connection bound + tested** | **done** |
| **Db2 off the public internet — P2S VPN, everything else denied** | **done** |
| **Ingestion proven: Copy job → `lh_bronze.CUSTOMERS`, 2,000 rows** | **done** |
| **Bronze: all 6 tables, 27,307,478 rows, Db2 → `lh_bronze`** | **done — 10m31s, ~43k rows/s** |
| **Bronze verification: 77 checks against the source** | **done, 77/77** |
| Source-pristine assertion (delta unspent) | done, 3/3 — `18_assert_pristine.sh` |
| Fabric Copy job **incremental** from Db2 | **tested — does not work**, see `docs/roadmap.md` |
| Bronze audit columns (row-level provenance) | not applied — JSON shape unpublished, needs a portal pass |
| Silver, gold, semantic model, report, data agent | next — `docs/roadmap.md` |

Data files are not committed: the primary dataset is ~1.4 GB and the AML set
reaches 41 GB, and we redistribute nothing — only the scripts that fetch it.
Licences are recorded in [`docs/dataset-selection.md`](docs/dataset-selection.md).
