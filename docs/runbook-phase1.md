# Runbook — Phase 1: Db2 on Azure, gateway, and the Fabric connection

Everything needed to bring this environment up, demo from it, and take it down.
Written to be followed by someone who did not build it.

Companion documents: `docs/roadmap.md` (what comes next),
`docs/feasibility.md` (why any of this is shaped the way it is).

---

## What exists

Resource group **`rg-nbki-db2-demo`**, Sweden Central.

| Resource | What it is |
|---|---|
| `vgw-nbki` | Point-to-site VPN gateway, VpnGw1AZ, OpenVPN + Entra ID. Public IP `74.158.4.142`, client pool `172.16.201.0/24` |
| `vm-db2` | Ubuntu 22.04, Standard_D4s_v5, 128 GB Premium SSD. Runs Db2 11.5.9.0 Community Edition in Docker |
| `vm-gateway` | Windows Server 2022 Datacenter (Desktop Experience), Standard_D4s_v5. Runs the on-premises data gateway |
| `vnet-nbki` | 10.20.0.0/16 — `snet-db2` 10.20.1.0/24, `snet-gateway` 10.20.2.0/24 |
| `bst-nbki` | Azure Bastion, **Developer SKU (free)**. The interactive access path |
| `asg-gateway` | Application security group on the gateway NIC; the Db2 NSG rule targets this, not the subnet |
| `nsg-db2`, `nsg-gateway` | See "Network posture" |

Secrets and connection details live on the operator workstation in
**`~/.nbki-demo`** (mode 0700, files 0600), created by `infra/deploy.sh`:

| File | What |
|---|---|
| `env.sh` | IPs, admin username, key path. `source` it before running anything. `NBKI_DB2_HOST` is the address the scripts actually use — it follows the network posture, so it is the private IP once locked to the VPN |
| `id_ed25519`, `.pub` | SSH keypair for `vm-db2` |
| `db2inst1.pw` | Db2 instance owner. Also the TLS keystore password |
| `fabricro.pw` | The read-only account Fabric connects as |
| `windows-admin.pw` | `vm-gateway` administrator |
| `gateway-recovery.key` | **Keep this.** Without it the gateway cannot be restored or clustered, and Microsoft holds no copy |
| `db2cert.arm` | The Db2 TLS certificate, for the gateway trust store and SQL clients |

---

## Bringing it up from nothing

```bash
./infra/deploy.sh                    # resource group, VNet, NSGs, both VMs, Bastion
./infra/bootstrap_db2.sh             # Docker, operator account, /opt/nbki
./scripts/11_sync_to_vm.sh           # repo + 1.7 GB of prepared CSVs  (the long one)
./infra/start_db2.sh                 # Db2 container + TLS listener on 50001
ssh ... 'cd /opt/nbki && ./scripts/04_load.sh'
ssh ... 'cd /opt/nbki && ./scripts/05_verify.sh'     # must be 23/23
./scripts/14_create_fabricro.sh      # the read-only principal Fabric uses
./infra/trust_cert_on_gateway.sh     # gateway trusts the Db2 certificate
# then: RDP via Bastion, run scripts/13_gateway_register.ps1
```

`infra/deploy.sh` is idempotent and safe to re-run; it will not rotate a password
that a running database is already using.

## Day to day

```bash
./infra/stop.sh     # deallocate both VMs. ~$320/month if you forget
./infra/start.sh    # start VMs AND Db2 AND check FABRICRO AND check the gateway
```

**Do not use `az vm start` on its own.** Two separate things break, and both
present as "Fabric cannot reach the source":

1. The Db2 container has no Docker restart policy, so the VM comes back with
   Docker running and `db2demo` stopped.
2. Even once the container is started, the image's entrypoint resets
   **`DB2COMM=TCPIP`**, dropping SSL. The keystore, `SSL_SVCENAME` and
   `SSL_SVR_LABEL` all persist on the `/database` volume and the port is still
   published — so every setting you would think to check looks correct while
   nothing is listening on 50001 at all.

