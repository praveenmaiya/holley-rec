-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.18 (Fitment-Only + Popularity-Only)
-- --------------------------------------------------------------------------------------------------
-- Based on V5.17 (3-Tier Segment Fallback), with the following changes:
--   1. All 4 slots fitment-only (no universal candidates)
--   2. Popularity-only scoring (remove intent score entirely)
--   3. Remove intent scoring (staged_events still extracts all events for price/image)
--   4. Price floor: $50 (unchanged from v5.17)
--   5. Minimum 3 recs per user (was 4), up to 4
--   6. PartType diversity cap: 999 → 2 (force category diversity)
--   7. Binary engagement tier (hot/cold) for analysis
--   8. Email consent filter: intentionally not applied (all fitment users included)
--
-- Why:
--   - Client flagged universal (non-fitment) parts appearing for a golf cart
--   - Supervisor directed simplifying scoring to orders-only popularity
--   - Keep 3-tier popularity fallback (v5.17's best feature)
--
-- Fallback Logic (unchanged from v5.17):
--   IF segment_orders >= 5: use segment_popularity_score (weight 10.0)
--   ELIF make_orders >= 20: use make_popularity_score (weight 8.0)
--   ELSE: use global_popularity_score (weight 2.0)
--
-- Data Sources (Combined):
--   - Historical (Jan 1, 2024 - Aug 31, 2025): import_orders
--   - Recent (Sep 1+): ingestion_unified_schema_incremental (all events for data, orders for scoring)
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_18_fitment_recommendations.sql
-- ==================================================================================================

-- Pipeline version
DECLARE pipeline_version STRING DEFAULT 'v5.18';

-- Working dataset (intermediate tables)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_18';

-- Production dataset (final deployment)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_vehicle_recommendations';

-- Deployment flag (set to FALSE for backtest, TRUE for production)
DECLARE deploy_to_production BOOL DEFAULT FALSE;

-- Backup suffix (current date)
DECLARE backup_suffix STRING DEFAULT FORMAT_DATE('%Y_%m_%d', CURRENT_DATE());

-- Intent window: Fixed Sep 1 boundary to current date
DECLARE intent_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';

-- Historical popularity: Everything before Sep 1 (import_orders)
DECLARE pop_hist_end     DATE DEFAULT DATE '2025-08-31';
DECLARE pop_hist_start   DATE DEFAULT DATE '2024-01-01';  -- V5.18: extended from 2025-04-16

DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE allow_price_fallback BOOL DEFAULT TRUE;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_parttype_per_user INT64 DEFAULT 2;            -- V5.18: was 999
DECLARE required_recs INT64 DEFAULT 4;                    -- Max recs per user
DECLARE min_required_recs INT64 DEFAULT 3;                -- V5.18: min to include user (was 4)
DECLARE require_purchase_signal BOOL DEFAULT TRUE;         -- Enforce purchase-backed recommendations
DECLARE min_users_with_v1 INT64 DEFAULT 400000;           -- Monitoring threshold
DECLARE min_final_users INT64 DEFAULT 400000;             -- Keep aligned with QA expectation

-- V5.17: 3-tier popularity configuration (unchanged)
DECLARE min_segment_orders INT64 DEFAULT 2;
DECLARE segment_popularity_weight FLOAT64 DEFAULT 10.0;
DECLARE min_segment_for_use INT64 DEFAULT 5;
DECLARE min_make_for_use INT64 DEFAULT 20;
DECLARE make_popularity_weight FLOAT64 DEFAULT 8.0;

-- Year range for ORDER_DATE string pre-filter (avoids PARSE_DATE on every row)
-- Contiguous range from pop_hist_start year to current year — no gaps possible
DECLARE min_prefilter_year INT64 DEFAULT EXTRACT(YEAR FROM pop_hist_start);
DECLARE max_prefilter_year INT64 DEFAULT EXTRACT(YEAR FROM CURRENT_DATE());

-- Table names
DECLARE tbl_users STRING DEFAULT FORMAT('`%s.%s.users_with_v1_vehicles`', target_project, target_dataset);
DECLARE tbl_staged_events STRING DEFAULT FORMAT('`%s.%s.staged_events`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_parts STRING DEFAULT FORMAT('`%s.%s.eligible_parts`', target_project, target_dataset);
DECLARE tbl_vehicle_generation STRING DEFAULT FORMAT('`%s.%s.vehicle_generation_fitment`', target_project, target_dataset);
DECLARE tbl_segment_popularity STRING DEFAULT FORMAT('`%s.%s.segment_popularity`', target_project, target_dataset);
DECLARE tbl_make_popularity STRING DEFAULT FORMAT('`%s.%s.make_popularity`', target_project, target_dataset);
DECLARE tbl_global_popularity STRING DEFAULT FORMAT('`%s.%s.global_popularity_fallback`', target_project, target_dataset);
DECLARE tbl_import_orders_filtered STRING DEFAULT FORMAT('`%s.%s.import_orders_filtered`', target_project, target_dataset);
DECLARE tbl_purchase_excl STRING DEFAULT FORMAT('`%s.%s.user_purchased_parts_365d`', target_project, target_dataset);
DECLARE tbl_scored STRING DEFAULT FORMAT('`%s.%s.scored_recommendations`', target_project, target_dataset);
DECLARE tbl_diversity STRING DEFAULT FORMAT('`%s.%s.diversity_filtered`', target_project, target_dataset);
DECLARE tbl_ranked STRING DEFAULT FORMAT('`%s.%s.ranked_recommendations`', target_project, target_dataset);
DECLARE tbl_final STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);

-- Execution timing
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- ====================================================================================
-- STEP 0: USERS WITH V1 VEHICLES
-- ====================================================================================
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
  user_id,
  email_lower,
  UPPER(email_lower) AS email_upper,
  v1_year,
  SAFE_CAST(v1_year AS INT64) AS v1_year_int,
  v1_make,
  v1_model
FROM pivoted
WHERE email_lower IS NOT NULL
  AND v1_year IS NOT NULL
  AND v1_make IS NOT NULL
  AND v1_model IS NOT NULL;
""", tbl_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0] Users with V1 vehicles: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'users_with_v1_vehicles' AS table_name, COUNT(*) AS row_count,
  COUNT(DISTINCT CONCAT(v1_make, '/', v1_model)) AS unique_segments,
  CASE WHEN COUNT(*) >= @min_users_with_v1 THEN 'OK' ELSE 'WARNING: Low user count' END AS status
FROM %s
""", tbl_users)
USING min_users_with_v1 AS min_users_with_v1;

