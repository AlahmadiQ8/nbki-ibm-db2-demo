# Dataset selection

Why these two datasets seed the Db2 demo, why the obvious alternatives were rejected, and what
we actually know versus what we assumed.

---

## The requirement

The demo proves **IBM Db2 → Microsoft Fabric**. The data has to make that story credible, which
means it must be:

1. **Genuinely relational** — a medallion architecture on a single flat table is a fake. We need
   foreign keys, so silver has something to conform and gold has something to star-schema.
2. **Licensed for a commercial customer demo** — no NonCommercial clauses, ideally no share-alike.
3. **Not localised to the wrong country** — NBKI is a UK-regulated Kuwaiti subsidiary. Rupee
   amounts and IFSC codes invite exactly the wrong question at exactly the wrong moment.
4. **Large enough to be interesting** — the pain being solved is that manual CSV extraction does
   not scale. Demonstrating that on 50,000 rows undermines the point.
5. **Carrying real timestamps** — a watermark-based incremental load needs a monotonic column with
   sufficient granularity. Date-only columns produce mass ties at the watermark boundary, which is
   both a correctness hazard and an awkward thing to be asked about.

Most public "banking" datasets fail (1) immediately. The overwhelming majority are single-table
ML training files — one wide denormalised table with a label column. Useful for a classifier,
useless for demonstrating a data platform.

---

## Primary: `computingvictor/transactions-fraud-datasets`

<https://www.kaggle.com/datasets/computingvictor/transactions-fraud-datasets>

| | |
|---|---|
| **Licence** | **Apache-2.0** — the cleanest found anywhere in this search |
| Size | ~1.4 GB |
| Locale | United States, 2009–2019 |
| Provenance | Built by **CaixaBank Tech** for their 2024 AI hackathon; descended from IBM's synthetic transaction generator |
| Community signal | ~370 votes, ~54,000 downloads |

### Why it wins

**It is actually relational.** A real `users → cards → transactions` foreign-key chain with roughly
13 million transaction rows, plus two reference files. That is a medallion architecture's worth of
structure, not a flat file.

**The licence is boring, which is the highest praise a licence can receive.** Apache-2.0 carries no
NonCommercial restriction and no share-alike obligation. Nothing about putting it in front of a bank
requires a legal conversation.

**Two independent hyperscalers already use it as a database demo corpus.** Microsoft uses it in the
`microsoft/databricks-mlops-workshop` repository, and Google uses it in
`GoogleCloudPlatform/training-data-analyst` for an AlloyDB *"AI agents with databases"* course. That
second one matters more than it looks: it is direct evidence the dataset loads cleanly into a
relational engine and behaves sensibly under SQL, which is precisely what we are about to ask Db2
to do. If it works for AlloyDB it will work for Db2.

**It carries the columns a credible gold layer needs** — `mcc` (merchant category), `credit_score`,
`total_debt`, `credit_limit`, `yearly_income`. That supports genuine banking analytics: spend
analysis by category, credit exposure, customer segmentation. Not a toy.

### Files and columns

Column *names* below are verified from the Microsoft workshop README. Column *formats* are **not**
verified — see "What we assumed" at the end of this document.

| File | Contents |
|---|---|
| `users_data.csv` | `id`, `current_age`, `yearly_income`, `total_debt`, `credit_score`, `num_credit_cards` |
| `cards_data.csv` | `id`, `client_id`, `card_brand`, `card_type`, `credit_limit`, `num_cards_issued` |
| `transactions_data.csv` | `id`, `client_id`, `card_id`, `amount`, `date`, `mcc`, `use_chip`, `merchant_state` (~13M rows) |
| `mcc_codes.json` | Merchant category code → description. A flat map; becomes a dimension table. |
| `train_fraud_labels.json` | Nested `{"target": {"<txn_id>": "Yes"/"No"}}`. Not a table; must be flattened. |

---

## Secondary: `ealtman2019/ibm-transactions-for-anti-money-laundering-aml`

<https://www.kaggle.com/datasets/ealtman2019/ibm-transactions-for-anti-money-laundering-aml>

| | |
|---|---|
| **Licence** | **CDLA-Sharing-1.0** (Community Data License Agreement) |
| Publisher | **IBM Research** (Erik Altman) |
| Paper | NeurIPS 2023 — <https://arxiv.org/abs/2306.16424> |
| Size | ~41.6 GB across all six variants; we download one |

A single wide table of 11 columns. Its job is **volume**, nothing else — which is exactly why
including it is cheap. The loader is thin because the schema is trivial.

### Why it earns its place

**No country localisation at all.** It models a synthetic virtual world with no real geography, so
the "why is this Indian?" problem cannot arise. Compare this to every domestic retail banking
dataset, which is inescapably *somewhere*.

**It fits an international bank.** Multi-currency, multi-bank, with payment formats spanning ACH,
cheque, wire, credit card and bitcoin. NBKI is a cross-border institution; domestic retail card
spend is not their shape. This is.

**It has a true `Timestamp` column**, which removes the watermark mass-tie problem for free rather
than requiring us to manufacture one.

**Volume is a configuration value, not a rebuild.** Six pre-sized variants:

