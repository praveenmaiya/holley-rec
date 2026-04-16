-- ==================================================================================================
-- Holley Non-Fitment Product Recommendations – V5.19 (No-YMM Users)
-- --------------------------------------------------------------------------------------------------
-- Purpose:
--   Extends recommendations to active users WITHOUT complete v1 YMM (~1.8M audience).
--   Disjoint from v5.18's YMM output — same users never appear in both pipelines.
--
-- Signal Hierarchy (unified recency-weighted scoring):
--   score(u, sku) = Σ weight[signal] × exp(-age_days / tau[signal])
--
--   cart                 weight=10, tau=7d
--   view                 weight=5,  tau=3d
--   purchase_recent      weight=3,  tau=30d  (events table, last 365d)
--   purchase_historical  weight=2,  tau=180d (import_orders, all time)
--   bestseller           weight=1,  tau=∞    (global fallback)
--
-- Output:
--   Wide-format table with up to 4 recs per user + dominant_signal (for email routing)
--   + engagement_tier (hot/warm/cold/fallback).
--
-- Ticket: AUX-14029
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_19_non_fitment_recommendations.sql
--
-- Safety:
--   deploy_to_production defaults to FALSE. Never writes to company_1950_jp unless flipped.
-- ==================================================================================================

-- Pipeline version
DECLARE pipeline_version STRING DEFAULT 'v5.19';

-- Working dataset (intermediate + staging final)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_19';

-- Production dataset (guarded deployment)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_non_fitment_recommendations';

-- Deployment flag (SAFETY: default FALSE — never touch production)
DECLARE deploy_to_production BOOL DEFAULT FALSE;

-- Backup suffix (timestamp for snapshot copies)
DECLARE backup_suffix STRING DEFAULT FORMAT_TIMESTAMP('%Y_%m_%d_%H%M%S', CURRENT_TIMESTAMP());

-- Signal window: events table last 365 days (align with v5.18 convention)
DECLARE signal_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE signal_window_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY);

-- Fixed boundary between historical (import_orders) and recent (events table) purchase
-- signals. Matches v5.18 convention. Used EXCLUSIVELY on the hist side (order_date <
-- recent_boundary) and INCLUSIVELY on the event side (event_ts >= recent_boundary) so
-- the same order never double-contributes to purchase_recent + purchase_historical.
DECLARE recent_boundary DATE DEFAULT DATE '2025-09-01';

-- Historical purchase window (import_orders, strictly before recent_boundary)
DECLARE hist_pop_start DATE DEFAULT DATE '2024-01-01';
DECLARE hist_pop_end   DATE DEFAULT DATE '2025-09-01';  -- exclusive upper bound

-- Year range for ORDER_DATE pre-filter (avoids PARSE_DATE on every row)
DECLARE min_prefilter_year INT64 DEFAULT EXTRACT(YEAR FROM hist_pop_start);
DECLARE max_prefilter_year INT64 DEFAULT EXTRACT(YEAR FROM CURRENT_DATE());

-- Purchase exclusion window
DECLARE purchase_window_days INT64 DEFAULT 365;

-- Pricing / filtering
DECLARE min_price FLOAT64 DEFAULT 25.0;

-- Signal weights (tunable)
DECLARE w_cart                 FLOAT64 DEFAULT 10.0;
DECLARE w_view                 FLOAT64 DEFAULT 5.0;
DECLARE w_purchase_recent      FLOAT64 DEFAULT 3.0;
DECLARE w_purchase_historical  FLOAT64 DEFAULT 2.0;
DECLARE w_bestseller           FLOAT64 DEFAULT 1.0;

-- Decay tau in days (tunable)
DECLARE tau_cart                FLOAT64 DEFAULT 7.0;
DECLARE tau_view                FLOAT64 DEFAULT 3.0;
DECLARE tau_purchase_recent     FLOAT64 DEFAULT 30.0;
DECLARE tau_purchase_historical FLOAT64 DEFAULT 180.0;
-- tau_bestseller is effectively infinite (no decay applied)

-- Selection / diversity
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE required_recs INT64 DEFAULT 4;
DECLARE min_required_recs INT64 DEFAULT 1;

-- Bestseller fallback size
DECLARE top_n_bestsellers INT64 DEFAULT 20;

-- Monitoring thresholds
DECLARE min_noymm_users INT64 DEFAULT 500000;
DECLARE min_final_users INT64 DEFAULT 150000;

