-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.9 (Category-Aware Recommendations)
-- --------------------------------------------------------------------------------------------------
-- MAJOR CHANGES from V5.8:
--   1. Category matching: 50% of score based on PartType match with user's primary interest
--   2. Intent decay: Exponential decay with 30-day half-life (not fixed boundary)
--   3. Recency window: 60-day rolling window for primary category detection
--   4. Slot allocation: 2 primary category + 2 related (via co-purchase patterns)
--   5. Cold start: Fall back to vehicle segment popular
-- --------------------------------------------------------------------------------------------------
-- Scoring Formula (NEW):
--   final_score = category_score              (50 if matches, 25 if universal, 0 otherwise)
--               + intent_score_decayed        (with 30-day half-life decay)
--               + segment_popularity_score    (from v5.8)
--               + narrow_fit_bonus            (from v5.8)
--               + co_purchase_boost           (from v5.8)
-- --------------------------------------------------------------------------------------------------
-- Success Criteria:
--   - Match rate >= 1% (vs 0% in v5.8)
--   - Target: >= 5% match rate
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_9_vehicle_fitment_recommendations.sql
-- ==================================================================================================

-- Pipeline version
DECLARE pipeline_version STRING DEFAULT 'v5.9';

-- Working dataset (intermediate tables)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_9';

-- Production dataset (final deployment)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_vehicle_recommendations';

-- Deployment flag (set to TRUE to deploy to production)
DECLARE deploy_to_production BOOL DEFAULT FALSE;

-- Backup suffix (current date)
DECLARE backup_suffix STRING DEFAULT FORMAT_DATE('%Y_%m_%d', CURRENT_DATE());

-- V5.9: Category recency window (60 days - lenient)
DECLARE category_recency_days INT64 DEFAULT 60;

-- V5.9: Intent decay half-life (30 days - gentle decay)
DECLARE intent_decay_halflife INT64 DEFAULT 30;

-- V5.9: Category score weights
DECLARE category_match_score FLOAT64 DEFAULT 50.0;
DECLARE category_universal_score FLOAT64 DEFAULT 25.0;

-- Intent window: now uses rolling window for decay, not fixed boundary
DECLARE intent_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE intent_window_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL category_recency_days DAY);

-- Historical popularity: Keep Sep 1 boundary (import_orders data)
DECLARE pop_hist_end     DATE DEFAULT DATE '2025-08-31';
DECLARE pop_hist_start   DATE DEFAULT DATE '2025-01-10';

-- V5.8 parameters (kept)
DECLARE recency_window_days INT64 DEFAULT 90;
DECLARE min_co_purchase_count INT64 DEFAULT 20;

DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE allow_price_fallback BOOL DEFAULT TRUE;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE required_recs INT64 DEFAULT 4;

-- Dynamic year patterns for ORDER_DATE string pre-filter
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM CURRENT_DATE()) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)) AS STRING), '%');

-- Table names
DECLARE tbl_users_v1 STRING DEFAULT FORMAT('`%s.%s.users_with_v1_vehicles`', target_project, target_dataset);
DECLARE tbl_users_unified STRING DEFAULT FORMAT('`%s.%s.users_with_vehicles_unified`', target_project, target_dataset);
DECLARE tbl_staged_events STRING DEFAULT FORMAT('`%s.%s.staged_events`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_parts STRING DEFAULT FORMAT('`%s.%s.eligible_parts`', target_project, target_dataset);
DECLARE tbl_import_orders_filtered STRING DEFAULT FORMAT('`%s.%s.import_orders_filtered`', target_project, target_dataset);
DECLARE tbl_user_primary_category STRING DEFAULT FORMAT('`%s.%s.user_primary_category`', target_project, target_dataset);
DECLARE tbl_intent_decayed STRING DEFAULT FORMAT('`%s.%s.intent_scores_decayed`', target_project, target_dataset);
DECLARE tbl_segment_sales STRING DEFAULT FORMAT('`%s.%s.segment_product_sales`', target_project, target_dataset);
DECLARE tbl_segment_popularity STRING DEFAULT FORMAT('`%s.%s.segment_popularity_scores`', target_project, target_dataset);
DECLARE tbl_fitment_breadth STRING DEFAULT FORMAT('`%s.%s.sku_fitment_breadth`', target_project, target_dataset);
DECLARE tbl_co_purchases STRING DEFAULT FORMAT('`%s.%s.product_co_purchases`', target_project, target_dataset);
DECLARE tbl_category_co_purchases STRING DEFAULT FORMAT('`%s.%s.category_co_purchases`', target_project, target_dataset);
DECLARE tbl_purchase_excl STRING DEFAULT FORMAT('`%s.%s.user_purchased_parts_365d`', target_project, target_dataset);
DECLARE tbl_primary_candidates STRING DEFAULT FORMAT('`%s.%s.primary_category_candidates`', target_project, target_dataset);
DECLARE tbl_related_candidates STRING DEFAULT FORMAT('`%s.%s.related_category_candidates`', target_project, target_dataset);
DECLARE tbl_cold_start_candidates STRING DEFAULT FORMAT('`%s.%s.cold_start_candidates`', target_project, target_dataset);
DECLARE tbl_tiered_ranked STRING DEFAULT FORMAT('`%s.%s.tiered_ranked`', target_project, target_dataset);
DECLARE tbl_final STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);

