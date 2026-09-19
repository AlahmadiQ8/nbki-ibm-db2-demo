-- Fabric T-SQL notebook source — nb_gold
--
-- Cell markers: `-- MD ---` (markdown) and `-- CELL ---` (T-SQL).
-- Built into .ipynb and uploaded by scripts/22_deploy_gold.py.
-- Edit THIS file, never the notebook in the portal — the portal copy is generated.
--
-- Primary warehouse: wh_gold. Silver is read by three-part name,
-- `lh_silver.dbo.<table>`, which works because both items live in the same
-- workspace and the same region. Cross-region or cross-workspace would not.

-- MD ---
-- # Gold — the dimensional model
--
-- Two stars sharing a conformed `dim_date`, built in T-SQL from `lh_silver`.
--
-- ### Why this is a Warehouse and not a Lakehouse
--
-- **T-SQL cannot write to a Lakehouse** — its SQL analytics endpoint is
-- read-only. So a T-SQL-authored gold layer must be a Warehouse. That is a
-- constraint, not a preference, and it happens to be the better answer anyway:
-- V-Order is **on** by default in a Warehouse and **off** by default in new Spark
-- workspaces, and file compaction is automatic rather than your problem.
--
-- ### Rules this model follows, and why
--
-- | Rule | Reason |
-- |---|---|
-- | Physical tables, never views | A view means permanent DirectQuery fallback on Direct Lake on SQL, and is unsupported outright on Direct Lake on OneLake |
-- | Integer surrogate keys | Every Power BI relationship costs a key-column dictionary load. Integers beat strings |
-- | `-1` Unknown member in every dimension | So an unmatched fact row joins to *something* rather than disappearing from a report |
-- | `PRIMARY KEY`/`FOREIGN KEY` `NOT ENFORCED` | The only form Fabric allows. They are optimiser hints and Power BI relationship detection — **the pipeline enforces correctness, the constraint documents intent** |
-- | All derivation here, none in DAX | Calculated columns and tables are unsupported or preview-only under Direct Lake |
-- | Role-playing dimensions materialised physically | Power BI's recommended fix is a Power Query reference or a DAX calculated table. Direct Lake can do neither, so the copy has to be a real table |
--
-- ### Surrogate keys are deterministic, not `IDENTITY`
--
-- Fabric supports `IDENTITY`, and for an incrementally maintained warehouse it is
-- the right answer. This build uses `ROW_NUMBER()` over the natural key instead,
-- deliberately:
--
-- * `IDENTITY` in Fabric is **`bigint` only, gappy, and explicitly not ordered** —
--   allocation is distributed across compute nodes.
-- * Seeding a `-1` member needs `SET IDENTITY_INSERT` (one table per session)
--   followed by `DBCC CHECKIDENT ... RESEED`. Across a dozen dimensions that is a
--   lot of ceremony for a demo to trip over.
-- * **This build is a full rebuild, and the demo claims re-running it does not
--   move the numbers.** Deterministic keys make that claim true of the keys too.
--
-- Switch to `IDENTITY` the moment dimensions are maintained incrementally rather
-- than rebuilt — and note you cannot `ALTER TABLE ADD` one, so it is a CTAS.
--
-- ### Why every surrogate key is wrapped in `ISNULL(..., -1)`
--
-- `CREATE TABLE AS SELECT` infers column nullability from the expression, and it
-- infers `ROW_NUMBER()` as **nullable** even though it cannot produce a null. A
-- `PRIMARY KEY` on a nullable column is refused outright:
--
--     Cannot define PRIMARY KEY constraint on nullable column in table 'dim_customer'
--
-- `ISNULL(expr, -1)` forces the inferred type to `NOT NULL`. The `-1` is never
-- used. This is the standard T-SQL idiom and it is the alternative to
-- `ALTER TABLE ... ALTER COLUMN`, which is still preview in Fabric.

-- CELL ---
-- Idempotent teardown. Facts first: a FOREIGN KEY, even NOT ENFORCED, still
-- registers a dependency.
DROP TABLE IF EXISTS dbo.fact_card_transaction;
DROP TABLE IF EXISTS dbo.fact_aml_transfer;

DROP TABLE IF EXISTS dbo.dim_customer;
DROP TABLE IF EXISTS dbo.dim_card;
DROP TABLE IF EXISTS dbo.dim_location;
DROP TABLE IF EXISTS dbo.dim_mcc;
DROP TABLE IF EXISTS dbo.dim_channel;
DROP TABLE IF EXISTS dbo.dim_transaction_error;
DROP TABLE IF EXISTS dbo.dim_fraud_status;
DROP TABLE IF EXISTS dbo.dim_account_from;
DROP TABLE IF EXISTS dbo.dim_account_to;
DROP TABLE IF EXISTS dbo.dim_currency;
DROP TABLE IF EXISTS dbo.dim_payment_format;
DROP TABLE IF EXISTS dbo.dim_card_expiry_date;
DROP TABLE IF EXISTS dbo.dim_card_open_date;
DROP TABLE IF EXISTS dbo.dim_date;
DROP TABLE IF EXISTS dbo.dim_time;
DROP TABLE IF EXISTS dbo.gold_validation;
DROP TABLE IF EXISTS dbo.probe_log;   -- leftover from connectivity probing

