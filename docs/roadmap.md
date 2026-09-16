# Roadmap — what this session deliberately did not build

This session's scope was narrow on purpose: **build the dataset that seeds Db2,
plus the CSV drop-in fallback**. That is done and proven.

Everything below is the backlog for follow-up sessions, recorded here so the
research does not have to be re-derived. Where something is a known trap, it is
written down as a trap — the point of this file is that the next session does
not lose a day to something this one already found.

---

## Phase 1 — Stand up Db2 somewhere Fabric can reach it

**Done.** See `docs/runbook-phase1.md` for how to operate what was built, and
`infra/` for the Bicep and the lifecycle scripts.

Local validation used a Docker container on a Mac. That was the right call for
proving the data pipeline, but Fabric cannot reach `localhost`.

- [x] Provision an Azure VM. **Standard_D4s_v5 (4 vCPU / 16 GiB)** matches the
      Db2 Community Edition entitlement, so a larger VM buys nothing.
- [x] Install Db2 **11.5.9.0**. Do not take the latest. See "Version pinning".
      Done as the `icr.io/db2_community/db2:11.5.9.0` container on Ubuntu 22.04,
      x86_64 — the `DB2_MODE=docker` path this repo already proves, without the
      Rosetta emulation that made local start-up slow.
- [x] Open port 50000 to the gateway subnet only. Not to the internet.
      **Done better than specified:** cleartext 50000 is published on the host's
      loopback only and is not reachable from anywhere. A TLS listener on 50001
      is the only exposed port, scoped by NSG to the operator's `/32` and to the
      gateway NIC via an application security group.
- [x] `./scripts/05_verify.sh` must pass 23/23 on the VM before anything else.

### What running it on a real VM actually broke

Three of these were latent bugs in code that had passed every check on the Mac.
All are fixed; they are recorded because each one presents as something else.

| Symptom | Cause |
|---|---|
| `db2_up.sh` dies with "unexpected container state" | Docker 29 prints an **empty line to stdout** *and* exits non-zero when inspecting a missing container, so `docker inspect ... \|\| echo absent` yields `"\nabsent"`. Older Docker printed nothing, which hid it |
| `db2_up.sh` waits the full 900s against a database that came up in four minutes | `db2_prep_stage` ran *after* the readiness loop, but the readiness probe ships its SQL in with `docker cp` into that very directory. On a genuinely fresh container it does not exist, so every probe fails. Only ever reproduces on a brand-new container — the demo machine, not the developer's |
| `rsync: unrecognized option --info=progress2` | macOS ships rsync 2.6.9; `--info` arrived in 3.1. Same family as the BSD/GNU `seq` divergence already recorded in the README |
| TLS listener silently gone after a deallocate/start, with every setting still correct | The Db2 CE image's entrypoint sets **`DB2COMM=TCPIP`** on every container start, dropping SSL. The keystore, `SSL_SVCENAME` and `SSL_SVR_LABEL` persist on the `/database` volume and the port stays published, so the configuration looks untouched while nothing listens on 50001. Only reproduces on a restart — i.e. on the morning of the demo, not during the build |

### The subscription fought back

This tenant is governed, and two controls changed the design rather than merely
inconveniencing it. Both are worth knowing before planning any Azure work here.

**Storage and Key Vault are forced private.** An `ASC DataProtection` policy
assignment sets `publicNetworkAccess: Disabled` on every new storage account and
key vault within about a minute of creation, and sets
`allowSharedKeyAccess: false`. An attempt to re-enable public access is accepted
and silently reverted. The failure surfaces as `AuthorizationFailure` on the data
plane, which reads exactly like a missing RBAC role and is not — the role
assignment was correct throughout. Consequences: the planned Blob staging hop for
the 1.7 GB of CSVs is impossible from a workstation, so data goes straight to the
VM over `rsync`; and secrets live in `~/.nbki-demo` at 0600 rather than in Key
Vault. Key Vault behind a private endpoint is the right production answer.

**Internet-facing management ports are deleted automatically.** An automated
control removes any NSG rule exposing 22 or 3389 to the internet, even pinned to
a single `/32`. Both rules vanished within about 45 minutes of the first
deployment; the Db2 TLS rule on 50001 was left alone. Two answers, and the second
is the real one:

- **Azure Bastion, Developer SKU** — free, no subnet, no public IP — for anything
  interactive. Its Developer SKU cannot carry native-client tunnelling, so a bulk
  `rsync` still needs a real SSH rule, which must be expected to disappear.
- **A point-to-site VPN gateway.** With the workstation holding an address inside
  the VNet, no internet-sourced inbound rule is needed at all, so Db2 comes off
  the public internet entirely and both problems disappear at the root. The Basic
  SKU cannot do it — SSTP only, which is Windows-only — so the floor for a Mac is
  **VpnGw1AZ** at roughly $153/month, and a VPN gateway **cannot be deallocated**.
  Entra ID authentication needs no app registration and no admin consent when you
  use the Microsoft-registered client app ID
  `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`; the guidance telling you otherwise
  applies to the older, manually-registered audience values.

