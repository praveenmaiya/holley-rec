-- ==================================================================================================
-- V5.8 Retrospective Backtest
-- --------------------------------------------------------------------------------------------------
-- Goal: Validate v5.8 algorithm by testing if Dec 15 recommendations would have predicted
--       actual purchases in the Dec 15 - Jan 5 window (21 days)
--
-- Approach:
--   1. Generate recommendations "as of Dec 15" using v5.8 logic
--   2. Get actual purchases from Dec 15 - Jan 5
--   3. Match recommendations to purchases
--   4. Compare v5.7 vs v5.8 match rates
-- ==================================================================================================

-- Backtest parameters
DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';

-- Intent window: Sep 1 to test cutoff (not CURRENT_DATE)
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';  -- Fixed per spec

-- Historical popularity window (unchanged)
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';

-- Other parameters
DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE min_co_purchase_count INT64 DEFAULT 20;
DECLARE allow_price_fallback BOOL DEFAULT TRUE;

-- Dynamic year patterns for ORDER_DATE string pre-filter
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM test_cutoff_date) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(test_cutoff_date, INTERVAL 365 DAY)) AS STRING), '%');

-- Working dataset
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_8';

-- ==================================================================================================
-- STEP 1: USERS WITH VEHICLES (as of Dec 15)
-- ==================================================================================================

CREATE TEMP TABLE users_with_vehicles AS
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

SELECT 'Step 1: Users with vehicles' AS step, COUNT(*) AS count FROM users_with_vehicles;

-- ==================================================================================================
-- STEP 2: STAGED EVENTS (Sep 1 to Dec 15 only)
-- ==================================================================================================

CREATE TEMP TABLE staged_events AS
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
           AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      WHEN UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER'
           AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      ELSE NULL
    END AS sku,
    CASE
      WHEN LOWER(ep.property_name) IN ('price','itemprice')
        THEN COALESCE(ep.double_value, SAFE_CAST(ep.string_value AS FLOAT64))
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.itemprice$')
        THEN COALESCE(ep.double_value, SAFE_CAST(ep.string_value AS FLOAT64))
    END AS price_val,
    CASE
      WHEN LOWER(ep.property_name) = 'imageurl' THEN ep.string_value
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.imageurl$') THEN ep.string_value
    END AS image_val
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep
  WHERE DATE(t.client_event_timestamp) BETWEEN intent_window_start AND intent_window_end
    AND UPPER(t.event_name) IN ('VIEWED PRODUCT','ORDERED PRODUCT','CART UPDATE','PLACED ORDER','CONSUMER WEBSITE ORDER')
)
SELECT user_id, sku, event_ts, event_name, MAX(price_val) AS price, MAX(image_val) AS image_url_raw
FROM raw_events
WHERE sku IS NOT NULL
GROUP BY user_id, sku, event_ts, event_name;

SELECT 'Step 2: Staged events' AS step, COUNT(*) AS count FROM staged_events;

-- ==================================================================================================
-- STEP 3: SKU PRICES & IMAGES
-- ==================================================================================================

CREATE TEMP TABLE sku_prices AS
SELECT sku, MAX(price) AS price
FROM staged_events
WHERE price IS NOT NULL
GROUP BY sku;

CREATE TEMP TABLE sku_images AS
SELECT sku, image_url
FROM (
  SELECT sku,
    REGEXP_REPLACE(
      CASE
        WHEN image_url_raw LIKE '//%' THEN CONCAT('https:', image_url_raw)
        WHEN LOWER(image_url_raw) LIKE 'http://%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
        ELSE image_url_raw
      END, '^//', 'https://'
    ) AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM staged_events
  WHERE image_url_raw IS NOT NULL
)
WHERE rn = 1 AND image_url LIKE 'https://%';

-- ==================================================================================================
-- STEP 4: ELIGIBLE PARTS
-- ==================================================================================================