-- Execution timing
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- ====================================================================================
-- STEP 0: USERS WITH VEHICLES
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

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

-- Simplified unified for v5.9 (v1 only for now)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT
  user_id,
  email_lower,
  email_upper,
  v1_year_int AS primary_year_int,
  v1_make AS primary_make,
  v1_model AS primary_model,
  v1_year,
  v1_year_int,
  v1_make,
  v1_model
FROM %s;
""", tbl_users_unified, tbl_users_v1);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0] Users: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 1: STAGED EVENTS (with PartType for category detection)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

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

-- SKU Prices
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, MAX(price) AS price, COUNT(*) AS observations
FROM %s
WHERE sku IS NOT NULL
GROUP BY sku;
""", tbl_sku_prices, tbl_staged_events);

-- SKU Images
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

-- Eligible Parts (with PartType)
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
    COALESCE(NULLIF(TRIM(cat.PartType), ''), 'UNIVERSAL') AS part_type  -- NULL -> UNIVERSAL
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
    AND NOT (f.part_type = 'UNIVERSAL' AND COALESCE(price.price, @min_price) < 3000)
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

-- Import orders filtered
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
-- STEP 2: USER PRIMARY CATEGORY (NEW in V5.9)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH user_events_with_category AS (
  -- Join events with PartType
  SELECT
    e.user_id,
    e.sku,
    e.event_ts,
    e.event_name,
    COALESCE(NULLIF(TRIM(ii.PartType), ''), 'UNIVERSAL') AS part_type
  FROM %s e
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` ii
    ON e.sku = UPPER(TRIM(ii.PartNumber))
),
-- Most recent interaction determines primary category
most_recent_per_user AS (
  SELECT
    user_id,
    part_type,
    event_ts,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_ts DESC) AS recency_rank
  FROM user_events_with_category
  WHERE part_type IS NOT NULL
)
SELECT
  user_id,
  part_type AS primary_category,
  event_ts AS last_activity_ts,
  TRUE AS has_recent_activity
FROM most_recent_per_user
WHERE recency_rank = 1;
""", tbl_user_primary_category, tbl_staged_events);

-- Add cold start users (no activity in last 60 days)
EXECUTE IMMEDIATE FORMAT("""
INSERT INTO %s (user_id, primary_category, last_activity_ts, has_recent_activity)
SELECT
  uv.user_id,
  'COLD_START' AS primary_category,
  NULL AS last_activity_ts,
  FALSE AS has_recent_activity
FROM %s uv
WHERE NOT EXISTS (
  SELECT 1 FROM %s upc WHERE upc.user_id = uv.user_id
);
""", tbl_user_primary_category, tbl_users_unified, tbl_user_primary_category);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] User primary category: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate primary categories
EXECUTE IMMEDIATE FORMAT("""
SELECT 'user_categories' AS check_name,
  COUNT(*) AS total_users,
  COUNTIF(has_recent_activity) AS users_with_activity,
  COUNTIF(NOT has_recent_activity) AS cold_start_users,
  ROUND(COUNTIF(has_recent_activity) * 100.0 / COUNT(*), 1) AS pct_with_activity,
  COUNT(DISTINCT primary_category) AS unique_categories
FROM %s
""", tbl_user_primary_category);

-- ====================================================================================
-- STEP 3: INTENT SCORES WITH EXPONENTIAL DECAY (NEW in V5.9)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH events_with_decay AS (
  SELECT
    user_id,
    sku,
    event_ts,
    event_name,
    DATE_DIFF(@intent_window_end, DATE(event_ts), DAY) AS days_ago,
    -- Decay factor: 0.5 ^ (days_ago / half_life)
    POW(0.5, DATE_DIFF(@intent_window_end, DATE(event_ts), DAY) / @intent_decay_halflife) AS decay_factor,
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
    -- Apply decay to base scores
    SUM(CASE WHEN intent_type = 'order' THEN 20 * decay_factor ELSE 0 END) AS order_score,
    SUM(CASE WHEN intent_type = 'cart' THEN 10 * decay_factor ELSE 0 END) AS cart_score,
    SUM(CASE WHEN intent_type = 'view' THEN 2 * decay_factor ELSE 0 END) AS view_score,
    COUNTIF(intent_type = 'order') AS order_count,
    COUNTIF(intent_type = 'cart') AS cart_count,
    COUNTIF(intent_type = 'view') AS view_count
  FROM events_with_decay
  WHERE intent_type IS NOT NULL
  GROUP BY user_id, sku
)
SELECT user_id, sku,
  CASE WHEN order_count > 0 THEN 'order' WHEN cart_count > 0 THEN 'cart' WHEN view_count > 0 THEN 'view' ELSE 'none' END AS intent_type,
  -- Use decayed scores instead of LOG-based
  ROUND(order_score + cart_score + view_score, 2) AS intent_score_decayed
FROM agg
WHERE EXISTS (SELECT 1 FROM %s ep WHERE agg.sku = ep.sku);
""", tbl_intent_decayed, tbl_staged_events, tbl_eligible_parts)
USING intent_window_end AS intent_window_end, intent_decay_halflife AS intent_decay_halflife;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Intent scores with decay: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 4: SEGMENT POPULARITY (from v5.8)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

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
HAVING COUNT(*) >= 2;
""", tbl_segment_sales, tbl_import_orders_filtered, tbl_users_unified);

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY segment_key, sku AS
SELECT
  segment_key,
  sku,
  segment_orders,
  LOG(1 + segment_orders) * 10 AS segment_popularity_score
FROM %s;
""", tbl_segment_popularity, tbl_segment_sales);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 4] Segment popularity: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 5: FITMENT BREADTH (from v5.8)
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
SELECT FORMAT('[Step 5] Fitment breadth: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 6: CO-PURCHASES + CATEGORY CO-PURCHASES (NEW in V5.9)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Product co-purchases (from v5.8)
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

-- Category co-purchases (NEW in V5.9)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY category_a, category_b AS
WITH order_baskets AS (
  SELECT
    io.email_lower,
    DATE(io.order_date_parsed) AS order_date,
    ARRAY_AGG(DISTINCT COALESCE(NULLIF(TRIM(ii.PartType), ''), 'UNIVERSAL')) AS basket_categories
  FROM %s io
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` ii
    ON io.sku = UPPER(TRIM(ii.PartNumber))
  WHERE io.is_popularity_window = 1
  GROUP BY io.email_lower, order_date
  HAVING ARRAY_LENGTH(ARRAY_AGG(DISTINCT COALESCE(NULLIF(TRIM(ii.PartType), ''), 'UNIVERSAL'))) BETWEEN 2 AND 5
),
co_cats AS (
  SELECT a AS category_a, b AS category_b, COUNT(*) AS co_category_count
  FROM order_baskets, UNNEST(basket_categories) AS a, UNNEST(basket_categories) AS b
  WHERE a < b
  GROUP BY category_a, category_b
  HAVING COUNT(*) >= 50  -- Higher threshold for categories
)
SELECT category_a, category_b, co_category_count
FROM co_cats;
""", tbl_category_co_purchases, tbl_import_orders_filtered);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 6] Co-purchases: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate category co-purchases
EXECUTE IMMEDIATE FORMAT("""
SELECT 'category_co_purchases' AS table_name, COUNT(*) AS total_pairs
FROM %s
""", tbl_category_co_purchases);

-- ====================================================================================
-- STEP 7: PURCHASE EXCLUSION
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
SELECT FORMAT('[Step 7] Purchase exclusion: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 8: CANDIDATE GENERATION (NEW STRUCTURE in V5.9)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Step 8.1: Primary category candidates (slots 1-2)
-- Products that match user's primary category AND fit their vehicle
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
  upc.primary_category,
  ep.sku,
  ep.part_type,
  ep.price,
  ep.image_url,
  'primary' AS slot_type,
  -- Category score (50 percent of total)
  CASE
    WHEN ep.part_type = upc.primary_category THEN @category_match_score
    WHEN ep.part_type = 'UNIVERSAL' THEN @category_universal_score
    ELSE 0
  END AS category_score,
  COALESCE(int.intent_score_decayed, 0) AS intent_score,
  COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
  COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
  0 AS co_purchase_boost,  -- Primary slots don't use co-purchase
  ROUND(
    CASE
      WHEN ep.part_type = upc.primary_category THEN @category_match_score
      WHEN ep.part_type = 'UNIVERSAL' THEN @category_universal_score
      ELSE 0
    END +
    COALESCE(int.intent_score_decayed, 0) +
    COALESCE(sp.segment_popularity_score, 0) +
    COALESCE(fb.narrow_fit_bonus, 0),
    2
  ) AS final_score
FROM %s uv
JOIN %s upc ON uv.user_id = upc.user_id AND upc.has_recent_activity = TRUE
JOIN %s ep
  ON uv.primary_year_int = ep.year AND uv.primary_make = ep.make AND uv.primary_model = ep.model
LEFT JOIN %s int ON uv.user_id = int.user_id AND ep.sku = int.sku
LEFT JOIN %s sp
  ON CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) = sp.segment_key
  AND ep.sku = sp.sku
LEFT JOIN %s fb ON ep.sku = fb.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
WHERE purch.sku IS NULL  -- Exclude purchased
  AND ep.image_url IS NOT NULL
  -- Category filter: only matching or universal
  AND (ep.part_type = upc.primary_category OR ep.part_type = 'UNIVERSAL');
""", tbl_primary_candidates, tbl_users_unified, tbl_user_primary_category, tbl_eligible_parts,
    tbl_intent_decayed, tbl_segment_popularity, tbl_fitment_breadth, tbl_purchase_excl)