`infra/start.sh` handles both, and now fails loudly if the gateway still cannot
reach Db2 afterwards rather than printing a cheerful summary. Verified across two
full deallocate/start cycles: 23/23, 21/21, client test 7/7.

---

## Network posture

| From | To | Port | Rule |
|---|---|---|---|
| VPN client | `vm-db2` | 50001 (TLS) | `nsg-db2/allow-db2-tls-vpn`, from `172.16.201.0/24` — **the current path** |
| Operator workstation | `vm-db2` | 50001 (TLS) | `nsg-db2/allow-db2-tls-operator`, one `/32`. **Removed by `--lock-to-vpn`** |
| Gateway NIC | `vm-db2` | 50001 (TLS) | `nsg-db2/allow-db2-tls-gateway`, scoped to `asg-gateway` |
| Bastion | both VMs | 22 / 3389 | `allow-ssh-bastion`, `allow-rdp-bastion`, source `VirtualNetwork` |
| anything else | anything | anything | `deny-all-inbound` at priority 4000 |

Two details that are easy to get wrong:

**The deny rule at 4000 is load-bearing.** Azure's default `AllowVNetInBound`
sits at 65000, so listing three allow rules does *not* mean everything else is
denied — without an explicit deny the two subnets can reach each other on every
port. `allow-azure-lb` at 3900 re-permits platform probes above it.

**Cleartext Db2 is not exposed at all.** The container publishes 50000 on
`127.0.0.1` only; there is nothing to firewall. Only the TLS listener on 50001
is reachable from anywhere. Verify with:

```bash
nc -z -w5 $NBKI_DB2_PUBLIC 50001   # succeeds
nc -z -w5 $NBKI_DB2_PUBLIC 50000   # must fail
```

### Interactive access goes through Bastion

**This tenant runs an automated control that deletes any NSG rule exposing port
22 or 3389 to the internet**, even pinned to a single `/32`. Both were removed
within about 45 minutes of the first deployment. The Db2 TLS rule on 50001 was
untouched, so this is specifically about management ports.

**The durable answer is the VPN** (below), which removes the need for any
internet-sourced rule at all. Until that is connected, or as break-glass:

- Use **Bastion** (portal → the VM → Connect → Bastion) for anything
  interactive. Nothing deletes those rules, because they are sourced from
  `VirtualNetwork`.
- The `allow-ssh-operator` rule exists only for the initial bulk `rsync`, because
  Bastion's Developer SKU does not support native-client tunnelling. Expect it to
  disappear. Re-create it with:

  ```bash
  az network nsg rule create -g rg-nbki-db2-demo --nsg-name nsg-db2 \
    -n allow-ssh-operator --priority 100 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$(curl -s https://api.ipify.org)/32" \
    --destination-port-ranges 22
  ```

  `./infra/deploy.sh` also restores it, since the rule is declared in the Bicep —
  and it re-reads your current public address at the same time, which matters
  because that address moves. Observed cadence: the control appears to sweep
  periodically rather than continuously, so a freshly re-created rule lasts long
  enough to do a piece of work.

  `infra/start.sh` calls `ensure_ssh_access` (from
  `infra/_ensure_ssh_access.sh`) before it tries to connect, so the recurring
  path repairs itself. That helper handles both failure modes — a deleted rule
  and a rule pinned to an address you no longer have — because they present
  identically as a timeout with nothing in any log.

- Removing an NSG rule does **not** kill established connections — NSGs are
  stateful. An in-flight `rsync` survives; only new connections are refused.

---

## The VPN, and taking Db2 off the internet

A point-to-site VPN gateway (`vgw-nbki`) puts this workstation inside the VNet.
That is what allows every internet-sourced inbound rule to be deleted — which is
the posture `docs/feasibility.md` specified in the first place, and which also
removes both recurring operational problems at the root: the tenant control that
deletes management-port rules, and a home IP address that moves.

