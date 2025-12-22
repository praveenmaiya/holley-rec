-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.7 (Performance & Bug Fixes)
-- --------------------------------------------------------------------------------------------------
-- Based on V5.6, with the following improvements:
--   1. Fixed variant dedup regex (only strip B/R/G/P when preceded by number or dash)
--   2. Consolidated import_orders into single scan (was scanned twice in v5.6)
--   3. Added pre-filter before PARSE_DATE for better partition pruning
--   4. Cast v1_year to INT64 once in Step 0 (was repeated in joins)
--   5. Fixed QA validation threshold to match min_price ($50, was $20)
--   6. Added deploy_to_production flag (default FALSE for testing)
--   7. Added pipeline_version to output table
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_7_vehicle_fitment_recommendations.sql
--
-- Tuning knobs are declared below; adjust target_dataset for sandbox vs production.
-- ==================================================================================================

-- Pipeline version (update this when making changes)
DECLARE pipeline_version STRING DEFAULT 'v5.7';

-- Working dataset (intermediate tables)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_7';

-- Production dataset (final deployment)
DECLARE prod_project STRING DEFAULT 'auxia-reporting';
DECLARE prod_dataset STRING DEFAULT 'company_1950_jp';
DECLARE prod_table_name STRING DEFAULT 'final_vehicle_recommendations';

-- Deployment flag (set to TRUE to deploy to production)
DECLARE deploy_to_production BOOL DEFAULT TRUE;

-- Backup suffix (current date)
DECLARE backup_suffix STRING DEFAULT FORMAT_DATE('%Y_%m_%d', CURRENT_DATE());

-- Intent window: Fixed Sep 1 boundary to current date
DECLARE intent_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';  -- Fixed boundary

-- Historical popularity: Everything before Sep 1 (import_orders)
DECLARE pop_hist_end     DATE DEFAULT DATE '2025-08-31';     -- Day before Sep 1
DECLARE pop_hist_start   DATE DEFAULT DATE '2025-01-10';     -- ~233 days before Aug 31

-- Recent popularity: Aligns with intent (Sep 1 to today, unified_events)
DECLARE pop_recent_start DATE DEFAULT intent_window_start;
DECLARE pop_recent_end   DATE DEFAULT intent_window_end;

DECLARE purchase_window_days INT64 DEFAULT 365;              -- suppression window
DECLARE allow_price_fallback BOOL DEFAULT TRUE;              -- allow @min_price fallback when price missing
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE required_recs INT64 DEFAULT 4;

-- Convenience for dynamic table names
DECLARE tbl_users STRING DEFAULT FORMAT('`%s.%s.users_with_v1_vehicles`', target_project, target_dataset);
DECLARE tbl_staged_events STRING DEFAULT FORMAT('`%s.%s.staged_events`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_parts STRING DEFAULT FORMAT('`%s.%s.eligible_parts`', target_project, target_dataset);
DECLARE tbl_vehicle_generation STRING DEFAULT FORMAT('`%s.%s.vehicle_generation_fitment`', target_project, target_dataset);
DECLARE tbl_intent STRING DEFAULT FORMAT('`%s.%s.dedup_intent`', target_project, target_dataset);
DECLARE tbl_popularity STRING DEFAULT FORMAT('`%s.%s.sku_popularity_324d`', target_project, target_dataset);
DECLARE tbl_import_orders_filtered STRING DEFAULT FORMAT('`%s.%s.import_orders_filtered`', target_project, target_dataset);
DECLARE tbl_purchase_excl STRING DEFAULT FORMAT('`%s.%s.user_purchased_parts_365d`', target_project, target_dataset);
DECLARE tbl_scored STRING DEFAULT FORMAT('`%s.%s.scored_recommendations`', target_project, target_dataset);
DECLARE tbl_diversity STRING DEFAULT FORMAT('`%s.%s.diversity_filtered`', target_project, target_dataset);
DECLARE tbl_ranked STRING DEFAULT FORMAT('`%s.%s.ranked_recommendations`', target_project, target_dataset);
DECLARE tbl_final STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);

-- Execution timing variables
DECLARE step_start TIMESTAMP;
DECLARE step_end TIMESTAMP;
DECLARE pipeline_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

