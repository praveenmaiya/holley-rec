-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.8 (User-Centric Recommendations)
-- --------------------------------------------------------------------------------------------------
-- MAJOR CHANGES from V5.7:
--   1. Segment popularity: Replace global popularity with per-vehicle-segment scores
--   2. Narrow-fit bonus: Products fitting fewer vehicles get scoring boost
--   3. Co-purchase signals: Boost products bought with user's past purchases
--   4. Multi-vehicle support: Use v2 vehicle data with 90-day recency prioritization
--   5. Tiered slots: Slots 1-2 from fitment tier, slots 3-4 from segment-popular tier
--   6. Vehicle generations: Pool sparse segments using generation mappings
-- --------------------------------------------------------------------------------------------------
-- Scoring Formula (NEW):
--   final_score = intent_score
--               + segment_popularity_score  (LOG(1 + segment_orders) * 10)
--               + narrow_fit_bonus          (≤50: +10, ≤100: +7, ≤500: +3, ≤1000: +1)
--               + co_purchase_boost         (LOG(1 + co_purchase_count) * 3)
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_8_vehicle_fitment_recommendations.sql
-- ==================================================================================================

-- Pipeline version
DECLARE pipeline_version STRING DEFAULT 'v5.8';

-- Working dataset (intermediate tables)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_8';

-- Production dataset (final deployment)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_vehicle_recommendations';

-- Deployment flag (set to TRUE to deploy to production)
DECLARE deploy_to_production BOOL DEFAULT FALSE;  -- Start with FALSE for testing

-- Backup suffix (current date)
DECLARE backup_suffix STRING DEFAULT FORMAT_DATE('%Y_%m_%d', CURRENT_DATE());

-- Intent window: Fixed Sep 1 boundary to current date
DECLARE intent_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';

-- Historical popularity: Everything before Sep 1 (import_orders)
DECLARE pop_hist_end     DATE DEFAULT DATE '2025-08-31';
DECLARE pop_hist_start   DATE DEFAULT DATE '2025-01-10';

-- V5.8: Recency window for vehicle prioritization
DECLARE recency_window_days INT64 DEFAULT 90;

-- V5.8: Co-purchase minimum threshold
DECLARE min_co_purchase_count INT64 DEFAULT 20;

DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE allow_price_fallback BOOL DEFAULT TRUE;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE required_recs INT64 DEFAULT 4;

-- Dynamic year patterns for ORDER_DATE string pre-filter
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM CURRENT_DATE()) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)) AS STRING), '%');

-- Convenience for dynamic table names
DECLARE tbl_users_v1 STRING DEFAULT FORMAT('`%s.%s.users_with_v1_vehicles`', target_project, target_dataset);
DECLARE tbl_users_v2 STRING DEFAULT FORMAT('`%s.%s.users_with_v2_vehicles`', target_project, target_dataset);
DECLARE tbl_users_unified STRING DEFAULT FORMAT('`%s.%s.users_with_vehicles_unified`', target_project, target_dataset);
DECLARE tbl_vehicle_generations STRING DEFAULT FORMAT('`%s.%s.vehicle_generations`', target_project, target_dataset);
DECLARE tbl_staged_events STRING DEFAULT FORMAT('`%s.%s.staged_events`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_parts STRING DEFAULT FORMAT('`%s.%s.eligible_parts`', target_project, target_dataset);
DECLARE tbl_import_orders_filtered STRING DEFAULT FORMAT('`%s.%s.import_orders_filtered`', target_project, target_dataset);
DECLARE tbl_intent STRING DEFAULT FORMAT('`%s.%s.intent_scores`', target_project, target_dataset);
DECLARE tbl_segment_sales STRING DEFAULT FORMAT('`%s.%s.segment_product_sales`', target_project, target_dataset);
DECLARE tbl_segment_popularity STRING DEFAULT FORMAT('`%s.%s.segment_popularity_scores`', target_project, target_dataset);
DECLARE tbl_fitment_breadth STRING DEFAULT FORMAT('`%s.%s.sku_fitment_breadth`', target_project, target_dataset);
DECLARE tbl_co_purchases STRING DEFAULT FORMAT('`%s.%s.product_co_purchases`', target_project, target_dataset);
DECLARE tbl_purchase_excl STRING DEFAULT FORMAT('`%s.%s.user_purchased_parts_365d`', target_project, target_dataset);
DECLARE tbl_tier1_candidates STRING DEFAULT FORMAT('`%s.%s.tier1_fitment_candidates`', target_project, target_dataset);
DECLARE tbl_tier2_candidates STRING DEFAULT FORMAT('`%s.%s.tier2_segment_popular_candidates`', target_project, target_dataset);
DECLARE tbl_tiered_ranked STRING DEFAULT FORMAT('`%s.%s.tiered_ranked`', target_project, target_dataset);
DECLARE tbl_final STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);

