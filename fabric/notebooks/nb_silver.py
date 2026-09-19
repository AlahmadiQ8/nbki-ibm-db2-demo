# Fabric notebook source — nb_silver
#
# Cell markers: `# MD ---` (markdown) and `# CELL ---` (code).
# Built into .ipynb and uploaded by scripts/20_deploy_silver.py.
# Edit THIS file, never the notebook in the portal — the portal copy is generated.

# MD ---
# # Silver — conform, validate, quarantine
#
# Reads `lh_bronze` (landed by Copy job, unmodified) and writes `lh_silver`.
#
# Three things this layer does, and one it deliberately does not:
#
# | | |
# |---|---|
# | **Conform** | types, casing, the state/country split, dates, the PAN |
# | **Validate** | eight documented data-quality rules |
# | **Quarantine** | failures are *moved*, never dropped — with the rule that caught them |
# | **Not** aggregate | no business logic, no dimensional modelling. That is gold's job |
#
# **Every table here satisfies: `clean + quarantine = bronze`**, on both row count
# and control total. `scripts/21_verify_silver.py` proves it.

# CELL --- parameters
# Parameters. Tagged as the parameters cell so a pipeline can override them.
workspace = "nbki-db2-demo"
bronze_lh = "lh_bronze"
silver_lh = "lh_silver"
batch_id = ""  # blank = generate from the clock

# CELL ---
from pyspark.sql import functions as F, Window
from datetime import datetime, timezone

# V-Order is OFF by default in new Fabric workspaces. Direct Lake is the
# downstream consumer here, so turn it on deliberately rather than inheriting a
# default that reverses guidance from 18 months ago.
spark.conf.set("spark.sql.parquet.vorder.default", "true")

if not batch_id:
    batch_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

ROOT = f"abfss://{workspace}@onelake.dfs.fabric.microsoft.com"
BRONZE = f"{ROOT}/{bronze_lh}.Lakehouse/Tables"
SILVER = f"{ROOT}/{silver_lh}.Lakehouse/Tables"

def read_bronze(table):
    return spark.read.format("delta").load(f"{BRONZE}/{table}")

def write_silver(df, name):
    (df.write.format("delta").mode("overwrite")
       .option("overwriteSchema", "true")
       .save(f"{SILVER}/{name}"))
    return name

# Provenance. Bronze audit columns were never applied (the Copy job JSON shape is
# unpublished and a guessed one was rejected), so silver stamps its own. Every
# row can answer "which run produced me, and when".
def stamped(df):
    return (df.withColumn("_silver_batch_id", F.lit(batch_id))
              .withColumn("_silver_loaded_at", F.current_timestamp()))

audit = []   # one row per table, written out at the end
print(f"batch_id = {batch_id}")

# MD ---
# ## The data-quality rules
#
# Eight rules. Against the **governed Db2 source only two of them fire** —
# and that is the point, not a shortfall.
#
# | Rule | Expected on Db2 bronze |
# |---|---|
# | `zero_amount` | **10,639** |
# | `channel_location_mismatch` | **5,788** |
# | `implausible_amount` | 0 — the largest transaction in the whole set is 6,820.20 |
# | `future_dated` | 0 — data ends 2019-10-31 |
# | `duplicate_business_key` | 0 — `TRANSACTION_ID` is a Db2 primary key |
# | `state_whitespace` | 0 |
# | `state_case_mismatch` | 0 |
# | `negative_non_refund` | **cannot be implemented — see below** |
#
# The six that find nothing are the argument: **a governed source cannot produce
# these defects.** Run the identical rules over the hand-made CSV extract
# (`slv_csv_transactions`, built by the Dataflow) and they light up.
#
# ### `channel_location_mismatch` was found by profiling, not planted
#
# `MERCHANT_STATE IS NULL` turns out to be *exactly* `MERCHANT_CITY = 'ONLINE'`
# — 1,563,700 rows, coincident to the row. Those are online transactions, not
# missing data, and treating that 11.75% as "unknown" would have been wrong.
#
# But 5,788 of them are recorded as **`Swipe` or `Chip`** — a card-present
# transaction at a card-not-present merchant. That is implausible on its face and
# is the shape of a card-testing signal. Worth showing to a bank.
#
# ### `negative_non_refund` is reported, not enforced
#
# 660,049 rows (5.0%) carry a negative amount and only 9,543 of them have any
# error flag. They are refunds and reversals. **The source carries no refund
# indicator**, so the rule cannot be implemented without quarantining ~650,000
# legitimate rows and destroying the control total.
#
# That absence is itself a finding worth giving the customer: *the extract cannot
# distinguish a refund from a reversal.* We report the count and enforce nothing.