-- MD ---
-- ## `dim_date` — the conformed dimension
--
-- The surrogate key is `INT` in `YYYYMMDD` form. This is the one place Microsoft
-- explicitly sanctions a surrogate key that means something and is human
-- readable.
--
-- It also quietly dissolves the Db2 timezone problem. Db2's naive timestamps were
-- *labelled* `+00:00` by the Copy job; silver left the wall-clock value untouched
-- and derived an integer date key from it. The fact joins on that integer, so no
-- report ever renders a timestamp through a session timezone and gets a different
-- day.
--
-- The grain deliberately stops at the day. Microsoft's guidance is that a date
-- dimension must not extend to time of day — if you need time analysis you have a
-- **separate** time dimension, which is why `dim_time` exists below.

-- CELL ---
CREATE TABLE dbo.dim_date (
    date_key            INT          NOT NULL,
    [date]              DATE         NOT NULL,
    day_of_month        INT          NOT NULL,
    day_name            VARCHAR(9)   NOT NULL,
    day_of_week         INT          NOT NULL,
    is_weekend          BIT          NOT NULL,
    month_number        INT          NOT NULL,
    month_name          VARCHAR(12)  NOT NULL,
    month_year          VARCHAR(8)   NOT NULL,
    quarter_number      INT          NOT NULL,
    quarter_name        VARCHAR(7)   NOT NULL,
    [year]              INT          NOT NULL,
    year_month_key      INT          NOT NULL
);

-- 2009-01-01 .. 2030-12-31. Wider than either fact needs, so the model does not
-- have to be rebuilt when the data moves.
-- Sequential CTEs rather than a recursive one: Fabric Warehouse does not support
-- recursive queries.
WITH
  t0(n) AS (SELECT 1 UNION ALL SELECT 1),
  t1(n) AS (SELECT 1 FROM t0 a CROSS JOIN t0 b),
  t2(n) AS (SELECT 1 FROM t1 a CROSS JOIN t1 b),
  t3(n) AS (SELECT 1 FROM t2 a CROSS JOIN t2 b),
  t4(n) AS (SELECT 1 FROM t3 a CROSS JOIN t3 b),
  nums  AS (SELECT TOP (8035)
                   ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
            FROM t4),
  dates AS (SELECT DATEADD(day, i, CAST('2009-01-01' AS DATE)) AS d FROM nums)
INSERT INTO dbo.dim_date
SELECT
    YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d),
    d,
    DAY(d),
    DATENAME(weekday, d),
    DATEPART(weekday, d),
    CASE WHEN DATEPART(weekday, d) IN (1, 7) THEN 1 ELSE 0 END,
    MONTH(d),
    DATENAME(month, d),
    CONCAT(LEFT(DATENAME(month, d), 3), ' ', YEAR(d)),
    DATEPART(quarter, d),
    CONCAT('Q', DATEPART(quarter, d), ' ', YEAR(d)),
    YEAR(d),
    YEAR(d) * 100 + MONTH(d)
FROM dates;

ALTER TABLE dbo.dim_date
    ADD CONSTRAINT pk_dim_date PRIMARY KEY NONCLUSTERED (date_key) NOT ENFORCED;

-- CELL ---
-- Minute grain: 1,440 rows. Silver derives time_key as HH*100+MM.
CREATE TABLE dbo.dim_time (
    time_key      INT          NOT NULL,
    time_label    VARCHAR(5)   NOT NULL,
    hour_24       INT          NOT NULL,
    minute_of_hour INT         NOT NULL,
    day_part      VARCHAR(9)   NOT NULL
);

WITH
  t0(n) AS (SELECT 1 UNION ALL SELECT 1),
  t1(n) AS (SELECT 1 FROM t0 a CROSS JOIN t0 b),
  t2(n) AS (SELECT 1 FROM t1 a CROSS JOIN t1 b),
  t3(n) AS (SELECT 1 FROM t2 a CROSS JOIN t2 b),
  nums  AS (SELECT TOP (1440)
                   ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
            FROM t3 a CROSS JOIN t3 b)
INSERT INTO dbo.dim_time
SELECT
    (i / 60) * 100 + (i % 60),
    CONCAT(RIGHT(CONCAT('0', i / 60), 2), ':', RIGHT(CONCAT('0', i % 60), 2)),
    i / 60,
    i % 60,
    CASE
        WHEN i / 60 <  6 THEN 'Night'
        WHEN i / 60 < 12 THEN 'Morning'
        WHEN i / 60 < 18 THEN 'Afternoon'
        ELSE 'Evening'
    END