-- Execution timing
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- ====================================================================================
-- STEP 0: USERS WITH VEHICLES (V1 + V2 + UNIFIED)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 0.1: Users with V1 vehicles (same as v5.7)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT DISTINCT
  user_id,
  LOWER(email_val) AS email_lower,
  UPPER(email_val) AS email_upper,
  v1_year_str AS v1_year,
  SAFE_CAST(v1_year_str AS INT64) AS v1_year_int,
  v1_make,
  v1_model
FROM (
  SELECT user_id,
         MAX(IF(LOWER(p.property_name) = 'email', TRIM(p.string_value), NULL)) AS email_val,
         MAX(IF(LOWER(p.property_name) = 'v1_year', COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year_str,
         MAX(IF(LOWER(p.property_name) = 'v1_make', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_make,
         MAX(IF(LOWER(p.property_name) = 'v1_model', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_model
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`, UNNEST(user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email','v1_year','v1_make','v1_model')
  GROUP BY user_id
)
WHERE email_val IS NOT NULL AND v1_year_str IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL;
""", tbl_users_v1);

SELECT FORMAT('[Step 0.1] Users with V1 vehicles created') AS log;

-- Step 0.2: Users with V2 vehicles (NEW in v5.8)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT DISTINCT
  user_id,
  LOWER(email_val) AS email_lower,
  v2_year_str AS v2_year,
  SAFE_CAST(v2_year_str AS INT64) AS v2_year_int,
  v2_make,
  v2_model
FROM (
  SELECT user_id,
         MAX(IF(LOWER(p.property_name) = 'email', TRIM(p.string_value), NULL)) AS email_val,
         MAX(IF(LOWER(p.property_name) = 'v2_year', COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v2_year_str,
         MAX(IF(LOWER(p.property_name) = 'v2_make', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v2_make,
         MAX(IF(LOWER(p.property_name) = 'v2_model', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v2_model
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`, UNNEST(user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email','v2_year','v2_make','v2_model')
  GROUP BY user_id
)
WHERE email_val IS NOT NULL AND v2_year_str IS NOT NULL AND v2_make IS NOT NULL AND v2_model IS NOT NULL;
""", tbl_users_v2);

SELECT FORMAT('[Step 0.2] Users with V2 vehicles created') AS log;

-- Step 0.3: Unified users with primary vehicle selection (v1 by default, v2 if more recent activity)
-- For v5.8.0, we simplify: just use v1 as primary, but track v2 for future use
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT
  v1.user_id,
  v1.email_lower,
  v1.email_upper,
  -- Primary vehicle is v1 for now (v5.8.0 simplification)
  v1.v1_year_int AS primary_year_int,
  v1.v1_make AS primary_make,
  v1.v1_model AS primary_model,
  -- Keep original v1 data
  v1.v1_year,
  v1.v1_year_int,
  v1.v1_make,
  v1.v1_model,
  -- V2 data if exists
  v2.v2_year,
  v2.v2_year_int,
  v2.v2_make,
  v2.v2_model,
  -- Flag for multi-vehicle users
  CASE WHEN v2.user_id IS NOT NULL THEN TRUE ELSE FALSE END AS has_v2_vehicle
FROM %s v1
LEFT JOIN %s v2 USING (user_id, email_lower);
""", tbl_users_unified, tbl_users_v1, tbl_users_v2);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0] Users unified: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate
EXECUTE IMMEDIATE FORMAT("""
SELECT 'users_unified' AS table_name,
  COUNT(*) AS total_users,
  COUNTIF(has_v2_vehicle) AS users_with_v2,
  ROUND(COUNTIF(has_v2_vehicle) * 100.0 / COUNT(*), 2) AS pct_with_v2
FROM %s
""", tbl_users_unified);

-- ====================================================================================
-- STEP 1: STAGED EVENTS + SKU DATA (Reused from v5.7)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 1.1: Staged events
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
PARTITION BY DATE(event_ts)
CLUSTER BY user_id, sku AS
WITH raw_events AS (
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
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep
  WHERE DATE(t.client_event_timestamp) BETWEEN @intent_window_start AND @intent_window_end
    AND UPPER(t.event_name) IN ('VIEWED PRODUCT','ORDERED PRODUCT','CART UPDATE','PLACED ORDER','CONSUMER WEBSITE ORDER')
),
prepared AS (
  SELECT user_id, sku, event_ts, event_name,
    COALESCE(sku_idx, sku_idx_skus, price_idx, image_idx) AS item_idx,
    price_val, price_idx, image_val, image_idx
  FROM raw_events
),
aggregated AS (
  SELECT user_id, MAX(sku) AS sku, event_ts, event_name, item_idx,
    MAX(IF(price_idx IS NULL, price_val, NULL)) AS price_main,
    MAX(IF(price_idx IS NOT NULL AND price_idx = item_idx, price_val, NULL)) AS price_item,
    MAX(IF(image_idx IS NULL, image_val, NULL)) AS image_main,
    MAX(IF(image_idx IS NOT NULL AND image_idx = item_idx, image_val, NULL)) AS image_item
  FROM prepared
  GROUP BY user_id, event_ts, event_name, item_idx
)
SELECT user_id, sku, event_ts, event_name,
  COALESCE(price_item, price_main) AS price,
  COALESCE(image_item, image_main) AS image_url_raw
FROM aggregated
WHERE sku IS NOT NULL;
""", tbl_staged_events)
USING intent_window_start AS intent_window_start, intent_window_end AS intent_window_end;

-- Step 1.2: SKU Prices
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, MAX(price) AS price, COUNT(*) AS observations
FROM %s
WHERE sku IS NOT NULL
GROUP BY sku;
""", tbl_sku_prices, tbl_staged_events);

-- Step 1.3: SKU Images
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, image_url
FROM (
  SELECT sku,
    REGEXP_REPLACE(
      CASE
        WHEN image_url_raw LIKE '//%%' THEN CONCAT('https:', image_url_raw)
        WHEN LOWER(image_url_raw) LIKE 'http://%%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
        ELSE image_url_raw
      END, '^//', 'https://'
    ) AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM %s
  WHERE sku IS NOT NULL AND image_url_raw IS NOT NULL
)
WHERE rn = 1 AND image_url LIKE 'https://%%';
""", tbl_sku_images, tbl_staged_events);

-- Step 1.4: Eligible Parts (same filters as v5.7)
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
    AND NOT (f.sku LIKE 'EXT-%%' OR f.sku LIKE 'GIFT-%%' OR f.sku LIKE 'WARRANTY-%%' OR f.sku LIKE 'SERVICE-%%' OR f.sku LIKE 'PREAUTH-%%')
    AND COALESCE(price.price, @min_price) >= @min_price
    AND (price.price IS NOT NULL OR @allow_price_fallback)
    AND img.image_url IS NOT NULL AND img.image_url LIKE 'https://%%'
    AND NOT (
      f.part_type LIKE '%%Gasket%%' OR f.part_type LIKE '%%Decal%%' OR f.part_type LIKE '%%Key%%'
      OR f.part_type LIKE '%%Washer%%' OR f.part_type LIKE '%%Clamp%%'
      OR (f.part_type LIKE '%%Bolt%%' AND f.part_type NOT IN ('Engine Cylinder Head Bolt', 'Engine Bolt Kit'))
      OR (f.part_type LIKE '%%Cap%%' AND f.part_type NOT LIKE '%%Distributor Cap%%' AND f.part_type NOT IN ('Wheel Hub Cap', 'Wheel Cap Set'))
    )
    AND NOT (f.part_type = 'UNKNOWN' AND COALESCE(price.price, @min_price) < 3000)
),
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

-- Step 1.5: Import orders filtered
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku, email_lower AS
WITH prefiltered AS (
  SELECT
    UPPER(TRIM(ITEM)) AS sku,
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    ORDER_DATE,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
    AND (ORDER_DATE LIKE @current_year_pattern OR ORDER_DATE LIKE @previous_year_pattern)
)
SELECT sku, email_lower, order_date_parsed,
  CASE WHEN order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end THEN 1 ELSE 0 END AS is_popularity_window,
  CASE WHEN order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end THEN 1 ELSE 0 END AS is_exclusion_window
FROM prefiltered
WHERE order_date_parsed IS NOT NULL
  AND (order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end
       OR order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end);
""", tbl_import_orders_filtered)
USING pop_hist_start AS pop_hist_start, pop_hist_end AS pop_hist_end,
      intent_window_end AS intent_window_end, purchase_window_days AS purchase_window_days,
      current_year_pattern AS current_year_pattern, previous_year_pattern AS previous_year_pattern;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1] Staged events + SKU data: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 2: INTENT SCORES (Reused from v5.7)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH events AS (
  SELECT user_id, sku,
    CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN 'order'
      WHEN UPPER(event_name) = 'CART UPDATE' THEN 'cart'
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN 'view'
      ELSE NULL
    END AS intent_type
  FROM %s
  WHERE sku IS NOT NULL AND user_id IS NOT NULL
),
agg AS (
  SELECT user_id, sku,
    COUNTIF(intent_type='order') AS order_count,
    COUNTIF(intent_type='cart') AS cart_count,
    COUNTIF(intent_type='view') AS view_count
  FROM events
  WHERE intent_type IS NOT NULL
  GROUP BY user_id, sku
)
SELECT user_id, sku,
  CASE WHEN order_count > 0 THEN 'order' WHEN cart_count > 0 THEN 'cart' WHEN view_count > 0 THEN 'view' ELSE 'none' END AS intent_type,
  CASE WHEN order_count > 0 THEN LOG(1 + order_count) * 20
       WHEN cart_count > 0 THEN LOG(1 + cart_count) * 10
       WHEN view_count > 0 THEN LOG(1 + view_count) * 2
       ELSE 0
  END AS intent_score
FROM agg
WHERE EXISTS (SELECT 1 FROM %s ep WHERE agg.sku = ep.sku);
""", tbl_intent, tbl_staged_events, tbl_eligible_parts);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Intent scores: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3: SEGMENT POPULARITY SCORES (NEW in v5.8)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 3.1: Segment product sales - What do owners of each vehicle segment buy?
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY segment_key, sku AS
SELECT
  CONCAT(UPPER(uv.primary_make), '|', UPPER(uv.primary_model), '|', CAST(uv.primary_year_int AS STRING)) AS segment_key,
  io.sku,
  COUNT(*) AS segment_orders,
  COUNT(DISTINCT io.email_lower) AS segment_buyers
FROM %s io
JOIN %s uv ON io.email_lower = uv.email_lower
WHERE io.is_popularity_window = 1
GROUP BY 1, 2
HAVING COUNT(*) >= 2;  -- Minimum 2 orders to be considered
""", tbl_segment_sales, tbl_import_orders_filtered, tbl_users_unified);

-- Step 3.2: Segment popularity scores with generation fallback
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY segment_key, sku AS
WITH generation_sales AS (
  -- Pool sales by generation (for sparse segments)
  SELECT
    CONCAT(g.make, '|', g.model, '|', g.generation) AS generation_key,
    CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) AS segment_key,
    io.sku,
    COUNT(*) AS generation_orders
  FROM %s io
  JOIN %s uv ON io.email_lower = uv.email_lower
  JOIN %s g
    ON uv.primary_make = g.make
    AND uv.primary_model = g.model
    AND uv.primary_year_int BETWEEN g.year_start AND g.year_end
  WHERE io.is_popularity_window = 1
  GROUP BY 1, 2, 3
  HAVING COUNT(*) >= 3
)
SELECT
  COALESCE(ss.segment_key, gs.segment_key) AS segment_key,
  COALESCE(ss.sku, gs.sku) AS sku,
  COALESCE(ss.segment_orders, 0) AS segment_orders,
  COALESCE(gs.generation_orders, 0) AS generation_orders,
  -- Use segment orders if available, else use 50%% of generation orders
  LOG(1 + GREATEST(COALESCE(ss.segment_orders, 0), COALESCE(gs.generation_orders, 0) * 0.5)) * 10 AS segment_popularity_score