USING category_match_score AS category_match_score, category_universal_score AS category_universal_score;

SELECT FORMAT('[Step 8.1] Primary category candidates created') AS log;

-- Step 8.2: Related category candidates (slots 3-4)
-- Products from co-purchased categories
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH user_related_categories AS (
  -- For each user, find related categories via co-purchase
  SELECT DISTINCT
    upc.user_id,
    upc.primary_category,
    CASE
      WHEN ccp.category_a = upc.primary_category THEN ccp.category_b
      ELSE ccp.category_a
    END AS related_category
  FROM %s upc
  JOIN %s ccp
    ON upc.primary_category = ccp.category_a OR upc.primary_category = ccp.category_b
  WHERE upc.has_recent_activity = TRUE
    AND upc.primary_category != 'UNIVERSAL'
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
  urc.related_category,
  ep.sku,
  ep.part_type,
  ep.price,
  ep.image_url,
  'related' AS slot_type,
  @category_universal_score AS category_score,  -- Related gets partial category score
  COALESCE(int.intent_score_decayed, 0) AS intent_score,
  COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
  COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
  0 AS co_purchase_boost,
  ROUND(
    @category_universal_score +
    COALESCE(int.intent_score_decayed, 0) +
    COALESCE(sp.segment_popularity_score, 0) +
    COALESCE(fb.narrow_fit_bonus, 0),
    2
  ) AS final_score
FROM %s uv
JOIN user_related_categories urc ON uv.user_id = urc.user_id
JOIN %s ep
  ON uv.primary_year_int = ep.year AND uv.primary_make = ep.make AND uv.primary_model = ep.model
  AND ep.part_type = urc.related_category
LEFT JOIN %s int ON uv.user_id = int.user_id AND ep.sku = int.sku
LEFT JOIN %s sp
  ON CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) = sp.segment_key
  AND ep.sku = sp.sku