-- ====================================================================================
-- STEP 1: STAGED EVENTS (All events for price/image; orders used for scoring)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
PARTITION BY DATE(event_ts)
CLUSTER BY user_id, sku AS
WITH bounds AS (
  SELECT @intent_window_start AS start_date, @intent_window_end AS end_date
),
raw_events AS (
  SELECT
    t.user_id,
    t.client_event_timestamp AS event_ts,
    UPPER(t.event_name) AS event_name,
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
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep, bounds b
  WHERE DATE(t.client_event_timestamp) BETWEEN b.start_date AND b.end_date
    AND UPPER(t.event_name) IN ('VIEWED PRODUCT','ORDERED PRODUCT','CART UPDATE','PLACED ORDER','CONSUMER WEBSITE ORDER')
),
prepared AS (
  SELECT
    user_id,
    sku,
    event_ts,
    event_name,
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
    item_idx,
    MAX(IF(price_idx IS NULL, price_val, NULL)) AS price_main,
    MAX(IF(price_idx IS NOT NULL AND price_idx = item_idx, price_val, NULL)) AS price_item,
    MAX(IF(image_idx IS NULL, image_val, NULL)) AS image_main,
    MAX(IF(image_idx IS NOT NULL AND image_idx = item_idx, image_val, NULL)) AS image_item
  FROM prepared
  GROUP BY user_id, event_ts, event_name, item_idx
)
SELECT
  user_id,
  sku,
  event_ts,
  event_name,
  COALESCE(price_item, price_main) AS price,
  COALESCE(image_item, image_main) AS image_url_raw
FROM aggregated
WHERE sku IS NOT NULL;
""", tbl_staged_events)
USING intent_window_start AS intent_window_start, intent_window_end AS intent_window_end;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1] Staged events: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'staged_events' AS table_name, COUNT(*) AS row_count,
  CASE WHEN COUNT(*) >= 100000 THEN 'OK' ELSE 'WARNING: Low event count' END AS status
FROM %s
""", tbl_staged_events);

-- -----------------------------------------------------------------------------------
-- STEP 1.1: SKU PRICES (No change)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, MAX(price) AS price, COUNT(*) AS observations
FROM %s
WHERE sku IS NOT NULL
GROUP BY sku;
""", tbl_sku_prices, tbl_staged_events);

-- -----------------------------------------------------------------------------------
-- STEP 1.2: SKU IMAGES (No change)
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
""", tbl_sku_images, tbl_staged_events);