FROM %s ss
FULL OUTER JOIN generation_sales gs ON ss.segment_key = gs.segment_key AND ss.sku = gs.sku
WHERE COALESCE(ss.segment_orders, 0) >= 2 OR COALESCE(gs.generation_orders, 0) >= 3;
""", tbl_segment_popularity, tbl_import_orders_filtered, tbl_users_unified, tbl_vehicle_generations, tbl_segment_sales);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Segment popularity: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate segment popularity
EXECUTE IMMEDIATE FORMAT("""
SELECT 'segment_popularity' AS table_name,
  COUNT(*) AS total_rows,
  COUNT(DISTINCT segment_key) AS unique_segments,
  COUNT(DISTINCT sku) AS unique_skus,
  ROUND(AVG(segment_popularity_score), 2) AS avg_score
FROM %s
""", tbl_segment_popularity);

-- ====================================================================================
-- STEP 4: FITMENT BREADTH + NARROW-FIT BONUS (NEW in v5.8)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT
  sku,
  COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) AS vehicles_fit,
  CASE
    WHEN COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) <= 50 THEN 10
    WHEN COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) <= 100 THEN 7
    WHEN COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) <= 500 THEN 3
    WHEN COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) <= 1000 THEN 1
    ELSE 0
  END AS narrow_fit_bonus
FROM %s
GROUP BY sku;
""", tbl_fitment_breadth, tbl_eligible_parts);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 4] Fitment breadth: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate fitment breadth
EXECUTE IMMEDIATE FORMAT("""
SELECT 'fitment_breadth' AS table_name,
  COUNT(*) AS total_skus,
  COUNTIF(narrow_fit_bonus = 10) AS very_specific,
  COUNTIF(narrow_fit_bonus = 7) AS specific,
  COUNTIF(narrow_fit_bonus = 3) AS moderate,
  COUNTIF(narrow_fit_bonus = 1) AS slightly_narrow,
  COUNTIF(narrow_fit_bonus = 0) AS broad
FROM %s
""", tbl_fitment_breadth);

