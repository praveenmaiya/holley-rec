-- ==================================================================================================
-- Holley Recommendations – V5.19 (Release: fitment + non-fitment in one shared table)
-- --------------------------------------------------------------------------------------------------
-- Purpose:
--   V5.19 is a RELEASE that extends V5.18's fitment output to also cover no-YMM users.
--   Both audiences land in the SAME table `final_vehicle_recommendations` with the SAME V5.18
--   column set. `rec1..4_type IN ('fitment','non_fitment')` is the row-level audience marker;
--   every row in the shared table carries `pipeline_version = 'v5.19'`.
--
-- Audiences (disjoint by email):
--   Fitment     (~457K, have YMM)   → V5.18 algorithm, re-projected into the shared table
--   Non-fitment (~1.8M, no YMM)     → V5.19 behavior-based algorithm (this file)
--
-- V5.19 non-fitment ranking shape:
--   Primary path:
--     purchase/cart/view seeds
--       -> co-purchase graph expansion
--       -> lifetime/cart/recent-browse exclusion
--       -> related-item ranking
--   Backup floor:
--     current exact-SKU cart/view+bestseller engine, demoted to a flow-safe backfill layer
--   Purchase history is reintroduced only as a SEED, never as the final exact SKU.
--
-- Materialization:
--   1. Non-fitment candidates built into temp_holley_v5_19.*
--   2. V5.18 staging snapshotted into temp_holley_v5_19.fitment_source_snapshot (per-run
--      overwrite) to stop the UNION from reading V5.18's CREATE-OR-REPLACE staging table.
--   3. UNION ALL of snapshot + non-fitment pivot → temp_holley_v5_19.final_vehicle_recommendations
--      with a single fresh release timestamp (`pipeline_start`) on every row.
--
-- Ticket: AUX-14029
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_19_non_fitment_recommendations.sql
--
-- Safety:
--   deploy_to_production defaults to FALSE. Never writes to company_1950_jp unless flipped.
-- ==================================================================================================

-- Pipeline version (shared-table release tag — every row carries this value)
DECLARE pipeline_version STRING DEFAULT 'v5.19';

-- Working dataset (intermediate + staging final)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_19';

-- V5.18 staging (read-only source for the fitment snapshot)
DECLARE v5_18_project STRING DEFAULT 'auxia-reporting';
DECLARE v5_18_dataset STRING DEFAULT 'temp_holley_v5_18';

-- Production dataset (guarded deployment — shared table name for both audiences)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_vehicle_recommendations';

-- Deployment flag (SAFETY: default FALSE — never touch production)
DECLARE deploy_to_production BOOL DEFAULT FALSE;

-- Backup suffix (timestamp for snapshot copies)
DECLARE backup_suffix STRING DEFAULT FORMAT_TIMESTAMP('%Y_%m_%d_%H%M%S', CURRENT_TIMESTAMP());

-- Signal window: events table last 365 days
DECLARE signal_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE signal_window_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY);