FROM nums;

ALTER TABLE dbo.dim_time
    ADD CONSTRAINT pk_dim_time PRIMARY KEY NONCLUSTERED (time_key) NOT ENFORCED;

-- MD ---
-- ## Role-playing date dimensions
--
-- A card has an expiry month and an account-open month. Both are dates, and both
-- want the full date dimension's attributes.
--
-- Power BI's own guidance recommends a separate dimension table per role, created
-- "as a referencing query using Power Query, or a calculated table using DAX".
-- **Direct Lake can do neither** — its tables do not pass through Power Query, and
-- calculated tables are unsupported on Direct Lake on SQL and preview-only on
-- Direct Lake on OneLake.
--
-- So the copy has to be a physical table. Storage is irrelevant at 8,036 rows, and
-- each role then gets a single **active** relationship instead of an inactive one
-- that every measure has to unlock with `USERELATIONSHIP`.

-- CELL ---
CREATE TABLE dbo.dim_card_expiry_date AS
SELECT
    date_key       AS expiry_date_key,
    [date]         AS expiry_date,
    month_name     AS expiry_month_name,
    month_year     AS expiry_month_year,
    quarter_name   AS expiry_quarter,
    [year]         AS expiry_year,
    year_month_key AS expiry_year_month_key
FROM dbo.dim_date;

CREATE TABLE dbo.dim_card_open_date AS
SELECT
    date_key       AS open_date_key,
    [date]         AS open_date,
    month_name     AS open_month_name,
    month_year     AS open_month_year,
    quarter_name   AS open_quarter,
    [year]         AS open_year,
    year_month_key AS open_year_month_key
FROM dbo.dim_date;

ALTER TABLE dbo.dim_card_expiry_date ADD CONSTRAINT pk_dim_card_expiry_date
    PRIMARY KEY NONCLUSTERED (expiry_date_key) NOT ENFORCED;
ALTER TABLE dbo.dim_card_open_date ADD CONSTRAINT pk_dim_card_open_date
    PRIMARY KEY NONCLUSTERED (open_date_key) NOT ENFORCED;

-- MD ---
-- ## Customer and card dimensions
--
-- Banding happens **here**, not in silver and not in DAX. Silver keeps atomic
-- conformed values; grouping them into bands is a modelling decision, and Direct
-- Lake cannot compute a calculated column to do it later.
--
-- Note what is *not* in `dim_card`: the PAN and the CVV. Silver reduced the card
-- number to its last four digits and dropped the CVV entirely, so neither can
-- reach a report even by accident.

-- CELL ---
CREATE TABLE dbo.dim_customer AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY customer_id) AS BIGINT), -1) AS customer_sk,
    customer_id,
    current_age,
    retirement_age,
    birth_year,
    birth_month,
    gender,
    address,
    latitude,
    longitude,
    per_capita_income,
    yearly_income,
    total_debt,
    credit_score,
    num_credit_cards,
    CASE
        WHEN credit_score IS NULL  THEN 'Unknown'
        WHEN credit_score <  580   THEN '1 Poor (<580)'
        WHEN credit_score <  670   THEN '2 Fair (580-669)'
        WHEN credit_score <  740   THEN '3 Good (670-739)'
        WHEN credit_score <  800   THEN '4 Very good (740-799)'
        ELSE                            '5 Exceptional (800+)'
    END AS credit_score_band,
    CASE
        WHEN yearly_income IS NULL   THEN 'Unknown'
        WHEN yearly_income <  25000  THEN '1 Under 25k'
        WHEN yearly_income <  50000  THEN '2 25k-50k'
        WHEN yearly_income <  75000  THEN '3 50k-75k'
        WHEN yearly_income < 100000  THEN '4 75k-100k'
        ELSE                              '5 100k+'
    END AS income_band,
    CASE
        WHEN current_age IS NULL THEN 'Unknown'
        WHEN current_age <  25   THEN '1 Under 25'
        WHEN current_age <  35   THEN '2 25-34'
        WHEN current_age <  45   THEN '3 35-44'
        WHEN current_age <  55   THEN '4 45-54'
        WHEN current_age <  65   THEN '5 55-64'
        ELSE                          '6 65+'
    END AS age_band,
    CASE WHEN yearly_income > 0
         THEN CAST(total_debt / yearly_income AS DECIMAL(9, 4)) END AS debt_to_income
FROM lh_silver.dbo.slv_customers;

INSERT INTO dbo.dim_customer (customer_sk, customer_id, gender, address,
                              credit_score_band, income_band, age_band)
VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown');