-- -----------------------------------------------------------------------------------
-- STEP 1.3: ELIGIBLE PARTS (Fitment Only - price floor $50)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY make, model, year, sku AS
WITH refurb AS (
  SELECT DISTINCT UPPER(TRIM(PartNumber)) AS sku
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL AND LOWER(Tags) LIKE '%%refurbished%%'
),
fitment AS (
  SELECT
    SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku,
    COALESCE(cat.PartType, 'UNKNOWN') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat
    ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
),
fitment_filtered AS (
  SELECT f.*, img.image_url, COALESCE(price.price, @min_price) AS price
  FROM fitment f
  LEFT JOIN %s img ON f.sku = img.sku
  LEFT JOIN %s price ON f.sku = price.sku
  LEFT JOIN refurb r ON f.sku = r.sku
  WHERE r.sku IS NULL
    AND NOT (
      f.sku LIKE 'EXT-%%' OR
      f.sku LIKE 'GIFT-%%' OR
      f.sku LIKE 'WARRANTY-%%' OR
      f.sku LIKE 'SERVICE-%%' OR
      f.sku LIKE 'PREAUTH-%%'
    )
    AND COALESCE(price.price, @min_price) >= @min_price
    AND (price.price IS NOT NULL OR @allow_price_fallback)
    AND img.image_url IS NOT NULL
    AND img.image_url LIKE 'https://%%'
    AND NOT (
      f.part_type LIKE '%%Gasket%%'
      OR f.part_type LIKE '%%Decal%%'
      OR f.part_type LIKE '%%Key%%'
      OR f.part_type LIKE '%%Washer%%'
      OR f.part_type LIKE '%%Clamp%%'
      OR (f.part_type LIKE '%%Bolt%%'
          AND f.part_type NOT IN ('Engine Cylinder Head Bolt', 'Engine Bolt Kit'))
      OR (f.part_type LIKE '%%Cap%%'
          AND f.part_type NOT LIKE '%%Distributor Cap%%'
          AND f.part_type NOT IN ('Wheel Hub Cap', 'Wheel Cap Set'))
    )
    AND NOT (f.part_type = 'UNKNOWN' AND COALESCE(price.price, @min_price) < 3000)
),
-- Quality gate: require >= 4 eligible parts per vehicle generation.
-- Intentionally stricter than min_required_recs (3) — ensures enough candidate
-- diversity for each vehicle before any enter the scoring pipeline.
per_generation AS (
  SELECT year, make, model, COUNT(*) AS part_count
  FROM fitment_filtered
  GROUP BY year, make, model
  HAVING part_count >= 4
)
SELECT ff.*
FROM fitment_filtered ff
JOIN per_generation pg USING (year, make, model);
""", tbl_eligible_parts, tbl_sku_images, tbl_sku_prices)
USING min_price AS min_price, allow_price_fallback AS allow_price_fallback;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.3] Eligible fitment parts: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'eligible_fitment_parts' AS table_name, COUNT(*) AS row_count,
  COUNT(DISTINCT sku) AS unique_skus,
  CASE WHEN COUNT(*) >= 1000 THEN 'OK' ELSE 'WARNING: Low eligible parts' END AS status
FROM %s
""", tbl_eligible_parts);

-- V5.18: Step 1.3b (Universal parts) REMOVED — fitment-only pipeline

-- -----------------------------------------------------------------------------------
-- STEP 1.4: VEHICLE GENERATION FITMENT (Reporting, no change)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY make, model AS
SELECT
  year AS year_from,
  year AS year_to,
  make,
  model,
  ARRAY_AGG(sku ORDER BY sku) AS parts,
  COUNT(*) AS total_count