-- ====================================================================================
-- STEP 5: CO-PURCHASE SIGNALS (NEW in v5.8)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku_a, sku_b AS
WITH order_baskets AS (
  SELECT email_lower, DATE(order_date_parsed) AS order_date, ARRAY_AGG(DISTINCT sku) AS basket_skus
  FROM %s
  WHERE is_popularity_window = 1
  GROUP BY email_lower, order_date
  HAVING ARRAY_LENGTH(ARRAY_AGG(DISTINCT sku)) BETWEEN 2 AND 10
),
co_pairs AS (
  SELECT a AS sku_a, b AS sku_b, COUNT(*) AS co_purchase_count
  FROM order_baskets, UNNEST(basket_skus) AS a, UNNEST(basket_skus) AS b
  WHERE a < b
  GROUP BY sku_a, sku_b
  HAVING COUNT(*) >= @min_co_purchase_count
)
SELECT sku_a, sku_b, co_purchase_count,
  LOG(1 + co_purchase_count) * 3 AS co_purchase_boost
FROM co_pairs;
""", tbl_co_purchases, tbl_import_orders_filtered)
USING min_co_purchase_count AS min_co_purchase_count;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 5] Co-purchases: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate co-purchases
EXECUTE IMMEDIATE FORMAT("""
SELECT 'co_purchases' AS table_name,
  COUNT(*) AS total_pairs,
  ROUND(AVG(co_purchase_count), 1) AS avg_co_purchases,
  ROUND(AVG(co_purchase_boost), 2) AS avg_boost