# CELL ---
ERROR_TYPES = [
    ("Insufficient Balance", "err_insufficient_balance"),
    ("Bad PIN",              "err_bad_pin"),
    ("Technical Glitch",     "err_technical_glitch"),
    ("Bad Card Number",      "err_bad_card_number"),
    ("Bad Expiration",       "err_bad_expiration"),
    ("Bad CVV",              "err_bad_cvv"),
    ("Bad Zipcode",          "err_bad_zipcode"),
]

def violations(rules):
    """A rule map -> an array column naming every rule a row breaks.

    Rules are evaluated against the RAW bronze values, before conforming. A
    quarantine decision has to be made on what actually arrived, otherwise
    trimming a value silently repairs the evidence that it was wrong.
    """
    return F.array_compact(F.array(*[
        F.when(cond, F.lit(name)) for name, cond in rules.items()
    ]))

def split_and_write(df, clean_name, quarantine_name, amount_col=None):
    """One scan, two sinks: clean and quarantine, with a per-table audit row."""
    df = df.cache()
    total = df.count()

    clean = df.filter(F.size("violations") == 0).drop("violations")
    dirty = df.filter(F.size("violations") > 0)

    n_clean = clean.count()
    n_dirty = dirty.count()
    assert n_clean + n_dirty == total, "clean + quarantine must equal the input"

    write_silver(stamped(clean), clean_name)
    write_silver(stamped(dirty), quarantine_name)

    row = {"table": clean_name, "rows_in": total,
           "rows_clean": n_clean, "rows_quarantined": n_dirty}
    if amount_col:
        agg = df.select(
            F.sum(amount_col).alias("t"),
            F.sum(F.when(F.size("violations") == 0, F.col(amount_col))).alias("c"),
        ).first()
        row["total_amount"] = agg["t"]
        row["clean_amount"] = agg["c"]
    audit.append(row)

    print(f"  {clean_name:26s} in={total:>10,}  clean={n_clean:>10,}  "
          f"quarantined={n_dirty:>8,}")
    if n_dirty:
        (dirty.select(F.explode("violations").alias("rule"))
              .groupBy("rule").count().orderBy(F.desc("count")).show(20, False))
    df.unpersist()

# MD ---
# ## Customers and cards
#
# Two governance decisions are made here and should be said out loud:
#
# * **The PAN never reaches silver.** `CARD_NUMBER` is reduced to its last four
#   digits at the first point of transformation.
# * **`CVV` is not carried forward at all.** It is not masked, it is dropped —
#   there is no analytical use for it, so it should not exist downstream.
#
# `EXPIRES_YM` and `ACCT_OPEN_YM` are `MM/YYYY` with no day component. They become
# the first of the month, which is a stated convention rather than an invented
# day.

# CELL ---
cust = read_bronze("CUSTOMERS")
slv_customers = cust.select(
    F.col("CUSTOMER_ID").cast("int").alias("customer_id"),
    F.col("CURRENT_AGE").cast("int").alias("current_age"),
    F.col("RETIREMENT_AGE").cast("int").alias("retirement_age"),
    F.col("BIRTH_YEAR").cast("int").alias("birth_year"),
    F.col("BIRTH_MONTH").cast("int").alias("birth_month"),
    F.initcap(F.trim(F.col("GENDER"))).alias("gender"),
    F.trim(F.col("ADDRESS")).alias("address"),
    F.col("LATITUDE").cast("decimal(9,4)").alias("latitude"),
    F.col("LONGITUDE").cast("decimal(9,4)").alias("longitude"),
    F.col("PER_CAPITA_INCOME").cast("decimal(15,2)").alias("per_capita_income"),
    F.col("YEARLY_INCOME").cast("decimal(15,2)").alias("yearly_income"),
    F.col("TOTAL_DEBT").cast("decimal(15,2)").alias("total_debt"),
    F.col("CREDIT_SCORE").cast("int").alias("credit_score"),
    F.col("NUM_CREDIT_CARDS").cast("int").alias("num_credit_cards"),
)
write_silver(stamped(slv_customers), "slv_customers")
n = slv_customers.count()
audit.append({"table": "slv_customers", "rows_in": n, "rows_clean": n,
              "rows_quarantined": 0})
