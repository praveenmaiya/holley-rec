-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.15 (Universal + Fitment Products)
-- --------------------------------------------------------------------------------------------------
-- Based on V5.12 (no diversity filter), with the following improvement:
--   1. Add universal products (NOT in fitment catalog) to recommendation pool
--      - Universal products: recommendable to ANY user (no YMM filter needed)
--      - Fitment products: still require YMM match
--
-- Motivation (from reverse engineering analysis):
--   - V5.12 only recommends fitment products, missing 64% of VFU purchases
--   - Universal products (gauges, sensors, electronics) have comparable intent signals (23.8%)
--   - This change expands addressable purchases from 21% to 85% (21% + 64%)
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < sql/recommendations/v5_15_vehicle_fitment_recommendations.sql
-- ==================================================================================================

-- Pipeline version
DECLARE pipeline_version STRING DEFAULT 'v5.15';

-- Working dataset (intermediate tables)
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_15';

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
DECLARE pop_hist_start   DATE DEFAULT DATE '2025-01-10';

DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE allow_price_fallback BOOL DEFAULT TRUE;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_parttype_per_user INT64 DEFAULT 999;  -- V5.12: No diversity filter
DECLARE required_recs INT64 DEFAULT 4;

-- V5.15: Limit universal products to top N by popularity (prevent explosion)
DECLARE max_universal_products INT64 DEFAULT 500;

-- Dynamic year patterns for ORDER_DATE string pre-filter
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM CURRENT_DATE()) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)) AS STRING), '%');

-- Table names
DECLARE tbl_users STRING DEFAULT FORMAT('`%s.%s.users_with_v1_vehicles`', target_project, target_dataset);
DECLARE tbl_staged_events STRING DEFAULT FORMAT('`%s.%s.staged_events`', target_project, target_dataset);
DECLARE tbl_sku_prices STRING DEFAULT FORMAT('`%s.%s.sku_prices`', target_project, target_dataset);
DECLARE tbl_sku_images STRING DEFAULT FORMAT('`%s.%s.sku_image_urls`', target_project, target_dataset);
DECLARE tbl_eligible_parts STRING DEFAULT FORMAT('`%s.%s.eligible_parts`', target_project, target_dataset);
DECLARE tbl_universal_parts STRING DEFAULT FORMAT('`%s.%s.universal_eligible_parts`', target_project, target_dataset);  -- V5.15 NEW
DECLARE tbl_vehicle_generation STRING DEFAULT FORMAT('`%s.%s.vehicle_generation_fitment`', target_project, target_dataset);
DECLARE tbl_intent STRING DEFAULT FORMAT('`%s.%s.dedup_intent`', target_project, target_dataset);
DECLARE tbl_popularity STRING DEFAULT FORMAT('`%s.%s.sku_popularity_324d`', target_project, target_dataset);
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
""", tbl_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 0] Users with V1 vehicles: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'users_with_v1_vehicles' AS table_name, COUNT(*) AS row_count,
  CASE WHEN COUNT(*) >= 400000 THEN 'OK' ELSE 'WARNING: Low user count' END AS status
FROM %s
""", tbl_users);

