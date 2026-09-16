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

Phase 1 and Phase 2 of the roadmap are **done**. Db2 runs on Azure with the real
27.3M-row dataset, a SQL client reaches it over TLS as a least-privileged
account, the on-premises data gateway is registered and Online, and a Fabric
connection is bound to it and tests green.

**One task remains** — see "The one thing left" below.

### Proven, by running it

| Check | Result |
|---|---|
| `05_verify.sh` on the VM | **23/23**, control totals tie exactly |
| `09_reconcile.sh` on the VM | **21/21** |
| `04_load.sh` | 27,307,478 rows, **0 rejected** |
| `15_client_test.py` over TLS as `FABRICRO` | **7/7**, six counts exact, DELETE refused `SQL0551N` |
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
| `asg-gateway` | ASG on the gateway NIC; the Db2 rule targets this, not the subnet CIDR |

**Fabric** — workspace `nbki-db2-demo`, on the F8 capacity `momof8sweden` (Sweden Central, Active):

| Item | ID |
|---|---|
| Workspace | `5c84bcc5-f497-4eac-b59b-5c2a36bec619` |
| Lakehouse `lh_bronze` | `56ba34ce-c8c8-467e-a1a9-8952b7b03dba` |
| SQL endpoint (same lakehouse) | `640253d8-8ea7-4683-b294-01bdd8188162` |
| Gateway `nbki-db2-gw` | `b35258fb-ff47-4221-8749-b551885e4ce1` |
| Connection `nbki-db2-onprem` | `f7169c24-7911-4efe-8855-cbb8f33691a7` → `10.20.1.4:50001;NBKI`, Basic, **Encrypted** |

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
| Gateway NIC (via `asg-gateway`) | `vm-db2` | 50001 (TLS) |
| Bastion (`VirtualNetwork`) | both | 22 / 3389 — break-glass |
| anything else | anything | denied at priority 4000 |

**To work with this environment you must connect the Azure VPN Client first.**
Profile: `~/.nbki-demo/azurevpnconfig.xml` (regenerate with
`./infra/vpn_client_profile.sh`). Without it, only Bastion works.

Reopen the public path with a plain `./infra/deploy.sh`; re-lock with
`./infra/deploy.sh --lock-to-vpn`.

---

## The one thing left

**Prove ingestion with a Copy activity:** `NBKI.CUSTOMERS` → `lh_bronze.customers`,
asserting 2,000 rows. A Lookup would only prove auth and package binding; a Copy
proves the path the demo is actually about.

**It has to be built in the portal.** Four routes to automating it were tried and
each hit a real wall — all documented in `docs/runbook-phase1.md`:

1. Hand-authoring the pipeline JSON: three attempts, three different errors. The
   Db2 source schema is not documented well enough to author blind.
2. Exporting a known-good reference pipeline: the only one available sits on an
   inactive West US 3 capacity.
3. Creating the connection via API: on-premises credentials must be RSA-encrypted
   with the gateway member's public key.
4. Repointing an existing connection by script: `connectionDetails` is not
   updatable.

Do this:

```
Workspace nbki-db2-demo → New → Data pipeline → "pl_bronze_customers"
  → Copy data assistant
  → Source: connection nbki-db2-onprem, table NBKI.CUSTOMERS
  → Destination: Lakehouse lh_bronze, table customers
  → Save and Run
```

Then capture it into the repo so it stops living only in a workspace:

```bash
./scripts/16_fabric_pipeline.sh --export pl_bronze_customers
git add fabric/pl_bronze_customers.json
```

### The open question it settles

A hand-authored Copy activity sent **cleartext DRDA at the TLS-only port** and
Db2 logged `DIA3604E … GSK_ERROR_BAD_MESSAGE`. The client reported it as
`Have not received expected codepoint: EUSRIDNWPWD SQLCODE=-1040`, which looks
like an authentication failure and is not one.

The *connection test* reaches Db2 over TLS fine, so the gateway is capable of it.
Two candidate causes remain, and the assistant-built pipeline distinguishes them:

- **It succeeds** → the hand-authored JSON was simply wrong. Commit the export.
- **It fails the same way** → the pipeline Copy path does not negotiate TLS the
  way the Power Query path does. Mitigation is already built and inert:

  ```bash
  ./infra/deploy.sh --lock-to-vpn --gateway-cleartext
  NBKI_DB2_CLEARTEXT_BIND=0.0.0.0 ./infra/start_db2.sh --recreate
  ./scripts/14_create_fabricro.sh          # OS user does not survive a recreate
  ```

  That allows cleartext 50000 **from the gateway NIC only**, inside the VNet,
  never the internet. The workstation keeps TLS on 50001. You then recreate the
  Fabric connection pointing at `10.20.1.4:50000`.

Either way, correct the runbook to say which it was.

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
- **`Package collection` is not a connection setting.** The Advanced section in
  the connection dialog does not have it. It is `connectionProperties` on the
  Copy activity source, and must be a **dictionary**.
- **Do not pin the gateway's `-RegionKey`.** Power BI can only use a gateway in
  the tenant's default region; pinning it to the capacity's region can make the
  gateway unusable.
- **The tenant deletes NSG rules exposing 22/3389 to the internet**, even pinned
  to a `/32`. Irrelevant while locked to the VPN; it returns the moment you
  reopen the public path.
- **`08_apply_delta.sh` has not been run on Azure.** It is a demo-time action —
  applying it spends the watermark reveal and leaves the data mid-state, since
  rollback is partial by design. To restore afterwards, re-run `04_load.sh`.

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

`./infra/teardown.sh` removes everything, and deliberately leaves two things
behind: `~/.nbki-demo` (including the gateway recovery key) and the gateway
cluster registration in the Fabric tenant, which must be removed from *Manage
connections and gateways* or it lingers as permanently offline.