### Connecting

```bash
./infra/vpn_client_profile.sh        # writes ~/.nbki-demo/azurevpnconfig.xml
```

Then, once, in the **Azure VPN Client** on macOS: **Import** that file,
**Connect**, sign in with your Entra account. There is no certificate to
generate and nothing to renew.

Connected, you hold an address in `172.16.201.0/24` and reach the VNet directly:

| Target | Address |
|---|---|
| Db2 (TLS, as `FABRICRO`) | `10.20.1.4:50001` |
| `vm-db2` SSH | `10.20.1.4:22` |
| `vm-gateway` RDP | `10.20.2.4:3389` |

Verify before changing anything:

```bash
NBKI_DB2_HOST=10.20.1.4 .venv/bin/python scripts/15_client_test.py
```

### Then lock it down

```bash
./infra/deploy.sh --lock-to-vpn
```

This removes `allow-ssh-operator`, `allow-db2-tls-operator` and
`allow-rdp-operator`. Afterwards nothing is reachable from the internet;
access is VPN, or Bastion as break-glass. Reverse it with a plain
`./infra/deploy.sh`.

It also rewrites `~/.nbki-demo/env.sh` so `NBKI_DB2_HOST` points at the private
address. Every script here reaches the VM through that variable, so they keep
working unchanged — `source ~/.nbki-demo/env.sh` after switching posture and
nothing else needs touching. `infra/_ensure_ssh_access.sh` also notices the
locked state and refuses to punch a public hole; if the VPN is not connected it
says so rather than "repairing" a rule the template will close again.

**Do not run it before you have connected successfully at least once.** The
Bastion rules survive either way, so you are not truly locked out — but
recovering through a browser console is a bad way to spend a morning.

**Confirmed working in this environment:** with the VPN connected, public 22 and
50001 both refuse connections, while `10.20.1.4:50001` (Db2, 7/7),
`10.20.1.4:22` (SSH) and `10.20.2.4:3389` (RDP) all answer.

### Facts worth knowing before relying on it

- **The Basic SKU cannot do this.** It supports only SSTP, which is Windows-only.
  A Mac needs IKEv2 or OpenVPN, so the floor is **VpnGw1AZ**.
- **Cost is about $153/month plus ~$7/month per connection**, and a VPN gateway
  **cannot be deallocated**. `infra/stop.sh` saves the VM compute; this keeps
  billing until the gateway is deleted. Set `deployVpnGateway=false` to build
  without it.
- **Provisioning takes 30–45 minutes**, and so does recreating it.
- **No app registration, no admin consent.** The gateway uses the
  Microsoft-registered Azure VPN Client app ID
  `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`. Guidance telling you to register an
  enterprise application and grant consent applies to the older,
  manually-registered audience values, not this one.
- **The issuer needs its trailing slash** (`https://sts.windows.net/{tenant}/`)
  and the tenant URL must *not* have one. Getting this backwards produces a
  connection failure that does not mention the cause.
- **The VMs keep their public IPs** even after `--lock-to-vpn`, with no inbound
  allow rules. That is for **outbound** access: default outbound for new VMs is
  retired, and an instance-level public IP is what gives the VM a route to the
  internet for package installs and the gateway's Service Bus traffic. Removing
  them properly means adding a NAT gateway.

---

## Connecting a SQL client

Db2 presents a **self-signed** certificate with the private and public IPs as
subject-alternative names. Two artefacts matter, both in `~/.nbki-demo` and both
refreshed by `./infra/start_db2.sh`:

| File | For |
|---|---|
| `db2cert.arm` | PEM. The gateway trust store, and CLI-driver clients (`ibm_db`) |
| `db2-truststore.jks` | JKS, password `nbkidemo`. **JDBC clients** |

### IBM Db2 Developer Extension for VS Code