-- Table names
DECLARE tbl_noymm_users STRING DEFAULT FORMAT('`%s.%s.no_ymm_users`', target_project, target_dataset);
DECLARE tbl_ymm_users   STRING DEFAULT FORMAT('`%s.%s.ymm_users_for_exclusion`', target_project, target_dataset);
DECLARE tbl_staged_signals STRING DEFAULT FORMAT('`%s.%s.staged_signals`', target_project, target_dataset);
DECLARE tbl_hist_purchases STRING DEFAULT FORMAT('`%s.%s.hist_purchase_signals`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_skus STRING DEFAULT FORMAT('`%s.%s.eligible_skus`', target_project, target_dataset);
DECLARE tbl_bestsellers STRING DEFAULT FORMAT('`%s.%s.bestsellers`', target_project, target_dataset);
DECLARE tbl_purchase_excl STRING DEFAULT FORMAT('`%s.%s.user_purchased_365d`', target_project, target_dataset);
DECLARE tbl_raw_signal_ages STRING DEFAULT FORMAT('`%s.%s.user_raw_signal_ages`', target_project, target_dataset);
DECLARE tbl_scored STRING DEFAULT FORMAT('`%s.%s.scored_candidates`', target_project, target_dataset);
DECLARE tbl_diversity STRING DEFAULT FORMAT('`%s.%s.diversity_filtered`', target_project, target_dataset);
DECLARE tbl_ranked STRING DEFAULT FORMAT('`%s.%s.ranked_recommendations`', target_project, target_dataset);
DECLARE tbl_final STRING DEFAULT FORMAT('`%s.%s.final_non_fitment_recommendations`', target_project, target_dataset);

-- Execution timing
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- ====================================================================================
-- STEP 0: USER UNIVERSE (YMM-for-exclusion FIRST, then No-YMM anti-joined on email)
-- ====================================================================================
-- Build order matters for the disjoint invariant:
--   0a. ymm_users_for_exclusion: every email that has a complete YMM on ANY user_id.
--       Matches v5.18's user universe.
--   0b. no_ymm_users: user_ids where THAT user_id has incomplete YMM, AND the email
--       never appears with complete YMM on any other user_id (anti-join on email).
--       This guarantees v5.19 output is disjoint from v5.18 output at the email level,
--       not merely at the user_id level.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 0a: ymm_users_for_exclusion — emails with at least one complete-YMM user_id
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH attr_ranked AS (
  SELECT
    t.user_id,
    LOWER(p.property_name) AS property_name,
    CASE
      WHEN LOWER(p.property_name) = 'email'
        THEN LOWER(TRIM(p.string_value))
      WHEN LOWER(p.property_name) = 'v1_year'
        THEN TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))
      WHEN LOWER(p.property_name) = 'v1_make'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      WHEN LOWER(p.property_name) = 'v1_model'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      ELSE NULL
    END AS property_value,
    ROW_NUMBER() OVER (
      PARTITION BY t.user_id, LOWER(p.property_name)
      ORDER BY t.update_timestamp DESC, t.auxia_insertion_timestamp DESC
    ) AS rn
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` t,
       UNNEST(t.user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email', 'v1_year', 'v1_make', 'v1_model')
),
latest_props AS (
  SELECT user_id, property_name, property_value
  FROM attr_ranked
  WHERE rn = 1
    AND property_value IS NOT NULL
    AND property_value != ''
),
pivoted AS (
  SELECT
    user_id,
    MAX(IF(property_name = 'email', property_value, NULL)) AS email_lower,
    MAX(IF(property_name = 'v1_year', property_value, NULL)) AS v1_year,
    MAX(IF(property_name = 'v1_make', property_value, NULL)) AS v1_make,
    MAX(IF(property_name = 'v1_model', property_value, NULL)) AS v1_model
  FROM latest_props
  GROUP BY user_id
)
SELECT DISTINCT email_lower
FROM pivoted
WHERE email_lower IS NOT NULL
  AND v1_year IS NOT NULL
  AND SAFE_CAST(v1_year AS INT64) IS NOT NULL
  AND v1_make IS NOT NULL
  AND v1_model IS NOT NULL;
""", tbl_ymm_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0a] YMM exclusion set: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Step 0b: no_ymm_users — per-user-id incomplete YMM + email not in ymm_users
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH attr_ranked AS (
  SELECT
    t.user_id,
    LOWER(p.property_name) AS property_name,
    CASE
      WHEN LOWER(p.property_name) = 'email'
        THEN LOWER(TRIM(p.string_value))
      WHEN LOWER(p.property_name) = 'v1_year'
        THEN TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))
      WHEN LOWER(p.property_name) = 'v1_make'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      WHEN LOWER(p.property_name) = 'v1_model'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      ELSE NULL
    END AS property_value,
    ROW_NUMBER() OVER (
      PARTITION BY t.user_id, LOWER(p.property_name)
      ORDER BY t.update_timestamp DESC, t.auxia_insertion_timestamp DESC
    ) AS rn
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` t,
       UNNEST(t.user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email', 'v1_year', 'v1_make', 'v1_model')
),
latest_props AS (
  SELECT user_id, property_name, property_value
  FROM attr_ranked
  WHERE rn = 1
    AND property_value IS NOT NULL
    AND property_value != ''
),
pivoted AS (
  SELECT
    user_id,
    MAX(IF(property_name = 'email', property_value, NULL)) AS email_lower,
    MAX(IF(property_name = 'v1_year', property_value, NULL)) AS v1_year,
    MAX(IF(property_name = 'v1_make', property_value, NULL)) AS v1_make,
    MAX(IF(property_name = 'v1_model', property_value, NULL)) AS v1_model
  FROM latest_props
  GROUP BY user_id
)
SELECT
  p.user_id,
  p.email_lower
FROM pivoted p
LEFT JOIN %s y ON p.email_lower = y.email_lower
WHERE p.email_lower IS NOT NULL
  -- This user_id has incomplete YMM
  AND (
    p.v1_year IS NULL
    OR p.v1_make IS NULL
    OR p.v1_model IS NULL
    OR SAFE_CAST(p.v1_year AS INT64) IS NULL
  )
  -- AND no user_id under this email has complete YMM (email-level disjoint invariant)
  AND y.email_lower IS NULL;
""", tbl_noymm_users, tbl_ymm_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0b] No-YMM users: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'no_ymm_users' AS table_name, COUNT(*) AS row_count,
  COUNT(DISTINCT email_lower) AS unique_emails,
  CASE WHEN COUNT(*) >= @min_noymm_users THEN 'OK' ELSE 'WARNING: Low no-YMM user count' END AS status
FROM %s
""", tbl_noymm_users)
USING min_noymm_users AS min_noymm_users;