-- Fixed boundary used only for bestseller construction (splits hist vs recent order counts so
-- the same order can't contribute to both halves of the 365d bestseller window).
DECLARE recent_boundary DATE DEFAULT DATE '2025-09-01';

-- Year prefilter for import_orders string-date queries (bytes optimization).
-- Kept wide to cover lifetime purchase exclusion.
DECLARE min_prefilter_year INT64 DEFAULT 2000;
DECLARE max_prefilter_year INT64 DEFAULT EXTRACT(YEAR FROM CURRENT_DATE());

-- Pricing / filtering (V5.19 matches V5.18's $50 floor — locked contract item #8)
DECLARE min_price FLOAT64 DEFAULT 50.0;

-- Signal weights (tunable)
DECLARE w_cart       FLOAT64 DEFAULT 10.0;
DECLARE w_view       FLOAT64 DEFAULT 5.0;
DECLARE w_bestseller FLOAT64 DEFAULT 1.0;

-- Decay tau in days (tunable)
DECLARE tau_cart FLOAT64 DEFAULT 7.0;
DECLARE tau_view FLOAT64 DEFAULT 3.0;
-- tau_bestseller is effectively infinite (no decay applied)

-- Selection / diversity
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE required_recs INT64 DEFAULT 4;
DECLARE min_required_recs INT64 DEFAULT 1;

-- Flow-safe browse exclusion window (locked design decision)
DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;

-- Related-item graph thresholds
DECLARE min_co_purchase_support INT64 DEFAULT 3;
DECLARE min_seed_buyer_count INT64 DEFAULT 5;

-- Seed weights (initial implementation defaults; tunable)
DECLARE w_purchase_seed FLOAT64 DEFAULT 3.0;
DECLARE w_cart_seed     FLOAT64 DEFAULT 2.0;
DECLARE w_view_seed     FLOAT64 DEFAULT 1.0;

-- Seed recency decay in days
DECLARE tau_purchase_seed FLOAT64 DEFAULT 90.0;
DECLARE tau_cart_seed     FLOAT64 DEFAULT 14.0;
DECLARE tau_view_seed     FLOAT64 DEFAULT 30.0;

-- Related-item path is the primary source; its persisted scores must stay above the
-- backup floor path so rec*_score ordering matches the actual rank precedence.
DECLARE related_score_offset FLOAT64 DEFAULT 0.0;

-- Bestseller fallback size
DECLARE top_n_bestsellers INT64 DEFAULT 20;

-- Monitoring thresholds
DECLARE min_noymm_users INT64 DEFAULT 500000;
DECLARE min_final_users INT64 DEFAULT 150000;

-- Table names
DECLARE tbl_noymm_users       STRING DEFAULT FORMAT('`%s.%s.no_ymm_users`', target_project, target_dataset);
DECLARE tbl_ymm_users         STRING DEFAULT FORMAT('`%s.%s.ymm_users_for_exclusion`', target_project, target_dataset);
DECLARE tbl_staged_signals    STRING DEFAULT FORMAT('`%s.%s.staged_signals`', target_project, target_dataset);
DECLARE tbl_sku_prices        STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images        STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_skus     STRING DEFAULT FORMAT('`%s.%s.eligible_skus`', target_project, target_dataset);
DECLARE tbl_bestsellers       STRING DEFAULT FORMAT('`%s.%s.bestsellers`', target_project, target_dataset);
DECLARE tbl_purchase_history  STRING DEFAULT FORMAT('`%s.%s.user_purchase_history`', target_project, target_dataset);
DECLARE tbl_purchase_excl     STRING DEFAULT FORMAT('`%s.%s.user_purchased_lifetime`', target_project, target_dataset);
DECLARE tbl_co_purchase_graph STRING DEFAULT FORMAT('`%s.%s.co_purchase_graph`', target_project, target_dataset);
DECLARE tbl_active_cart       STRING DEFAULT FORMAT('`%s.%s.active_cart_context`', target_project, target_dataset);
DECLARE tbl_recent_browse     STRING DEFAULT FORMAT('`%s.%s.recent_browse_context`', target_project, target_dataset);
DECLARE tbl_seed_skus         STRING DEFAULT FORMAT('`%s.%s.seed_sku_per_user`', target_project, target_dataset);
DECLARE tbl_related_pool      STRING DEFAULT FORMAT('`%s.%s.related_candidate_pool`', target_project, target_dataset);
DECLARE tbl_related_filtered  STRING DEFAULT FORMAT('`%s.%s.related_filtered`', target_project, target_dataset);
DECLARE tbl_related_ranked    STRING DEFAULT FORMAT('`%s.%s.related_ranked`', target_project, target_dataset);
DECLARE tbl_floor_scored      STRING DEFAULT FORMAT('`%s.%s.floor_scored_candidates`', target_project, target_dataset);
DECLARE tbl_floor_filtered    STRING DEFAULT FORMAT('`%s.%s.floor_filtered`', target_project, target_dataset);
DECLARE tbl_floor_ranked      STRING DEFAULT FORMAT('`%s.%s.floor_ranked`', target_project, target_dataset);
DECLARE tbl_ranked            STRING DEFAULT FORMAT('`%s.%s.ranked_recommendations`', target_project, target_dataset);
DECLARE tbl_final_nf          STRING DEFAULT FORMAT('`%s.%s.final_non_fitment_intermediate`', target_project, target_dataset);
DECLARE tbl_fitment_snapshot  STRING DEFAULT FORMAT('`%s.%s.fitment_source_snapshot`', target_project, target_dataset);
DECLARE tbl_final             STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);

-- Execution timing
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- Row count used to assert V5.18 staging is populated before snapshot
DECLARE v5_18_row_count INT64;

-- Keep related-item scores above the floor path even if floor weights change.
SET related_score_offset = w_cart + w_view + w_bestseller + 1.0;

-- ====================================================================================
-- PRE-STEP: SNAPSHOT V5.18 FITMENT STAGING ONCE
-- ====================================================================================
-- Snapshot once up front so every downstream read in this run sees the same fitment slice.
-- This closes the Step 0a vs Step 3.5 race where V5.18 could be re-run between reads.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
SELECT COUNT(*) FROM `%s.%s.final_vehicle_recommendations`
""", v5_18_project, v5_18_dataset) INTO v5_18_row_count;

IF v5_18_row_count = 0 THEN
  RAISE USING MESSAGE = 'V5.18 fitment staging is empty — run V5.18 before V5.19';
END IF;

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
SELECT * FROM `%s.%s.final_vehicle_recommendations`
""", tbl_fitment_snapshot, v5_18_project, v5_18_dataset);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Pre-step] Fitment snapshot (%d rows): %d seconds',
  v5_18_row_count,
  TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 0: USER UNIVERSE (YMM-for-exclusion FIRST, then No-YMM anti-joined on email)