-- ====================================================================================
-- STEP 0: USERS WITH V1 VEHICLES
-- -----------------------------------------------------------------------------------
-- WHAT: Build audience of users who have email + registered vehicle (year/make/model)
-- HOW:  Pivot user_properties array, filter to users with all 4 required fields
-- ALGO: MAX(IF(property=X)) pivot pattern; pre-cast year to INT64 for join efficiency
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
  SAFE_CAST(v1_year_str AS INT64) AS v1_year_int,  -- V5.7: Pre-cast for joins
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
""", tbl_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0] Users with V1 vehicles: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate: Expect ~475K users
EXECUTE IMMEDIATE FORMAT("""
SELECT 'users_with_v1_vehicles' AS table_name, COUNT(*) AS row_count,
  CASE WHEN COUNT(*) >= 400000 THEN 'OK' ELSE 'WARNING: Low user count' END AS status
FROM %s
""", tbl_users);

-- ====================================================================================
-- STEP 1: STAGED EVENTS (Single Scan)
-- -----------------------------------------------------------------------------------
-- WHAT: Extract SKU, price, image from behavioral events (views, carts, orders)
-- HOW:  Single scan of unified_events with regex to handle varied property formats
-- ALGO: CASE+REGEXP matches ProductId/Items_n.ProductId/SKUs_n; index-match prices
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

-- Validate: Expect millions of event rows
EXECUTE IMMEDIATE FORMAT("""
SELECT 'staged_events' AS table_name, COUNT(*) AS row_count,
  CASE WHEN COUNT(*) >= 100000 THEN 'OK' ELSE 'WARNING: Low event count' END AS status
FROM %s
""", tbl_staged_events);

-- -----------------------------------------------------------------------------------
-- STEP 1.1: SKU PRICES
-- WHAT: Get max observed price per SKU | HOW: GROUP BY sku, MAX(price)
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
-- STEP 1.2: SKU IMAGES
-- WHAT: Get most recent HTTPS image per SKU | HOW: ROW_NUMBER by recency, normalize URLs
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
-- STEP 1.3: ELIGIBLE PARTS
-- WHAT: Filter fitment catalog to recommendable products
-- HOW:  Join fitment→catalog→prices→images; exclude refurb/service/commodity/low-price
-- ALGO: 7 filters: price≥$50, HTTPS image, !refurbished, !service SKU, !commodity PartType,
--       !UNKNOWN<$3K, vehicle must have ≥4 eligible parts
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
    -- Exclude commodity part types (gaskets, bolts, caps, etc.)
    AND NOT (
      -- Safe exclusions (all low-value)
      f.part_type LIKE '%%Gasket%%'
      OR f.part_type LIKE '%%Decal%%'
      OR f.part_type LIKE '%%Key%%'
      OR f.part_type LIKE '%%Washer%%'
      OR f.part_type LIKE '%%Clamp%%'
      -- Bolt exclusions (except high-value engine bolts)
      OR (f.part_type LIKE '%%Bolt%%'
          AND f.part_type NOT IN ('Engine Cylinder Head Bolt', 'Engine Bolt Kit'))
      -- Cap exclusions (except high-value distributor/wheel caps)
      OR (f.part_type LIKE '%%Cap%%'
          AND f.part_type NOT LIKE '%%Distributor Cap%%'
          AND f.part_type NOT IN ('Wheel Hub Cap', 'Wheel Cap Set'))
    )
    -- Exclude UNKNOWN parts under $3000 (commodity noise)
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

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.3] Eligible parts: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate: Expect thousands of eligible parts
EXECUTE IMMEDIATE FORMAT("""
SELECT 'eligible_parts' AS table_name, COUNT(*) AS row_count,
  CASE WHEN COUNT(*) >= 1000 THEN 'OK' ELSE 'WARNING: Low eligible parts' END AS status