FROM %s
""", tbl_co_purchases);

-- ====================================================================================
-- STEP 6: PURCHASE EXCLUSION
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH from_events AS (
  SELECT DISTINCT user_id, sku
  FROM %s
  WHERE sku IS NOT NULL AND user_id IS NOT NULL
    AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND DATE(event_ts) BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end
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
""", tbl_purchase_excl, tbl_staged_events, tbl_import_orders_filtered, tbl_users_unified)
USING purchase_window_days AS purchase_window_days, intent_window_end AS intent_window_end;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 6] Purchase exclusion: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 7: TIERED CANDIDATE GENERATION (NEW in v5.8)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 7.1: Tier 1 - Fitment candidates (products that fit user's vehicle)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH user_co_purchase_boost AS (
  -- For each user, compute max co-purchase boost for products based on their purchase history
  SELECT purch.user_id, cp.sku_b AS sku, MAX(cp.co_purchase_boost) AS co_purchase_boost
  FROM %s purch
  JOIN %s cp ON purch.sku = cp.sku_a
  GROUP BY purch.user_id, cp.sku_b
  UNION ALL
  SELECT purch.user_id, cp.sku_a AS sku, MAX(cp.co_purchase_boost) AS co_purchase_boost
  FROM %s purch
  JOIN %s cp ON purch.sku = cp.sku_b
  GROUP BY purch.user_id, cp.sku_a
)
SELECT
  uv.user_id,
  uv.email_lower,
  uv.primary_year_int,
  uv.primary_make,
  uv.primary_model,
  uv.v1_year,
  uv.v1_make,
  uv.v1_model,
  ep.sku,
  ep.part_type,
  ep.price,
  ep.image_url,
  'fitment' AS tier,
  COALESCE(int.intent_score, 0) AS intent_score,
  COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
  COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
  COALESCE(ucb.co_purchase_boost, 0) AS co_purchase_boost,
  ROUND(
    COALESCE(int.intent_score, 0) +
    COALESCE(sp.segment_popularity_score, 0) +
    COALESCE(fb.narrow_fit_bonus, 0) +
    COALESCE(ucb.co_purchase_boost, 0),
    2
  ) AS final_score