-- ====================================================================================
-- Build order matters for the disjoint invariant:
--   0a. ymm_users_for_exclusion: every email that has a complete YMM on ANY user_id.
--       Matches v5.18's user universe.
--   0b. no_ymm_users: user_ids where THAT user_id has incomplete YMM, AND the email
--       never appears with complete YMM on any other user_id (anti-join on email).
--       This guarantees v5.19 non-fitment rows are disjoint from v5.18 fitment rows
--       at the email level, not merely at the user_id level.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 0a: ymm_users_for_exclusion — emails that will appear in the fitment slice.
-- Union of:
--   (i)  emails with at least one complete-YMM user_id in current attributes, and
--   (ii) emails currently present in the snapshotted fitment output.
-- Reason (ii) matters: V5.18 snapshots are produced asynchronously on their own
-- cycle, so an email that had complete YMM at V5.18 time may have since lost that
-- attribute (update_timestamp moved, user_properties nulled, etc.). Without (ii),
-- such an email would be classified as no-YMM and produce a non-fitment row
-- alongside the still-present fitment row, violating the email-level disjoint
-- invariant.
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
),
current_ymm_emails AS (
  SELECT DISTINCT email_lower
  FROM pivoted
  WHERE email_lower IS NOT NULL
    AND v1_year IS NOT NULL
    AND SAFE_CAST(v1_year AS INT64) IS NOT NULL
    AND v1_make IS NOT NULL
    AND v1_model IS NOT NULL
),
fitment_snapshot_emails AS (
  SELECT DISTINCT email_lower
  FROM %s
  WHERE email_lower IS NOT NULL
)
SELECT email_lower FROM current_ymm_emails
UNION DISTINCT
SELECT email_lower FROM fitment_snapshot_emails;
""", tbl_ymm_users, tbl_fitment_snapshot);

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
-- Reuses v5.18 staged_events extraction pattern (prod(uct)?id, items_N.productid, skus_N).
-- Note: purchase_recent is still extracted here — used for lifetime purchase exclusion
-- (Step 2) and bestseller construction (Step 1.5). It is NOT used in scoring (Step 3).
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
WHERE sku IS NOT NULL AND signal_type IS NOT NULL;
""", tbl_staged_signals)
USING signal_window_start AS signal_window_start, signal_window_end AS signal_window_end;

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
-- STEP 1.3: ELIGIBLE SKUS (price floor, HTTPS image, refurb/commodity exclusions)
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
SELECT FORMAT('[Step 1.3] Eligible SKUs: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'eligible_skus' AS table_name, COUNT(*) AS row_count
FROM %s
""", tbl_eligible_skus);

-- ====================================================================================
-- STEP 1.4: BESTSELLERS (top-N globally by order count in last 365 days)
-- ====================================================================================
-- Combines historical (import_orders < recent_boundary) and recent (events, >= recent_boundary)
-- order counts so the same order never double-contributes. Keeps only SKUs that pass
-- eligibility.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH hist_365d AS (
  -- Historical sliver of last-365d window: trailing 365d AND strictly before recent_boundary.
  -- Non-overlapping with recent_365d (events post-recent_boundary).
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
SELECT FORMAT('[Step 1.4] Bestsellers: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 2: PURCHASE HISTORY + LIFETIME PURCHASE EXCLUSION
-- ====================================================================================
-- Shared purchase-history source for:
--   - lifetime exclusion
--   - purchase seeds
--   - co-purchase graph construction
--
-- Purchase history remains authoritative at the email level (import_orders joined on
-- email_lower), then is expanded back onto the no-YMM user_ids under that email so the
-- downstream ranking tables can stay user_id-aware like the current pipeline.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku_norm AS
WITH noymm_emails AS (
  SELECT DISTINCT email_lower
  FROM %s
),
from_events AS (
  SELECT DISTINCT
    u.email_lower,
    u.user_id,
    REGEXP_REPLACE(s.sku, r'([0-9])[BRGP]$', r'\\1') AS sku_norm,
    DATE(s.event_ts) AS purchase_date
  FROM %s s
  JOIN %s u ON s.user_id = u.user_id
  WHERE s.signal_type = 'purchase_recent'
    AND s.user_id IS NOT NULL
    AND s.sku IS NOT NULL
),
from_import AS (
  SELECT DISTINCT
    e.email_lower,
    u.user_id,
    REGEXP_REPLACE(UPPER(TRIM(io.ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku_norm,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', io.ORDER_DATE) AS purchase_date
  FROM `auxia-gcp.data_company_1950.import_orders` io
  JOIN noymm_emails e
    ON LOWER(TRIM(io.SHIP_TO_EMAIL)) = e.email_lower
  JOIN %s u
    ON e.email_lower = u.email_lower
  WHERE io.ITEM IS NOT NULL
    AND io.SHIP_TO_EMAIL IS NOT NULL
    AND NOT (
      io.ITEM LIKE 'EXT-%%' OR
      io.ITEM LIKE 'GIFT-%%' OR
      io.ITEM LIKE 'WARRANTY-%%' OR
      io.ITEM LIKE 'SERVICE-%%' OR
      io.ITEM LIKE 'PREAUTH-%%'
    )
    AND SAFE_CAST(REGEXP_EXTRACT(io.ORDER_DATE, r'\\b(20[0-9]{2})\\b') AS INT64) BETWEEN @min_prefilter_year AND @max_prefilter_year
    AND SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', io.ORDER_DATE) IS NOT NULL
)
SELECT DISTINCT
  email_lower,
  user_id,
  sku_norm,
  purchase_date
FROM (
  SELECT * FROM from_events
  UNION DISTINCT
  SELECT * FROM from_import
)
WHERE sku_norm IS NOT NULL
  AND purchase_date IS NOT NULL;
""", tbl_purchase_history, tbl_noymm_users, tbl_staged_signals, tbl_noymm_users, tbl_noymm_users)
USING min_prefilter_year AS min_prefilter_year, max_prefilter_year AS max_prefilter_year;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2.0] Purchase history: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku_norm AS
SELECT DISTINCT
  user_id,
  REGEXP_REPLACE(
    REGEXP_REPLACE(sku_norm, r'([0-9])[BRGP]$', r'\\1'),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM %s;
""", tbl_purchase_excl, tbl_purchase_history);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2.1] Lifetime purchase exclusion: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.0: FLOW-SAFETY CONTEXTS + CO-PURCHASE GRAPH
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, cart_sku_normalized AS
WITH latest_cart AS (
  SELECT user_id, MAX(event_ts) AS cart_snapshot_ts
  FROM %s
  WHERE signal_type = 'cart'
  GROUP BY user_id
)
SELECT DISTINCT
  u.email_lower,
  s.user_id,
  REGEXP_REPLACE(s.sku, r'([0-9])[BRGP]$', r'\\1') AS cart_sku_normalized,
  lc.cart_snapshot_ts
FROM latest_cart lc
JOIN %s s
  ON s.user_id = lc.user_id
 AND s.event_ts = lc.cart_snapshot_ts
 AND s.signal_type = 'cart'
JOIN %s u ON s.user_id = u.user_id
WHERE s.sku IS NOT NULL;
""", tbl_active_cart, tbl_staged_signals, tbl_staged_signals, tbl_noymm_users);

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, browse_sku_normalized AS
SELECT
  u.email_lower,
  s.user_id,
  REGEXP_REPLACE(s.sku, r'([0-9])[BRGP]$', r'\\1') AS browse_sku_normalized,
  MAX(s.event_ts) AS last_view_ts