print(f"  slv_customers              {n:,}")

# CELL ---
def yn(col):
    u = F.upper(F.trim(col))
    return (F.when(u.isin("YES", "Y", "TRUE", "1"), F.lit(True))
             .when(u.isin("NO", "N", "FALSE", "0"), F.lit(False)))

def ym_to_date(col):
    # 'MM/YYYY' -> first of that month. No day is invented silently; the
    # convention is stated here and carried into the column name.
    return F.to_date(F.concat(F.lit("01/"), F.trim(col)), "dd/MM/yyyy")

cards = read_bronze("CARDS")
slv_cards = cards.select(
    F.col("CARD_ID").cast("int").alias("card_id"),
    F.col("CUSTOMER_ID").cast("int").alias("customer_id"),
    F.trim(F.col("CARD_BRAND")).alias("card_brand"),
    F.trim(F.col("CARD_TYPE")).alias("card_type"),
    # The PAN stops here. Last four only, for identification in a report.
    F.concat(F.lit("****"), F.substring(F.col("CARD_NUMBER"), -4, 4)).alias("card_last4"),
    # CVV is deliberately absent.
    ym_to_date(F.col("EXPIRES_YM")).alias("expires_month"),
    ym_to_date(F.col("ACCT_OPEN_YM")).alias("acct_open_month"),
    yn(F.col("HAS_CHIP")).alias("has_chip"),
    yn(F.col("CARD_ON_DARK_WEB")).alias("card_on_dark_web"),
    F.col("NUM_CARDS_ISSUED").cast("int").alias("num_cards_issued"),
    F.col("CREDIT_LIMIT").cast("decimal(15,2)").alias("credit_limit"),
    F.col("YEAR_PIN_LAST_CHANGED").cast("int").alias("year_pin_last_changed"),
)
write_silver(stamped(slv_cards), "slv_cards")
n = slv_cards.count()
audit.append({"table": "slv_cards", "rows_in": n, "rows_clean": n,
              "rows_quarantined": 0})
print(f"  slv_cards                  {n:,}")

# MD ---
# ## Transactions — the one that matters
#
# 13,305,915 rows. Conformance work worth narrating:
#
# * **`MERCHANT_STATE` is not a state.** 52 two-letter US codes mixed with 147
#   country names in one column. It splits into `merchant_state` (US only) and
#   `merchant_country`.
# * **`MERCHANT_ID` is not a merchant key.** 22% of merchant IDs carry more than
#   one city — one has 2,579. Location is a property of the transaction, so it
#   stays on the row and becomes its own dimension in gold. There is no
#   merchant dimension, because there is no merchant attribute to put in it.
# * **`ERROR_FLAGS` is a comma-separated multi-value** — 7 atomic errors in 22
#   combinations, 98.41% null. It explodes into seven booleans so a report can
#   filter on one error without a bridge table.
# * **The timestamp is left exactly as it arrived.** Db2's naive value was
#   *labelled* `+00:00` by the Copy job; that label is an artefact, not a fact.
#   We do not convert it, we document it, and gold joins on an integer
#   `YYYYMMDD` date key so the question never reaches a report.
#   It stays Delta `TIMESTAMP` — **never `timestamp_ntz`**, which is invisible to
#   both the SQL analytics endpoint and Direct Lake.

# CELL ---
txn = read_bronze("TRANSACTIONS")

raw_state = F.trim(F.col("MERCHANT_STATE"))
is_online = F.col("MERCHANT_CITY") == "ONLINE"
dup_count = F.count("*").over(Window.partitionBy("TRANSACTION_ID"))

txn_rules = {
    "zero_amount":               F.col("AMOUNT") == 0,
    "implausible_amount":        F.abs(F.col("AMOUNT")) > 1000000,
    "future_dated":              F.col("TXN_TS") > F.current_timestamp(),
    "duplicate_business_key":    dup_count > 1,
    "state_whitespace":          (F.col("MERCHANT_STATE").isNotNull()
                                  & (F.col("MERCHANT_STATE") != raw_state)),
    "state_case_mismatch":       ((F.length(raw_state) == 2)
                                  & (raw_state != F.upper(raw_state))),
    "channel_location_mismatch": (is_online
                                  & (F.col("USE_CHIP") != "Online Transaction")),
}