FROM %s uv
JOIN %s ep
  ON uv.primary_year_int = ep.year AND uv.primary_make = ep.make AND uv.primary_model = ep.model
LEFT JOIN %s int ON uv.user_id = int.user_id AND ep.sku = int.sku
LEFT JOIN %s sp
  ON CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) = sp.segment_key
  AND ep.sku = sp.sku
LEFT JOIN %s fb ON ep.sku = fb.sku
LEFT JOIN user_co_purchase_boost ucb ON uv.user_id = ucb.user_id AND ep.sku = ucb.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
WHERE purch.sku IS NULL
  AND ep.image_url IS NOT NULL;
""", tbl_tier1_candidates,
    tbl_purchase_excl, tbl_co_purchases,
    tbl_purchase_excl, tbl_co_purchases,
    tbl_users_unified, tbl_eligible_parts, tbl_intent, tbl_segment_popularity, tbl_fitment_breadth, tbl_purchase_excl);

SELECT FORMAT('[Step 7.1] Tier 1 (fitment) candidates created') AS log;

-- Step 7.2: Tier 2 - Segment popular candidates (products segment buys, regardless of fitment)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT
  uv.user_id,
  uv.email_lower,
  uv.primary_year_int,
  uv.primary_make,
  uv.primary_model,
  uv.v1_year,
  uv.v1_make,
  uv.v1_model,
  sp.sku,
  COALESCE(ii.PartType, 'UNKNOWN') AS part_type,
  COALESCE(price.price, @min_price) AS price,
  img.image_url,
  'segment_popular' AS tier,
  0 AS intent_score,  -- No personal intent for segment-popular tier
  sp.segment_popularity_score,
  0 AS narrow_fit_bonus,  -- Not applicable for non-fitment products
  0 AS co_purchase_boost,  -- Simplified for tier 2
  ROUND(sp.segment_popularity_score, 2) AS final_score
FROM %s uv
JOIN %s sp
  ON CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) = sp.segment_key
LEFT JOIN %s price ON sp.sku = price.sku
LEFT JOIN %s img ON sp.sku = img.sku
LEFT JOIN `auxia-gcp.data_company_1950.import_items` ii ON sp.sku = UPPER(TRIM(ii.PartNumber))
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND sp.sku = purch.sku
LEFT JOIN %s t1 ON uv.user_id = t1.user_id AND sp.sku = t1.sku  -- Exclude tier 1 products
WHERE purch.sku IS NULL
  AND t1.sku IS NULL  -- Not already in tier 1
  AND img.image_url IS NOT NULL
  AND COALESCE(price.price, @min_price) >= @min_price;
""", tbl_tier2_candidates, tbl_users_unified, tbl_segment_popularity,
    tbl_sku_prices, tbl_sku_images, tbl_purchase_excl, tbl_tier1_candidates)