CREATE TEMP TABLE eligible_parts AS
WITH refurb AS (
  SELECT DISTINCT UPPER(TRIM(PartNumber)) AS sku
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL AND LOWER(Tags) LIKE '%refurbished%'
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
)
SELECT f.*, COALESCE(img.image_url, 'https://placeholder') AS image_url, COALESCE(price.price, min_price) AS price
FROM fitment f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
LEFT JOIN refurb r ON f.sku = r.sku
WHERE r.sku IS NULL
  AND NOT (f.sku LIKE 'EXT-%' OR f.sku LIKE 'GIFT-%' OR f.sku LIKE 'WARRANTY-%' OR f.sku LIKE 'SERVICE-%' OR f.sku LIKE 'PREAUTH-%')
  AND COALESCE(price.price, min_price) >= min_price
  AND (price.price IS NOT NULL OR allow_price_fallback);
-- NOTE: Image filter relaxed for backtest (production requires real images)

SELECT 'Step 4: Eligible parts' AS step, COUNT(*) AS count FROM eligible_parts;

-- ==================================================================================================
-- STEP 5: IMPORT ORDERS (for popularity and exclusion)
-- ==================================================================================================

CREATE TEMP TABLE import_orders_filtered AS
WITH prefiltered AS (
  SELECT
    UPPER(TRIM(ITEM)) AS sku,
    LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
    ORDER_DATE,
    SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) AS order_date_parsed
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL
    AND NOT (ITEM LIKE 'EXT-%' OR ITEM LIKE 'GIFT-%' OR ITEM LIKE 'WARRANTY-%' OR ITEM LIKE 'SERVICE-%' OR ITEM LIKE 'PREAUTH-%')
    AND (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
)
SELECT sku, email_lower, order_date_parsed,
  CASE WHEN order_date_parsed BETWEEN pop_hist_start AND pop_hist_end THEN 1 ELSE 0 END AS is_popularity_window,
  CASE WHEN order_date_parsed BETWEEN DATE_SUB(intent_window_end, INTERVAL purchase_window_days DAY) AND intent_window_end THEN 1 ELSE 0 END AS is_exclusion_window
FROM prefiltered
WHERE order_date_parsed IS NOT NULL;

-- ==================================================================================================
-- STEP 6: SEGMENT POPULARITY (V5.8 NEW LOGIC)
-- ==================================================================================================

CREATE TEMP TABLE segment_product_sales AS
SELECT
  CONCAT(UPPER(uv.v1_make), '|', UPPER(uv.v1_model), '|', CAST(uv.v1_year_int AS STRING)) AS segment_key,
  io.sku,
  COUNT(*) AS segment_orders
FROM import_orders_filtered io
JOIN users_with_vehicles uv ON io.email_lower = uv.email_lower
WHERE io.is_popularity_window = 1
GROUP BY 1, 2
HAVING COUNT(*) >= 2;

CREATE TEMP TABLE segment_popularity AS
SELECT
  segment_key,
  sku,
  segment_orders,
  LOG(1 + segment_orders) * 10 AS segment_popularity_score
FROM segment_product_sales;

SELECT 'Step 6: Segment popularity' AS step, COUNT(DISTINCT segment_key) AS segments, COUNT(DISTINCT sku) AS skus FROM segment_popularity;

-- ==================================================================================================
-- STEP 7: FITMENT BREADTH + NARROW FIT BONUS (V5.8 NEW LOGIC)
-- ==================================================================================================

CREATE TEMP TABLE fitment_breadth AS
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
FROM eligible_parts
GROUP BY sku;

-- ==================================================================================================
-- STEP 8: CO-PURCHASE SIGNALS (V5.8 NEW LOGIC)
-- ==================================================================================================

CREATE TEMP TABLE co_purchases AS
WITH order_baskets AS (
  SELECT email_lower, DATE(order_date_parsed) AS order_date, ARRAY_AGG(DISTINCT sku) AS basket_skus
  FROM import_orders_filtered
  WHERE is_popularity_window = 1
  GROUP BY email_lower, order_date
  HAVING ARRAY_LENGTH(ARRAY_AGG(DISTINCT sku)) BETWEEN 2 AND 10
),
co_pairs AS (
  SELECT a AS sku_a, b AS sku_b, COUNT(*) AS co_purchase_count
  FROM order_baskets, UNNEST(basket_skus) AS a, UNNEST(basket_skus) AS b
  WHERE a < b
  GROUP BY sku_a, sku_b
  HAVING COUNT(*) >= min_co_purchase_count
)
SELECT sku_a, sku_b, co_purchase_count,
  LOG(1 + co_purchase_count) * 3 AS co_purchase_boost
