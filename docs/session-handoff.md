# Session handoff — current state

**As of 2026-09-16.** Read this first in a new session; it is the snapshot of what
exists right now. The other documents explain *why* things are the way they are:

| Document | Answers |
|---|---|
| `README.md` | What the repo is, what the data proves, every sharp edge found |
| `docs/runbook-phase1.md` | How to operate the Azure environment day to day |
| `docs/roadmap.md` | What is deliberately not built yet, and the traps waiting there |
| `docs/feasibility.md` | The original analysis and the architecture argument |

---

## Where this got to

**Phases 1 and 2 are complete. Bronze is now landed and verified** — all six
tables, 27,307,478 rows, in `lh_bronze` as Delta, reconciling to the source
exactly. Next is **silver**; see `docs/roadmap.md`.

Read the two findings under "What bronze proved, and what it disproved" before
saying anything about incremental to a customer. One of them retires a claim the
previous handoff was optimistic about.

### Proven, by running it

| Check | Result |
|---|---|
| `05_verify.sh` (Db2 aggregates, all six tables) | **23/23**, control totals tie exactly |
| `18_assert_pristine.sh` (delta unspent) | **3/3** |
| `09_reconcile.sh` (CSV fallback, transactions, 3 months) | **21/21** |
| `04_load.sh` | 27,307,478 rows, **0 rejected** |
| `15_client_test.py` over TLS as `FABRICRO` | **7/7**, DELETE refused `SQL0551N` |
| **`17_verify_bronze.py` — bronze vs source** | **77/77**, every control total exact |
| **Bronze initial load, six tables** | **27,307,478 rows in 10m31s** (~43k rows/s) |
| Copy job **incremental** leg | **FAILS** — reproducible, see below |
| Public exposure | **none** — VPN + Bastion only |

> **Scope correction, carried forward.** `09_reconcile.sh` is **7 checks against
> each of 3 monthly transaction extracts** — it covers the CSV fallback path for
> `TRANSACTIONS` only, not all six tables. `05_verify.sh` is the all-table Db2
> reconciliation. Earlier notes cited 21/21 as though it were the latter.

---

## What bronze proved, and what it disproved

### It works, and it is fast

27.3M rows across six tables landed in **10 minutes 31 seconds** through the
on-premises gateway — roughly 43,000 rows/second, with no auto-partitioning
(Copy job does not offer it for Db2). That figure is the evidence for the
"Slow → throughput at scale" line on the demo's Slide 3, which was previously
unevidenced.

`17_verify_bronze.py` then checks 65 things and passes all of them: row counts,
exact control totals, Db2→Delta type mapping, merge-key uniqueness, null
profiles, and value domains.

Two type results worth keeping:

- **`DECIMAL(23,6)` lands as Delta `decimal(23,6)`, not a double.** The AML total
  ties to all six places — `30412817094323.869350`. A silent demotion to double
  would have rounded the crypto rows and still looked approximately right.
- **Timestamps do not shift.** Db2 `2026-09-15-08.18.10.189024` arrives as
  `2026-09-15 08:18:10.189024+00:00` — identical wall-clock to the microsecond,
  despite `enableTimestampNtz: false`. The naive Db2 value is labelled UTC rather
  than moved. This was settled with a 109-row probe *before* the 27.3M-row load.

  > The residual risk is downstream, not here: the value is *labelled* UTC, so a
  > report rendering in a non-UTC session timezone will display something else.
  > That is a silver / semantic-model decision, and it needs making deliberately.

### The incremental leg fails — this retires a hoped-for claim

The previous handoff recorded the incremental leg as "not yet proven" and
recommended proving it. It has now been tested, and **it does not work.**

Minimal reproduction — one table, 109 rows:

    single-table Copy job, Db2 NBKI.MCC_CODES -> Lakehouse
    run 1, initial snapshot .................. Completed
    touch one source row (watermark advances)
    run 2, incremental ....................... Failed

- Fails identically with `writeBehavior: Upsert` **and** `Append`, so the fault is
  in the incremental **read** from Db2, not the merge.