FROM %s s
JOIN %s u ON s.user_id = u.user_id
WHERE s.signal_type = 'view'
  AND s.sku IS NOT NULL
  AND DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY) <= @browse_recovery_lookback_days
GROUP BY u.email_lower, s.user_id, browse_sku_normalized;
""", tbl_recent_browse, tbl_staged_signals, tbl_noymm_users)
USING signal_window_end AS signal_window_end,
      browse_recovery_lookback_days AS browse_recovery_lookback_days;

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY seed_sku, related_sku AS
WITH eligible_purchase_history AS (
  SELECT DISTINCT
    email_lower,
    sku_norm
  FROM %s ph
  JOIN %s e
    ON ph.sku_norm = e.sku
),
buyer_counts AS (
  SELECT
    sku_norm,
    COUNT(DISTINCT email_lower) AS buyer_count
  FROM eligible_purchase_history
  GROUP BY sku_norm
),
pair_counts AS (
  SELECT
    a.sku_norm AS seed_sku,
    b.sku_norm AS related_sku,
    COUNT(DISTINCT a.email_lower) AS co_order_count
  FROM eligible_purchase_history a
  JOIN eligible_purchase_history b
    ON a.email_lower = b.email_lower
   AND a.sku_norm != b.sku_norm
  GROUP BY a.sku_norm, b.sku_norm
)
SELECT
  pc.seed_sku,
  pc.related_sku,
  pc.co_order_count,
  sb.buyer_count AS seed_buyer_count,
  rb.buyer_count AS related_buyer_count,
  ROUND(SAFE_DIVIDE(pc.co_order_count, sb.buyer_count) * LOG(1 + pc.co_order_count), 6) AS co_score
FROM pair_counts pc
JOIN buyer_counts sb ON pc.seed_sku = sb.sku_norm
JOIN buyer_counts rb ON pc.related_sku = rb.sku_norm
WHERE pc.co_order_count >= @min_co_purchase_support
  AND sb.buyer_count >= @min_seed_buyer_count;
""", tbl_co_purchase_graph, tbl_purchase_history, tbl_eligible_skus)
USING min_co_purchase_support AS min_co_purchase_support,
      min_seed_buyer_count AS min_seed_buyer_count;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.0] Contexts + co-purchase graph: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.1: SEED EXTRACTION + RELATED CANDIDATE EXPANSION
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, seed_sku AS
WITH purchase_seeds AS (
  SELECT
    email_lower,
    user_id,
    sku_norm AS seed_sku,
    'purchase' AS seed_source,
    MIN(DATE_DIFF(@signal_window_end, purchase_date, DAY)) AS age_days
  FROM %s
  GROUP BY email_lower, user_id, sku_norm
),
cart_seeds AS (
  SELECT
    email_lower,
    user_id,
    cart_sku_normalized AS seed_sku,
    'cart' AS seed_source,
    DATE_DIFF(@signal_window_end, DATE(cart_snapshot_ts), DAY) AS age_days
  FROM %s
),
view_seeds AS (
  SELECT
    u.email_lower,
    s.user_id,
    REGEXP_REPLACE(s.sku, r'([0-9])[BRGP]$', r'\\1') AS seed_sku,
    'view' AS seed_source,
    MIN(DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY)) AS age_days
  FROM %s s
  JOIN %s u ON s.user_id = u.user_id
  WHERE s.signal_type = 'view'
    AND s.sku IS NOT NULL
  GROUP BY u.email_lower, s.user_id, seed_sku
),
all_seeds AS (
  SELECT * FROM purchase_seeds
  UNION ALL
  SELECT * FROM cart_seeds
  UNION ALL
  SELECT * FROM view_seeds
)
SELECT
  email_lower,
  user_id,
  seed_sku,
  seed_source,
  ROUND(
    CASE seed_source
      WHEN 'purchase' THEN @w_purchase_seed * EXP(-age_days / @tau_purchase_seed)
      WHEN 'cart'     THEN @w_cart_seed * EXP(-age_days / @tau_cart_seed)
      WHEN 'view'     THEN @w_view_seed * EXP(-age_days / @tau_view_seed)
      ELSE 0.0
    END,
    6
  ) AS seed_weight