-- ====================================================================================
-- STEP 1: STAGED SIGNALS (view / cart / purchase_recent from events table)
-- ====================================================================================
-- Reuses v5.18 staged_events extraction pattern (prod(uct)?id, items_N.productid, skus_N)
-- but keeps signal type so we can score by event class.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
PARTITION BY DATE(event_ts)
CLUSTER BY user_id, sku AS
WITH bounds AS (
  SELECT @signal_window_start AS start_date, @signal_window_end AS end_date
),
raw_events AS (
  SELECT
    t.user_id,
    t.client_event_timestamp AS event_ts,
    UPPER(t.event_name) AS event_name,
    CASE
      WHEN UPPER(t.event_name) = 'VIEWED PRODUCT' THEN 'view'
      WHEN UPPER(t.event_name) = 'CART UPDATE' THEN 'cart'
      WHEN UPPER(t.event_name) IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER') THEN 'purchase_recent'
      ELSE NULL
    END AS signal_type,
    CASE
      WHEN UPPER(t.event_name) IN ('VIEWED PRODUCT', 'ORDERED PRODUCT')
           AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      WHEN UPPER(t.event_name) IN ('CART UPDATE', 'PLACED ORDER')
           AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.productid$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      WHEN UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER'
           AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      ELSE NULL
    END AS sku,
    REGEXP_EXTRACT(LOWER(ep.property_name), r'^items_([0-9]+)\\.productid$') AS sku_idx,
    REGEXP_EXTRACT(LOWER(ep.property_name), r'^skus_([0-9]+)$') AS sku_idx_skus,
    CASE
      WHEN LOWER(ep.property_name) IN ('price','itemprice')
        THEN COALESCE(ep.double_value, SAFE_CAST(ep.string_value AS FLOAT64))
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.itemprice$')
        THEN COALESCE(ep.double_value, SAFE_CAST(ep.string_value AS FLOAT64))
    END AS price_val,
    REGEXP_EXTRACT(LOWER(ep.property_name), r'^items_([0-9]+)\\.itemprice$') AS price_idx,
    CASE
      WHEN LOWER(ep.property_name) = 'imageurl' THEN ep.string_value
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\\.imageurl$') THEN ep.string_value
    END AS image_val,
    REGEXP_EXTRACT(LOWER(ep.property_name), r'^items_([0-9]+)\\.imageurl$') AS image_idx
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t,
       UNNEST(t.event_properties) ep,
       bounds b
  WHERE DATE(t.client_event_timestamp) BETWEEN b.start_date AND b.end_date
    AND UPPER(t.event_name) IN ('VIEWED PRODUCT','CART UPDATE','ORDERED PRODUCT','PLACED ORDER','CONSUMER WEBSITE ORDER')
),
prepared AS (
  SELECT
    user_id,
    sku,
    event_ts,
    event_name,
    signal_type,
    COALESCE(sku_idx, sku_idx_skus, price_idx, image_idx) AS item_idx,
    price_val,
    price_idx,
    image_val,
    image_idx
  FROM raw_events
),
aggregated AS (
  SELECT
    user_id,
    MAX(sku) AS sku,
    event_ts,
    event_name,
    signal_type,
    item_idx,
    MAX(IF(price_idx IS NULL, price_val, NULL)) AS price_main,
    MAX(IF(price_idx IS NOT NULL AND price_idx = item_idx, price_val, NULL)) AS price_item,
    MAX(IF(image_idx IS NULL, image_val, NULL)) AS image_main,
    MAX(IF(image_idx IS NOT NULL AND image_idx = item_idx, image_val, NULL)) AS image_item
  FROM prepared
  GROUP BY user_id, event_ts, event_name, signal_type, item_idx
)
SELECT
  user_id,
  sku,
  event_ts,
  event_name,
  signal_type,
  COALESCE(price_item, price_main) AS price,
  COALESCE(image_item, image_main) AS image_url_raw
FROM aggregated
WHERE sku IS NOT NULL AND signal_type IS NOT NULL
  -- Enforce v5.18 convention: purchase events before recent_boundary belong to
  -- import_orders (purchase_historical), not the events table. Prevents the same
  -- order from contributing to both purchase_recent and purchase_historical.
  AND NOT (signal_type = 'purchase_recent' AND DATE(event_ts) < @recent_boundary);
""", tbl_staged_signals)
USING signal_window_start AS signal_window_start, signal_window_end AS signal_window_end,
      recent_boundary AS recent_boundary;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1] Staged signals: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'staged_signals' AS table_name,
  COUNT(*) AS row_count,
  COUNTIF(signal_type='view') AS views,
  COUNTIF(signal_type='cart') AS carts,
  COUNTIF(signal_type='purchase_recent') AS recent_purchases
FROM %s
""", tbl_staged_signals);

-- -----------------------------------------------------------------------------------
-- STEP 1.1: SKU PRICES (from events)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, MAX(price) AS price, COUNT(*) AS observations
FROM %s
WHERE sku IS NOT NULL AND price IS NOT NULL
GROUP BY sku;
""", tbl_sku_prices, tbl_staged_signals);

-- -----------------------------------------------------------------------------------
-- STEP 1.2: SKU IMAGES (https-normalized, latest per SKU)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, image_url
FROM (
  SELECT
    sku,
    REGEXP_REPLACE(
      CASE
        WHEN image_url_raw LIKE '//%%' THEN CONCAT('https:', image_url_raw)
        WHEN LOWER(image_url_raw) LIKE 'http://%%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
        ELSE image_url_raw
      END,
      '^//', 'https://'
    ) AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM %s
  WHERE sku IS NOT NULL AND image_url_raw IS NOT NULL
)
WHERE rn = 1 AND image_url LIKE 'https://%%';
""", tbl_sku_images, tbl_staged_signals);