ALTER TABLE dbo.dim_customer
    ADD CONSTRAINT pk_dim_customer PRIMARY KEY NONCLUSTERED (customer_sk) NOT ENFORCED;

-- CELL ---
CREATE TABLE dbo.dim_card AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY card_id) AS BIGINT), -1) AS card_sk,
    card_id,
    customer_id,
    card_brand,
    card_type,
    card_last4,
    has_chip,
    card_on_dark_web,
    num_cards_issued,
    credit_limit,
    year_pin_last_changed,
    expires_month,
    acct_open_month,
    -- Integer keys into the two role-playing date dimensions.
    CASE WHEN expires_month IS NOT NULL
         THEN YEAR(expires_month) * 10000 + MONTH(expires_month) * 100
              + DAY(expires_month) ELSE -1 END AS expiry_date_key,
    CASE WHEN acct_open_month IS NOT NULL
         THEN YEAR(acct_open_month) * 10000 + MONTH(acct_open_month) * 100
              + DAY(acct_open_month) ELSE -1 END AS open_date_key,
    CASE
        WHEN credit_limit IS NULL  THEN 'Unknown'
        WHEN credit_limit <  5000  THEN '1 Under 5k'
        WHEN credit_limit < 10000  THEN '2 5k-10k'
        WHEN credit_limit < 25000  THEN '3 10k-25k'
        ELSE                            '4 25k+'
    END AS credit_limit_band
FROM lh_silver.dbo.slv_cards;

INSERT INTO dbo.dim_card (card_sk, card_id, customer_id, card_brand, card_type,
                          card_last4, credit_limit_band, expiry_date_key,
                          open_date_key)
VALUES (-1, -1, -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', -1, -1);

ALTER TABLE dbo.dim_card
    ADD CONSTRAINT pk_dim_card PRIMARY KEY NONCLUSTERED (card_sk) NOT ENFORCED;

-- MD ---
-- ## `dim_location` — the dimension that replaced `dim_merchant`
--
-- The original design had a merchant dimension carrying city, state and ZIP.
-- **Profiling killed it.** `MERCHANT_ID` has 74,831 distinct values, but 16,164 of
-- them (22%) appear with more than one city — one with **2,579 cities** and
-- another with **4,337 ZIPs**. Location is not functionally dependent on the
-- merchant, so a merchant dimension would have had to pick one arbitrarily and
-- would have been quietly wrong for a fifth of all merchants.
--
-- Two consequences:
--
-- * **`merchant_id` is a degenerate dimension** and stays on the fact. The source
--   carries no merchant name or any other attribute, and a dimension with nothing
--   but a key is degenerate by definition.
-- * **Location becomes its own dimension**, keyed on the distinct
--   `(city, state, country, zip)` combination — about 25,400 rows.
--
-- And the `Online` member is a real member, not `Unknown`. In bronze,
-- `MERCHANT_STATE IS NULL` is *exactly* `MERCHANT_CITY = 'ONLINE'` — 1,563,700
-- rows, coincident to the row. Those are online transactions. Calling 11.75% of
-- the fact "unknown location" would have been a lie.

-- CELL ---
CREATE TABLE dbo.dim_location AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (
        ORDER BY is_online, merchant_country, merchant_state,
                 merchant_city, merchant_zip) AS BIGINT), -1) AS location_sk,
    merchant_city    AS city,
    merchant_state   AS state_code,
    merchant_country AS country,
    merchant_zip     AS postal_code,
    is_online,
    CASE WHEN is_online = 1 THEN 'Online'
         WHEN merchant_state IS NOT NULL
              THEN CONCAT(merchant_city, ', ', merchant_state)
         ELSE CONCAT(merchant_city, ', ', merchant_country)
    END AS location_label,
    CASE WHEN is_online = 1 THEN 'Card not present'
         ELSE 'Card present' END AS presence
FROM (
    SELECT DISTINCT merchant_city, merchant_state, merchant_country,
                    merchant_zip, is_online
    FROM lh_silver.dbo.slv_transactions
) AS d;

INSERT INTO dbo.dim_location (location_sk, city, state_code, country,
                              postal_code, is_online, location_label, presence)
VALUES (-1, 'Unknown', NULL, 'Unknown', NULL, 0, 'Unknown', 'Unknown');

ALTER TABLE dbo.dim_location
    ADD CONSTRAINT pk_dim_location PRIMARY KEY NONCLUSTERED (location_sk) NOT ENFORCED;

-- CELL ---
CREATE TABLE dbo.dim_mcc AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY mcc_code) AS BIGINT), -1) AS mcc_sk,
    mcc_code,
    mcc_description
FROM lh_silver.dbo.slv_mcc_codes_spark;

INSERT INTO dbo.dim_mcc (mcc_sk, mcc_code, mcc_description)
VALUES (-1, 'N/A', 'Unknown');