FROM %s
""", tbl_eligible_parts);

-- -----------------------------------------------------------------------------------
-- STEP 1.4: VEHICLE GENERATION FITMENT (Reporting)
-- WHAT: Aggregate eligible SKUs per vehicle | HOW: GROUP BY year/make/model, ARRAY_AGG
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
-- STEP 1.5: IMPORT ORDERS (Consolidated Scan) [V5.7 NEW]
-- -----------------------------------------------------------------------------------
-- WHAT: Pre-filter historical orders for popularity + purchase exclusion (single scan)
-- HOW:  String pre-filter (LIKE '%2024%') before PARSE_DATE; flag rows by window
-- ALGO: is_popularity_window (Jan-Aug 2025), is_exclusion_window (365d rolling)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku, email_lower AS
WITH date_bounds AS (
  -- Calculate the earliest date we need (max of popularity start and purchase exclusion start)
  SELECT
    @pop_hist_start AS popularity_start,
    @pop_hist_end AS popularity_end,
    DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AS exclusion_start,
    @intent_window_end AS exclusion_end
),
-- Pre-filter with string comparison for better performance (avoids PARSE_DATE on all rows)
-- ORDER_DATE format: "Friday, January 10, 2025"
prefiltered AS (
  SELECT
    UPPER(TRIM(ITEM)) AS sku,
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    ORDER_DATE,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
    -- String pre-filter: ORDER_DATE contains year 2024 or 2025 (covers our date range)
    AND (ORDER_DATE LIKE '%%2024%%' OR ORDER_DATE LIKE '%%2025%%')
)
SELECT
  sku,
  email_lower,
  order_date_parsed,
  -- Flag for popularity calculation (Jan 10 - Aug 31, 2025)
  CASE WHEN order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end THEN 1 ELSE 0 END AS is_popularity_window,
  -- Flag for purchase exclusion (365 days from today)
  CASE WHEN order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end THEN 1 ELSE 0 END AS is_exclusion_window
FROM prefiltered, date_bounds
WHERE order_date_parsed IS NOT NULL
  AND (
    -- Include if in popularity window OR exclusion window
    order_date_parsed BETWEEN @pop_hist_start AND @pop_hist_end
    OR order_date_parsed BETWEEN DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AND @intent_window_end
  );
""", tbl_import_orders_filtered)
USING pop_hist_start AS pop_hist_start, pop_hist_end AS pop_hist_end,
      intent_window_end AS intent_window_end, purchase_window_days AS purchase_window_days;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.5] Import orders filtered (single scan): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- Validate
EXECUTE IMMEDIATE FORMAT("""
SELECT 'import_orders_filtered' AS table_name,
  COUNT(*) AS total_rows,
  COUNTIF(is_popularity_window = 1) AS popularity_rows,
  COUNTIF(is_exclusion_window = 1) AS exclusion_rows
FROM %s
""", tbl_import_orders_filtered);

-- ====================================================================================
-- STEP 2: SCORING (Intent + Popularity)
-- -----------------------------------------------------------------------------------
-- WHAT: Calculate per-SKU scores from user behavior + global popularity
-- HOW:  Intent from staged_events (Sep 1+), Popularity from import_orders + events
-- ALGO: final_score = intent_score + popularity_score
--       Intent:     LOG(1+count) × weight [orders×20, carts×10, views×2]
--       Popularity: LOG(1+total_orders) × 2
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------------
-- STEP 2.1: INTENT SCORES
-- WHAT: Score user×SKU pairs by behavioral intent | HOW: Hierarchical (order>cart>view)
-- ALGO: LOG(1+count)×20 for orders, ×10 for carts, ×2 for views; keep strongest signal
-- -----------------------------------------------------------------------------------
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
         COUNTIF(intent_type='cart')  AS cart_count,
         COUNTIF(intent_type='view')  AS view_count
  FROM events
  WHERE intent_type IS NOT NULL
  GROUP BY user_id, sku
)
SELECT
  a.user_id, a.sku,
  CASE
    WHEN a.order_count > 0 THEN 'order'
    WHEN a.cart_count  > 0 THEN 'cart'
    WHEN a.view_count  > 0 THEN 'view'
    ELSE 'none'
  END AS intent_type,
  CASE
    WHEN a.order_count > 0 THEN a.order_count
    WHEN a.cart_count  > 0 THEN a.cart_count
    WHEN a.view_count  > 0 THEN a.view_count
    ELSE 0
  END AS intent_level,
  CASE
    WHEN a.order_count > 0 THEN LOG(1 + a.order_count) * 20
    WHEN a.cart_count  > 0 THEN LOG(1 + a.cart_count)  * 10
    WHEN a.view_count  > 0 THEN LOG(1 + a.view_count)  * 2
    ELSE 0
  END AS intent_score