FROM all_seeds
WHERE seed_sku IS NOT NULL;
""", tbl_seed_skus, tbl_purchase_history, tbl_active_cart, tbl_staged_signals, tbl_noymm_users)
USING signal_window_end AS signal_window_end,
      w_purchase_seed AS w_purchase_seed,
      w_cart_seed AS w_cart_seed,
      w_view_seed AS w_view_seed,
      tau_purchase_seed AS tau_purchase_seed,
      tau_cart_seed AS tau_cart_seed,
      tau_view_seed AS tau_view_seed;

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, candidate_sku AS
SELECT
  s.email_lower,
  s.user_id,
  g.related_sku AS candidate_sku,
  e.part_type,
  e.price,
  e.image_url,
  ROUND(MAX(s.seed_weight * g.co_score), 6) AS candidate_score
FROM %s s
JOIN %s g
  ON s.seed_sku = g.seed_sku
JOIN %s e
  ON g.related_sku = e.sku
GROUP BY
  s.email_lower,
  s.user_id,
  g.related_sku,
  e.part_type,
  e.price,
  e.image_url;
""", tbl_related_pool, tbl_seed_skus, tbl_co_purchase_graph, tbl_eligible_skus);

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH filtered AS (
  SELECT
    rp.email_lower,
    rp.user_id,
    rp.candidate_sku AS sku,
    rp.part_type,
    rp.price,
    rp.image_url,
    ROUND(rp.candidate_score, 4) AS final_score,
    REGEXP_REPLACE(
      REGEXP_REPLACE(rp.candidate_sku, r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''),
      r'([0-9])[BRGP]$', r'\\1'
    ) AS base_sku
  FROM %s rp
  LEFT JOIN %s pe
    ON rp.user_id = pe.user_id
   AND REGEXP_REPLACE(
         REGEXP_REPLACE(rp.candidate_sku, r'([0-9])[BRGP]$', r'\\1'),
         r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
       ) = pe.sku_norm
  LEFT JOIN %s ac
    ON rp.user_id = ac.user_id
   AND REGEXP_REPLACE(rp.candidate_sku, r'([0-9])[BRGP]$', r'\\1') = ac.cart_sku_normalized
  LEFT JOIN %s rb
    ON rp.user_id = rb.user_id
   AND REGEXP_REPLACE(rp.candidate_sku, r'([0-9])[BRGP]$', r'\\1') = rb.browse_sku_normalized
  WHERE pe.user_id IS NULL
    AND ac.user_id IS NULL
    AND rb.user_id IS NULL
),
deduped AS (
  SELECT * EXCEPT(rn_base)
  FROM (
    SELECT
      f.*,
      ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku) AS rn_base
    FROM filtered f
  )
  WHERE rn_base = 1
)
SELECT email_lower, user_id, sku, part_type, price, image_url, final_score
FROM deduped;
""", tbl_related_filtered, tbl_related_pool, tbl_purchase_excl, tbl_active_cart, tbl_recent_browse);

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT
  email_lower,
  user_id,
  sku,
  part_type,
  price,
  image_url,
  ROUND(final_score + @related_score_offset, 4) AS final_score,
  1 AS source_tier,
  'related' AS source_family,
  ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score DESC, sku) AS source_rank
FROM %s
QUALIFY source_rank <= @required_recs * 3;
""", tbl_related_ranked, tbl_related_filtered)
USING related_score_offset AS related_score_offset,
      required_recs AS required_recs;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.1] Seed extraction + related expansion: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.2: BACKUP FLOOR PATH (current exact-SKU engine, flow-safe filtered)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH event_signals AS (
  SELECT
    s.user_id,
    s.sku,
    s.signal_type,
    DATE_DIFF(@signal_window_end, DATE(s.event_ts), DAY) AS age_days
  FROM %s s
  JOIN %s u ON s.user_id = u.user_id
  WHERE s.signal_type IN ('view', 'cart')
),
bestseller_signals AS (
  SELECT
    u.user_id,
    b.sku,
    'bestseller' AS signal_type,
    0 AS age_days
  FROM %s u
  CROSS JOIN %s b
),
all_signals AS (
  SELECT * FROM event_signals
  UNION ALL
  SELECT * FROM bestseller_signals
),
per_signal_freshest AS (
  SELECT user_id, sku, signal_type, MIN(age_days) AS age_days
  FROM all_signals
  GROUP BY user_id, sku, signal_type
),
per_signal_scored AS (
  SELECT
    user_id,
    sku,
    signal_type,
    CASE signal_type
      WHEN 'cart'       THEN @w_cart * EXP(-age_days / @tau_cart)
      WHEN 'view'       THEN @w_view * EXP(-age_days / @tau_view)
      WHEN 'bestseller' THEN @w_bestseller
      ELSE 0.0
    END AS signal_score
  FROM per_signal_freshest
),
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
  ROUND(t.final_score, 4) AS final_score