The extension talks **JDBC** (it ships `db2jcc4.jar` and a small Java service), and
its connection form takes `sslTrustStorePath` + `sslTrustStorePassword`. It has no
field for a PEM file, and it **throws unless both are supplied** whenever the
certificate type is anything other than a standard CA. Pointing it at
`db2cert.arm` cannot work — that is the trap.

Connect the VPN first, then **Db2: Add connection**:

| Field | Value |
|---|---|
| Connection name | `NBKI Db2 (Azure, TLS)` |
| Host | `10.20.1.4` |
| Port | `50001` |
| Database | `NBKI` |
| Username | `fabricro` |
| Password | from `~/.nbki-demo/fabricro.pw` |
| Enable SSL | **on** |
| Certificate type | self-signed / custom — **not** Standard CA |
| Truststore path | `~/.nbki-demo/db2-truststore.jks` |
| Truststore password | `nbkidemo` |

Alternatively **Db2: Manage Connections → Import**, and give it
`~/.nbki-demo/db2-connection-profile.json`, which `start_db2.sh` keeps in step
with the current certificate.

Verified against this environment with the extension's own JCC driver (4.36.6):
connects to `DB2/LINUXX8664 SQL110590` and returns all six counts.

### Any other JDBC client (DBeaver, DataGrip, …)

| Setting | Value |
|---|---|
| Driver | `com.ibm.db2.jcc.DB2Driver` |
| URL | `jdbc:db2://10.20.1.4:50001/NBKI` |
| Property | `sslConnection=true` |
| Property | `sslTrustStoreLocation=<home>/.nbki-demo/db2-truststore.jks` |
| Property | `sslTrustStorePassword=nbkidemo` |

Use `fabricro`, not `db2inst1`. The instance owner can drop every table in the
database, and there is no reason for a SQL client to hold it.

The six counts that must come back:

```sql
SELECT 'CUSTOMERS', COUNT(*) FROM NBKI.CUSTOMERS          -- 2,000
UNION ALL SELECT 'CARDS', COUNT(*) FROM NBKI.CARDS         -- 6,146
UNION ALL SELECT 'TRANSACTIONS', COUNT(*) FROM NBKI.TRANSACTIONS      -- 13,305,915
UNION ALL SELECT 'FRAUD_LABELS', COUNT(*) FROM NBKI.FRAUD_LABELS      -- 8,914,963
UNION ALL SELECT 'AML_TRANSACTIONS', COUNT(*) FROM NBKI.AML_TRANSACTIONS -- 5,078,345
UNION ALL SELECT 'MCC_CODES', COUNT(*) FROM NBKI.MCC_CODES;
```

## Registering the gateway

Needed once. Cannot be automated: `Add-DataGatewayCluster` is documented *"This
command must be run with a user based credential"*, so no service principal,
managed identity or SYSTEM context can create the cluster.

1. Reach the machine, either way:
   - **On the VPN:** RDP straight to `10.20.2.4` — Microsoft Remote Desktop, username
     `nbkiadmin`, password from `~/.nbki-demo/windows-admin.pw`.
   - **Otherwise:** Portal → `vm-gateway` → **Connect** → **Bastion**, same
     credentials.
2. Open **PowerShell 7 as Administrator** (`pwsh`, not Windows PowerShell).
3. Run the staged launcher — the script and the recovery key are already on the
   machine, so there is nothing to copy or type:

   ```powershell
   & 'C:\nbki\REGISTER-GATEWAY.ps1'
   ```

4. Complete the browser sign-in when prompted.

### Confirming it worked, without the portal

The Fabric REST API answers this directly, and is quicker than hunting through
the portal. Before registration it returns `count: 0`:

```bash
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
curl -fsS -H "Authorization: Bearer $TOKEN" https://api.fabric.microsoft.com/v1/gateways \
  | python3 -c "import json,sys; v=json.load(sys.stdin)['value']; print('count:', len(v)); [print(' -', g['displayName'], g['type']) for g in v]"
```

After registration `nbki-db2-gw` should appear with type `OnPremises`.