| Variant | Transactions | Accounts | Span |
|---|---|---|---|
| `HI-Small` / `LI-Small` | 5M / 7M | 515K / 705K | 10 days |
| `HI-Medium` / `LI-Medium` | 32M / 31M | ~2.07M | 16 days |
| `HI-Large` / `LI-Large` | 180M / 176M | ~2.1M | 97 days |

*(HI = higher illicit ratio, LI = lower.)*

**Default is `HI-Small`.** `Medium` is a flag flip when you want the throughput story. **Not
`Large`** — Db2 Community Edition is capped at 4 cores and 16 GB, and 180 million rows is not a
sensible thing to ask of it.

**AML is board-relevant** for a UK-regulated subsidiary of a Kuwaiti bank. Financial crime
monitoring is a live regulatory obligation, not a hypothetical analytics use case.

And there is some pleasant symmetry in IBM's own published dataset running on IBM Db2.

### Columns

Verified from the `Hobao000/GNN` repository:

```
Timestamp, From Bank, Account, To Bank, Account.1,
Amount Received, Receiving Currency, Amount Paid, Payment Currency,
Payment Format, Is Laundering
```

Two things to handle: the column literally named **`Account.1`** (renamed to `ACCOUNT_TO`), and
spaces in every column name.

### Known defect

Kaggle discussion #427517 reports transactions existing *after* the stated date range, all of
which are flagged as laundering. Worth knowing before someone at NBKI finds it. It does not affect
the integration story — the demo is about moving data, not about the labels being perfect — but do
not build a fraud-detection narrative on those rows.

---

## Rejected, and why

| Dataset | Why not |
|---|---|
| **`vivekmali1436` "BankCorp"** | Indian localisation (₹ INR, IFSC codes, Kochi/Bhopal/Maharashtra); CC BY-SA share-alike; `DATE` columns only, so mass watermark ties; balances do not reconcile (no balance on transactions, static `accounts.balance`, free-text `txn_type`); companion GitHub repo has no licence file at all |
| **Berka (Czech, PKDD'99)** | Tiny, and from 1993–98. Its one advantage was a proper relational schema, which the primary dataset now supplies at far greater scale |
| **`shivamb/bank-customer-segmentation`** | Indian |
| **BankSim** | **CC BY-NC-SA — NonCommercial.** Unusable for a commercial customer demo, full stop |
| **PaySim** | CC BY-SA share-alike, and a single flat table |
| **`demodatauk`** | 0 MB teaser for a paid product |
| **SDV (Synthetic Data Vault)** | **BSL 1.1 — not open source.** Also learns distributions, so balances would not reconcile |
| **IBM TabFormer** | Repository contains git-lfs pointer files, not data |
| **`nethajisubash/ibmi-banking-simulation`** | Six toy tables. The "Equation" label is the author's aspiration, not a real Equation schema |

### On Finastra Equation itself

Equation's physical file and field layouts are **not public**. There is no published data
dictionary and no DDS layouts in the open.

⚠️ **A web search during research hallucinated `CUSMAS` and `ACCMAS` as Equation file names.**
Neither is verifiable from any primary source. Do not let either appear in a customer deck.

This is precisely why the demo scope was refocused onto proving the **Db2 integration pattern**
rather than Equation fidelity. We cannot credibly replicate a schema we have no access to, and
attempting it in front of the customer's own Equation specialists would be the worst possible
place to be caught guessing.

---

## Licensing position

- **We redistribute nothing.** `data/` is gitignored. `scripts/00_download.sh` fetches each dataset
  from Kaggle so every user receives it under the licence Kaggle serves it with.
- **Attribution is retained** in this document and in the repository README.
- Apache-2.0 (primary) imposes no practical restriction on demo use. CDLA-Sharing-1.0 (secondary)
  is a sharing-style licence whose obligations attach to *redistribution of the data*, which we do
  not do.

⚠️ **A caveat worth stating plainly.** A Kaggle uploader declaring a licence does not establish
that they had the authority to grant it. For an internal Microsoft demo this is a normal and
accepted risk. If any of this data were ever to end up in a customer deliverable, a deployed
artefact, or a public asset, get it reviewed properly first.

*(An earlier revision of this analysis claimed that regenerating synthetic data "strips" the
original licence. That claim was withdrawn as legally unsafe.)*

---

## What we assumed, and how the repository handles it

Column **names** are verified from third-party repositories. Column **formats** are not — the
Kaggle file-listing API requires authentication and could not be inspected during planning.

Rather than write DDL from remembered column lists and discover the truth at row four million,
`scripts/01_profile.py` runs **first** and reports what is actually in the files. The DDL is
written from its output.

Traps it is specifically looking for:

- Currency amounts stored as `$`-prefixed strings (`"$123.45"`, `"-$12.00"`, `"($12.00)"`) — these
  will not cast, and must be cleaned before Db2 sees them
- `date` is a **Db2 reserved word** → renamed to `TXN_TS`
- AML's column literally named **`Account.1`** → renamed to `ACCOUNT_TO`
- `train_fraud_labels.json` is a nested map, not a table
- `mcc_codes.json` is a flat code→description map
- Card `expires` / `acct_open_date` likely `MM/YYYY` — no day component, so `DATE` would invent one
- Encoding, BOM, CRLF line endings, embedded commas and NUL bytes, each of which breaks Db2 `LOAD`
  in its own distinct way