-- ====================================================================================
-- STEP 1.3: HISTORICAL PURCHASE SIGNALS (import_orders)
-- ====================================================================================
-- Joins to user_id via email. Produces (user_id, sku, order_date) rows.
-- Also produces the 365d purchase exclusion set (reused in Step 2).
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH import_filtered AS (
  SELECT
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (
      ITEM LIKE 'EXT-%%' OR
      ITEM LIKE 'GIFT-%%' OR
      ITEM LIKE 'WARRANTY-%%' OR
      ITEM LIKE 'SERVICE-%%' OR
      ITEM LIKE 'PREAUTH-%%'
    )
    AND SHIP_TO_EMAIL IS NOT NULL
    AND SAFE_CAST(REGEXP_EXTRACT(ORDER_DATE, r'\\b(20[0-9]{2})\\b') AS INT64) BETWEEN @min_prefilter_year AND @max_prefilter_year
)
SELECT
  u.user_id,
  f.sku,
  f.order_date_parsed AS order_date
FROM import_filtered f
JOIN %s u
  ON f.email_lower = u.email_lower
WHERE f.order_date_parsed IS NOT NULL
  -- Historical window is [hist_pop_start, recent_boundary) — strictly before the
  -- fixed Sep 1, 2025 split that separates historical from recent purchases.
  AND f.order_date_parsed >= @hist_pop_start
  AND f.order_date_parsed <  @recent_boundary;
""", tbl_hist_purchases, tbl_noymm_users)
USING min_prefilter_year AS min_prefilter_year, max_prefilter_year AS max_prefilter_year,
      hist_pop_start AS hist_pop_start, recent_boundary AS recent_boundary;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.3] Historical purchases joined: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 1.4: ELIGIBLE SKUS (price floor, HTTPS image, refurb/commodity exclusions)
-- ====================================================================================
-- Unlike v5.18, this is not fitment-gated — any SKU in catalog with acceptable
-- price/image/tags is eligible. Variant normalization happens later in dedup step.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH catalog AS (
  SELECT
    UPPER(TRIM(PartNumber)) AS sku,
    MAX(PartType) AS part_type,
    MAX(Tags) AS tags
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL
  GROUP BY sku
),
refurb AS (
  SELECT sku FROM catalog WHERE LOWER(COALESCE(tags, '')) LIKE '%%refurbished%%'
),
priced AS (
  SELECT
    c.sku,
    COALESCE(c.part_type, 'UNKNOWN') AS part_type,
    img.image_url,
    price.price
  FROM catalog c
  LEFT JOIN %s img ON c.sku = img.sku
  LEFT JOIN %s price ON c.sku = price.sku
  LEFT JOIN refurb r ON c.sku = r.sku
  WHERE r.sku IS NULL
    AND NOT (
      c.sku LIKE 'EXT-%%' OR
      c.sku LIKE 'GIFT-%%' OR
      c.sku LIKE 'WARRANTY-%%' OR
      c.sku LIKE 'SERVICE-%%' OR
      c.sku LIKE 'PREAUTH-%%'
    )
    AND price.price IS NOT NULL
    AND price.price >= @min_price
    AND img.image_url IS NOT NULL
    AND img.image_url LIKE 'https://%%'
    AND NOT (
      COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Gasket%%'
      OR COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Decal%%'
      OR COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Key%%'
      OR COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Washer%%'
      OR COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Clamp%%'
      OR (COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Bolt%%'
          AND COALESCE(c.part_type, 'UNKNOWN') NOT IN ('Engine Cylinder Head Bolt', 'Engine Bolt Kit'))
      OR (COALESCE(c.part_type, 'UNKNOWN') LIKE '%%Cap%%'
          AND COALESCE(c.part_type, 'UNKNOWN') NOT LIKE '%%Distributor Cap%%'
          AND COALESCE(c.part_type, 'UNKNOWN') NOT IN ('Wheel Hub Cap', 'Wheel Cap Set'))
    )
    AND NOT (COALESCE(c.part_type, 'UNKNOWN') = 'UNKNOWN' AND price.price < 3000)
)
SELECT sku, part_type, image_url, price FROM priced;
""", tbl_eligible_skus, tbl_sku_images, tbl_sku_prices)
USING min_price AS min_price;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.4] Eligible SKUs: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'eligible_skus' AS table_name, COUNT(*) AS row_count
FROM %s
""", tbl_eligible_skus);

-- ====================================================================================
-- STEP 1.5: BESTSELLERS (top-N globally by order count in last 365 days)
-- ====================================================================================
-- Combines historical (import_orders) and recent (staged_signals.purchase_recent)
-- order counts, keeps only SKUs that pass eligibility.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH hist_365d AS (
  -- Historical sliver of last-365d window: trailing 365d AND strictly before recent_boundary.
  -- Non-overlapping with recent_365d (events post-recent_boundary).
  -- Year prefilter avoids SAFE.PARSE_DATE on every row (matches v5.18 pattern).
  SELECT
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku,
    COUNT(*) AS order_count
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
    AND SAFE_CAST(REGEXP_EXTRACT(ORDER_DATE, r'\\b(20[0-9]{2})\\b') AS INT64) BETWEEN @min_prefilter_year AND @max_prefilter_year
    AND SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
    AND SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) <  @recent_boundary
  GROUP BY sku
),
recent_365d AS (
  -- Event-side purchases, at or after recent_boundary.
  SELECT
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\\1') AS sku,
    COUNT(*) AS order_count
  FROM %s
  WHERE signal_type = 'purchase_recent'
    AND DATE(event_ts) >= @recent_boundary
    AND DATE(event_ts) <= CURRENT_DATE()
  GROUP BY sku
),
combined AS (
  SELECT sku, SUM(order_count) AS order_count
  FROM (
    SELECT * FROM hist_365d
    UNION ALL
    SELECT * FROM recent_365d
  )
  GROUP BY sku
),
ranked AS (
  SELECT
    c.sku,
    c.order_count,
    ROW_NUMBER() OVER (ORDER BY c.order_count DESC, c.sku) AS bestseller_rank
  FROM combined c
  JOIN %s e ON c.sku = e.sku
)
SELECT *
FROM ranked
WHERE bestseller_rank <= @top_n_bestsellers;
""", tbl_bestsellers, tbl_staged_signals, tbl_eligible_skus)
USING top_n_bestsellers AS top_n_bestsellers,
      recent_boundary AS recent_boundary,
      min_prefilter_year AS min_prefilter_year,
      max_prefilter_year AS max_prefilter_year;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.5] Bestsellers: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 1.6: RAW SIGNAL AGES PER EMAIL (pre-filter; drives engagement_tier)