- Db2's `db2diag.log` records nothing for the attempt.
- The error is only ever `Operation on target CopyJobActivityLoop failed …
  Inner activity name: ConditionalCopy`.
- The portal-built definition configures it identically, so this is not an
  artefact of generating the JSON by hand.

**Operational consequence: a CDC Copy job works exactly once.** Every run after
the first takes the incremental path and fails. Re-land with
`./scripts/16_fabric_pipeline.sh --reland`, which deletes, recreates and runs —
recreating resets the job to "never run".

> This is precisely what the repo's own rule was for: *do not put it on a slide
> on the strength of the exported JSON.* The exported JSON says
> `jobMode: CDC, readMethod: SnapshotPlusIncremental`. It runs snapshots. It does
> not do incremental.

### `Batch` mode is not an escape hatch, and shows `--export` is lossy

Switching to `jobMode: Batch` — a full snapshot every run — looks like the
obvious fix. It fails immediately:

    The expression 'if(equals(pipeline().parameters?.latestCheckpoints
    ?[item().checkpointName], null), ...)' cannot be evaluated because
    property 'checkpointName' doesn't exist

The runtime requires a `checkpointName` on every activity. In CDC mode it is
derived from `changeDataSettings`; with none, there is nothing to derive it from.

**The finding underneath is the important one: `--export` is not lossless.** A
definition exported from a working portal-built job carries no `checkpointName`,
and none is mentioned anywhere in the published Copy job definition schema. So a
committed definition can be recreated faithfully in the mode it was built in, but
cannot be freely edited into another mode. "Build in the portal, export, commit"
still holds — this is a concrete limit on what may be changed afterwards.

### Audit columns: real, wanted, and not yet applied

Copy job now supports per-row audit columns — extraction time, workspace ID, job
ID, **run ID**, job name, incremental window bounds, and custom static values.
That is exactly the provenance the demo narrative promises, with no custom code.

They are **not** applied, because the JSON shape is unpublished. A shape found
online was tried and **rejected with HTTP 400**; the identical definition was
accepted the moment the block was removed. Adding them is a portal pass followed
by `--export`, and it will require re-landing, since they add columns.

---

## Live resources

**Azure** — resource group `rg-nbki-db2-demo`, Sweden Central:

| Resource | Detail |
|---|---|
| `vm-db2` | Ubuntu 22.04, D4s_v5. Db2 11.5.9.0 CE in Docker (`db2demo`). Private **10.20.1.4** |
| `vm-gateway` | Windows Server 2022 Desktop Experience, D4s_v5. Private **10.20.2.4** |
| `vgw-nbki` | P2S VPN gateway, VpnGw1AZ, OpenVPN + Entra ID. Client pool **172.16.201.0/24** |
| `bst-nbki` | Azure Bastion, Developer SKU (free). Break-glass |
| `vnet-nbki` | 10.20.0.0/16 — `snet-db2` .1.0/24, `snet-gateway` .2.0/24, `GatewaySubnet` .255.0/27 |
| `asg-gateway` | ASG on the gateway NIC; both Db2 rules target this, not the subnet CIDR |

**Fabric** — workspace `nbki-db2-demo`, on the F8 capacity `momof8sweden` (Sweden Central, Active):

| Item | ID |
|---|---|
| Workspace | `5c84bcc5-f497-4eac-b59b-5c2a36bec619` |
| Lakehouse `lh_bronze` | `56ba34ce-c8c8-467e-a1a9-8952b7b03dba` |
| SQL endpoint (same lakehouse) | `640253d8-8ea7-4683-b294-01bdd8188162` |
| Gateway `nbki-db2-gw` | `b35258fb-ff47-4221-8749-b551885e4ce1` |
| Copy job `cj_bronze_db2` | recreated on every re-land, so the id changes — find it with `--list` |
| Capacity `momof8sweden` (F8, Sweden Central) | in resource group `fabric-playground-sweden` |

### Bronze contents — verified by `17_verify_bronze.py`, 77/77