ALTER TABLE dbo.dim_mcc
    ADD CONSTRAINT pk_dim_mcc PRIMARY KEY NONCLUSTERED (mcc_sk) NOT ENFORCED;

-- CELL ---
CREATE TABLE dbo.dim_channel (
    channel_sk       BIGINT      NOT NULL,
    channel          VARCHAR(16) NOT NULL,
    is_card_present  BIT         NOT NULL
);
INSERT INTO dbo.dim_channel VALUES
    ( 1, 'Swipe',   1),
    ( 2, 'Chip',    1),
    ( 3, 'Online',  0),
    (-1, 'Unknown', 0);

ALTER TABLE dbo.dim_channel
    ADD CONSTRAINT pk_dim_channel PRIMARY KEY NONCLUSTERED (channel_sk) NOT ENFORCED;

-- MD ---
-- ## `dim_transaction_error` — a junk dimension
--
-- `ERROR_FLAGS` is a comma-separated multi-value: **7 atomic errors appearing in
-- 22 combinations**, and null on 98.41% of rows.
--
-- Modelled as a junk dimension — one row per observed combination plus a `None`
-- member — with a boolean column per atomic error. That lets a report answer
-- *"every transaction that hit an insufficient balance"* with a simple filter,
-- instead of a bridge table and a many-to-many relationship that would drag the
-- whole model into ambiguity.

-- CELL ---
CREATE TABLE dbo.dim_transaction_error AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY error_flags) AS BIGINT), -1) AS error_sk,
    error_flags,
    -- The join key. NOT the nullable `error_flags`: joining on
    -- `a IS NULL AND b IS NULL OR a = b` means any second row with a null
    -- `error_flags` matches every null-error fact row a second time. That is a
    -- 13-million-row fan-out, and it is silent -- the totals just double.
    -- 'None' cannot collide with a real combination.
    CASE WHEN error_flags IS NULL THEN 'None' ELSE error_flags END AS error_label,
    CASE WHEN error_flags IS NULL THEN 0 ELSE 1 END AS has_error,
    err_insufficient_balance,
    err_bad_pin,
    err_technical_glitch,
    err_bad_card_number,
    err_bad_expiration,
    err_bad_cvv,
    err_bad_zipcode
FROM (
    SELECT DISTINCT error_flags, err_insufficient_balance, err_bad_pin,
                    err_technical_glitch, err_bad_card_number,
                    err_bad_expiration, err_bad_cvv, err_bad_zipcode
    FROM lh_silver.dbo.slv_transactions
) AS d;

-- Nothing lands here today: the dimension is built from the same table the fact
-- reads, so every combination matches. It exists for the day that stops being
-- true -- an incrementally loaded fact meeting an error combination the
-- dimension has not seen would otherwise orphan.
INSERT INTO dbo.dim_transaction_error
    (error_sk, error_flags, error_label, has_error,
     err_insufficient_balance, err_bad_pin, err_technical_glitch,
     err_bad_card_number, err_bad_expiration, err_bad_cvv, err_bad_zipcode)
VALUES (-1, NULL, 'Unknown', 0, 0, 0, 0, 0, 0, 0, 0);

ALTER TABLE dbo.dim_transaction_error
    ADD CONSTRAINT pk_dim_transaction_error
    PRIMARY KEY NONCLUSTERED (error_sk) NOT ENFORCED;

-- MD ---
-- ## `dim_fraud_status` — where `Unlabelled` earns its place
--
-- The fraud label set covers 8,914,963 of 13,305,915 transactions. **4.4 million
-- are unlabelled**, by design of the dataset.
--
-- The fact therefore **left** joins the labels and unmatched rows land on
-- `Unlabelled`. An inner join would have silently dropped a third of the fact —
-- the totals would still have looked plausible, which is exactly what makes that
-- class of mistake dangerous.

-- CELL ---
CREATE TABLE dbo.dim_fraud_status (
    fraud_sk      BIGINT      NOT NULL,
    fraud_status  VARCHAR(12) NOT NULL,
    is_labelled   BIT         NOT NULL,
    is_fraud      BIT         NULL
);
INSERT INTO dbo.dim_fraud_status VALUES
    ( 1, 'Not fraud',  1, 0),
    ( 2, 'Fraud',      1, 1),
    (-1, 'Unlabelled', 0, NULL);

ALTER TABLE dbo.dim_fraud_status
    ADD CONSTRAINT pk_dim_fraud_status
    PRIMARY KEY NONCLUSTERED (fraud_sk) NOT ENFORCED;

-- MD ---
-- ## `fact_card_transaction`
--
-- Grain: **one card transaction**. 13,305,915 rows minus whatever silver
-- quarantined.
--
-- Every dimension key is `COALESCE`d to `-1` rather than left null. A null foreign
-- key in Power BI creates a blank member and the row quietly stops being counted
-- under any filter — the failure looks like missing data rather than a modelling
-- bug.