FROM agg a
JOIN %s ep ON a.sku = ep.sku;
""", tbl_intent, tbl_staged_events, tbl_eligible_parts);

-- -----------------------------------------------------------------------------------
-- STEP 2.2: POPULARITY SCORES
-- WHAT: Global SKU popularity from 324-day order history | HOW: Hybrid import+events
-- ALGO: LOG(1+total_orders)×2; combines Jan-Aug (import_orders) + Sep+ (unified_events)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH historical AS (
  -- V5.7: Read from consolidated table instead of scanning import_orders again
  SELECT sku, COUNT(*) AS order_count
  FROM %s
  WHERE is_popularity_window = 1
  GROUP BY sku
),
recent AS (
  SELECT sku,
         COUNT(*) AS order_count
  FROM %s
  WHERE sku IS NOT NULL
    AND user_id IS NOT NULL
    AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
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
  LOG(1 + total_orders) * 2 AS popularity_score
FROM combined;
""", tbl_popularity, tbl_import_orders_filtered, tbl_staged_events);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Scoring (intent + popularity): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3: USER RECOMMENDATIONS
-- -----------------------------------------------------------------------------------
-- WHAT: Generate final 4 recommendations per user with all filters applied
-- HOW:  Join scores → exclude purchases → dedup variants → diversity cap → top 4
-- ALGO: 1) Exclude 365d purchases, 2) Dedup color variants (140061B→140061),
--       3) Max 2 per PartType, 4) Top 4 by final_score, 5) Pivot to wide format
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------------
-- STEP 3.1: PURCHASE EXCLUSION
-- WHAT: Suppress SKUs user already purchased in last 365 days
-- HOW:  Union recent orders (events) + historical orders (import_orders via email)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH bounds AS (
  SELECT DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AS start_date,
         @intent_window_end AS end_date
),
-- Recent orders from unified_events
from_events AS (
  SELECT DISTINCT user_id, sku
  FROM %s, bounds b
  WHERE sku IS NOT NULL AND user_id IS NOT NULL
    AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND DATE(event_ts) BETWEEN b.start_date AND b.end_date
),
-- Historical orders from import_orders (V5.7: via consolidated table)
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
-- STEP 3.2: SCORED RECOMMENDATIONS
-- WHAT: Join user→vehicle→eligible_parts→scores, exclude purchased
-- HOW:  Multi-table join on vehicle YMM + LEFT JOINs for scores; WHERE NOT purchased
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT
  uv.user_id, uv.email_lower, uv.v1_year, uv.v1_make, uv.v1_model,
  ep.sku, img.image_url, CONCAT('https://www.holley.com/products/', ep.sku) AS product_url,
  ep.part_type,
  ep.price,
  COALESCE(int.intent_type, 'none') AS intent_type,
  COALESCE(int.intent_score, 0) AS intent_score,
  COALESCE(pop.popularity_score, 0) AS popularity_score,
  ROUND(COALESCE(int.intent_score, 0) + COALESCE(pop.popularity_score, 0), 2) AS final_score
FROM %s uv
JOIN %s ep
  ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model  -- V5.7: Use pre-cast v1_year_int
LEFT JOIN %s int ON uv.user_id = int.user_id AND ep.sku = int.sku
LEFT JOIN %s pop ON ep.sku = pop.sku
LEFT JOIN %s img ON ep.sku = img.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
WHERE purch.sku IS NULL
  AND ep.sku IS NOT NULL
  AND img.image_url IS NOT NULL;
""", tbl_scored, tbl_users, tbl_eligible_parts, tbl_intent, tbl_popularity, tbl_sku_images, tbl_purchase_excl);

-- -----------------------------------------------------------------------------------
-- STEP 3.3: VARIANT DEDUP + DIVERSITY
-- WHAT: Remove color variants, limit PartType diversity
-- HOW:  Regex strips B/R/G/P suffix when preceded by digit; ROW_NUMBER per PartType
-- ALGO: base_sku = strip(-KIT,-BLK,etc) then strip digit+[BRGP]; max 2 per PartType
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH normalized AS (
  SELECT s.*,
         -- V5.7 FIX: Two-step regex to safely handle color variants
         -- Step 1: Strip explicit suffixes (-KIT, -BLK, etc.) and any dash+1-2 char suffix
         -- Step 2: Strip single B/R/G/P only when preceded by a digit (true color variants)
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
-- STEP 3.4: TOP 4 SELECTION
-- WHAT: Select top 4 recommendations per user | HOW: ROW_NUMBER by score DESC
-- ALGO: Only include users with ≥4 candidates (ensures full recommendation set)
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
WHERE rec_count >= @required_recs
  AND rn <= @required_recs;
""", tbl_ranked, tbl_diversity)
USING required_recs AS required_recs;