| Table | Rows | Merge key |
|---|---:|---|
| `MCC_CODES` | 109 | `MCC_CODE` |
| `CUSTOMERS` | 2,000 | `CUSTOMER_ID` |
| `CARDS` | 6,146 | `CARD_ID` |
| `AML_TRANSACTIONS` | 5,078,345 | `AML_TXN_ID` |
| `FRAUD_LABELS` | 8,914,963 | `TRANSACTION_ID` |
| `TRANSACTIONS` | 13,305,915 | `TRANSACTION_ID` |
| **Total** | **27,307,478** | |

`FRAUD_LABELS` splits `No` = 8,901,631 / `Yes` = 13,332. No audit columns yet —
see above.

> **The previous session's Copy job had vanished from the workspace** when this
> one started; only `lh_bronze` and its SQL endpoint remained. Cause unknown,
> most likely a manual deletion. The committed definition was the only surviving
> record — and `--create` could not actually restore it, because it hardcoded
> `DataPipeline`. Both are fixed: `--create` handles `CopyJob`, and
> `--verify-restore` proves a committed definition round-trips without running it.

---

## The environment shuts itself down overnight

**New, and it will catch you.** At **21:47 UTC** during this session an automated
tenant identity deallocated **both VMs**, and the **F8 capacity was found
paused**. Neither was requested by any script here.

This is the same family of governed-tenant behaviour already recorded for NSG
rules and storage accounts. Budget for it: *the demo environment does not stay up
by itself.*

Symptoms, so they are recognisable rather than mysterious:

| What you see | What it is |
|---|---|
| `az vm run-command` → `OperationNotAllowed: requires the VM to be running` | VMs deallocated |
| Any Fabric item create → **HTTP 404** with `CapacityNotActive` | capacity paused |
| `05_verify.sh` reporting **22 of 23 checks failed** with empty values | Db2 unreachable, *not* bad data |

The last one was actively misleading, so `05_verify.sh` now calls
`db2_require_running` first and fails with one clear message instead.

### Bringing it back up — one command

```bash
./infra/start.sh              # uses SSH when the VPN is up
./infra/start.sh --via-azure  # no VPN: everything over az vm run-command
```

`start.sh` now does the whole recovery, and **probes SSH first** — if the VPN is
down it falls back to `az vm run-command` automatically rather than waiting ten
minutes and then blaming the VM. It is idempotent; running it against a healthy
environment just confirms each step.

What it covers, in order:

1. **Resumes the Fabric capacity** if paused. This is first because a paused
   F-SKU is invisible until Fabric starts returning bare 404s on unrelated calls.
2. Starts both VMs and waits for them.
3. Starts the Db2 container — it has **no restart policy**, so a VM boot leaves
   it stopped — and waits for a real `SELECT` to succeed.
4. **Re-asserts TLS.** The image's entrypoint resets `DB2COMM` to `TCPIP` on
   every container start, dropping SSL. Reproduced live this session: `DB2COMM`
   came back as `TCPIP` with the keystore, `SSL_SVCENAME` and the published port
   all still correct — nothing looks wrong, and nothing listens on 50001.
5. Verifies the listener is actually up, and recreates `FABRICRO` if the
   container was rebuilt.
6. Checks the gateway service and that it can still reach Db2.

Expected output when healthy:

```
==> Checking the Fabric capacity (momof8sweden)
    Active
==> Starting both VMs
==> Starting Db2 and re-asserting TLS via az vm run-command
    [i] DB2COMM=TCPIP,SSL
    TLS_LISTENING=yes
    FABRICRO=present
==> Checking the gateway
Running
db2 reachable: True
```

> **Never use plain `az vm start` on its own.** It leaves the container stopped,
> and once started, `DB2COMM` is back to `TCPIP` with SSL gone. Fabric then
> reports the source as unreachable with nothing visibly misconfigured — the
> single most likely way to arrive at a customer session with a broken demo.