FROM co_pairs;

-- ==================================================================================================
-- STEP 9: INTENT SCORES
-- ==================================================================================================

CREATE TEMP TABLE intent_scores AS
WITH events AS (
  SELECT user_id, sku,
    CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN 'order'
      WHEN UPPER(event_name) = 'CART UPDATE' THEN 'cart'
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN 'view'
      ELSE NULL
    END AS intent_type
  FROM staged_events
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
  CASE WHEN order_count > 0 THEN LOG(1 + order_count) * 20
       WHEN cart_count > 0 THEN LOG(1 + cart_count) * 10
       WHEN view_count > 0 THEN LOG(1 + view_count) * 2
       ELSE 0
  END AS intent_score
FROM agg;

-- ==================================================================================================
-- STEP 10: PURCHASE EXCLUSION (before Dec 15)
-- ==================================================================================================

CREATE TEMP TABLE purchase_exclusion AS
WITH from_events AS (
  SELECT DISTINCT user_id, sku
  FROM staged_events
  WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
    AND DATE(event_ts) BETWEEN DATE_SUB(intent_window_end, INTERVAL purchase_window_days DAY) AND intent_window_end
),
from_import AS (
  SELECT uv.user_id, io.sku
  FROM import_orders_filtered io
  JOIN users_with_vehicles uv ON io.email_lower = uv.email_lower
  WHERE io.is_exclusion_window = 1
)
SELECT DISTINCT user_id, sku FROM (
  SELECT * FROM from_events
  UNION DISTINCT
  SELECT * FROM from_import
);

-- ==================================================================================================
-- STEP 11: V5.8 BACKTEST RECOMMENDATIONS
-- ==================================================================================================

CREATE TEMP TABLE v5_8_backtest_recs AS
WITH user_co_purchase_boost AS (
  SELECT purch.user_id, cp.sku_b AS sku, MAX(cp.co_purchase_boost) AS co_purchase_boost
  FROM purchase_exclusion purch
  JOIN co_purchases cp ON purch.sku = cp.sku_a
  GROUP BY purch.user_id, cp.sku_b
  UNION ALL
  SELECT purch.user_id, cp.sku_a AS sku, MAX(cp.co_purchase_boost) AS co_purchase_boost
  FROM purchase_exclusion purch
  JOIN co_purchases cp ON purch.sku = cp.sku_b
  GROUP BY purch.user_id, cp.sku_a
),
candidates AS (
  SELECT
    uv.user_id,
    uv.email_lower,
    uv.v1_year,
    uv.v1_year_int,
    uv.v1_make,
    uv.v1_model,
    ep.sku,
    ep.part_type,
    ep.price,
    ep.image_url,
    COALESCE(int.intent_score, 0) AS intent_score,
    COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
    COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
    COALESCE(ucb.co_purchase_boost, 0) AS co_purchase_boost,
    -- V5.8 scoring formula
    ROUND(
      COALESCE(int.intent_score, 0) +
      COALESCE(sp.segment_popularity_score, 0) +
      COALESCE(fb.narrow_fit_bonus, 0) +
      COALESCE(ucb.co_purchase_boost, 0),
      2
    ) AS final_score_v58
  FROM users_with_vehicles uv
  JOIN eligible_parts ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN segment_popularity sp
    ON CONCAT(uv.v1_make, '|', uv.v1_model, '|', CAST(uv.v1_year_int AS STRING)) = sp.segment_key
    AND ep.sku = sp.sku
  LEFT JOIN fitment_breadth fb ON ep.sku = fb.sku
  LEFT JOIN user_co_purchase_boost ucb ON uv.user_id = ucb.user_id AND ep.sku = ucb.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
-- Variant dedup
normalized AS (
  SELECT *,
    REGEXP_REPLACE(
      REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
      r'([0-9])[BRGP]$', r'\1'
    ) AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v58 DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v58 DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= 2
),
-- Top 4 per user
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v58 DESC, sku) AS rank_v58
  FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v58 <= 4;

-- Pivot to wide format
CREATE TEMP TABLE v5_8_recs_wide AS
WITH users_with_4_recs AS (
  SELECT user_id FROM v5_8_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  MAX(CASE WHEN rank_v58 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v58 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v58 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v58 = 4 THEN sku END) AS rec_part_4
FROM v5_8_backtest_recs r
JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 11: V5.8 backtest recs' AS step, COUNT(*) AS users FROM v5_8_recs_wide;

-- ==================================================================================================
-- STEP 12: V5.7 BASELINE RECOMMENDATIONS (for comparison)
-- Uses global popularity instead of segment popularity, no narrow-fit bonus, no co-purchase
-- ==================================================================================================

CREATE TEMP TABLE global_popularity AS
SELECT
  sku,
  COUNT(*) AS global_orders,
  LOG(1 + COUNT(*)) * 2 AS popularity_score  -- V5.7 formula
FROM import_orders_filtered
WHERE is_popularity_window = 1
GROUP BY sku;

CREATE TEMP TABLE v5_7_backtest_recs AS
WITH candidates AS (
  SELECT
    uv.user_id,
    uv.email_lower,
    uv.v1_year,
    uv.v1_year_int,
    uv.v1_make,
    uv.v1_model,
    ep.sku,
    ep.part_type,
    -- V5.7 scoring formula: intent + global popularity
    ROUND(
      COALESCE(int.intent_score, 0) +
      COALESCE(gp.popularity_score, 0),
      2
    ) AS final_score_v57
  FROM users_with_vehicles uv
  JOIN eligible_parts ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN global_popularity gp ON ep.sku = gp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
-- Variant dedup
normalized AS (
  SELECT *,
    REGEXP_REPLACE(
      REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
      r'([0-9])[BRGP]$', r'\1'
    ) AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v57 DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v57 DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= 2
),
-- Top 4 per user
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v57 DESC, sku) AS rank_v57
  FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v57 <= 4;

-- Pivot to wide format
CREATE TEMP TABLE v5_7_recs_wide AS
WITH users_with_4_recs AS (
  SELECT user_id FROM v5_7_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  MAX(CASE WHEN rank_v57 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v57 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v57 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v57 = 4 THEN sku END) AS rec_part_4
FROM v5_7_backtest_recs r
JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 12: V5.7 baseline recs' AS step, COUNT(*) AS users FROM v5_7_recs_wide;

-- ==================================================================================================
-- STEP 13: ACTUAL PURCHASES (Dec 15 - Jan 5) - Using EVENTS table
-- ==================================================================================================

CREATE TEMP TABLE actual_purchases AS
WITH order_events AS (
  SELECT
    t.user_id,
    t.client_event_timestamp AS event_ts,
    UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))) AS sku
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep
  WHERE DATE(t.client_event_timestamp) BETWEEN test_cutoff_date AND eval_window_end
    AND UPPER(t.event_name) IN ('PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
    AND (
      REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
    )
)
SELECT DISTINCT
  uv.email_lower,
  oe.sku,
  DATE(oe.event_ts) AS order_date
FROM order_events oe
JOIN users_with_vehicles uv ON oe.user_id = uv.user_id
WHERE oe.sku IS NOT NULL;

SELECT 'Step 13: Actual purchases' AS step,
  COUNT(DISTINCT email_lower) AS unique_buyers,
  COUNT(DISTINCT sku) AS unique_products
FROM actual_purchases;

-- ==================================================================================================
-- STEP 14: MATCH ANALYSIS
-- ==================================================================================================

-- V5.8 matches
CREATE TEMP TABLE v5_8_matches AS
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  p.sku AS purchased_sku,
  CASE
    WHEN p.sku = r.rec_part_1 THEN 1
    WHEN p.sku = r.rec_part_2 THEN 2
    WHEN p.sku = r.rec_part_3 THEN 3
    WHEN p.sku = r.rec_part_4 THEN 4
  END AS matched_slot
FROM v5_8_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- V5.7 matches
CREATE TEMP TABLE v5_7_matches AS
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  p.sku AS purchased_sku,
  CASE
    WHEN p.sku = r.rec_part_1 THEN 1
    WHEN p.sku = r.rec_part_2 THEN 2
    WHEN p.sku = r.rec_part_3 THEN 3
    WHEN p.sku = r.rec_part_4 THEN 4
  END AS matched_slot
FROM v5_7_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- ==================================================================================================
-- FINAL RESULTS
-- ==================================================================================================

-- Summary comparison
SELECT
  '=== BACKTEST SUMMARY ===' AS section,
  FORMAT('Test cutoff: %s', CAST(test_cutoff_date AS STRING)) AS test_cutoff,
  FORMAT('Eval window: %s to %s', CAST(test_cutoff_date AS STRING), CAST(eval_window_end AS STRING)) AS eval_window;

SELECT
  version,
  users_with_recs,
  users_who_purchased,
  users_matched,
  ROUND(100.0 * users_matched / NULLIF(users_with_recs, 0), 4) AS match_rate_pct,
  total_matches
FROM (
  SELECT
    'v5.7 (baseline)' AS version,
    (SELECT COUNT(*) FROM v5_7_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_7_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_7_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_7_matches) AS total_matches
  UNION ALL
  SELECT
    'v5.8 (new)' AS version,
    (SELECT COUNT(*) FROM v5_8_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_8_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_8_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_8_matches) AS total_matches
)
ORDER BY version;

-- Match slot distribution
SELECT 'V5.8 Match Slot Distribution' AS analysis,
  matched_slot,
  COUNT(*) AS match_count
FROM v5_8_matches
GROUP BY matched_slot
ORDER BY matched_slot;

SELECT 'V5.7 Match Slot Distribution' AS analysis,
  matched_slot,
  COUNT(*) AS match_count
FROM v5_7_matches
GROUP BY matched_slot
ORDER BY matched_slot;

-- Sample matched users (V5.8)
SELECT 'V5.8 Sample Matches' AS analysis,
  email_lower,
  v1_year,
  v1_make,
  v1_model,
  purchased_sku,
  matched_slot
FROM v5_8_matches
LIMIT 20;

-- Sample matched users (V5.7)
SELECT 'V5.7 Sample Matches' AS analysis,
  email_lower,
  v1_year,
  v1_make,
  v1_model,
  purchased_sku,
  matched_slot
FROM v5_7_matches
LIMIT 20;

-- SKU diversity comparison
SELECT 'SKU Diversity Comparison' AS analysis,
  'v5.7' AS version,
  COUNT(DISTINCT rec_part_1) AS unique_rec1,
  COUNT(DISTINCT rec_part_2) AS unique_rec2,
  COUNT(DISTINCT rec_part_3) AS unique_rec3,
  COUNT(DISTINCT rec_part_4) AS unique_rec4
FROM v5_7_recs_wide
UNION ALL
SELECT 'SKU Diversity Comparison' AS analysis,
  'v5.8' AS version,
  COUNT(DISTINCT rec_part_1) AS unique_rec1,
  COUNT(DISTINCT rec_part_2) AS unique_rec2,
  COUNT(DISTINCT rec_part_3) AS unique_rec3,
  COUNT(DISTINCT rec_part_4) AS unique_rec4
FROM v5_8_recs_wide;

-- 1969 Camaro check
SELECT '1969 Camaro Top Recs Comparison' AS analysis,
  version,
  rec_part_1,
  rec_count
FROM (
  SELECT 'v5.7' AS version, rec_part_1, COUNT(*) AS rec_count
  FROM v5_7_recs_wide
  WHERE v1_year = '1969' AND UPPER(v1_model) = 'CAMARO'
  GROUP BY rec_part_1
  ORDER BY rec_count DESC
  LIMIT 5
)
UNION ALL
SELECT '1969 Camaro Top Recs Comparison' AS analysis,
  'v5.8' AS version, rec_part_1, COUNT(*) AS rec_count
FROM v5_8_recs_wide
WHERE v1_year = '1969' AND UPPER(v1_model) = 'CAMARO'
GROUP BY rec_part_1
ORDER BY rec_count DESC
LIMIT 5;

SELECT '=== BACKTEST COMPLETE ===' AS status;
