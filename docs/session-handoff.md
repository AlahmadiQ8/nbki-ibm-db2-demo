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

**Phase 1 and Phase 2 are complete, end to end.** Db2 runs on Azure with the real
27.3M-row dataset, a SQL client reaches it over TLS as a least-privileged account,
the on-premises data gateway is registered and Online, two Fabric connections are
bound to it, and **a Copy job has successfully landed Db2 data into a Fabric
Lakehouse**. The ingestion path the whole demo rests on is proven.

**Next is Phase 3** — the medallion build. See `docs/roadmap.md`.

### Proven, by running it

| Check | Result |
|---|---|
| `05_verify.sh` on the VM | **23/23**, control totals tie exactly |
| `09_reconcile.sh` on the VM | **21/21** |
| `04_load.sh` | 27,307,478 rows, **0 rejected** |
| `15_client_test.py` over TLS as `FABRICRO` | **7/7**, six counts exact, DELETE refused `SQL0551N` |
| VS Code Db2 extension over JDBC + TLS | connects, returns all six counts |
| **Copy job → `lh_bronze.CUSTOMERS`** | **2,000 rows**, confirmed from the Delta log *and* the Parquet footer |
| Copy job mode | **CDC / `SnapshotPlusIncremental`** on `LAST_UPDATED_TS` — snapshot leg proven, incremental leg not yet |
| Public exposure | **none** — 22 and 50001 both refuse; VPN + Bastion only |
| Two full `stop.sh` → `start.sh` cycles | green each time |

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
| Lakehouse `lh_bronze` | `56ba34ce-c8c8-467e-a1a9-8952b7b03dba` — contains `CUSTOMERS` (2,000 rows) |
| SQL endpoint (same lakehouse) | `640253d8-8ea7-4683-b294-01bdd8188162` |
| Gateway `nbki-db2-gw` | `b35258fb-ff47-4221-8749-b551885e4ce1` |

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

## The finding that matters most

**The pipeline Copy path does not negotiate TLS; the Power Query path does.**

Against the same Db2 server: the connection test, Dataflow Gen2 and the Navigator
all complete a TLS handshake on 50001, but a Copy job sent cleartext DRDA at that
port and Db2 rejected it with `GSK_ERROR_BAD_MESSAGE`. The client reported it as
`EUSRIDNWPWD SQLCODE=-1040`, which reads like an authentication failure and is
not one.

Hence the two connections, and hence the cleartext rule scoped to the gateway NIC
alone — not the internet, not even the VPN subnet. Gateway → Fabric is TLS
regardless.

**This is worth saying out loud in the demo.** For a bank, "Db2 → gateway is
unencrypted on the pipeline path, confined to one NIC inside a private VNet" is a
real architectural point, and it is the argument for co-locating the gateway with
the database in production.

---

## Next: Phase 3, the medallion build

`fabric/copyjob_bronze_customers.json` is the exported definition of the working
Copy job — the reference for how a Db2 source and a Lakehouse sink are wired.
`scripts/16_fabric_pipeline.sh` lists, exports, creates and runs pipelines.

Bear in mind when building it out:

- **Authoring pipeline JSON by hand is unreliable.** Three hand-written
  definitions each failed differently — cleartext-at-TLS-port, an
  `InvalidCastException` because `connectionProperties` must be a dictionary, and
  `Invalid type ''`. Build in the portal, then export.
- **`Package collection` is not a connection setting.** It is
  `connectionProperties` on the Copy activity source. No `-805` has been seen so
  far, so the portal default is evidently `NULLID`.
- **Copy job for Db2 is not full-load only** — the capability matrix says
  "Full load", but the UI offers **CDC mode** and it works. The committed job is
  `readMethod: SnapshotPlusIncremental` on `LAST_UPDATED_TS`, `Upsert` keyed on
  `CUSTOMER_ID`. **The snapshot leg is proven; the incremental leg is not.**
  Proving it is the single highest-value next experiment: run
  `08_apply_delta.sh`, re-run the Copy job, and show it pick up 250 inserts and
  50 in-place updates — that is the watermark story the whole demo is built on.
- **`08_apply_delta.sh` has not been run on Azure.** It is a demo-time action —
  applying it spends the watermark reveal and leaves the data mid-state, since
  rollback is partial by design. To restore afterwards, re-run `04_load.sh`.

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