The capacity resource defaults to `momof8sweden` in `fabric-playground-sweden`;
override with `NBKI_FABRIC_CAPACITY` / `NBKI_FABRIC_CAPACITY_RG`.

---

## Talking to Db2 without the VPN

The VPN dropped mid-session, which presents as `SQL30081N` with protocol error
`60` — a timeout that reads like Db2 being down when it is healthy.

`scripts/_db2_lib.sh` now supports **`DB2_MODE=azure`**, which ships SQL over the
Azure control plane with `az vm run-command` instead of a socket. No VPN, no SSH
rule, no open port:

```bash
DB2_MODE=azure ./scripts/05_verify.sh
DB2_MODE=azure ./scripts/18_assert_pristine.sh
```

Each call is an ARM round trip of 20–60 seconds, so it is for verification and
inspection, not chatty loops. Bulk data staging is refused outright — a
control-plane channel is not a data path — and says so.

### Two Db2 connections — do not delete either

`nbki-db2-onprem-copy` looks like an accidental duplicate. It is not; it is the
only one Copy works with. Its name cannot be corrected —
`PATCH /v1/connections/{id}` returns HTTP 200 and silently ignores `displayName`.

| Connection | ID | Endpoint | Encryption | Used by |
|---|---|---|---|---|
| `nbki-db2-onprem` | `f7169c24-…` | `10.20.1.4:50001` | Encrypted | Connection test, Power Query, Dataflow Gen2 |
| `nbki-db2-onprem-copy` | `d247ae2f-…` | `10.20.1.4:50000` | **NotEncrypted** | **Copy jobs / Copy activities** |

**Secrets** — `~/.nbki-demo` on the operator workstation, 0700/0600. Not in Azure
Key Vault; see "Deviations" below. `env.sh` there is what every script sources.

---

## Current network posture: locked to the VPN

Nothing is reachable from the public internet. Both VMs keep public IPs, but only
for **outbound** (default outbound access for new VMs is retired); no inbound
rule references them.

| From | To | Port |
|---|---|---|
| VPN client `172.16.201.0/24` | `vm-db2` | 22, 50001 (TLS) |
| VPN client | `vm-gateway` | 3389 |
| Gateway NIC (`asg-gateway`) | `vm-db2` | 50001 (TLS) **and 50000 (cleartext)** |
| Bastion (`VirtualNetwork`) | both | 22 / 3389 — break-glass |
| anything else | anything | denied at priority 4000 |

**To work with this environment you must connect the Azure VPN Client first.**
Profile: `~/.nbki-demo/azurevpnconfig.xml` (regenerate with
`./infra/vpn_client_profile.sh`). Without it, only Bastion works.

Reopen the public path with a plain `./infra/deploy.sh`; re-lock with
`./infra/deploy.sh --lock-to-vpn --gateway-cleartext`.

> **Keep `--gateway-cleartext` on any redeploy.** Dropping it removes the
> cleartext rule and Copy jobs stop working, with an error that blames
> credentials rather than the network.

---

## Two connector findings that change what you'd say to a customer

**1. The Fabric Copy engine does not speak TLS to Db2.** The Power Query path
(connection test, Navigator, Dataflow Gen2) does; the Copy engine does not — on
the *same connection object*, regardless of it being marked Encrypted. Confirmed
by the portal's own Copy wizard failing identically to hand-authored JSON, with
`GSK_ERROR_BAD_MESSAGE` in `db2diag.log`. The client reports it as
`EUSRIDNWPWD SQLCODE=-1040`, which reads like an authentication failure and is
not one — check `db2diag.log` before chasing credentials. Full detail and the
security position are in the runbook.

That is why there are **two** Db2 connections and why both are needed; the
cleartext hop is scoped by NSG to the gateway NIC alone — not the internet, not
even the VPN subnet. Gateway → Fabric is TLS regardless.

**Worth saying out loud in the demo.** For a bank, "Db2 → gateway is unencrypted
on the Copy path, confined to one NIC inside a private VNet" is a real
architectural point, and it is the argument for co-locating the gateway with the
database in production.