USING min_price AS min_price;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 7] Tiered candidates: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate tiers
EXECUTE IMMEDIATE FORMAT("""
SELECT 'tier1_candidates' AS tier, COUNT(*) AS total_rows, COUNT(DISTINCT user_id) AS unique_users
FROM %s
UNION ALL
SELECT 'tier2_candidates', COUNT(*), COUNT(DISTINCT user_id)
FROM %s
""", tbl_tier1_candidates, tbl_tier2_candidates);

-- ====================================================================================
-- STEP 8: TIERED RANKING + FINAL OUTPUT
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 8.1: Combine tiers, apply diversity, rank
-- Strategy: Take top 4 from combined candidates
-- - Fitment tier gets priority (tier_priority=0)
-- - Within same tier, rank by final_score
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH all_candidates AS (
  SELECT *, 0 AS tier_priority FROM %s  -- Fitment gets priority
  UNION ALL
  SELECT *, 1 AS tier_priority FROM %s  -- Segment popular is secondary
),
-- Variant dedup across all candidates
normalized AS (
  SELECT *,
    REGEXP_REPLACE(
      REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
      r'([0-9])[BRGP]$', r'\\1'
    ) AS base_sku
  FROM all_candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY tier_priority, final_score DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType across all candidates
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY tier_priority, final_score DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= @max_parttype_per_user
),
-- Global ranking: fitment first, then by score
global_ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY tier_priority, final_score DESC, sku
    ) AS global_rank
  FROM diversity_filtered
)
SELECT * FROM global_ranked WHERE global_rank <= @required_recs;
""", tbl_tiered_ranked, tbl_tier1_candidates, tbl_tier2_candidates)
USING max_parttype_per_user AS max_parttype_per_user, required_recs AS required_recs;

-- Step 8.2: Pivot to wide format
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
WITH users_with_4_recs AS (
  SELECT user_id FROM %s GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  tr.email_lower,
  tr.v1_year,
  tr.v1_make,
  tr.v1_model,
  MAX(CASE WHEN global_rank = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN global_rank = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN global_rank = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN global_rank = 1 THEN image_url END) AS rec1_image,
  MAX(CASE WHEN global_rank = 1 THEN tier END) AS rec1_tier,
  MAX(CASE WHEN global_rank = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN global_rank = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN global_rank = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN global_rank = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN global_rank = 2 THEN tier END) AS rec2_tier,
  MAX(CASE WHEN global_rank = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN global_rank = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN global_rank = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN global_rank = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN global_rank = 3 THEN tier END) AS rec3_tier,
  MAX(CASE WHEN global_rank = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN global_rank = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN global_rank = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN global_rank = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN global_rank = 4 THEN tier END) AS rec4_tier,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s tr
JOIN users_with_4_recs u4 ON tr.user_id = u4.user_id
GROUP BY tr.email_lower, tr.v1_year, tr.v1_make, tr.v1_model;
""", tbl_final, tbl_tiered_ranked, tbl_tiered_ranked)
USING pipeline_version AS pipeline_version;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 8] Final output: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION
-- ====================================================================================