NSGs are stateful, so an in-flight transfer survives a rule's removal; only new
connections are refused.


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

Confirmed against the connector matrix: Dataflow Gen2, Copy activity, Lookup and
Copy job are *all* source-only and *all* say **On-premises**. A VNet data gateway
cannot be used. `docs/feasibility.md` drew one; that was wrong and has been
corrected.

- [x] Gateway VM in the same VNet (or peered).
- [x] Install the on-premises data gateway (standard mode, not personal).
- [ ] Register it to the Fabric tenant. **Requires one interactive sign-in** —
      see "Registration cannot be automated".
- [ ] Create the Db2 connection in Fabric and bind it to the gateway.

### Registration cannot be automated, and the install nearly cannot either

The obvious automation path looks viable and is not. Two separate walls:

1. **`Add-DataGatewayCluster` is documented "This command must be run with a user
   based credential."** `Connect-DataGatewayServiceAccount` happily accepts
   `-ApplicationId`/`-ClientSecret`, which makes the whole thing look
   automatable, but the cmdlet that actually creates the cluster rejects that
   identity. No Entra app registration, managed identity or SYSTEM context gets
   past it. Budget one RDP session.

2. **`Install-DataGateway -AcceptConditions` is not an unattended install
   either.** It fails with *"Login first with Login-DataGatewayServiceAccount"* —
   the cmdlet needs an authenticated session merely to fetch and run the
   installer. The way round it is to skip the module and run the vendor installer
   directly:

   ```powershell
   Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?LinkId=2116849' -OutFile $exe
   Start-Process $exe -ArgumentList '-q','-norestart','ACCEPTEULA=yes' -Wait
   ```

   That *is* genuinely silent, and `scripts/12_gateway_install.ps1` uses it. The
   whole install, including PowerShell 7 and the `DataGateway` module, now runs
   unattended through `az vm run-command`.

   Related: `Install-PackageProvider -Name NuGet` is Windows PowerShell 5.1
   advice and fails under PowerShell 7 with *"No match was found for the
   specified search criteria for the provider 'NuGet'"*. PowerShellGet 2.x
   already has what it needs.

### Do not pin the gateway's region

The instinct is to set `-RegionKey` to wherever the Fabric capacity lives. Do
not. Microsoft documents: *"changing the gateway region will restrict the regions
in which you can use the gateway. For Power BI, it can only be used in the
default tenant region."* Pinning it to match the capacity can make the gateway
**unusable** rather than faster.

Omit `-RegionKey` and the tenant default is used, which is correct. Note also
that `Get-DataGatewayRegion` is tenant-specific and must be run *after*
`Connect-DataGatewayServiceAccount`, not before.

### TLS and least privilege are not optional here

`docs/feasibility.md` specified TLS and a dedicated read-only account. Because
this build keeps a publicly reachable Db2 port for SQL-client convenience, those
two stopped being nice-to-have:

- Db2 listens for TLS on **50001** with a self-signed certificate carrying both
  the private and public IPs as SANs. Cleartext 50000 is bound to the container
  host's loopback and is never published.
- Fabric connects as **`FABRICRO`** (`CONNECT` + `SELECTIN` on schema `NBKI`,
  plus `EXECUTE` on the `NULLID` packages), never as the instance owner.
- The self-signed certificate must be imported into `LocalMachine\Root` on the
  gateway VM, or "Use Encrypted Connection" fails validation with a transport
  error that never mentions certificates.

**`FABRICRO` does not survive a container rebuild.** It is an OS user in the
container's `/etc/passwd`, which is an image layer, not the `/database` volume.
`db2_up.sh --recreate` silently removes it while leaving the GRANTs pointing at a
user that no longer exists, and Fabric starts failing authentication for no
visible reason. `infra/start.sh` checks for this.


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
- ~~Two Microsoft doc pages **conflict** on whether Copy job supports
  watermark-based incremental for Db2.~~ **Resolved.** The connector capability
  matrix settles it: Copy job for Db2 lists **"Full load"** only, with no
  incremental option. Incremental has to be a pipeline driving the
  `ROW CHANGE TIMESTAMP` watermark this repo already proves. Do not promise a
  Copy job will do it.

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

Everything in the original list here is **done** and was left stale for a while,
which is its own lesson: the real Kaggle data was downloaded, profiled (four
assumptions corrected), the DDL regenerated, and the CSV drop and delta rebuilt
and reconciled against real data. `HI-Small` was chosen for AML. See the README.

What is actually left is in `docs/session-handoff.md`, which is the current-state
snapshot — live resource IDs, network posture, and the single remaining task.

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