**2. Copy job *offers* watermark incremental for Db2, and it does not work.**

~~The capability matrix saying "Full load only" is wrong.~~ The matrix has since
been corrected to say watermark incremental **is** supported, and the wizard
does produce `jobMode: CDC`, `readMethod: SnapshotPlusIncremental` on
`LAST_UPDATED_TS`, `writeBehavior: Upsert`. It finds and uses the
`ROW CHANGE TIMESTAMP` column this repo exists to provide.

**It still does not work.** Configuring it and running it are different things,
and this session ran it. See "What bronze proved, and what it disproved" above
for the 109-row reproduction. The snapshot leg is solid — 27.3M rows, 10m31s.
The incremental leg fails every time.

> The previous version of this entry said the incremental *behaviour* was
> "still unproven" and should be demonstrated before demoing. That advice was
> right, it was taken, and the answer came back negative. The delta remains
> unspent — `18_assert_pristine.sh` confirms 3/3 — but there is currently
> nothing in Fabric that would consume it incrementally.

---

## Operating bronze

```bash
# 0. the environment does not stay up by itself -- see above
DB2_MODE=azure ./scripts/18_assert_pristine.sh     # 3/3, or stop and reload
DB2_MODE=azure ./scripts/05_verify.sh              # 23/23

# 1. regenerate the definition (only if you changed 19_make_bronze_copyjob.py)
./scripts/19_make_bronze_copyjob.py

# 2. land it. --reland is delete + recreate + run: a CDC Copy job only does a
#    full snapshot on its FIRST run, so recreating is how you re-land.
./scripts/16_fabric_pipeline.sh --reland fabric/cj_bronze_db2.json cj_bronze_db2 CopyJob

# 3. prove it
.venv/bin/python scripts/17_verify_bronze.py       # 77/77
```

Expect about **10m30s** for the load, plus up to a few minutes in `--reland`
waiting for Fabric to release the deleted item's display name.

`17_verify_bronze.py` reads OneLake directly over REST — row counts come from the
Delta transaction log at no data cost, and aggregates fetch only the Parquet
column chunks they need via HTTP range requests. It needs no ODBC driver, no
Spark session and no SQL endpoint, all three of which were unavailable here.

> **Three `MCC_CODES` rows were touched in Db2** during this session
> (`5812`, `5411`, `5511`) to exercise the incremental path —
> `MCC_DESCRIPTION` was set to itself, so **no data changed**; only
> `LAST_UPDATED_TS` advanced. Bronze was re-landed afterwards, so the two agree.
> `TRANSACTIONS` was never touched, and the delta is unspent.

---

## Next: silver

Bronze is done. The next build is **silver**: conform types, resolve the three
date formats, apply the DQ rules, and **quarantine** failures rather than
dropping them. `docs/roadmap.md` Phase 3 has the detail.

Two smaller items worth taking first, because both are cheap and both improve
what can be claimed:

1. **Audit columns.** One portal pass on `cj_bronze_db2` to add extraction time,
   run id, job name and a custom source tag, then `--export` and a re-land.
   Turns the narrative's provenance promise from "the capability exists" into
   "here it is, on every row". Note the JSON shape is unpublished, so it must be
   done in the portal — a guessed shape is rejected with HTTP 400.
2. **Re-check the incremental leg** when the Fabric release notes suggest
   anything has changed. `19_make_bronze_copyjob.py --batch` and the 109-row
   reproduction in its header make retesting a ten-minute job.

Things to keep in mind when building it out:

- **Hand-authoring is safe only from a proven shape.** Three hand-written
  *pipeline* definitions each failed differently — cleartext-at-TLS-port, an
  `InvalidCastException` because `connectionProperties` must be a dictionary,
  and `Invalid type ''`. What worked for bronze was generating six activities by
  substitution into an exported, known-good Copy job, then proving the round trip
  with `--verify-restore` before running anything. Do that, not blind authoring.
- **`--export` is not lossless.** It omits `checkpointName`, which the runtime
  requires, so an exported definition cannot be edited into a different
  `jobMode`. Build the new mode in the portal.