FROM total_score t
JOIN %s u ON t.user_id = u.user_id
JOIN %s e ON t.sku = e.sku;
""", tbl_floor_scored, tbl_staged_signals, tbl_noymm_users, tbl_noymm_users, tbl_bestsellers, tbl_noymm_users, tbl_eligible_skus)
USING signal_window_end AS signal_window_end,
      w_cart AS w_cart,
      w_view AS w_view,
      w_bestseller AS w_bestseller,
      tau_cart AS tau_cart,
      tau_view AS tau_view;

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH filtered AS (
  SELECT
    fs.email_lower,
    fs.user_id,
    fs.sku,
    fs.part_type,
    fs.price,
    fs.image_url,
    fs.final_score,
    REGEXP_REPLACE(
      REGEXP_REPLACE(fs.sku, r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''),
      r'([0-9])[BRGP]$', r'\\1'
    ) AS base_sku
  FROM %s fs
  LEFT JOIN %s pe
    ON fs.user_id = pe.user_id
   AND REGEXP_REPLACE(
         REGEXP_REPLACE(fs.sku, r'([0-9])[BRGP]$', r'\\1'),
         r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
       ) = pe.sku_norm
  LEFT JOIN %s ac
    ON fs.user_id = ac.user_id
   AND REGEXP_REPLACE(fs.sku, r'([0-9])[BRGP]$', r'\\1') = ac.cart_sku_normalized
  LEFT JOIN %s rb
    ON fs.user_id = rb.user_id
   AND REGEXP_REPLACE(fs.sku, r'([0-9])[BRGP]$', r'\\1') = rb.browse_sku_normalized
  WHERE pe.user_id IS NULL
    AND ac.user_id IS NULL
    AND rb.user_id IS NULL
),
deduped AS (
  SELECT * EXCEPT(rn_base)
  FROM (
    SELECT
      f.*,
      ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku) AS rn_base
    FROM filtered f
  )
  WHERE rn_base = 1
)
SELECT email_lower, user_id, sku, part_type, price, image_url, final_score
FROM deduped;
""", tbl_floor_filtered, tbl_floor_scored, tbl_purchase_excl, tbl_active_cart, tbl_recent_browse);

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH primary_ranked AS (
  SELECT
    f.email_lower,
    f.user_id,
    f.sku,
    f.part_type,
    f.price,
    f.image_url,
    f.final_score,
    ROW_NUMBER() OVER (PARTITION BY f.user_id ORDER BY f.final_score DESC, f.sku) AS rn
  FROM %s f
),
primary_selected AS (
  SELECT
    email_lower,
    user_id,
    sku,
    part_type,
    price,
    image_url,
    final_score
  FROM primary_ranked
  WHERE rn <= @required_recs * 3
),
covered_users AS (
  SELECT DISTINCT user_id FROM primary_selected
),
missing_users AS (
  SELECT u.user_id, u.email_lower
  FROM %s u
  LEFT JOIN covered_users cu ON u.user_id = cu.user_id
  WHERE cu.user_id IS NULL
),
fallback_pool AS (
  SELECT
    mu.email_lower,
    mu.user_id,
    b.sku,
    e.part_type,
    e.price,
    e.image_url,
    @w_bestseller AS final_score,
    b.bestseller_rank
  FROM missing_users mu
  CROSS JOIN %s b
  JOIN %s e ON b.sku = e.sku
  LEFT JOIN %s pe
    ON mu.user_id = pe.user_id
   AND REGEXP_REPLACE(b.sku, r'([0-9])[BRGP]$', r'\\1') = pe.sku_norm
  LEFT JOIN %s ac
    ON mu.user_id = ac.user_id
   AND REGEXP_REPLACE(b.sku, r'([0-9])[BRGP]$', r'\\1') = ac.cart_sku_normalized
  LEFT JOIN %s rb
    ON mu.user_id = rb.user_id
   AND REGEXP_REPLACE(b.sku, r'([0-9])[BRGP]$', r'\\1') = rb.browse_sku_normalized
  WHERE pe.user_id IS NULL
    AND ac.user_id IS NULL
    AND rb.user_id IS NULL
),
fallback_selected AS (
  SELECT
    email_lower,
    user_id,
    sku,
    part_type,
    price,
    image_url,
    final_score
  FROM (
    SELECT
      fp.*,
      ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY bestseller_rank, sku) AS rn
    FROM fallback_pool fp
  )
  WHERE rn <= @required_recs * 3
)
SELECT
  email_lower,
  user_id,
  sku,
  part_type,
  price,
  image_url,
  final_score,
  2 AS source_tier,
  'floor' AS source_family
FROM primary_selected
UNION ALL
SELECT
  email_lower,
  user_id,
  sku,
  part_type,
  price,
  image_url,
  final_score,
  2 AS source_tier,
  'floor' AS source_family