If you would rather supply the key yourself, the underlying script is at
`C:\nbki\13_gateway_register.ps1`:

```powershell
.\13_gateway_register.ps1 -RecoveryKey (Read-Host 'Recovery key' -AsSecureString)
```

The binaries, PowerShell 7 and the `DataGateway` module (3000.318.6) are already
installed by `scripts/12_gateway_install.ps1`, so this session is short.

**Do not pass `-RegionKey`.** The instinct is to pin the gateway to the region
the Fabric capacity lives in. Microsoft documents the opposite: *"changing the
gateway region will restrict the regions in which you can use the gateway. For
Power BI, it can only be used in the default tenant region."* Pinning it can make
the gateway unusable. Omitting it selects the tenant default, which is correct.

---

## The Fabric connection

A workspace and a Bronze lakehouse are already provisioned, so there is nothing
to create before wiring the connection:

| Item | Value |
|---|---|
| Workspace | **`nbki-db2-demo`** — `5c84bcc5-f497-4eac-b59b-5c2a36bec619` |
| Capacity | `momof8sweden` (F8, Sweden Central, Active) — `a47c6dd1-1dcd-4e17-9985-769c4faab20c` |
| Lakehouse | **`lh_bronze`** — `56ba34ce-c8c8-467e-a1a9-8952b7b03dba` |

### There are TWO Db2 connections, and both are needed

Do not delete either. The second one looks like an accidental duplicate and is
not — it is what makes Copy work. (Its name cannot be fixed: the
`PATCH /v1/connections/{id}` API returns **HTTP 200 and silently ignores**
`displayName` for on-premises gateway connections.)

| Connection | Endpoint | Encryption | Used by |
|---|---|---|---|
| `nbki-db2-onprem` | `10.20.1.4:50001` | **Encrypted** | Connection test, Dataflow Gen2, Power Query, the Navigator |
| `nbki-db2-onprem-copy` | `10.20.1.4:50000` | **NotEncrypted** | **Copy jobs and pipeline Copy activities** |

Why the split is unavoidable: see "RESOLVED: the pipeline Copy path does not
speak TLS" below.


**Create this in the portal, not the API** — but not for the reason you might
assume from a first look.

Querying `supportedConnectionTypes` with `gatewayType=OnPremises` returns 282
types and **no Db2**, which looks conclusive. It is not: query it with a real
`gatewayId` instead and you get 297 types **including `DB2`**, with creation
method `DB2` and parameters `server` and `database`.

```bash
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://api.fabric.microsoft.com/v1/connections/supportedConnectionTypes?gatewayId=<gatewayId>" \
  | python3 -c "import json,sys; print([t['type'] for t in json.load(sys.stdin)['value'] if 'DB2' in t['type']])"
```

Two things still make the portal the practical route:

1. **On-premises credentials must be RSA-encrypted with the gateway member's own
   public key** and submitted as `credentials.values[].encryptedCredentials`.
   Posting a plaintext `username`/`password` returns the rather opaque
   `InvalidInput: The Values field is required`. The public key is in
   `GET /v1/gateways/{id}/members`, but implementing Power BI's credential
   serialisation correctly is a project in itself.
2. **The server and database cannot be changed afterwards either.**
   `UpdateOnPremisesGatewayConnectionRequest` accepts only `connectivityType`,
   `credentialDetails`, `displayName` and `privacyLevel` — `connectionDetails` is
   not updatable. So a connection cannot be repointed at a different host or port
   by script; it has to be recreated in the portal.

Between them these two rule out scripting the connection at all, which matters
more than it looks: it makes the portal a hard dependency in an otherwise
fully-automated build, and it blocks any experiment that needs a connection on a
different port.

Fabric → **Manage connections and gateways** → **New** → **On-premises**.