FROM %s
GROUP BY year, make, model;
""", tbl_vehicle_generation, tbl_eligible_parts);

-- ====================================================================================
-- STEP 1.5: IMPORT ORDERS (Consolidated Scan, no change from v5.17)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku, email_lower AS
WITH date_bounds AS (
  SELECT
    @pop_hist_start AS popularity_start,
    @pop_hist_end AS popularity_end,
    DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AS exclusion_start,
    @intent_window_end AS exclusion_end
),
prefiltered AS (
  SELECT
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku,  -- Normalize variants
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    ORDER_DATE,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
    AND SAFE_CAST(REGEXP_EXTRACT(ORDER_DATE, r'\\b(20[0-9]{2})\\b') AS INT64) BETWEEN @min_prefilter_year AND @max_prefilter_year
)
SELECT
  sku,
  email_lower,
  order_date_parsed,
  CASE WHEN order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end THEN 1 ELSE 0 END AS is_popularity_window,
  CASE WHEN order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end THEN 1 ELSE 0 END AS is_exclusion_window
FROM prefiltered, date_bounds
WHERE order_date_parsed IS NOT NULL
  AND (
    order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end
    OR order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end
  );
""", tbl_import_orders_filtered)
USING pop_hist_start AS pop_hist_start, pop_hist_end AS pop_hist_end,
      intent_window_end AS intent_window_end, purchase_window_days AS purchase_window_days,
      min_prefilter_year AS min_prefilter_year, max_prefilter_year AS max_prefilter_year;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.5] Import orders filtered: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'import_orders_filtered' AS table_name,
  COUNT(*) AS total_rows,
  COUNTIF(is_popularity_window = 1) AS popularity_rows,
  COUNTIF(is_exclusion_window = 1) AS exclusion_rows
FROM %s
""", tbl_import_orders_filtered);

-- ====================================================================================
-- STEP 2: SCORING (V5.18: Popularity-only with 3-tier fallback, no intent)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- V5.18: Step 2.1 (Intent scores) REMOVED — popularity-only scoring

-- -----------------------------------------------------------------------------------
-- STEP 2.2: SEGMENT POPULARITY (No change from v5.17 — combines historical + recent)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY v1_make, v1_model, sku AS
WITH
-- Historical segment purchases (import_orders: Jan 1, 2024 - Aug 31, 2025)
historical_segment AS (
  SELECT
    uv.v1_make,
    uv.v1_model,
    io.sku,
    COUNT(*) AS order_count
  FROM %s io
  JOIN %s uv ON io.email_lower = uv.email_lower
  WHERE io.is_popularity_window = 1
  GROUP BY uv.v1_make, uv.v1_model, io.sku
),
-- Recent segment purchases (staged_events orders: Sept 1+)
recent_segment AS (
  SELECT
    uv.v1_make,
    uv.v1_model,
    REGEXP_REPLACE(se.sku, r'([0-9])[BRGP]$', r'\\1') AS sku,  -- Normalize variants
    COUNT(*) AS order_count
  FROM %s se
  JOIN %s uv ON se.user_id = uv.user_id
  WHERE UPPER(se.event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND se.sku IS NOT NULL
  GROUP BY uv.v1_make, uv.v1_model, sku
),
-- Combine both sources
combined_segment AS (
  SELECT
    v1_make,
    v1_model,
    sku,
    SUM(order_count) AS total_segment_orders
  FROM (
    SELECT * FROM historical_segment
    UNION ALL
    SELECT * FROM recent_segment
  )
  GROUP BY v1_make, v1_model, sku
  HAVING SUM(order_count) >= @min_segment_orders
)
SELECT
  v1_make,
  v1_model,
  sku,
  total_segment_orders,
  ROUND(LOG(1 + total_segment_orders) * @segment_popularity_weight, 2) AS segment_popularity_score,
  ROW_NUMBER() OVER (PARTITION BY v1_make, v1_model ORDER BY total_segment_orders DESC) AS rank_in_segment
FROM combined_segment;
""", tbl_segment_popularity, tbl_import_orders_filtered, tbl_users, tbl_staged_events, tbl_users)
USING min_segment_orders AS min_segment_orders, segment_popularity_weight AS segment_popularity_weight;

-- -----------------------------------------------------------------------------------
-- STEP 2.2b: GLOBAL POPULARITY FALLBACK (No change from v5.17)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH historical AS (
  SELECT io.sku, COUNT(*) AS order_count
  FROM %s io
  WHERE io.is_popularity_window = 1
    AND io.email_lower IN (SELECT email_lower FROM %s)
  GROUP BY io.sku
),
recent AS (
  SELECT sku,
         COUNT(*) AS order_count
  FROM %s
  WHERE sku IS NOT NULL
    AND user_id IS NOT NULL
    AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND user_id IN (SELECT user_id FROM %s)
  GROUP BY sku
),
combined AS (
  SELECT sku, SUM(order_count) AS total_orders
  FROM (
    SELECT * FROM historical
    UNION ALL
    SELECT * FROM recent
  )
  GROUP BY sku
)
SELECT
  sku,
  total_orders,
  LOG(1 + total_orders) * 2 AS global_popularity_score  -- Lower weight for fallback