-- ====================================================================================
-- engagement_tier must reflect the user's actual behavior, not whatever survived the
-- filtering/ranking cascade. If the user's freshest cart was on a purchase-excluded
-- SKU, the cart signal disappears downstream — but we still want to tier them 'hot'
-- because we know the signal exists.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH event_ages AS (
  SELECT
    u.email_lower,
    MIN(IF(s.signal_type = 'cart', DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY), NULL)) AS min_cart_age,
    MIN(IF(s.signal_type = 'view', DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY), NULL)) AS min_view_age,
    MIN(IF(s.signal_type = 'purchase_recent', DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY), NULL)) AS min_recent_purchase_age
  FROM %s s
  JOIN %s u ON s.user_id = u.user_id
  GROUP BY u.email_lower
),
hist_ages AS (
  SELECT
    u.email_lower,
    MIN(DATE_DIFF(@signal_window_end, h.order_date, DAY)) AS min_hist_purchase_age
  FROM %s h
  JOIN %s u ON h.user_id = u.user_id
  GROUP BY u.email_lower
)
SELECT
  COALESCE(ea.email_lower, ha.email_lower) AS email_lower,
  ea.min_cart_age,
  ea.min_view_age,
  -- Freshest purchase = MIN across recent events and historical orders
  CASE
    WHEN ea.min_recent_purchase_age IS NULL AND ha.min_hist_purchase_age IS NULL THEN NULL
    WHEN ea.min_recent_purchase_age IS NULL THEN ha.min_hist_purchase_age
    WHEN ha.min_hist_purchase_age IS NULL THEN ea.min_recent_purchase_age
    ELSE LEAST(ea.min_recent_purchase_age, ha.min_hist_purchase_age)
  END AS min_purchase_age