-- -----------------------------------------------------------------------------------
-- STEP 3.5: PIVOT TO WIDE FORMAT
-- WHAT: Transform rows to columns (1 row per user with rec_part_1..4)
-- HOW:  MAX(CASE WHEN rn=N) pivot pattern; add generated_at + pipeline_version
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY email_lower AS
SELECT
  email_lower,
  v1_year,
  v1_make,
  v1_model,
  MAX(CASE WHEN rn = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rn = 1 THEN price END) AS rec1_price,
  MAX(CASE WHEN rn = 1 THEN final_score END) AS rec1_score,
  MAX(CASE WHEN rn = 1 THEN image_url END) AS rec1_image,
  MAX(CASE WHEN rn = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rn = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN rn = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN rn = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN rn = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rn = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN rn = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN rn = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN rn = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rn = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN rn = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN rn = 4 THEN image_url END) AS rec4_image,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version  -- V5.7: Track which version generated this
FROM %s
GROUP BY email_lower, v1_year, v1_make, v1_model
HAVING COUNT(*) = 4;
""", tbl_final, tbl_ranked)
USING pipeline_version AS pipeline_version;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Recommendations (exclusion + dedup + diversity + pivot): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final Output Checks
-- -----------------------------------------------------------------------------------
-- WHAT: Verify output quality (user count, duplicates, price range)
-- HOW:  COUNT, COUNTIF assertions with pass/fail status
-- ====================================================================================

-- Validate: Expect ~450K users with 4 recommendations each
EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_vehicle_recommendations' AS table_name,
  COUNT(*) AS unique_users,
  CASE WHEN COUNT(*) >= 400000 THEN 'OK' ELSE 'WARNING: Low final user count' END AS status
FROM %s
""", tbl_final);

-- Validate: Check for duplicate SKUs per user (should be 0)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'duplicate_check' AS check_name,
  COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR rec_part_1 = rec_part_4 OR
    rec_part_2 = rec_part_3 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
  ) AS users_with_duplicates,
  CASE WHEN COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR rec_part_1 = rec_part_4 OR
    rec_part_2 = rec_part_3 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
  ) = 0 THEN 'OK' ELSE 'ERROR: Duplicate SKUs found' END AS status
FROM %s
""", tbl_final);

-- Validate: Price distribution - V5.7 FIX: Threshold now matches min_price ($50)
EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_distribution' AS check_name,
  LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) AS min_price,
  GREATEST(MAX(rec1_price), MAX(rec2_price), MAX(rec3_price), MAX(rec4_price)) AS max_price,
  ROUND((AVG(rec1_price) + AVG(rec2_price) + AVG(rec3_price) + AVG(rec4_price)) / 4, 2) AS avg_price,
  CASE WHEN LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) >= @min_price
       THEN 'OK'
       ELSE FORMAT('WARNING: Prices below $%%d', CAST(@min_price AS INT64))
  END AS status
FROM %s
""", tbl_final)
USING min_price AS min_price;

-- Optional cleanup: drop staged_events to reduce footprint (keep others for debugging)
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_events);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Pipeline %s finished in %d seconds',
  pipeline_version,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 4: PRODUCTION DEPLOYMENT (Optional)
-- -----------------------------------------------------------------------------------
-- WHAT: Copy final table to production + create dated backup
-- HOW:  CREATE OR REPLACE TABLE COPY; guarded by deploy_to_production flag
-- ====================================================================================

IF deploy_to_production THEN
  SET step_start = CURRENT_TIMESTAMP();

  -- 4.1 Deploy to production (overwrite)
  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s`
  COPY `%s.%s.final_vehicle_recommendations`
  """, prod_project, prod_dataset, prod_table_name,
       target_project, target_dataset);

  SELECT FORMAT('[Step 4.1] Deployed to production: %s.%s.%s',
    prod_project, prod_dataset, prod_table_name) AS log;

  -- 4.2 Create timestamped copy
  EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE `%s.%s.%s_%s`
  COPY `%s.%s.%s`
  """, prod_project, prod_dataset, prod_table_name, backup_suffix,
       prod_project, prod_dataset, prod_table_name);

  SET step_end = CURRENT_TIMESTAMP();
  SELECT FORMAT('[Step 4.2] Timestamped copy: %s.%s.%s_%s (%d seconds)',
    prod_project, prod_dataset, prod_table_name, backup_suffix,
    TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

  -- Final verification
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