LEFT JOIN %s fb ON ep.sku = fb.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
LEFT JOIN %s pc ON uv.user_id = pc.user_id AND ep.sku = pc.sku  -- Exclude primary candidates
WHERE purch.sku IS NULL
  AND pc.sku IS NULL  -- Not already in primary
  AND ep.image_url IS NOT NULL;
""", tbl_related_candidates, tbl_user_primary_category, tbl_category_co_purchases,
    tbl_users_unified, tbl_eligible_parts, tbl_intent_decayed, tbl_segment_popularity,
    tbl_fitment_breadth, tbl_purchase_excl, tbl_primary_candidates)
USING category_universal_score AS category_universal_score;

SELECT FORMAT('[Step 8.2] Related category candidates created') AS log;

-- Step 8.3: Cold start candidates (for users without recent activity)
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
  'COLD_START' AS primary_category,
  ep.sku,
  ep.part_type,
  ep.price,
  ep.image_url,
  'cold_start' AS slot_type,
  0 AS category_score,  -- No category boost for cold start
  0 AS intent_score,
  COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
  COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
  0 AS co_purchase_boost,
  ROUND(
    COALESCE(sp.segment_popularity_score, 0) +
    COALESCE(fb.narrow_fit_bonus, 0),
    2
  ) AS final_score
FROM %s uv
JOIN %s upc ON uv.user_id = upc.user_id AND upc.has_recent_activity = FALSE
JOIN %s ep
  ON uv.primary_year_int = ep.year AND uv.primary_make = ep.make AND uv.primary_model = ep.model
LEFT JOIN %s sp
  ON CONCAT(uv.primary_make, '|', uv.primary_model, '|', CAST(uv.primary_year_int AS STRING)) = sp.segment_key
  AND ep.sku = sp.sku
LEFT JOIN %s fb ON ep.sku = fb.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
WHERE purch.sku IS NULL
  AND ep.image_url IS NOT NULL;
""", tbl_cold_start_candidates, tbl_users_unified, tbl_user_primary_category,
    tbl_eligible_parts, tbl_segment_popularity, tbl_fitment_breadth, tbl_purchase_excl);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 8] All candidates: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate candidates