FROM event_ages ea
FULL OUTER JOIN hist_ages ha ON ea.email_lower = ha.email_lower;
""", tbl_raw_signal_ages, tbl_staged_signals, tbl_noymm_users, tbl_hist_purchases, tbl_noymm_users)
USING signal_window_end AS signal_window_end;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.6] Raw signal ages: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 2: PURCHASE EXCLUSION (last 365 days)
-- ====================================================================================
-- Reuses v5.18 pattern: union event-sourced + import-sourced purchases per user.
-- SKU is variant-normalized so RA003R matches purchased RA003B.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku_norm AS
WITH from_events AS (
  SELECT DISTINCT
    user_id,
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\\1') AS sku_norm
  FROM %s
  WHERE signal_type = 'purchase_recent'
    AND DATE(event_ts) BETWEEN DATE_SUB(@signal_window_end, INTERVAL @purchase_window_days DAY) AND @signal_window_end
    AND user_id IS NOT NULL
    AND sku IS NOT NULL
),
from_import AS (
  SELECT DISTINCT
    user_id,
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\\1') AS sku_norm
  FROM %s
  WHERE order_date BETWEEN DATE_SUB(@signal_window_end, INTERVAL @purchase_window_days DAY) AND @signal_window_end
)
SELECT DISTINCT user_id, sku_norm
FROM (
  SELECT * FROM from_events
  UNION DISTINCT
  SELECT * FROM from_import
);
""", tbl_purchase_excl, tbl_staged_signals, tbl_hist_purchases)
USING signal_window_end AS signal_window_end, purchase_window_days AS purchase_window_days;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Purchase exclusion: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3: SCORED CANDIDATES (unified recency-weighted scoring)
-- ====================================================================================
-- Per (user, sku), aggregate the freshest event per signal_type, score each with
--   signal_score = weight × exp(-age_days / tau)
-- and sum across signal_types. Top contributing signal becomes the rec's type.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH
-- User-signal tuples from events (view, cart, purchase_recent)
event_signals AS (
  SELECT
    s.user_id,
    s.sku,
    s.signal_type,
    DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY) AS age_days
  FROM %s s
  JOIN %s u ON s.user_id = u.user_id
  WHERE s.signal_type IN ('view', 'cart', 'purchase_recent')
),
-- User-signal tuples from import_orders (purchase_historical)
hist_signals AS (
  SELECT
    h.user_id,
    h.sku,
    'purchase_historical' AS signal_type,
    DATE_DIFF(@signal_window_end, h.order_date, DAY) AS age_days
  FROM %s h
),
-- Bestseller candidates: cross join every no-YMM user with top bestsellers
bestseller_signals AS (
  SELECT
    u.user_id,
    b.sku,
    'bestseller' AS signal_type,
    0 AS age_days
  FROM %s u
  CROSS JOIN %s b
),
-- Union all signal sources
all_signals AS (
  SELECT * FROM event_signals
  UNION ALL
  SELECT * FROM hist_signals
  UNION ALL
  SELECT * FROM bestseller_signals
),
-- Take freshest event per (user, sku, signal_type)
per_signal_freshest AS (
  SELECT user_id, sku, signal_type, MIN(age_days) AS age_days
  FROM all_signals
  GROUP BY user_id, sku, signal_type
),
-- Score each (user, sku, signal) with weight × exp(-age/tau)
per_signal_scored AS (
  SELECT
    user_id,
    sku,
    signal_type,
    age_days,
    CASE signal_type
      WHEN 'cart' THEN @w_cart * EXP(-age_days / @tau_cart)
      WHEN 'view' THEN @w_view * EXP(-age_days / @tau_view)
      WHEN 'purchase_recent' THEN @w_purchase_recent * EXP(-age_days / @tau_purchase_recent)
      WHEN 'purchase_historical' THEN @w_purchase_historical * EXP(-age_days / @tau_purchase_historical)
      WHEN 'bestseller' THEN @w_bestseller
      ELSE 0.0
    END AS signal_score
  FROM per_signal_freshest
),
-- Top contributing signal per (user, sku) — becomes rec_type
top_signal_per_pair AS (
  SELECT user_id, sku, signal_type AS top_signal, age_days AS top_signal_age_days
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY user_id, sku ORDER BY signal_score DESC, signal_type) AS rn
    FROM per_signal_scored
  )
  WHERE rn = 1
),
-- Summed score per (user, sku)
total_score AS (
  SELECT user_id, sku, SUM(signal_score) AS final_score
  FROM per_signal_scored
  GROUP BY user_id, sku
)
SELECT
  u.email_lower,
  t.user_id,
  t.sku,
  e.part_type,
  e.price,
  e.image_url,
  ts.top_signal AS rec_type,
  ts.top_signal_age_days AS signal_age_days,
  ROUND(t.final_score, 4) AS final_score
FROM total_score t
JOIN top_signal_per_pair ts USING (user_id, sku)
JOIN %s u ON t.user_id = u.user_id
JOIN %s e ON t.sku = e.sku
-- Purchase exclusion: normalize variants for match
LEFT JOIN %s pe
  ON t.user_id = pe.user_id
 AND REGEXP_REPLACE(t.sku, r'([0-9])[BRGP]$', r'\\1') = pe.sku_norm
WHERE pe.user_id IS NULL;
""", tbl_scored, tbl_staged_signals, tbl_noymm_users, tbl_hist_purchases,
     tbl_noymm_users, tbl_bestsellers, tbl_noymm_users, tbl_eligible_skus, tbl_purchase_excl)
USING signal_window_end AS signal_window_end,
      w_cart AS w_cart, w_view AS w_view, w_purchase_recent AS w_purchase_recent,
      w_purchase_historical AS w_purchase_historical, w_bestseller AS w_bestseller,
      tau_cart AS tau_cart, tau_view AS tau_view,
      tau_purchase_recent AS tau_purchase_recent, tau_purchase_historical AS tau_purchase_historical;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Scored candidates: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'scored_candidates' AS table_name,
  COUNT(*) AS row_count,
  COUNT(DISTINCT user_id) AS unique_users,
  COUNT(DISTINCT sku) AS unique_skus
FROM %s
""", tbl_scored);