FROM fallback_selected;
""", tbl_floor_ranked, tbl_floor_filtered, tbl_noymm_users, tbl_bestsellers, tbl_eligible_skus, tbl_purchase_excl, tbl_active_cart, tbl_recent_browse)
USING required_recs AS required_recs,
      w_bestseller AS w_bestseller;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.2] Backup floor path: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.3: MERGE RELATED PRIMARY + FLOOR BACKFILL
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH combined AS (
  SELECT email_lower, user_id, sku, part_type, price, image_url, final_score, source_tier
  FROM %s
  UNION ALL
  SELECT email_lower, user_id, sku, part_type, price, image_url, final_score, source_tier
  FROM %s
),
normalized AS (
  SELECT
    c.*,
    REGEXP_REPLACE(
      REGEXP_REPLACE(c.sku, r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''),
      r'([0-9])[BRGP]$', r'\\1'
    ) AS base_sku
  FROM combined c
),
deduped AS (
  SELECT * EXCEPT(rn_base)
  FROM (
    SELECT
      n.*,
      ROW_NUMBER() OVER (
        PARTITION BY user_id, base_sku
        ORDER BY source_tier ASC, final_score DESC, sku
      ) AS rn_base
    FROM normalized n
  )
  WHERE rn_base = 1
),
diversified AS (
  SELECT
    d.*,
    ROW_NUMBER() OVER (
      PARTITION BY user_id, part_type
      ORDER BY source_tier ASC, final_score DESC, sku
    ) AS rn_parttype
  FROM deduped d
),
ranked AS (
  SELECT
    email_lower,
    user_id,
    sku,
    part_type,
    price,
    image_url,
    final_score,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY source_tier ASC, final_score DESC, sku
    ) AS rn,
    COUNT(*) OVER (PARTITION BY user_id) AS user_rec_count
  FROM diversified
  WHERE rn_parttype <= @max_parttype_per_user
)
SELECT
  email_lower,
  user_id,
  sku,
  part_type,
  price,
  image_url,
  final_score,
  rn
FROM ranked
WHERE user_rec_count >= @min_required_recs
  AND rn <= @required_recs;
""", tbl_ranked, tbl_related_ranked, tbl_floor_ranked)
USING max_parttype_per_user AS max_parttype_per_user,
      min_required_recs AS min_required_recs,
      required_recs AS required_recs;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.3] Merged ranking: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.4: PIVOT NON-FITMENT INTO V5.18 SHARED SCHEMA
-- ====================================================================================
-- Output schema MUST match V5.18 column-for-column. Non-fitment-specific literals:
--   v1_year  = v1_make = v1_model = 'UNKNOWN'     (locked contract #5)
--   rec*_type                                = 'non_fitment'    (locked contract #3)
--   rec*_pop_source                          = NULL             (V5.18-only field)
--   engagement_tier                          = NULL             (V5.18-only field)
--   fitment_count                            = NULL             (V5.18-only field)
--   generated_at, pipeline_version           — placeholders; overwritten at UNION (Step 3.6)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH
-- Choose one user_id per email_lower when the same email has multiple user_ids.
-- user_id-level aggregates (rec_count, total_score) are materialized in a dedicated
-- CTE so the ROW_NUMBER's ORDER BY can reference them as plain columns — BigQuery
-- forbids analytic functions inside another window's ORDER BY.
user_agg AS (
  SELECT
    email_lower,
    user_id,
    SUM(final_score) AS user_total_score,
    COUNT(*) AS user_rec_count
  FROM %s
  GROUP BY email_lower, user_id
),
selected_user AS (
  SELECT email_lower, user_id
  FROM (
    SELECT
      email_lower, user_id,
      ROW_NUMBER() OVER (
        PARTITION BY email_lower
        ORDER BY
          user_rec_count DESC,
          user_total_score DESC,
          user_id
      ) AS pick_rn
    FROM user_agg
  )
  WHERE pick_rn = 1
),
ranked_selected AS (
  SELECT r.*
  FROM %s r
  JOIN selected_user su
    ON r.email_lower = su.email_lower
   AND r.user_id = su.user_id
)
SELECT
  r.email_lower,
  CAST('UNKNOWN' AS STRING) AS v1_year,
  CAST('UNKNOWN' AS STRING) AS v1_make,
  CAST('UNKNOWN' AS STRING) AS v1_model,
  MAX(CASE WHEN rn = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rn = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN rn = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN rn = 1 THEN image_url END) AS rec1_image,
  -- rec*_type is gated on the slot being populated so null-slot rows don't violate
  -- the slot_consistency invariant (rec_part_N IS NULL ⇒ recN_* all NULL).
  MAX(CASE WHEN rn = 1 THEN CAST('non_fitment' AS STRING) END) AS rec1_type,
  CAST(NULL AS STRING) AS rec1_pop_source,
  MAX(CASE WHEN rn = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rn = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN rn = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN rn = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN rn = 2 THEN CAST('non_fitment' AS STRING) END) AS rec2_type,
  CAST(NULL AS STRING) AS rec2_pop_source,
  MAX(CASE WHEN rn = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rn = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN rn = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN rn = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN rn = 3 THEN CAST('non_fitment' AS STRING) END) AS rec3_type,
  CAST(NULL AS STRING) AS rec3_pop_source,
  MAX(CASE WHEN rn = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rn = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN rn = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN rn = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN rn = 4 THEN CAST('non_fitment' AS STRING) END) AS rec4_type,
  CAST(NULL AS STRING) AS rec4_pop_source,
  CAST(NULL AS STRING) AS engagement_tier,
  CAST(NULL AS INT64) AS fitment_count,
  -- generated_at / pipeline_version are re-stamped at UNION time (Step 3.6)
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM ranked_selected r
GROUP BY r.email_lower
HAVING COUNT(*) >= @min_required_recs;
""", tbl_final_nf, tbl_ranked, tbl_ranked)
USING pipeline_version AS pipeline_version, min_required_recs AS min_required_recs;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.4] Non-fitment pivot: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.5: FITMENT SNAPSHOT REUSE
-- ====================================================================================
-- The snapshot was materialized once before Step 0 so Step 0a and the final UNION read the
-- same fitment slice. Recheck row count here only as a guard before unioning.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
SELECT COUNT(*) FROM %s
""", tbl_fitment_snapshot) INTO v5_18_row_count;

IF v5_18_row_count = 0 THEN
  RAISE USING MESSAGE = 'V5.18 fitment snapshot is empty — snapshot pre-step failed';
END IF;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.5] Fitment snapshot reuse (%d rows): %d seconds',
  v5_18_row_count,
  TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3.6: UNION ALL → SHARED FINAL TABLE