| Setting | Value |
|---|---|
| Gateway cluster | `nbki-db2-gw` |
| Connection type | **IBM Db2 database** |
| Server | `10.20.1.4:50001` — the **private** IP; the gateway is inside the VNet |
| Database | `NBKI` |
| Authentication | **Basic** |
| Username | `fabricro` |
| Password | from `~/.nbki-demo/fabricro.pw` |
| Use Encrypted Connection | **on** |


### `Package collection` is NOT a connection setting

This cost an hour, so it is written down plainly. The Advanced section of the
connection dialog has no Package collection field, and that is not a bug or a
missing permission: **for the pipeline path it is a property of the Copy activity
source, not of the connection.** Microsoft documents it under *Additional
connection properties* on the copy activity — "provided as a dictionary of
key-value pairs, for example, Package collection".

In the pipeline JSON it is `connectionProperties`, and it must be a **dictionary**:

```json
"source": {
  "type": "Db2Source",
  "connectionProperties": { "Package Collection": "NULLID" }
}
```

A list — `[{"name": "...", "value": "..."}]` — is accepted by the item API and
then fails at runtime with
`InvalidCastException: Unable to cast ... List<Object> to IDictionary<String,Object>`.

The underlying trap is still real: Power Query defaults `packageCollection` to
`NULLID` while the pipeline linked service defaults it to `{username}`, so a
connection that tests green can still fail in a pipeline with
`SQLSTATE=51002 SQLCODE=-805`, and the error never names the setting. It simply
has to be set in a different place than the connection dialog suggests.

`scripts/14_create_fabricro.sh` separately grants `FABRICRO` EXECUTE on the
`NULLID` packages, which is the server-side half of the same story.

### RESOLVED: the pipeline Copy path does not speak TLS

This was an open question for a while and is now settled by evidence, because it
changes what you can promise a customer about encryption in transit.

**The Power Query path and the Copy path behave differently against the same Db2
server.** The connection test, Dataflow Gen2 and the Navigator all negotiate TLS
on 50001 happily — proven by wrong-password attempts reaching PAM and appearing
in `db2diag.log` as `Password validation for user fabricro failed`, which is only
possible after a completed TLS handshake.

A **Copy job** against that same TLS connection failed, and Db2 logged:

```
DIA3604E  gsk_secure_soc_init failed, return code "410"
GSK_ERROR_BAD_MESSAGE
An incorrectly formatted SSL message was received from the partner
```

— something sent cleartext DRDA at the TLS-only port. The client reports this as
`Have not received expected codepoint: EUSRIDNWPWD SQLCODE=-1040`, which looks
like an authentication failure and is not one. **Do not chase the credentials
when you see that error.**

The working Copy job uses a **second connection on cleartext 50000**
(`connectionEncryption: NotEncrypted`), and it succeeded: 2,000 rows landed in
`lh_bronze.CUSTOMERS`, confirmed independently from the Delta log
(`numRecords: 2000`) and the Parquet footer.

**The mitigation, and why it is acceptable here.** Cleartext 50000 is published
on the container, but the NSG rule `allow-db2-cleartext-gateway` (priority 130)
admits it **only from the `asg-gateway` application security group** — one NIC,
inside the VNet. It is not reachable from the internet, and not even from the VPN
client subnet. The workstation still uses TLS on 50001. Enable it with:

```bash
./infra/deploy.sh --lock-to-vpn --gateway-cleartext
NBKI_DB2_CLEARTEXT_BIND=0.0.0.0 ./infra/start_db2.sh
```

**Say this out loud in the demo if encryption comes up.** For a bank it is a real
finding, not a footnote: Db2 → gateway is unencrypted on the pipeline path, and
the honest answer is that the hop is confined to a single NIC inside a private
VNet. Gateway → Fabric is TLS regardless. In a production design this is the
argument for a gateway co-located with the database.

### What this connector can and cannot do

- **Read only.** Dataflow Gen2, Copy activity, Lookup and Copy job are all
  source-only. Fabric cannot write back to Db2. Do not let an architecture
  diagram imply otherwise.