-- CELL ---
CREATE TABLE dbo.fact_card_transaction AS
SELECT
    t.transaction_id,                                  -- degenerate
    t.merchant_id,                                     -- degenerate (see dim_location)
    t.txn_date_key,
    t.txn_time_key,
    COALESCE(c.customer_sk, -1)  AS customer_sk,
    COALESCE(cd.card_sk,    -1)  AS card_sk,
    COALESCE(l.location_sk, -1)  AS location_sk,
    COALESCE(m.mcc_sk,      -1)  AS mcc_sk,
    COALESCE(ch.channel_sk, -1)  AS channel_sk,
    COALESCE(e.error_sk,    -1)  AS error_sk,
    COALESCE(f.fraud_sk,    -1)  AS fraud_sk,
    t.amount,
    CASE WHEN t.amount < 0 THEN 1 ELSE 0 END AS is_refund,
    ABS(t.amount) AS amount_abs
FROM lh_silver.dbo.slv_transactions AS t
LEFT JOIN dbo.dim_customer AS c  ON c.customer_id = t.customer_id
LEFT JOIN dbo.dim_card     AS cd ON cd.card_id    = t.card_id
LEFT JOIN dbo.dim_mcc      AS m  ON m.mcc_code    = t.mcc_code
LEFT JOIN dbo.dim_channel  AS ch ON ch.channel    = t.channel
LEFT JOIN dbo.dim_location AS l
       ON  l.is_online = t.is_online
       AND ((l.city IS NULL AND t.merchant_city IS NULL) OR l.city = t.merchant_city)
       AND ((l.state_code IS NULL AND t.merchant_state IS NULL)
            OR l.state_code = t.merchant_state)
       AND ((l.country IS NULL AND t.merchant_country IS NULL)
            OR l.country = t.merchant_country)
       AND ((l.postal_code IS NULL AND t.merchant_zip IS NULL)
            OR l.postal_code = t.merchant_zip)
LEFT JOIN dbo.dim_transaction_error AS e
       ON e.error_label = COALESCE(t.error_flags, 'None')
-- LEFT, deliberately: 4.4M transactions have no label and must survive.
LEFT JOIN lh_silver.dbo.slv_fraud_labels AS fl ON fl.transaction_id = t.transaction_id
LEFT JOIN dbo.dim_fraud_status AS f
       ON f.fraud_sk = CASE WHEN fl.transaction_id IS NULL THEN -1
                            WHEN fl.is_fraud = 1 THEN 2 ELSE 1 END;

ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_date  FOREIGN KEY (txn_date_key)
        REFERENCES dbo.dim_date (date_key) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_time  FOREIGN KEY (txn_time_key)
        REFERENCES dbo.dim_time (time_key) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_cust  FOREIGN KEY (customer_sk)
        REFERENCES dbo.dim_customer (customer_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_card  FOREIGN KEY (card_sk)
        REFERENCES dbo.dim_card (card_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_loc   FOREIGN KEY (location_sk)
        REFERENCES dbo.dim_location (location_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_mcc   FOREIGN KEY (mcc_sk)
        REFERENCES dbo.dim_mcc (mcc_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_chan  FOREIGN KEY (channel_sk)
        REFERENCES dbo.dim_channel (channel_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_err   FOREIGN KEY (error_sk)
        REFERENCES dbo.dim_transaction_error (error_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_card_transaction
    ADD CONSTRAINT fk_fct_fraud FOREIGN KEY (fraud_sk)
        REFERENCES dbo.dim_fraud_status (fraud_sk) NOT ENFORCED;

-- MD ---
-- ## Star 2 — AML transfers
--
-- A second business process, so a second fact table, sharing **`dim_date`** and
-- nothing else. That is what makes `dim_date` a conformed dimension rather than
-- just a reused one.
--
-- ### Role playing, twice, deliberately solved two different ways
--
-- A transfer has a **from** account and a **to** account, and a **paid** currency
-- and a **received** currency. Both are role-playing problems, and this model
-- answers them differently on purpose, so the two can be compared on screen:
--
-- * **Accounts** get two *physical* dimensions (`dim_account_from`,
--   `dim_account_to`). Two active relationships, no DAX required.
-- * **Currency** gets one *shared* dimension with two relationships, of which only
--   one can be active — the other needs `USERELATIONSHIP` in every measure that
--   wants it.
--
-- The first is better under Direct Lake. Showing both is the fastest way to
-- explain why.
--
-- > The two facts barely overlap in time — card spend runs 2010–2019, the AML set
-- > covers days. They share a date dimension correctly, but they should never
-- > share a visual. Say so before someone asks.

-- CELL ---
CREATE TABLE dbo.dim_account_from AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY bank, account) AS BIGINT), -1) AS account_from_sk,
    account AS account_from,
    bank    AS from_bank,
    CONCAT(bank, ' / ', account) AS account_from_label
FROM (SELECT DISTINCT account_from AS account, from_bank AS bank
      FROM lh_silver.dbo.slv_aml_transfers) AS d;

CREATE TABLE dbo.dim_account_to AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY bank, account) AS BIGINT), -1) AS account_to_sk,
    account AS account_to,
    bank    AS to_bank,
    CONCAT(bank, ' / ', account) AS account_to_label
