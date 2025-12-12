-- ==================================================================================================
-- Holley Vehicle Fitment Recommendations – V5.6 (implements V5.3 hybrid LOG spec)
-- --------------------------------------------------------------------------------------------------
-- Adopted from ChatGPT collaboration (November 2025)
-- Reviewed and approved by Claude Sonnet
-- --------------------------------------------------------------------------------------------------
-- 3-Step pipeline
--   1) Fitment/Eligibility: price >= $50, HTTPS image, refurb + service SKU filters, vehicle fitment,
--      generation min-parts check (>=4), commodity PartType exclusions (gaskets, bolts, caps, etc.).
--   2) Scoring: LOG-scaled intent (Sep 1 to today) + hybrid popularity (import_orders < Sep 1,
--      unified_events >= Sep 1). Score ALL parts; user purchases still contribute to scores.
--   3) Recommendation: purchase exclusion (365d hybrid window), variant dedup (base_sku), diversity cap,
--      top 4 per user.
-- --------------------------------------------------------------------------------------------------
-- Usage:
--   bq query --use_legacy_sql=false < implementations/v5/sql/v5_6_vehicle_fitment_recommendations.sql
--
-- Tuning knobs are declared below; adjust target_dataset for sandbox vs production.
-- ==================================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_4';

-- Intent window: Fixed Sep 1 boundary to current date
DECLARE intent_window_end   DATE DEFAULT CURRENT_DATE();
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';  -- Fixed boundary

-- Historical popularity: Everything before Sep 1 (import_orders)
DECLARE pop_hist_end     DATE DEFAULT DATE '2025-08-31';     -- Day before Sep 1
DECLARE pop_hist_start   DATE DEFAULT DATE '2025-01-10';     -- ~234 days before Aug 31

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
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
SELECT DISTINCT
  user_id,
  LOWER(email_val) AS email_lower,
  UPPER(email_val) AS email_upper,
  v1_year, v1_make, v1_model