-- ====================================================================================
-- STEP 1: STAGED EVENTS (Single Scan)
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
-- STEP 1.1: SKU PRICES
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
-- STEP 1.3a: ELIGIBLE PARTS (Fitment Products - YMM Required)
-- WHAT: Filter fitment catalog to recommendable products
-- HOW:  Join fitment→catalog→prices→images; exclude refurb/service/commodity/low-price
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
SELECT FORMAT('[Step 1.3a] Eligible fitment parts: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'eligible_fitment_parts' AS table_name, COUNT(*) AS row_count,
  COUNT(DISTINCT sku) AS unique_skus,
  CASE WHEN COUNT(*) >= 1000 THEN 'OK' ELSE 'WARNING: Low eligible parts' END AS status
FROM %s
""", tbl_eligible_parts);

-- ====================================================================================
-- STEP 1.3b: UNIVERSAL ELIGIBLE PARTS (V5.15 NEW)
-- -----------------------------------------------------------------------------------
-- WHAT: Products NOT in fitment catalog - can be recommended to ANY user
-- HOW:  All SKUs from import_items that are NOT in vehicle_product_fitment_data
-- ALGO: Apply same quality filters (price, image, no refurb/service)
--       Limit to top N by popularity to prevent explosion
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH fitment_skus AS (
  -- All SKUs that are in the fitment catalog (vehicle-specific)
  SELECT DISTINCT UPPER(TRIM(prod.product_number)) AS sku
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
),
refurb AS (
  SELECT DISTINCT UPPER(TRIM(PartNumber)) AS sku
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL AND LOWER(Tags) LIKE '%%refurbished%%'
),
all_catalog AS (
  -- All products from catalog with part type
  SELECT
    UPPER(TRIM(PartNumber)) AS sku,
    COALESCE(PartType, 'UNKNOWN') AS part_type
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL
),
universal_base AS (
  -- Products NOT in fitment catalog = universal
  SELECT ac.sku, ac.part_type
  FROM all_catalog ac
  LEFT JOIN fitment_skus fs ON ac.sku = fs.sku
  WHERE fs.sku IS NULL  -- Not in fitment catalog
),
universal_filtered AS (
  SELECT
    ub.sku,
    ub.part_type,
    img.image_url,
    COALESCE(price.price, @min_price) AS price
  FROM universal_base ub
  LEFT JOIN %s img ON ub.sku = img.sku
  LEFT JOIN %s price ON ub.sku = price.sku
  LEFT JOIN refurb r ON ub.sku = r.sku
  WHERE r.sku IS NULL
    AND NOT (
      ub.sku LIKE 'EXT-%%' OR
      ub.sku LIKE 'GIFT-%%' OR
      ub.sku LIKE 'WARRANTY-%%' OR
      ub.sku LIKE 'SERVICE-%%' OR
      ub.sku LIKE 'PREAUTH-%%'
    )
    AND COALESCE(price.price, @min_price) >= @min_price
    AND (price.price IS NOT NULL OR @allow_price_fallback)
    AND img.image_url IS NOT NULL
    AND img.image_url LIKE 'https://%%'
    -- Same commodity exclusions as fitment
    AND NOT (
      ub.part_type LIKE '%%Gasket%%'
      OR ub.part_type LIKE '%%Decal%%'
      OR ub.part_type LIKE '%%Key%%'
      OR ub.part_type LIKE '%%Washer%%'
      OR ub.part_type LIKE '%%Clamp%%'
      OR (ub.part_type LIKE '%%Bolt%%'
          AND ub.part_type NOT IN ('Engine Cylinder Head Bolt', 'Engine Bolt Kit'))
      OR (ub.part_type LIKE '%%Cap%%'
          AND ub.part_type NOT LIKE '%%Distributor Cap%%'
          AND ub.part_type NOT IN ('Wheel Hub Cap', 'Wheel Cap Set'))
    )
    AND NOT (ub.part_type = 'UNKNOWN' AND COALESCE(price.price, @min_price) < 3000)
),
-- V5.15: Add popularity ranking to limit universal products
with_popularity AS (
  SELECT
    uf.*,
    COALESCE(pop.popularity_score, 0) AS popularity_score,
    ROW_NUMBER() OVER (ORDER BY COALESCE(pop.popularity_score, 0) DESC, uf.sku) AS pop_rank
  FROM universal_filtered uf
  LEFT JOIN (
    -- Inline popularity calculation for universal products
    SELECT sku, LOG(1 + COUNT(*)) * 2 AS popularity_score
    FROM %s
    WHERE sku IS NOT NULL
      AND user_id IS NOT NULL
      AND UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    GROUP BY sku
  ) pop ON uf.sku = pop.sku
)
SELECT sku, part_type, image_url, price, popularity_score
FROM with_popularity
WHERE pop_rank <= @max_universal_products;
""", tbl_universal_parts, tbl_sku_images, tbl_sku_prices, tbl_staged_events)
USING min_price AS min_price, allow_price_fallback AS allow_price_fallback, max_universal_products AS max_universal_products;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 1.3b] Universal eligible parts: %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