EXECUTE IMMEDIATE FORMAT("""
SELECT 'primary_candidates' AS tier, COUNT(*) AS row_count, COUNT(DISTINCT user_id) AS users FROM %s
UNION ALL
SELECT 'related_candidates', COUNT(*), COUNT(DISTINCT user_id) FROM %s
UNION ALL
SELECT 'cold_start_candidates', COUNT(*), COUNT(DISTINCT user_id) FROM %s
""", tbl_primary_candidates, tbl_related_candidates, tbl_cold_start_candidates);

-- ====================================================================================
-- STEP 9: TIERED RANKING + FINAL OUTPUT
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- Combine all candidates with slot priorities:
-- - Primary slots 1-2: from primary_candidates
-- - Related slots 3-4: from related_candidates (fallback to segment popular)
-- - Cold start: all 4 from cold_start_candidates
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH all_candidates AS (
  -- Primary category (for slots 1-2)
  SELECT *, 0 AS slot_priority FROM %s
  UNION ALL
  -- Related category (for slots 3-4)
  SELECT user_id, email_lower, primary_year_int, primary_make, primary_model,
         v1_year, v1_make, v1_model, related_category AS primary_category,
         sku, part_type, price, image_url, slot_type,
         category_score, intent_score, segment_popularity_score, narrow_fit_bonus, co_purchase_boost, final_score,
         1 AS slot_priority
  FROM %s
  UNION ALL
  -- Cold start (all slots)
  SELECT *, 0 AS slot_priority FROM %s
),
-- Variant dedup
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
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY slot_priority, final_score DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY slot_priority, final_score DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= @max_parttype_per_user
),
-- Rank within slot type, then combine
ranked_by_slot AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY user_id, slot_type
      ORDER BY final_score DESC, sku
    ) AS rank_in_slot_type
  FROM diversity_filtered
),
-- Allocate slots: 2 primary + 2 related (or 4 cold start)
slot_allocated AS (
  SELECT *,
    CASE
      WHEN slot_type = 'primary' AND rank_in_slot_type <= 2 THEN rank_in_slot_type
      WHEN slot_type = 'related' AND rank_in_slot_type <= 2 THEN rank_in_slot_type + 2
      WHEN slot_type = 'cold_start' AND rank_in_slot_type <= 4 THEN rank_in_slot_type
      ELSE NULL
    END AS slot_number
  FROM ranked_by_slot
)
SELECT * FROM slot_allocated WHERE slot_number IS NOT NULL;
""", tbl_tiered_ranked, tbl_primary_candidates, tbl_related_candidates, tbl_cold_start_candidates)
USING max_parttype_per_user AS max_parttype_per_user;

-- Pivot to wide format
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
  MAX(CASE WHEN slot_number = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN slot_number = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN slot_number = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN slot_number = 1 THEN image_url END) AS rec1_image,
  MAX(CASE WHEN slot_number = 1 THEN slot_type END) AS rec1_slot_type,
  MAX(CASE WHEN slot_number = 1 THEN part_type END) AS rec1_part_type,
  MAX(CASE WHEN slot_number = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN slot_number = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN slot_number = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN slot_number = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN slot_number = 2 THEN slot_type END) AS rec2_slot_type,
  MAX(CASE WHEN slot_number = 2 THEN part_type END) AS rec2_part_type,
  MAX(CASE WHEN slot_number = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN slot_number = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN slot_number = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN slot_number = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN slot_number = 3 THEN slot_type END) AS rec3_slot_type,
  MAX(CASE WHEN slot_number = 3 THEN part_type END) AS rec3_part_type,
  MAX(CASE WHEN slot_number = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN slot_number = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN slot_number = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN slot_number = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN slot_number = 4 THEN slot_type END) AS rec4_slot_type,
  MAX(CASE WHEN slot_number = 4 THEN part_type END) AS rec4_part_type,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s tr
JOIN users_with_4_recs u4 ON tr.user_id = u4.user_id
GROUP BY tr.email_lower, tr.v1_year, tr.v1_make, tr.v1_model;
""", tbl_final, tbl_tiered_ranked, tbl_tiered_ranked)
USING pipeline_version AS pipeline_version;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 9] Final output: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

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