-- ====================================================================================
-- STEP 3.1: VARIANT DEDUP + DIVERSITY CAP
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH normalized AS (
  SELECT s.*,
         REGEXP_REPLACE(
           REGEXP_REPLACE(s.sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
           r'([0-9])[BRGP]$', r'\\1'
         ) AS base_sku
  FROM %s s
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var)
  FROM (
    SELECT n.*, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku) AS rn_var
    FROM normalized n
  )
  WHERE rn_var = 1
),
diversified AS (
  SELECT dv.*,
         ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score DESC, sku) AS rn_parttype
  FROM dedup_variant dv
)
SELECT *
FROM diversified
WHERE rn_parttype <= @max_parttype_per_user;
""", tbl_diversity, tbl_scored)
USING max_parttype_per_user AS max_parttype_per_user;

-- ====================================================================================
-- STEP 3.2: TOP-N SELECTION (top 4 per user) + FALLBACK REFILL
-- ====================================================================================
-- Two passes UNION'd into a single output:
--   Primary: top-4 per user from diversity-filtered scored candidates.
--   Fallback: for users missing from Primary (0 surviving candidates), emit top
--             bestsellers minus purchase-excluded. Guarantees the spec's promise
--             that fallback (engagement_tier) users still receive recs.
-- ====================================================================================
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH primary_ranked AS (
  SELECT
    d.email_lower, d.user_id, d.sku, d.part_type, d.price, d.image_url,
    d.rec_type, d.signal_age_days, d.final_score,
    ROW_NUMBER() OVER (PARTITION BY d.user_id ORDER BY d.final_score DESC, d.sku) AS rn,
    COUNT(*) OVER (PARTITION BY d.user_id) AS user_rec_count
  FROM %s d
),
primary_selected AS (
  SELECT email_lower, user_id, sku, part_type, price, image_url, rec_type, signal_age_days, final_score, rn
  FROM primary_ranked
  WHERE user_rec_count >= @min_required_recs
    AND rn <= @required_recs
),
primary_emails AS (
  SELECT DISTINCT email_lower FROM primary_selected
),
missing_users AS (
  SELECT u.user_id, u.email_lower
  FROM %s u
  LEFT JOIN primary_emails pe ON u.email_lower = pe.email_lower
  WHERE pe.email_lower IS NULL
),
fallback_pool AS (
  SELECT
    mu.email_lower,
    mu.user_id,
    b.sku,
    e.part_type,
    e.price,
    e.image_url,
    'bestseller' AS rec_type,
    CAST(NULL AS INT64) AS signal_age_days,
    @w_bestseller AS final_score,
    b.bestseller_rank
  FROM missing_users mu
  CROSS JOIN %s b
  JOIN %s e ON b.sku = e.sku
  LEFT JOIN %s px
    ON mu.user_id = px.user_id
   AND REGEXP_REPLACE(b.sku, r'([0-9])[BRGP]$', r'\\1') = px.sku_norm
  WHERE px.user_id IS NULL
),
fallback_selected AS (
  SELECT email_lower, user_id, sku, part_type, price, image_url, rec_type, signal_age_days, final_score, rn
  FROM (
    SELECT fp.*,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY bestseller_rank, sku) AS rn
    FROM fallback_pool fp
  )
  WHERE rn <= @required_recs
)
SELECT * FROM primary_selected
UNION ALL
SELECT * FROM fallback_selected;
""", tbl_ranked, tbl_diversity, tbl_noymm_users, tbl_bestsellers, tbl_eligible_skus, tbl_purchase_excl)
USING required_recs AS required_recs,
      min_required_recs AS min_required_recs,
      w_bestseller AS w_bestseller;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.2] Ranked recommendations (with fallback): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.3: PIVOT TO WIDE FORMAT (+ dominant_signal, engagement_tier)
-- ====================================================================================
-- Per email_lower: emit up to 4 rec slots. rec_type is per-slot signal type.
-- dominant_signal = rec_type of slot 1 (highest-scoring signal for the user).
-- engagement_tier derived from the freshest/strongest user signal present.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH
-- Choose one user_id per email_lower when the same email has multiple user_ids
selected_user AS (
  SELECT email_lower, user_id
  FROM (
    SELECT
      email_lower, user_id,
      SUM(final_score) OVER (PARTITION BY email_lower, user_id) AS user_total_score,
      COUNT(*) OVER (PARTITION BY email_lower, user_id) AS user_rec_count,
      ROW_NUMBER() OVER (
        PARTITION BY email_lower
        ORDER BY
          COUNT(*) OVER (PARTITION BY email_lower, user_id) DESC,
          SUM(final_score) OVER (PARTITION BY email_lower, user_id) DESC,
          user_id
      ) AS pick_rn
    FROM %s
  )
  WHERE pick_rn = 1
),
ranked_selected AS (
  SELECT r.*
  FROM %s r
  JOIN selected_user su
    ON r.email_lower = su.email_lower
   AND r.user_id = su.user_id
),
-- For engagement_tier: freshest cart/view/purchase age per user, sourced from RAW
-- signal history (pre-filter) — a cart on a purchase-excluded SKU still marks the
-- user as 'hot' even though it doesn't appear in their output slots.
user_sig_agg AS (
  SELECT
    email_lower,
    min_cart_age,
    min_view_age,
    min_purchase_age,
    CASE
      WHEN min_cart_age IS NOT NULL OR min_view_age IS NOT NULL OR min_purchase_age IS NOT NULL
        THEN 1 ELSE 0
    END AS has_user_signal
  FROM %s
)
SELECT
  r.email_lower,
  MAX(CASE WHEN rn = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rn = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN rn = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN rn = 1 THEN image_url END) AS rec1_image,
  MAX(CASE WHEN rn = 1 THEN rec_type END) AS rec1_type,
  MAX(CASE WHEN rn = 1 THEN signal_age_days END) AS rec1_signal_age_days,
  MAX(CASE WHEN rn = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rn = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN rn = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN rn = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN rn = 2 THEN rec_type END) AS rec2_type,
  MAX(CASE WHEN rn = 2 THEN signal_age_days END) AS rec2_signal_age_days,
  MAX(CASE WHEN rn = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rn = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN rn = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN rn = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN rn = 3 THEN rec_type END) AS rec3_type,
  MAX(CASE WHEN rn = 3 THEN signal_age_days END) AS rec3_signal_age_days,
  MAX(CASE WHEN rn = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rn = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN rn = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN rn = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN rn = 4 THEN rec_type END) AS rec4_type,
  MAX(CASE WHEN rn = 4 THEN signal_age_days END) AS rec4_signal_age_days,
  COUNT(*) AS rec_count,
  -- dominant_signal = rec_type of the top slot (highest-scoring signal)
  MAX(CASE WHEN rn = 1 THEN rec_type END) AS dominant_signal,
  -- engagement_tier:
  --   hot     = cart OR view in last 7 days
  --   warm    = view/purchase in last 30 days (not hot)
  --   cold    = purchase-only signal
  --   fallback = only bestseller (no user signal)
  CASE
    WHEN agg.has_user_signal = 0 THEN 'fallback'
    WHEN LEAST(COALESCE(agg.min_cart_age, 999), COALESCE(agg.min_view_age, 999)) <= 7 THEN 'hot'
    WHEN LEAST(COALESCE(agg.min_view_age, 999), COALESCE(agg.min_purchase_age, 999)) <= 30 THEN 'warm'
    WHEN agg.min_purchase_age IS NOT NULL THEN 'cold'
    ELSE 'fallback'
  END AS engagement_tier,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM ranked_selected r