FROM combined;
""", tbl_global_popularity, tbl_import_orders_filtered, tbl_users, tbl_staged_events, tbl_users);

-- -----------------------------------------------------------------------------------
-- STEP 2.2c: MAKE-LEVEL POPULARITY (No change from v5.17)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY v1_make, sku AS
WITH
make_aggregated AS (
  SELECT
    v1_make,
    sku,
    SUM(total_segment_orders) AS total_make_orders
  FROM %s
  GROUP BY v1_make, sku
)
SELECT
  v1_make,
  sku,
  total_make_orders,
  ROUND(LOG(1 + total_make_orders) * @make_popularity_weight, 2) AS make_popularity_score,
  ROW_NUMBER() OVER (PARTITION BY v1_make ORDER BY total_make_orders DESC) AS rank_in_make
FROM make_aggregated
WHERE total_make_orders >= 2;
""", tbl_make_popularity, tbl_segment_popularity)
USING make_popularity_weight AS make_popularity_weight;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Scoring (popularity-only + 3-tier fallback): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'segment_popularity_coverage' AS check_name,
  COUNT(DISTINCT CONCAT(v1_make, '/', v1_model)) AS unique_segments,
  COUNT(DISTINCT sku) AS unique_skus,
  SUM(total_segment_orders) AS total_segment_orders,
  ROUND(AVG(segment_popularity_score), 2) AS avg_segment_score
FROM %s
""", tbl_segment_popularity);

EXECUTE IMMEDIATE FORMAT("""
SELECT 'make_popularity_coverage' AS check_name,
  COUNT(DISTINCT v1_make) AS unique_makes,
  COUNT(DISTINCT sku) AS unique_skus,
  SUM(total_make_orders) AS total_make_orders,
  ROUND(AVG(make_popularity_score), 2) AS avg_make_score
FROM %s
""", tbl_make_popularity);

-- ====================================================================================
-- STEP 3: USER RECOMMENDATIONS (V5.18: Fitment-only, popularity-only)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------------
-- STEP 3.1: PURCHASE EXCLUSION (No change from v5.17)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH bounds AS (
  SELECT DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AS start_date,
         @intent_window_end AS end_date
),
from_events AS (
  SELECT DISTINCT user_id,
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\\1') AS sku  -- Normalize variants
  FROM %s, bounds b
  WHERE sku IS NOT NULL AND user_id IS NOT NULL
    AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND DATE(event_ts) BETWEEN b.start_date AND b.end_date
),
from_import AS (
  SELECT uv.user_id, io.sku
  FROM %s io
  JOIN %s uv ON io.email_lower = uv.email_lower
  WHERE io.is_exclusion_window = 1
)
SELECT DISTINCT user_id, sku FROM (
  SELECT * FROM from_events
  UNION DISTINCT
  SELECT * FROM from_import
);
""", tbl_purchase_excl, tbl_staged_events, tbl_import_orders_filtered, tbl_users)
USING purchase_window_days AS purchase_window_days, intent_window_end AS intent_window_end;