FROM (SELECT DISTINCT account_to AS account, to_bank AS bank
      FROM lh_silver.dbo.slv_aml_transfers) AS d;

CREATE TABLE dbo.dim_currency AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY currency) AS BIGINT), -1) AS currency_sk,
    currency
FROM (SELECT DISTINCT payment_currency AS currency
      FROM lh_silver.dbo.slv_aml_transfers
      UNION
      SELECT DISTINCT receiving_currency
      FROM lh_silver.dbo.slv_aml_transfers) AS d;

CREATE TABLE dbo.dim_payment_format AS
SELECT
    ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY payment_format) AS BIGINT), -1) AS payment_format_sk,
    payment_format
FROM (SELECT DISTINCT payment_format
      FROM lh_silver.dbo.slv_aml_transfers) AS d;

ALTER TABLE dbo.dim_account_from ADD CONSTRAINT pk_dim_account_from
    PRIMARY KEY NONCLUSTERED (account_from_sk) NOT ENFORCED;
ALTER TABLE dbo.dim_account_to ADD CONSTRAINT pk_dim_account_to
    PRIMARY KEY NONCLUSTERED (account_to_sk) NOT ENFORCED;
ALTER TABLE dbo.dim_currency ADD CONSTRAINT pk_dim_currency
    PRIMARY KEY NONCLUSTERED (currency_sk) NOT ENFORCED;
ALTER TABLE dbo.dim_payment_format ADD CONSTRAINT pk_dim_payment_format
    PRIMARY KEY NONCLUSTERED (payment_format_sk) NOT ENFORCED;

-- CELL ---
CREATE TABLE dbo.fact_aml_transfer AS
SELECT
    a.aml_txn_id,                                      -- degenerate
    a.txn_date_key,
    COALESCE(af.account_from_sk,   -1) AS account_from_sk,
    COALESCE(at2.account_to_sk,    -1) AS account_to_sk,
    COALESCE(cp.currency_sk,       -1) AS paid_currency_sk,
    COALESCE(cr.currency_sk,       -1) AS received_currency_sk,
    COALESCE(pf.payment_format_sk, -1) AS payment_format_sk,
    a.amount_paid,
    a.amount_received,
    CASE WHEN a.is_laundering = 1 THEN 1 ELSE 0 END AS is_laundering,
    CASE WHEN a.is_cross_currency = 1 THEN 1 ELSE 0 END AS is_cross_currency
FROM lh_silver.dbo.slv_aml_transfers AS a
LEFT JOIN dbo.dim_account_from    AS af  ON af.account_from  = a.account_from
                                        AND af.from_bank     = a.from_bank
LEFT JOIN dbo.dim_account_to      AS at2 ON at2.account_to   = a.account_to
                                        AND at2.to_bank      = a.to_bank
LEFT JOIN dbo.dim_currency        AS cp  ON cp.currency      = a.payment_currency
LEFT JOIN dbo.dim_currency        AS cr  ON cr.currency      = a.receiving_currency
LEFT JOIN dbo.dim_payment_format  AS pf  ON pf.payment_format = a.payment_format;

ALTER TABLE dbo.fact_aml_transfer ADD CONSTRAINT fk_aml_date
    FOREIGN KEY (txn_date_key) REFERENCES dbo.dim_date (date_key) NOT ENFORCED;
ALTER TABLE dbo.fact_aml_transfer ADD CONSTRAINT fk_aml_from
    FOREIGN KEY (account_from_sk)
    REFERENCES dbo.dim_account_from (account_from_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_aml_transfer ADD CONSTRAINT fk_aml_to
    FOREIGN KEY (account_to_sk)
    REFERENCES dbo.dim_account_to (account_to_sk) NOT ENFORCED;
ALTER TABLE dbo.fact_aml_transfer ADD CONSTRAINT fk_aml_fmt
    FOREIGN KEY (payment_format_sk)
    REFERENCES dbo.dim_payment_format (payment_format_sk) NOT ENFORCED;

-- MD ---
-- ## Validation
--
-- The constraints above are `NOT ENFORCED`, which means Fabric will not check
-- them. **That is exactly why this cell exists.** The pipeline enforces
-- correctness; the constraint only documents the intent.
--
-- Results land in `dbo.gold_validation` so they can be queried, shown in a
-- report, or asserted by `scripts/23_verify_gold.py`.

-- CELL ---
CREATE TABLE dbo.gold_validation AS
SELECT CAST('fact rows = silver clean rows' AS VARCHAR(60)) AS check_name,
       CAST((SELECT COUNT(*) FROM lh_silver.dbo.slv_transactions) AS BIGINT) AS expected,
       CAST((SELECT COUNT(*) FROM dbo.fact_card_transaction) AS BIGINT) AS actual
UNION ALL
SELECT 'aml fact rows = silver clean rows',
       (SELECT COUNT(*) FROM lh_silver.dbo.slv_aml_transfers),
       (SELECT COUNT(*) FROM dbo.fact_aml_transfer)
UNION ALL
SELECT 'no orphan customer_sk', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_customer d
                          WHERE d.customer_sk = f.customer_sk))