-- Slot type distribution
EXECUTE IMMEDIATE FORMAT("""
SELECT 'slot_type_distribution' AS check_name,
  COUNTIF(rec1_slot_type = 'primary') AS slot1_primary,
  COUNTIF(rec1_slot_type = 'cold_start') AS slot1_cold,
  COUNTIF(rec2_slot_type = 'primary') AS slot2_primary,
  COUNTIF(rec2_slot_type = 'cold_start') AS slot2_cold,
  COUNTIF(rec3_slot_type = 'related') AS slot3_related,
  COUNTIF(rec3_slot_type = 'cold_start') AS slot3_cold,
  COUNTIF(rec4_slot_type = 'related') AS slot4_related,
  COUNTIF(rec4_slot_type = 'cold_start') AS slot4_cold
FROM %s
""", tbl_final);

-- Category diversity check
EXECUTE IMMEDIATE FORMAT("""
SELECT 'category_diversity' AS check_name,
  COUNT(DISTINCT rec1_part_type) AS unique_categories_slot1,
  COUNT(DISTINCT rec2_part_type) AS unique_categories_slot2,
  COUNT(DISTINCT rec3_part_type) AS unique_categories_slot3,
  COUNT(DISTINCT rec4_part_type) AS unique_categories_slot4
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

-- Cleanup
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_events);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Pipeline %s finished in %d seconds',
  pipeline_version,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 10: PRODUCTION DEPLOYMENT (Optional)
-- ====================================================================================
IF deploy_to_production THEN
  SET step_start = CURRENT_TIMESTAMP();

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s`
  COPY `%s.%s.final_vehicle_recommendations`
  """, prod_project, prod_dataset, prod_table_name, target_project, target_dataset);

  SELECT FORMAT('[Step 10.1] Deployed to production: %s.%s.%s', prod_project, prod_dataset, prod_table_name) AS log;

  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s_%s`
  COPY `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name, backup_suffix, prod_project, prod_dataset, prod_table_name);

  SET step_end = CURRENT_TIMESTAMP();
  SELECT FORMAT('[Step 10.2] Timestamped copy: %s.%s.%s_%s', prod_project, prod_dataset, prod_table_name, backup_suffix) AS log;

  EXECUTE IMMEDIATE FORMAT("""
  SELECT 'production_deployed' AS status, COUNT(*) AS user_count, MAX(pipeline_version) AS pipeline_version
  FROM `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name);

  SELECT '[DEPLOYMENT COMPLETE] Pipeline v5.9 deployed successfully' AS log;

ELSE
  SELECT FORMAT('[SKIP] Production deployment skipped. Output in %s.%s.final_vehicle_recommendations', target_project, target_dataset) AS log;
END IF;