err = F.coalesce(F.col("ERROR_FLAGS"), F.lit(""))

txn_conformed = txn.select(
    F.col("TRANSACTION_ID").cast("long").alias("transaction_id"),
    # Left exactly as it arrived. See the note above.
    F.col("TXN_TS").alias("txn_ts"),
    F.to_date(F.col("TXN_TS")).alias("txn_date"),
    (F.year("TXN_TS") * 10000 + F.month("TXN_TS") * 100
     + F.dayofmonth("TXN_TS")).cast("int").alias("txn_date_key"),
    (F.hour("TXN_TS") * 100 + F.minute("TXN_TS")).cast("int").alias("txn_time_key"),
    F.col("CUSTOMER_ID").cast("int").alias("customer_id"),
    F.col("CARD_ID").cast("int").alias("card_id"),
    F.col("AMOUNT").cast("decimal(15,2)").alias("amount"),
    F.when(F.col("USE_CHIP") == "Swipe Transaction", "Swipe")
     .when(F.col("USE_CHIP") == "Chip Transaction", "Chip")
     .when(F.col("USE_CHIP") == "Online Transaction", "Online")
     .otherwise("Unknown").alias("channel"),
    F.col("MERCHANT_ID").cast("int").alias("merchant_id"),
    is_online.alias("is_online"),
    F.when(is_online, F.lit("Online"))
     .otherwise(F.trim(F.col("MERCHANT_CITY"))).alias("merchant_city"),
    # US state codes only. A country name is not a state and must not sit here.
    F.when(is_online | (F.length(raw_state) != 2), F.lit(None))
     .otherwise(F.upper(raw_state)).alias("merchant_state"),
    F.when(is_online, F.lit("Online"))
     .when(F.length(raw_state) == 2, F.lit("United States"))
     .when(raw_state.isNotNull(), raw_state)
     .otherwise(F.lit("Unknown")).alias("merchant_country"),
    F.when(is_online, F.lit(None))
     .otherwise(F.trim(F.col("MERCHANT_ZIP"))).alias("merchant_zip"),
    F.trim(F.col("MCC_CODE")).alias("mcc_code"),
    F.col("ERROR_FLAGS").alias("error_flags"),
    F.col("ERROR_FLAGS").isNotNull().alias("has_error"),
    *[err.contains(label).alias(name) for label, name in ERROR_TYPES],
    violations(txn_rules).alias("violations"),
)

split_and_write(txn_conformed, "slv_transactions",
                "slv_transactions_quarantine", amount_col="amount")

# CELL ---
# Reported, not enforced. There is no refund indicator in the source, so this
# cannot become a rule without quarantining ~650,000 legitimate rows.
neg = txn.filter(F.col("AMOUNT") < 0)
print(f"negative amounts (refunds/reversals, NOT quarantined): "
      f"{neg.count():,}  of which carrying an error flag: "
      f"{neg.filter(F.col('ERROR_FLAGS').isNotNull()).count():,}")

# MD ---
# ## Fraud labels — partial coverage is by design
#
# 8,901,631 `No` + 13,332 `Yes` = 8,914,963 labels against 13,305,915
# transactions. **4.4 million transactions are unlabelled**, and that is a
# property of the dataset, not a load failure.
#
# Gold must therefore **left** join these and give the unlabelled rows a real
# `Unlabelled` member. An inner join would silently drop a third of the fact.

# CELL ---
fraud = read_bronze("FRAUD_LABELS")
slv_fraud = fraud.select(
    F.col("TRANSACTION_ID").cast("long").alias("transaction_id"),
    F.when(F.upper(F.trim(F.col("IS_FRAUD"))) == "YES", F.lit(True))
     .when(F.upper(F.trim(F.col("IS_FRAUD"))) == "NO", F.lit(False))
     .alias("is_fraud"),
)
write_silver(stamped(slv_fraud), "slv_fraud_labels")
n = slv_fraud.count()
audit.append({"table": "slv_fraud_labels", "rows_in": n, "rows_clean": n,
              "rows_quarantined": 0})