JOIN user_sig_agg agg USING (email_lower)
GROUP BY r.email_lower, agg.has_user_signal, agg.min_cart_age, agg.min_view_age, agg.min_purchase_age
HAVING COUNT(*) >= @min_required_recs;
""", tbl_final, tbl_ranked, tbl_ranked, tbl_raw_signal_ages)
USING pipeline_version AS pipeline_version, min_required_recs AS min_required_recs;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.3] Final pivot: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final Output Checks
-- ====================================================================================

EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_non_fitment_recommendations' AS table_name,
  COUNT(*) AS unique_users,
  CASE WHEN COUNT(*) >= @min_final_users THEN 'OK' ELSE 'WARNING: Low final user count' END AS status
FROM %s
""", tbl_final)
USING min_final_users AS min_final_users;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'rec_count_distribution' AS check_name,
  COUNTIF(rec_count = 1) AS with_1,
  COUNTIF(rec_count = 2) AS with_2,
  COUNTIF(rec_count = 3) AS with_3,
  COUNTIF(rec_count = 4) AS with_4,
  ROUND(AVG(rec_count), 2) AS avg_rec_count
FROM %s
""", tbl_final);

EXECUTE IMMEDIATE FORMAT("""
SELECT 'engagement_tier_distribution' AS check_name,
  COUNTIF(engagement_tier = 'hot')      AS hot,
  COUNTIF(engagement_tier = 'warm')     AS warm,
  COUNTIF(engagement_tier = 'cold')     AS cold,
  COUNTIF(engagement_tier = 'fallback') AS fallback,
  COUNT(*) AS total_users
FROM %s
""", tbl_final);

EXECUTE IMMEDIATE FORMAT("""
SELECT 'dominant_signal_distribution' AS check_name,
  COUNTIF(dominant_signal = 'cart')                AS cart,
  COUNTIF(dominant_signal = 'view')                AS view,
  COUNTIF(dominant_signal = 'purchase_recent')     AS purchase_recent,
  COUNTIF(dominant_signal = 'purchase_historical') AS purchase_historical,
  COUNTIF(dominant_signal = 'bestseller')          AS bestseller
FROM %s
""", tbl_final);

EXECUTE IMMEDIATE FORMAT("""
SELECT 'duplicate_check' AS check_name,
  COUNTIF(
    (rec_part_2 IS NOT NULL AND rec_part_1 = rec_part_2) OR
    (rec_part_3 IS NOT NULL AND (rec_part_1 = rec_part_3 OR rec_part_2 = rec_part_3)) OR
    (rec_part_4 IS NOT NULL AND (rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4))
  ) AS users_with_duplicates
FROM %s
""", tbl_final);

EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_floor_check' AS check_name,
  COUNTIF(rec1_price < @min_price OR rec2_price < @min_price OR rec3_price < @min_price OR rec4_price < @min_price) AS violations,
  @min_price AS min_price
FROM %s
""", tbl_final)
USING min_price AS min_price;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'score_ordering_check' AS check_name,
  COUNTIF(NOT (
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) AS violations
FROM %s
""", tbl_final);

-- Disjoint-from-v5.18 check: 0 emails should overlap with YMM universe
EXECUTE IMMEDIATE FORMAT("""
SELECT 'disjoint_from_v5_18_check' AS check_name,
  COUNT(*) AS ymm_overlap_count
FROM %s f
JOIN %s y ON f.email_lower = y.email_lower
""", tbl_final, tbl_ymm_users);

-- Cleanup large intermediate tables (keep staged_signals for debug if needed)
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_signals);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Pipeline %s finished in %d seconds',
  pipeline_version,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 4: PRODUCTION DEPLOYMENT (Guarded — DEFAULT OFF)
-- ====================================================================================
-- Never runs unless deploy_to_production is explicitly flipped to TRUE above.
-- ====================================================================================

IF deploy_to_production THEN
  SET step_start = CURRENT_TIMESTAMP();

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s`
  COPY `%s.%s.final_non_fitment_recommendations`
  """, prod_project, prod_dataset, prod_table_name,
       target_project, target_dataset);

  SELECT FORMAT('[Step 4.1] Deployed to production: %s.%s.%s',
    prod_project, prod_dataset, prod_table_name) AS log;

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s_%s`
  COPY `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name, backup_suffix,
       prod_project, prod_dataset, prod_table_name);

  SET step_end = CURRENT_TIMESTAMP();
  SELECT FORMAT('[Step 4.2] Timestamped copy: %s.%s.%s_%s (%d seconds)',
    prod_project, prod_dataset, prod_table_name, backup_suffix,
    TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

  SELECT '[DEPLOYMENT COMPLETE] Pipeline finished successfully' AS log;

ELSE
  SELECT FORMAT('[SKIP] Production deployment skipped (deploy_to_production = FALSE). Output in %s.%s.final_non_fitment_recommendations',
    target_project, target_dataset) AS log;

END IF;