-- -----------------------------------------------------------------------------------
-- STEP 3.2: SCORED RECOMMENDATIONS (V5.18: Fitment-only + popularity-only)
-- -----------------------------------------------------------------------------------
-- No universal candidates. No intent scoring.
-- final_score = 3-tier popularity fallback only.
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH
-- Fitment candidates: user's vehicle must match product's vehicle
fitment_candidates AS (
  SELECT
    uv.user_id, uv.email_lower, uv.v1_year, uv.v1_make, uv.v1_model,
    ep.sku, ep.image_url, CONCAT('https://www.holley.com/products/', ep.sku) AS product_url,
    ep.part_type,
    ep.price
  FROM %s uv
  JOIN %s ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  WHERE ep.image_url IS NOT NULL
),
-- Pre-compute segment totals per make/model to determine fallback tier
segment_totals AS (
  SELECT v1_make, v1_model, SUM(total_segment_orders) AS segment_total_orders
  FROM %s
  GROUP BY v1_make, v1_model
),
-- Pre-compute make totals to determine fallback tier
make_totals AS (
  SELECT v1_make, SUM(total_make_orders) AS make_total_orders
  FROM %s
  GROUP BY v1_make
)
SELECT
  fc.user_id, fc.email_lower, fc.v1_year, fc.v1_make, fc.v1_model,
  fc.sku, fc.image_url, fc.product_url,
  fc.part_type,
  fc.price,
  'fitment' AS product_type,
  -- 3-tier popularity fallback (per-product: fall through if product has no data at tier)
  CASE
    WHEN COALESCE(st.segment_total_orders, 0) >= @min_segment_for_use AND seg.segment_popularity_score IS NOT NULL
      THEN seg.segment_popularity_score
    WHEN COALESCE(mt.make_total_orders, 0) >= @min_make_for_use AND mk.make_popularity_score IS NOT NULL
      THEN mk.make_popularity_score
    ELSE COALESCE(glob.global_popularity_score, 0)
  END AS popularity_score,
  -- Track which tier was used
  CASE
    WHEN COALESCE(st.segment_total_orders, 0) >= @min_segment_for_use AND seg.segment_popularity_score IS NOT NULL THEN 'segment'
    WHEN COALESCE(mt.make_total_orders, 0) >= @min_make_for_use AND mk.make_popularity_score IS NOT NULL THEN 'make'
    WHEN glob.global_popularity_score IS NOT NULL THEN 'global'
    ELSE 'none'
  END AS popularity_source,
  seg.rank_in_segment,
  mk.rank_in_make,
  -- V5.18: final_score = popularity only (no intent)
  ROUND(
    CASE
      WHEN COALESCE(st.segment_total_orders, 0) >= @min_segment_for_use AND seg.segment_popularity_score IS NOT NULL
        THEN seg.segment_popularity_score
      WHEN COALESCE(mt.make_total_orders, 0) >= @min_make_for_use AND mk.make_popularity_score IS NOT NULL
        THEN mk.make_popularity_score
      ELSE COALESCE(glob.global_popularity_score, 0)
    END, 2) AS final_score
FROM fitment_candidates fc
-- Join all three popularity tiers
LEFT JOIN %s seg ON fc.v1_make = seg.v1_make AND fc.v1_model = seg.v1_model AND fc.sku = seg.sku
LEFT JOIN %s mk ON fc.v1_make = mk.v1_make AND fc.sku = mk.sku
LEFT JOIN %s glob ON fc.sku = glob.sku
-- Join tier totals for fallback logic
LEFT JOIN segment_totals st ON fc.v1_make = st.v1_make AND fc.v1_model = st.v1_model
LEFT JOIN make_totals mt ON fc.v1_make = mt.v1_make
-- Purchase exclusion (normalize variants so RA003R matches purchased RA003B)
LEFT JOIN %s purch ON fc.user_id = purch.user_id
  AND REGEXP_REPLACE(fc.sku, r'([0-9])[BRGP]$', r'\\1') = purch.sku
WHERE purch.sku IS NULL
  AND fc.sku IS NOT NULL
  AND fc.image_url IS NOT NULL
  AND (
    NOT @require_purchase_signal OR
    COALESCE(seg.segment_popularity_score, 0) > 0 OR
    COALESCE(mk.make_popularity_score, 0) > 0 OR
    COALESCE(glob.global_popularity_score, 0) > 0
  );
""", tbl_scored, tbl_users, tbl_eligible_parts,
    tbl_segment_popularity, tbl_make_popularity,
    tbl_segment_popularity, tbl_make_popularity, tbl_global_popularity, tbl_purchase_excl)
USING min_segment_for_use AS min_segment_for_use, min_make_for_use AS min_make_for_use,
      require_purchase_signal AS require_purchase_signal;

-- -----------------------------------------------------------------------------------
-- STEP 3.3: VARIANT DEDUP + DIVERSITY (V5.18: cap = 2)
-- -----------------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------------
-- STEP 3.4: TOP N SELECTION (V5.18: min 3, max 4)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT *
FROM (
  SELECT d.*,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score DESC, sku) AS rn,
         COUNT(*) OVER (PARTITION BY user_id) AS rec_count
  FROM %s d
)
WHERE rec_count >= @min_required_recs
  AND rn <= @required_recs;
""", tbl_ranked, tbl_diversity)
USING required_recs AS required_recs, min_required_recs AS min_required_recs;