print(f"  slv_fraud_labels           {n:,}")

# CELL ---
mcc_b = read_bronze("MCC_CODES")
slv_mcc_src = mcc_b.select(
    F.trim(F.col("MCC_CODE")).alias("mcc_code"),
    F.trim(F.col("MCC_DESCRIPTION")).alias("mcc_description"),
)
# Written under a distinct name: the Dataflow Gen2 owns `slv_mcc_codes`, and no
# table in this lakehouse has two writers. Spark Runtime 2.0 writes Delta
# Reader 3/Writer 7; Dataflow Gen2 writes Reader 1/Writer 2. Microsoft never
# states that co-writing breaks — nor that it is safe. So we never find out.
write_silver(stamped(slv_mcc_src), "slv_mcc_codes_spark")
print(f"  slv_mcc_codes_spark        {slv_mcc_src.count():,}")

# MD ---
# ## AML transfers — the second star's fact
#
# 5M rows, `DECIMAL(23,6)`. The scale matters: 148,151 rows carry more than two
# decimal places, so `DECIMAL(19,2)` would have rounded the crypto rows to zero
# with no error and no rejected row. It survives as `decimal(23,6)` and the
# control total ties to six places.

# CELL ---
aml = read_bronze("AML_TRANSACTIONS")

aml_rules = {
    "zero_amount":     F.col("AMOUNT_PAID") == 0,
    "negative_amount": (F.col("AMOUNT_PAID") < 0) | (F.col("AMOUNT_RECEIVED") < 0),
    "future_dated":    F.col("TXN_TS") > F.current_timestamp(),
}

aml_conformed = aml.select(
    F.col("AML_TXN_ID").cast("long").alias("aml_txn_id"),
    F.col("TXN_TS").alias("txn_ts"),
    F.to_date(F.col("TXN_TS")).alias("txn_date"),
    (F.year("TXN_TS") * 10000 + F.month("TXN_TS") * 100
     + F.dayofmonth("TXN_TS")).cast("int").alias("txn_date_key"),
    F.trim(F.col("FROM_BANK")).alias("from_bank"),
    F.trim(F.col("ACCOUNT_FROM")).alias("account_from"),
    F.trim(F.col("TO_BANK")).alias("to_bank"),
    F.trim(F.col("ACCOUNT_TO")).alias("account_to"),
    F.col("AMOUNT_PAID").cast("decimal(23,6)").alias("amount_paid"),
    F.trim(F.col("PAYMENT_CURRENCY")).alias("payment_currency"),
    F.col("AMOUNT_RECEIVED").cast("decimal(23,6)").alias("amount_received"),
    F.trim(F.col("RECEIVING_CURRENCY")).alias("receiving_currency"),
    F.trim(F.col("PAYMENT_FORMAT")).alias("payment_format"),
    (F.col("IS_LAUNDERING") == 1).alias("is_laundering"),
    (F.trim(F.col("PAYMENT_CURRENCY"))
     != F.trim(F.col("RECEIVING_CURRENCY"))).alias("is_cross_currency"),
    violations(aml_rules).alias("violations"),
)

split_and_write(aml_conformed, "slv_aml_transfers",
                "slv_aml_quarantine", amount_col="amount_paid")

# MD ---
# ## Load audit
#
# One row per table per run: what came in, what stayed clean, what was
# quarantined, and the control total on both sides.
#
# This is the table that answers *"who produced this number, when, and from
# what?"* — the question today's process cannot answer at all.

# CELL ---
from pyspark.sql.types import (StructType, StructField, StringType,
                               LongType, DecimalType)

schema = StructType([
    StructField("table", StringType()),
    StructField("rows_in", LongType()),
    StructField("rows_clean", LongType()),
    StructField("rows_quarantined", LongType()),
    StructField("total_amount", DecimalType(38, 6)),
    StructField("clean_amount", DecimalType(38, 6)),
])
rows = [(a["table"], int(a["rows_in"]), int(a["rows_clean"]),
         int(a["rows_quarantined"]),
         a.get("total_amount"), a.get("clean_amount")) for a in audit]

audit_df = stamped(spark.createDataFrame(rows, schema))
write_silver(audit_df, "slv_load_audit")
audit_df.show(20, False)

print(f"\nsilver batch {batch_id} complete")