FROM (
  SELECT user_id,
         MAX(IF(LOWER(p.property_name) = 'email', TRIM(p.string_value), NULL)) AS email_val,
         MAX(IF(LOWER(p.property_name) = 'v1_year', COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year,
         MAX(IF(LOWER(p.property_name) = 'v1_make', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_make,
         MAX(IF(LOWER(p.property_name) = 'v1_model', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_model
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`, UNNEST(user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email','v1_year','v1_make','v1_model')
  GROUP BY user_id
)
WHERE email_val IS NOT NULL AND v1_year IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL;
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
-- STEP 1: VEHICLE FITMENT PIPELINE (ELIGIBILITY)
--  - Stage events once (intent + price + image extraction)
--  - Price >= $20, HTTPS image, refurb/service filters, vehicle fitment, min 4 per generation
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

-- 1.1 SKU Prices
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
SELECT sku, MAX(price) AS price, COUNT(*) AS observations
FROM %s
WHERE sku IS NOT NULL
GROUP BY sku;
""", tbl_sku_prices, tbl_staged_events);

-- 1.2 SKU Images (HTTPS normalized)
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

-- 1.3 Eligible Parts (apply filters; fitment join; refurb + service prefixes + price + image)
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

-- 1.4 Vehicle Generation Fitment table (for reporting)
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
-- STEP 2: RANKING & SCORING
--  - Intent: hierarchical LOG scaled (orders > carts > views), 90d window
--  - Popularity: hybrid 324d (import_orders + unified_events split at Sep 1), LOG scaled
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- 2.1 Intent (dedup strongest per user/sku)
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

-- 2.2 Popularity (hybrid 324d)
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY sku AS
WITH historical AS (
  SELECT UPPER(TRIM(ITEM)) AS sku,
         COUNT(*) AS order_count
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', ORDER_DATE) BETWEEN @pop_hist_start AND @pop_hist_end
    AND NOT (ITEM LIKE 'EXT-%%' OR ITEM LIKE 'GIFT-%%' OR ITEM LIKE 'WARRANTY-%%' OR ITEM LIKE 'SERVICE-%%' OR ITEM LIKE 'PREAUTH-%%')
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
""", tbl_popularity, tbl_staged_events)
USING pop_hist_start AS pop_hist_start, pop_hist_end AS pop_hist_end;

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 2] Scoring (intent + popularity): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- STEP 3: USER RECOMMENDATIONS (filters after scoring)
--  - Purchase exclusion (365d hybrid)
--  - Variant dedup, diversity, top 4
-- ====================================================================================
SET step_start = CURRENT_TIMESTAMP();

-- 3.1 Purchase Exclusion (hybrid window)
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
  SELECT uv.user_id, UPPER(TRIM(io.ITEM)) AS sku
  FROM `auxia-gcp.data_company_1950.import_orders` io
  JOIN %s uv
    ON LOWER(TRIM(io.SHIP_TO_EMAIL)) = uv.email_lower
  JOIN bounds b
      ON SAFE.PARSE_DATE('%%A, %%B %%d, %%Y', io.ORDER_DATE) BETWEEN b.start_date AND b.end_date
  WHERE NOT (io.ITEM LIKE 'EXT-%%' OR io.ITEM LIKE 'GIFT-%%' OR io.ITEM LIKE 'WARRANTY-%%' OR io.ITEM LIKE 'SERVICE-%%' OR io.ITEM LIKE 'PREAUTH-%%')
)
SELECT DISTINCT user_id, sku FROM (
  SELECT * FROM from_events
  UNION DISTINCT
  SELECT * FROM from_import
);
""", tbl_purchase_excl, tbl_staged_events, tbl_users)
USING purchase_window_days AS purchase_window_days, intent_window_end AS intent_window_end;

-- 3.2 Score join + filters + diversity + top 4
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
  ON SAFE_CAST(uv.v1_year AS INT64) = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
LEFT JOIN %s int ON uv.user_id = int.user_id AND ep.sku = int.sku
LEFT JOIN %s pop ON ep.sku = pop.sku
LEFT JOIN %s img ON ep.sku = img.sku
LEFT JOIN %s purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
WHERE purch.sku IS NULL
  AND ep.sku IS NOT NULL
  AND img.image_url IS NOT NULL;
""", tbl_scored, tbl_users, tbl_eligible_parts, tbl_intent, tbl_popularity, tbl_sku_images, tbl_purchase_excl);

-- Variant dedup + diversity cap + top 4
EXECUTE IMMEDIATE FORMAT("""
CREATE OR REPLACE TABLE %s
CLUSTER BY user_id AS
WITH normalized AS (
  SELECT s.*,
         REGEXP_REPLACE(s.sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2}|[BRGP])$', '') AS base_sku
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

-- Rank top 4 per user (filter to users with at least required_recs)
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

-- Pivot to wide format (1 row per user with rec_part_1..4)
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
  CURRENT_TIMESTAMP() AS generated_at
FROM %s
GROUP BY email_lower, v1_year, v1_make, v1_model
HAVING COUNT(*) = 4;
""", tbl_final, tbl_ranked);

SET step_end = CURRENT_TIMESTAMP();
SELECT FORMAT('[Step 3] Recommendations (exclusion + dedup + diversity + pivot): %d seconds', TIMESTAMP_DIFF(step_end, step_start, SECOND)) AS log;

-- ====================================================================================
-- VALIDATION: Final output checks
-- ====================================================================================

-- Validate: Expect ~446K users with 4 recommendations each
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

-- Validate: Price distribution
EXECUTE IMMEDIATE FORMAT("""
SELECT 'price_distribution' AS check_name,
  LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) AS min_price,
  GREATEST(MAX(rec1_price), MAX(rec2_price), MAX(rec3_price), MAX(rec4_price)) AS max_price,
  ROUND((AVG(rec1_price) + AVG(rec2_price) + AVG(rec3_price) + AVG(rec4_price)) / 4, 2) AS avg_price,
  CASE WHEN LEAST(MIN(rec1_price), MIN(rec2_price), MIN(rec3_price), MIN(rec4_price)) >= 20 THEN 'OK' ELSE 'WARNING: Prices below $20' END AS status
FROM %s
""", tbl_final);

-- Optional cleanup: drop staged_events to reduce footprint (keep others for debugging)
EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS %s", tbl_staged_events);

-- Pipeline complete
SELECT FORMAT('[COMPLETE] Total pipeline time: %d seconds',
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), pipeline_start, SECOND)) AS log;