- **`Package collection` is not a connection setting.** It is
  `connectionProperties` on the Copy activity source. No `-805` has been seen
  across 27.3M rows, so the portal default is evidently `NULLID`.
- **`08_apply_delta.sh` has still not been run on Azure**, deliberately. It is a
  demo-time action; applying it spends the watermark reveal and leaves the data
  mid-state, since rollback is partial by design. Restore with `04_load.sh`, and
  check with `18_assert_pristine.sh` — which, unlike `05_verify.sh`, can tell a
  rolled-back delta from a clean one.
- **Bronze has no audit columns yet**, so silver cannot rely on a run id being
  present on a bronze row. Carry your own batch identifier until item 1 is done.
- **`AML_TXN_ID` is `GENERATED ALWAYS AS IDENTITY`.** It is fine as a merge key
  while Db2 is the only writer, but it is a surrogate with no business meaning:
  reload Db2 and the same business row can take a different id. Do not build a
  silver key on it.
- **Timestamps are labelled UTC in bronze.** The wall-clock values are preserved
  exactly, but a downstream model rendering in another session timezone will
  display something different. Decide this explicitly in silver rather than
  inheriting it.

---

## Things that will bite, if you forget them

These all cost real time once already.

- **`DB2COMM` resets to `TCPIP` on every container start**, silently dropping
  SSL. The keystore, `SSL_SVCENAME` and the published port all survive, so
  everything looks right while nothing listens on 50001. `infra/start.sh`
  re-asserts it — never use `az vm start` on its own.
- **`FABRICRO` does not survive a container rebuild.** It is an OS user in the
  container's `/etc/passwd`, not on the `/database` volume. The GRANTs survive
  and point at a user that no longer exists, and Fabric then reports *"Invalid
  connection credentials"*.
- **An expired OS password produces that identical error.** The image's default
  `useradd` policy set a 90-day expiry; `14_create_fabricro.sh` now disables
  aging, but if you create accounts by hand, don't reintroduce it.
- **A JDBC SQL client needs the JKS truststore, not the `.arm` file.**
  `start_db2.sh` rebuilds `~/.nbki-demo/db2-truststore.jks` (password `nbkidemo`)
  and the import profile on every run, so they cannot drift from the certificate.
- **Do not pin the gateway's `-RegionKey`.** Power BI can only use a gateway in
  the tenant's default region; pinning it to the capacity's region can make the
  gateway unusable.
- **The tenant deletes NSG rules exposing 22/3389 to the internet**, even pinned
  to a `/32`. Irrelevant while locked to the VPN; it returns the moment you
  reopen the public path.

---

## Deviations from the original plan, and why

- **No Azure Key Vault, no Blob staging.** An `ASC DataProtection` policy sets
  `publicNetworkAccess: Disabled` on new storage accounts and vaults within about
  a minute and disables shared-key auth, and re-enabling it is silently reverted.
  A workstation cannot use either. Data went to the VM by `rsync`; secrets are
  0600 files in `~/.nbki-demo`. Key Vault behind a private endpoint is the right
  production answer and is not built.
- **Azure Bastion and the VPN were both added mid-build**, in response to the
  management-port control above. Bastion Developer is free; the VPN gateway is
  **~$153/month and cannot be deallocated** — `infra/stop.sh` warns about this.

## Cost

Two D4s_v5 (~$320/month if left running) plus the VPN gateway (~$153/month,
unpauseable). `./infra/stop.sh` deallocates the VMs; delete `vgw-nbki` if the
environment will be idle for a long stretch, and rebuild it with
`./infra/deploy.sh` — 30–45 minutes, and the old VPN client profile will not work
against a new gateway.

`./infra/teardown.sh` removes everything, and deliberately leaves three things
behind: `~/.nbki-demo` (including the gateway recovery key), the gateway cluster
registration in the Fabric tenant, and the two Db2 connections — the last two must
be removed from *Manage connections and gateways* or they linger as permanently
offline.