-- -----------------------------------------------------------------------------------
-- STEP 3.5: PIVOT TO WIDE FORMAT (V5.18: + engagement_tier, fitment_count)
-- -----------------------------------------------------------------------------------
-- rec4 columns will be NULL for users with only 3 fitment recs.
-- engagement_tier: hot = has order since Sep 1, cold = no orders.
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH order_users AS (
  SELECT DISTINCT user_id FROM %s
  WHERE UPPER(event_name) IN ('PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
)
SELECT
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  MAX(CASE WHEN rn = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rn = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN rn = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN rn = 1 THEN image_url END) AS rec1_image,
  MAX(CASE WHEN rn = 1 THEN product_type END) AS rec1_type,
  MAX(CASE WHEN rn = 1 THEN popularity_source END) AS rec1_pop_source,
  MAX(CASE WHEN rn = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rn = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN rn = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN rn = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN rn = 2 THEN product_type END) AS rec2_type,
  MAX(CASE WHEN rn = 2 THEN popularity_source END) AS rec2_pop_source,
  MAX(CASE WHEN rn = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rn = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN rn = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN rn = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN rn = 3 THEN product_type END) AS rec3_type,
  MAX(CASE WHEN rn = 3 THEN popularity_source END) AS rec3_pop_source,
  MAX(CASE WHEN rn = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rn = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN rn = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN rn = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN rn = 4 THEN product_type END) AS rec4_type,
  MAX(CASE WHEN rn = 4 THEN popularity_source END) AS rec4_pop_source,
  -- V5.18: Engagement tier (binary: hot = has order since Sep 1, cold = no orders)
  CASE WHEN MAX(ou.user_id) IS NOT NULL THEN 'hot' ELSE 'cold' END AS engagement_tier,
  -- V5.18: Fitment count (= number of recs, 3 or 4)
  COUNT(*) AS fitment_count,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s r
LEFT JOIN order_users ou ON r.user_id = ou.user_id
GROUP BY r.email_lower, r.v1_year, r.v1_make, r.v1_model
HAVING COUNT(*) >= @min_required_recs;
""", tbl_final, tbl_staged_events, tbl_ranked)
USING pipeline_version AS pipeline_version, min_required_recs AS min_required_recs;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Recommendations (exclusion + dedup + diversity + pivot): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final Output Checks
-- ====================================================================================

EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_vehicle_recommendations' AS table_name,
  COUNT(*) AS unique_users,
  CASE WHEN COUNT(*) >= @min_final_users THEN 'OK' ELSE 'WARNING: Low final user count' END AS status
FROM %s
""", tbl_final)
USING min_final_users AS min_final_users;

-- Fitment count distribution (expect 3 or 4)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'fitment_count_distribution' AS check_name,
  COUNTIF(fitment_count = 3) AS with_3_recs,
  COUNTIF(fitment_count = 4) AS with_4_recs,
  ROUND(AVG(fitment_count), 2) AS avg_fitment_count
FROM %s
""", tbl_final);

-- Engagement tier distribution
EXECUTE IMMEDIATE FORMAT("""
SELECT 'engagement_tier_distribution' AS check_name,
  COUNTIF(engagement_tier = 'hot') AS hot_users,
  COUNTIF(engagement_tier = 'cold') AS cold_users,
  COUNT(*) AS total_users
FROM %s
""", tbl_final);

-- Generation coverage monitor: how many vehicle generations survived all filters
-- (price >= $50, image, refurbished, service SKUs, commodity exclusion, AND >= 4 parts gate).
-- Excluded = dropped by ANY filter, not just the >= 4 gate alone.
-- Trend this metric across versions to detect catalog/price shrinkage.
EXECUTE IMMEDIATE FORMAT("""
WITH included_generations AS (
  SELECT DISTINCT year, make, model FROM %s
),
all_fitment_generations AS (
  SELECT
    SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
  GROUP BY 1, 2, 3
)
SELECT 'generation_coverage' AS check_name,
  COUNT(*) AS total_generations,
  COUNTIF(ig.year IS NOT NULL) AS included,
  COUNTIF(ig.year IS NULL) AS excluded_all_filters,
  ROUND(SAFE_DIVIDE(COUNTIF(ig.year IS NULL) * 100.0, COUNT(*)), 2) AS pct_excluded