-- ====================================================================================
-- Locked contract #10: both row types are stamped with a FRESH shared-table run timestamp
-- at UNION time. Fitment rows do NOT preserve their original V5.18 build timestamp. Using
-- `pipeline_start` guarantees a single identical timestamp across every row in the table
-- (matches the post-deploy reporting expectation at
-- sql/recommendations/v5_18_fitment_recommendations.sql:1086).
--
-- pipeline_version is overwritten to 'v5.19' for EVERY row. The snapshot's 'v5.18' tag
-- is dropped so the shared table satisfies COUNT(DISTINCT pipeline_version) = 1.
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
SELECT
  email_lower,
  v1_year, v1_make, v1_model,
  rec_part_1, rec1_price, rec1_score, rec1_image, rec1_type, rec1_pop_source,
  rec_part_2, rec2_price, rec2_score, rec2_image, rec2_type, rec2_pop_source,
  rec_part_3, rec3_price, rec3_score, rec3_image, rec3_type, rec3_pop_source,
  rec_part_4, rec4_price, rec4_score, rec4_image, rec4_type, rec4_pop_source,
  engagement_tier,
  fitment_count,
  @pipeline_start AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s
UNION ALL
SELECT
  email_lower,
  v1_year, v1_make, v1_model,
  rec_part_1, rec1_price, rec1_score, rec1_image, rec1_type, rec1_pop_source,
  rec_part_2, rec2_price, rec2_score, rec2_image, rec2_type, rec2_pop_source,
  rec_part_3, rec3_price, rec3_score, rec3_image, rec3_type, rec3_pop_source,
  rec_part_4, rec4_price, rec4_score, rec4_image, rec4_type, rec4_pop_source,
  engagement_tier,
  fitment_count,
  @pipeline_start AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s
""", tbl_final, tbl_fitment_snapshot, tbl_final_nf)
USING pipeline_start AS pipeline_start, pipeline_version AS pipeline_version;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3.6] UNION ALL → shared final table: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final Output Checks (quick in-pipeline sanity; full gates in qa_checks.sql)
-- ====================================================================================

EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_vehicle_recommendations' AS table_name,
  COUNT(*) AS total_rows,
  COUNTIF(rec1_type = 'fitment')     AS fitment_rows,
  COUNTIF(rec1_type = 'non_fitment') AS non_fitment_rows,
  CASE WHEN COUNTIF(rec1_type = 'non_fitment') >= @min_final_users
       THEN 'OK' ELSE 'WARNING: Low non-fitment user count' END AS status
FROM %s
""", tbl_final)
USING min_final_users AS min_final_users;

-- Disjointness: 0 emails should appear in both audience partitions
EXECUTE IMMEDIATE FORMAT("""
SELECT 'disjointness_check' AS check_name,
  COUNT(*) AS violations
FROM (
  SELECT email_lower
  FROM %s
  GROUP BY email_lower
  HAVING COUNT(DISTINCT rec1_type) > 1
)
""", tbl_final);

-- Single pipeline_version: shared table must carry exactly one release tag
EXECUTE IMMEDIATE FORMAT("""
SELECT 'single_pipeline_version' AS check_name,
  COUNT(DISTINCT pipeline_version) AS distinct_versions,
  ARRAY_AGG(DISTINCT pipeline_version) AS versions_present
FROM %s
""", tbl_final);

-- Price floor (applies to both audiences)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_floor_check' AS check_name,
  COUNTIF(rec1_price < @min_price OR rec2_price < @min_price OR rec3_price < @min_price OR rec4_price < @min_price) AS violations,
  @min_price AS min_price
FROM %s
""", tbl_final)
USING min_price AS min_price;

-- Duplicate SKUs within a row (applies to both audiences)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'duplicate_check' AS check_name,
  COUNTIF(
    (rec_part_2 IS NOT NULL AND rec_part_1 = rec_part_2) OR
    (rec_part_3 IS NOT NULL AND (rec_part_1 = rec_part_3 OR rec_part_2 = rec_part_3)) OR
    (rec_part_4 IS NOT NULL AND (rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4))
  ) AS users_with_duplicates
FROM %s
""", tbl_final);

-- Score ordering within a row (applies to both audiences; scores ordered within audience)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'score_ordering_check' AS check_name,
  COUNTIF(NOT (
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) AS violations
FROM %s
""", tbl_final);

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
-- Deploys the SHARED final_vehicle_recommendations table (fitment + non-fitment rows).
-- ====================================================================================

IF deploy_to_production THEN
  SET step_start = CURRENT_TIMESTAMP();

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s`
  COPY `%s.%s.final_vehicle_recommendations`
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
  SELECT FORMAT('[SKIP] Production deployment skipped (deploy_to_production = FALSE). Output in %s.%s.final_vehicle_recommendations',
    target_project, target_dataset) AS log;

END IF;