UNION ALL
SELECT 'no orphan card_sk', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_card d
                          WHERE d.card_sk = f.card_sk))
UNION ALL
SELECT 'no orphan location_sk', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_location d
                          WHERE d.location_sk = f.location_sk))
UNION ALL
SELECT 'no orphan mcc_sk', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_mcc d WHERE d.mcc_sk = f.mcc_sk))
UNION ALL
SELECT 'no orphan error_sk', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_transaction_error d
                          WHERE d.error_sk = f.error_sk))
UNION ALL
SELECT 'no orphan date_key', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date d
                          WHERE d.date_key = f.txn_date_key))
UNION ALL
SELECT 'no orphan time_key', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction f
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_time d
                          WHERE d.time_key = f.txn_time_key))
-- Location must never fall through to Unknown: every silver row has either a
-- real location or the Online member.
UNION ALL
SELECT 'no fact row on Unknown location', 0,
       (SELECT COUNT(*) FROM dbo.fact_card_transaction WHERE location_sk = -1)
UNION ALL
SELECT 'customer_sk is unique in dim_customer', 0,
       (SELECT COUNT(*) FROM (SELECT customer_sk FROM dbo.dim_customer
                              GROUP BY customer_sk HAVING COUNT(*) > 1) AS d)
UNION ALL
SELECT 'location_sk is unique in dim_location', 0,
       (SELECT COUNT(*) FROM (SELECT location_sk FROM dbo.dim_location
                              GROUP BY location_sk HAVING COUNT(*) > 1) AS d)
-- Fan-out guards. A dimension whose JOIN KEY repeats multiplies the fact
-- silently: the row count and every total simply double, and nothing errors.
-- This is not hypothetical -- adding an Unknown member with a NULL `error_flags`
-- duplicated 13.08M rows here, and only the row-count check caught it.
UNION ALL
SELECT 'error_label is unique in dim_transaction_error', 0,
       (SELECT COUNT(*) FROM (SELECT error_label FROM dbo.dim_transaction_error
                              GROUP BY error_label HAVING COUNT(*) > 1) AS d)
UNION ALL
SELECT 'location natural key is unique', 0,
       (SELECT COUNT(*) FROM (
            SELECT is_online, city, state_code, country, postal_code
            FROM dbo.dim_location
            GROUP BY is_online, city, state_code, country, postal_code
            HAVING COUNT(*) > 1) AS d)
UNION ALL
SELECT 'customer_id is unique in dim_customer', 0,
       (SELECT COUNT(*) FROM (SELECT customer_id FROM dbo.dim_customer
                              GROUP BY customer_id HAVING COUNT(*) > 1) AS d)
UNION ALL
SELECT 'card_id is unique in dim_card', 0,
       (SELECT COUNT(*) FROM (SELECT card_id FROM dbo.dim_card
                              GROUP BY card_id HAVING COUNT(*) > 1) AS d)
UNION ALL
SELECT 'mcc_code is unique in dim_mcc', 0,
       (SELECT COUNT(*) FROM (SELECT mcc_code FROM dbo.dim_mcc
                              GROUP BY mcc_code HAVING COUNT(*) > 1) AS d);

SELECT check_name,
       expected,
       actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM dbo.gold_validation
ORDER BY result DESC, check_name;

-- CELL ---
-- Unlabelled is 4,385,608 — that is 13,305,915 transactions minus 8,914,963
-- labels, less the rows silver quarantined. The exact figure matters less than
-- the fact that it is not zero: if this ever reads zero, someone has turned the
-- left join into an inner one and quietly dropped a third of the fact.
SELECT fs.fraud_status,
       COUNT(*)       AS transactions,
       SUM(f.amount)  AS total_amount
FROM dbo.fact_card_transaction AS f
JOIN dbo.dim_fraud_status AS fs ON fs.fraud_sk = f.fraud_sk
GROUP BY fs.fraud_status
ORDER BY transactions DESC;