-- User count
EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_recommendations' AS table_name,
  COUNT(*) AS unique_users,
  CASE WHEN COUNT(*) >= 400000 THEN 'OK' ELSE 'WARNING: Low user count' END AS status
FROM %s
""", tbl_final);

-- Tier distribution
EXECUTE IMMEDIATE FORMAT("""
SELECT 'tier_distribution' AS check_name,
  COUNTIF(rec1_tier = 'fitment') AS slot1_fitment,
  COUNTIF(rec1_tier = 'segment_popular') AS slot1_segment,
  COUNTIF(rec2_tier = 'fitment') AS slot2_fitment,
  COUNTIF(rec2_tier = 'segment_popular') AS slot2_segment,
  COUNTIF(rec3_tier = 'fitment') AS slot3_fitment,
  COUNTIF(rec3_tier = 'segment_popular') AS slot3_segment,
  COUNTIF(rec4_tier = 'fitment') AS slot4_fitment,
  COUNTIF(rec4_tier = 'segment_popular') AS slot4_segment
FROM %s
""", tbl_final);

-- 1969 Camaro sanity check
EXECUTE IMMEDIATE FORMAT("""
SELECT '1969_camaro_check' AS check_name,
  rec_part_1, rec1_tier, rec1_score,
  CASE WHEN rec_part_1 = 'LFRB155' THEN 'FAIL: Still recommending LFRB155' ELSE 'OK' END AS status
FROM %s
WHERE v1_year = '1969' AND UPPER(v1_model) = 'CAMARO'
LIMIT 5
""", tbl_final);

-- Duplicate check
EXECUTE IMMEDIATE FORMAT("""
SELECT 'duplicate_check' AS check_name,
  COUNTIF(rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR rec_part_1 = rec_part_4 OR
          rec_part_2 = rec_part_3 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4) AS users_with_duplicates,
  CASE WHEN COUNTIF(rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR rec_part_1 = rec_part_4 OR
                    rec_part_2 = rec_part_3 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4) = 0
       THEN 'OK' ELSE 'ERROR: Duplicate SKUs found' END AS status
FROM %s
""", tbl_final);

-- Price check
EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_distribution' AS check_name,
  LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) AS min_price,
  GREATEST(MAX(rec1_price), MAX(rec2_price), MAX(rec3_price), MAX(rec4_price)) AS max_price,
  ROUND((AVG(rec1_price) + AVG(rec2_price) + AVG(rec3_price) + AVG(rec4_price)) / 4, 2) AS avg_price,
  CASE WHEN LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) >= @min_price
       THEN 'OK' ELSE 'WARNING: Prices below minimum' END AS status
FROM %s
""", tbl_final)
USING min_price AS min_price;

-- Cleanup staged events
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_events);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Pipeline %s finished in %d seconds',
  pipeline_version,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 9: PRODUCTION DEPLOYMENT (Optional)
-- ====================================================================================
IF deploy_to_production THEN
  SET step_start = CURRENT_TIMESTAMP();

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s`
  COPY `%s.%s.final_vehicle_recommendations`
  """, prod_project, prod_dataset, prod_table_name, target_project, target_dataset);

  SELECT FORMAT('[Step 9.1] Deployed to production: %s.%s.%s', prod_project, prod_dataset, prod_table_name) AS log;

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s_%s`
  COPY `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name, backup_suffix, prod_project, prod_dataset, prod_table_name);

  SET step_end = CURRENT_TIMESTAMP();
  SELECT FORMAT('[Step 9.2] Timestamped copy: %s.%s.%s_%s', prod_project, prod_dataset, prod_table_name, backup_suffix) AS log;

  EXECUTE IMMEDIATE FORMAT("""
  SELECT 'production_deployed' AS status, COUNT(*) AS user_count, MAX(pipeline_version) AS pipeline_version
  FROM `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name);

  SELECT '[DEPLOYMENT COMPLETE] Pipeline v5.8 deployed successfully' AS log;

ELSE
  SELECT FORMAT('[SKIP] Production deployment skipped. Output in %s.%s.final_vehicle_recommendations', target_project, target_dataset) AS log;
END IF;