FROM all_fitment_generations ag
LEFT JOIN included_generations ig USING (year, make, model)
""", tbl_eligible_parts);

-- Popularity source distribution (3-tier: segment vs make vs global)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'popularity_source_distribution' AS check_name,
  COUNTIF(rec1_pop_source = 'segment') AS rec1_segment,
  COUNTIF(rec1_pop_source = 'make') AS rec1_make,
  COUNTIF(rec1_pop_source = 'global') AS rec1_global,
  COUNTIF(rec1_pop_source = 'none') AS rec1_none,
  COUNTIF(rec2_pop_source = 'segment') AS rec2_segment,
  COUNTIF(rec2_pop_source = 'make') AS rec2_make,
  COUNTIF(rec2_pop_source = 'global') AS rec2_global,
  COUNTIF(rec3_pop_source = 'segment') AS rec3_segment,
  COUNTIF(rec3_pop_source = 'make') AS rec3_make,
  COUNTIF(rec3_pop_source = 'global') AS rec3_global,
  COUNTIF(rec4_pop_source = 'segment') AS rec4_segment,
  COUNTIF(rec4_pop_source = 'make') AS rec4_make,
  COUNTIF(rec4_pop_source = 'global') AS rec4_global
FROM %s
""", tbl_final);

-- Duplicate check (handles NULL rec4 for 3-rec users)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'duplicate_check' AS check_name,
  COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_2 = rec_part_3 OR
    (rec_part_4 IS NOT NULL AND (
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ))
  ) AS users_with_duplicates,
  CASE WHEN COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_2 = rec_part_3 OR
    (rec_part_4 IS NOT NULL AND (
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ))
  ) = 0 THEN 'OK' ELSE 'ERROR: Duplicate SKUs found' END AS status
FROM %s
""", tbl_final);

-- Price check (handles NULL rec4 for 3-rec users)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_distribution' AS check_name,
  MIN(LEAST(rec1_price, rec2_price, rec3_price)) AS min_price,
  GREATEST(MAX(rec1_price), MAX(rec2_price), MAX(rec3_price), COALESCE(MAX(rec4_price), 0)) AS max_price,
  ROUND(AVG((rec1_price + rec2_price + rec3_price + COALESCE(rec4_price, 0)) / fitment_count), 2) AS avg_price,
  CASE WHEN MIN(LEAST(rec1_price, rec2_price, rec3_price)) >= @min_price
       AND (MIN(rec4_price) IS NULL OR MIN(rec4_price) >= @min_price)
       THEN 'OK'
       ELSE FORMAT('WARNING: Prices below $%%d', CAST(@min_price AS INT64))
  END AS status
FROM %s
""", tbl_final)
USING min_price AS min_price;

-- Score ordering check (handles NULL rec4)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'score_ordering' AS check_name,
  COUNT(*) AS total_users,
  COUNTIF(
    rec1_score >= rec2_score AND
    rec2_score >= rec3_score AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  ) AS correctly_ordered,
  ROUND(SAFE_DIVIDE(
    COUNTIF(rec1_score >= rec2_score AND rec2_score >= rec3_score AND
            (rec4_score IS NULL OR rec3_score >= rec4_score))
    * 100.0, COUNT(*)), 2
  ) AS correct_ordering_pct
FROM %s
""", tbl_final);

-- No universals check (should be 0)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'no_universals_check' AS check_name,
  COUNTIF(rec1_type = 'universal') + COUNTIF(rec2_type = 'universal') +
  COUNTIF(rec3_type = 'universal') + COUNTIF(COALESCE(rec4_type, 'fitment') = 'universal') AS universal_count,
  CASE WHEN COUNTIF(rec1_type = 'universal') + COUNTIF(rec2_type = 'universal') +
            COUNTIF(rec3_type = 'universal') + COUNTIF(COALESCE(rec4_type, 'fitment') = 'universal') = 0
       THEN 'OK' ELSE 'ERROR: Universal products found' END AS status
FROM %s
""", tbl_final);

-- Cleanup
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_events);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Pipeline %s finished in %d seconds',
  pipeline_version,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 4: PRODUCTION DEPLOYMENT (Optional)
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

  EXECUTE IMMEDIATE FORMAT("""
  SELECT 'production_deployed' AS status,
    COUNT(*) AS user_count,
    MIN(generated_at) AS generated_at,
    MAX(pipeline_version) AS pipeline_version
  FROM `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name);

  SELECT '[DEPLOYMENT COMPLETE] Pipeline finished successfully' AS log;

ELSE
  SELECT FORMAT('[SKIP] Production deployment skipped (deploy_to_production = FALSE). Output in %s.%s.final_vehicle_recommendations',
    target_project, target_dataset) AS log;

END IF;