- **Copy job is NOT full-load only for Db2**, despite what the capability matrix
  says. The UI offers a **CDC mode**, and the job built here uses
  `readMethod: SnapshotPlusIncremental` watermarking on `LAST_UPDATED_TS` with
  `writeBehavior: Upsert`. The snapshot leg is proven (2,000 rows); the
  incremental leg is not yet — run `08_apply_delta.sh`, then re-run the Copy job,
  before claiming it.
- **On-premises gateway always**, even though Db2 is in Azure and publicly
  addressable. A VNet data gateway is not an option for this connector.
- **Power Query Online only uses the Microsoft driver.** The IBM .NET driver
  choice exists only in Power Query Desktop — and that driver does not work with
  IBM i, which is what NBKI actually runs.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| SSH times out, IP unchanged | The tenant control deleted `allow-ssh-operator`. Re-create it, or use Bastion |
| `docker ps` empty after `az vm start` | No restart policy on the container by design. Use `./infra/start.sh` |
| Fabric says the source is unreachable after a stop/start, and every setting looks right | **`DB2COMM` reverted to `TCPIP`.** The Db2 CE image's entrypoint sets it on every container start, silently dropping SSL. The keystore, `SSL_SVCENAME` and `SSL_SVR_LABEL` all survive on the `/database` volume and the port stays published, so nothing looks wrong — but nothing listens on 50001. `./infra/start.sh` re-asserts it; check with `db2set -all \| grep DB2COMM`, which must read `TCPIP,SSL` |
| Fabric auth fails, nothing changed | The container was rebuilt. `FABRICRO` lives in the container's `/etc/passwd`, not the `/database` volume, so it is gone while the GRANTs remain. Re-run `scripts/14_create_fabricro.sh` |
| `Test connection` fails with a TLS error | The gateway does not trust the Db2 certificate. Run `./infra/trust_cert_on_gateway.sh`. Re-run it after any keystore regeneration |
| `SQLCODE=-805`, `SQLSTATE=51002` | `Package collection` is not set to `NULLID` on the connection |
| `db2_up.sh` waits the full 900s | Fixed, but if it recurs: the readiness probe ships SQL via `docker cp` into `/tmp/nbki_load`, so that directory must exist *before* the probe runs |
| "unexpected container state" | Docker 29 prints an empty line and exits non-zero for a missing container. `container_state()` handles it; older Docker hid the bug |
| `az storage`/`az keyvault` fail with `AuthorizationFailure` | Not RBAC. An `ASC DataProtection` policy sets `publicNetworkAccess: Disabled` on new storage accounts and vaults, and disables shared-key auth. A private endpoint is required |
| `rsync: unrecognized option --info=progress2` | macOS ships rsync 2.6.9. Use `--progress` |

---

## Taking it down

```bash
./infra/teardown.sh     # deletes the whole resource group; asks you to type the name
```

Two things it deliberately does not remove:

- **`~/.nbki-demo`** — the SSH key, passwords and the gateway recovery key.
  Delete by hand once you are sure you will not restore the gateway.
- **The gateway cluster registration in the Fabric tenant.** Deleting the VM
  leaves a permanently-offline `nbki-db2-gw` in *Manage connections and
  gateways*. Remove it there, or the next build inherits a confusing list.

---

## Known gaps, honestly

- **Outbound is unrestricted** on both VMs. The gateway needs 443 plus Service
  Bus 5671/5672 and 9350–9354, and the VM agent needs DNS and CRL endpoints;
  restricting that properly is a hardening pass that has not been done. Recorded
  rather than claimed.
- **No Key Vault.** Blocked by the same policy that blocks blob staging. Secrets
  are 0600 files on the operator workstation. Key Vault behind a private endpoint
  is the right answer and is in the roadmap.
- **The Db2 certificate is self-signed** and valid for ten years. Fine for a
  demo; a real deployment uses a CA the client already trusts.
- **Db2 runs `--privileged`** because the Community Edition image requires it to
  set kernel parameters at startup.