EXECUTE IMMEDIATE FORMAT("""
SELECT 'universal_eligible_parts' AS table_name, COUNT(*) AS row_count,
  ROUND(AVG(popularity_score), 2) AS avg_popularity,
  COUNT(DISTINCT part_type) AS unique_part_types
FROM %s
""", tbl_universal_parts);

-- -----------------------------------------------------------------------------------
-- STEP 1.4: VEHICLE GENERATION FITMENT (Reporting - unchanged)
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
-- STEP 1.5: IMPORT ORDERS (Consolidated Scan)
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
    UPPER(TRIM(ITEM)) AS sku,
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    ORDER_DATE,
    SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
    AND (ORDER_DATE LIKE @current_year_pattern OR ORDER_DATE LIKE @previous_year_pattern)
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
      current_year_pattern AS current_year_pattern, previous_year_pattern AS previous_year_pattern;

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
-- STEP 2: SCORING (Intent + Popularity)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------------
-- STEP 2.1: INTENT SCORES (V5.15: Include both fitment AND universal SKUs)
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
),
-- V5.15: Include SKUs from both fitment AND universal pools
eligible_skus AS (
  SELECT DISTINCT sku FROM %s
  UNION DISTINCT
  SELECT DISTINCT sku FROM %s
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
WHERE EXISTS (SELECT 1 FROM eligible_skus es WHERE a.sku = es.sku);
""", tbl_intent, tbl_staged_events, tbl_eligible_parts, tbl_universal_parts);

-- -----------------------------------------------------------------------------------
-- STEP 2.2: POPULARITY SCORES (V5.15: VFU users only + both fitment AND universal SKUs)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH historical AS (
  -- V5.15: Only count orders from VFU users (not all 2M users)
  SELECT io.sku, COUNT(*) AS order_count
  FROM %s io
  WHERE io.is_popularity_window = 1
    AND io.email_lower IN (SELECT email_lower FROM %s)
  GROUP BY io.sku
),
recent AS (
  -- V5.15: Only count orders from VFU users
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
  LOG(1 + total_orders) * 2 AS popularity_score
FROM combined;
""", tbl_popularity, tbl_import_orders_filtered, tbl_users, tbl_staged_events, tbl_users);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Scoring (intent + popularity): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3: USER RECOMMENDATIONS (V5.15: UNION fitment + universal)
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------------
-- STEP 3.1: PURCHASE EXCLUSION
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id, sku AS
WITH bounds AS (
  SELECT DATE_SUB(@intent_window_end, INTERVAL @purchase_window_days DAY) AS start_date,
         @intent_window_end AS end_date
),
from_events AS (
  SELECT DISTINCT user_id, sku
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
-- STEP 3.2: SCORED RECOMMENDATIONS (V5.15: UNION fitment + universal candidates)
-- -----------------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH
-- Fitment candidates: user's vehicle must match product's vehicle
fitment_candidates AS (
  SELECT
    uv.user_id, uv.email_lower, uv.v1_year, uv.v1_make, uv.v1_model,
    ep.sku, img.image_url, CONCAT('https://www.holley.com/products/', ep.sku) AS product_url,
    ep.part_type,
    ep.price,
    'fitment' AS product_type  -- V5.15: Track source
  FROM %s uv
  JOIN %s ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN %s img ON ep.sku = img.sku
  WHERE img.image_url IS NOT NULL
),
-- Universal candidates: available to ALL users (no YMM filter)
-- V5.15: Cross join users with universal products
universal_candidates AS (
  SELECT
    uv.user_id, uv.email_lower, uv.v1_year, uv.v1_make, uv.v1_model,
    up.sku, up.image_url, CONCAT('https://www.holley.com/products/', up.sku) AS product_url,
    up.part_type,
    up.price,
    'universal' AS product_type  -- V5.15: Track source
  FROM %s uv
  CROSS JOIN %s up
),
-- Union both candidate sets
all_candidates AS (
  SELECT * FROM fitment_candidates
  UNION ALL
  SELECT * FROM universal_candidates
)
SELECT
  ac.user_id, ac.email_lower, ac.v1_year, ac.v1_make, ac.v1_model,
  ac.sku, ac.image_url, ac.product_url,
  ac.part_type,
  ac.price,
  ac.product_type,
  COALESCE(int.intent_type, 'none') AS intent_type,
  COALESCE(int.intent_score, 0) AS intent_score,
  COALESCE(pop.popularity_score, 0) AS popularity_score,
  ROUND(COALESCE(int.intent_score, 0) + COALESCE(pop.popularity_score, 0), 2) AS final_score
FROM all_candidates ac
LEFT JOIN %s int ON ac.user_id = int.user_id AND ac.sku = int.sku
LEFT JOIN %s pop ON ac.sku = pop.sku
LEFT JOIN %s purch ON ac.user_id = purch.user_id AND ac.sku = purch.sku
WHERE purch.sku IS NULL
  AND ac.sku IS NOT NULL
  AND ac.image_url IS NOT NULL;
""", tbl_scored, tbl_users, tbl_eligible_parts, tbl_sku_images, tbl_users, tbl_universal_parts,
    tbl_intent, tbl_popularity, tbl_purchase_excl);

-- -----------------------------------------------------------------------------------
-- STEP 3.3: VARIANT DEDUP + DIVERSITY (V5.12: max_parttype_per_user = 999, effectively no limit)
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
-- STEP 3.4: TOP 4 SELECTION
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
  MAX(CASE WHEN rn = 1 THEN product_type END) AS rec1_type,  -- V5.15: Track fitment vs universal
  MAX(CASE WHEN rn = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rn = 2 THEN price END) AS rec2_price,
  MAX(CASE WHEN rn = 2 THEN final_score END) AS rec2_score,
  MAX(CASE WHEN rn = 2 THEN image_url END) AS rec2_image,
  MAX(CASE WHEN rn = 2 THEN product_type END) AS rec2_type,
  MAX(CASE WHEN rn = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rn = 3 THEN price END) AS rec3_price,
  MAX(CASE WHEN rn = 3 THEN final_score END) AS rec3_score,
  MAX(CASE WHEN rn = 3 THEN image_url END) AS rec3_image,
  MAX(CASE WHEN rn = 3 THEN product_type END) AS rec3_type,
  MAX(CASE WHEN rn = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rn = 4 THEN price END) AS rec4_price,
  MAX(CASE WHEN rn = 4 THEN final_score END) AS rec4_score,
  MAX(CASE WHEN rn = 4 THEN image_url END) AS rec4_image,
  MAX(CASE WHEN rn = 4 THEN product_type END) AS rec4_type,
  CURRENT_TIMESTAMP() AS generated_at,
  @pipeline_version AS pipeline_version
FROM %s
GROUP BY email_lower, v1_year, v1_make, v1_model
HAVING COUNT(*) = 4;
""", tbl_final, tbl_ranked)
USING pipeline_version AS pipeline_version;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Recommendations (exclusion + dedup + diversity + pivot): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final Output Checks (V5.15: Include product type distribution)
-- ====================================================================================

EXECUTE IMMEDIATE FORMAT("""
SELECT 'final_vehicle_recommendations' AS table_name,
  COUNT(*) AS unique_users,
  CASE WHEN COUNT(*) >= 400000 THEN 'OK' ELSE 'WARNING: Low final user count' END AS status
FROM %s
""", tbl_final);

-- V5.15: Check product type distribution
EXECUTE IMMEDIATE FORMAT("""
SELECT 'product_type_distribution' AS check_name,
  COUNTIF(rec1_type = 'fitment') AS rec1_fitment,
  COUNTIF(rec1_type = 'universal') AS rec1_universal,
  COUNTIF(rec2_type = 'fitment') AS rec2_fitment,
  COUNTIF(rec2_type = 'universal') AS rec2_universal,
  COUNTIF(rec3_type = 'fitment') AS rec3_fitment,
  COUNTIF(rec3_type = 'universal') AS rec3_universal,
  COUNTIF(rec4_type = 'fitment') AS rec4_fitment,
  COUNTIF(rec4_type = 'universal') AS rec4_universal
FROM %s
""", tbl_final);

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
