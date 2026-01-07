-- ==================================================================================================
-- V5.9 Category-Aware Backtest
-- --------------------------------------------------------------------------------------------------
-- Goal: Validate v5.9 algorithm by testing if Dec 15 recommendations would have predicted
--       actual purchases in the Dec 15 - Jan 5 window (21 days)
--
-- Key V5.9 changes from V5.8:
--   1. Category matching: 50 points if product matches user's primary interest category
--   2. Intent decay: 30-day half-life exponential decay
--   3. Recency window: 60-day rolling window for primary category detection
--   4. Three-tier slot allocation: primary, related, cold_start
-- ==================================================================================================

-- Backtest parameters
DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';

-- V5.9: Category recency window (60 days before test cutoff)
DECLARE category_recency_days INT64 DEFAULT 60;
DECLARE category_window_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL category_recency_days DAY);

-- V5.9: Intent decay half-life
DECLARE intent_decay_halflife INT64 DEFAULT 30;

-- V5.9: Category score weights
DECLARE category_match_score FLOAT64 DEFAULT 50.0;
DECLARE category_universal_score FLOAT64 DEFAULT 25.0;

-- Intent window: for backtest, use 60-day window before cutoff
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE intent_window_start DATE DEFAULT category_window_start;

-- Historical popularity window (unchanged)
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';

-- Other parameters
DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE min_co_purchase_count INT64 DEFAULT 20;

-- Dynamic year patterns
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM test_cutoff_date) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(test_cutoff_date, INTERVAL 365 DAY)) AS STRING), '%');

-- Working dataset
DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_9';

SELECT '=== V5.9 CATEGORY-AWARE BACKTEST ===' AS status;
SELECT FORMAT('Test cutoff: %s', CAST(test_cutoff_date AS STRING)) AS param,
       FORMAT('Category window: %s to %s', CAST(category_window_start AS STRING), CAST(test_cutoff_date AS STRING)) AS value;

-- ==================================================================================================
-- STEP 1: USERS WITH VEHICLES (as of Dec 15)
-- ==================================================================================================

CREATE TEMP TABLE users_with_vehicles AS
SELECT DISTINCT
  user_id,
  LOWER(email_val) AS email_lower,
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
-- STEP 2: STAGED EVENTS (category window: Oct 16 - Dec 15)
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
    -- Price extraction (like v5.8)
    CASE
      WHEN LOWER(ep.property_name) IN ('price','itemprice')
        THEN SAFE_CAST(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS FLOAT64)
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.itemprice$')
        THEN SAFE_CAST(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS FLOAT64)
    END AS price_val,
    -- Image extraction
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
WHERE sku IS NOT NULL AND LENGTH(sku) > 0
GROUP BY user_id, sku, event_ts, event_name;

SELECT 'Step 2: Staged events' AS step, COUNT(*) AS count, COUNT(DISTINCT user_id) AS users FROM staged_events;

-- ==================================================================================================
-- STEP 3: USER PRIMARY CATEGORY (V5.9 NEW)
-- Based on most recent activity within 60-day window
-- ==================================================================================================

CREATE TEMP TABLE user_primary_category AS
WITH recent_activity AS (
  SELECT
    se.user_id,
    se.sku,
    se.event_name,
    se.event_ts,
    i.PartType,
    ROW_NUMBER() OVER (PARTITION BY se.user_id ORDER BY se.event_ts DESC) AS recency_rank
  FROM staged_events se
  JOIN `auxia-gcp.data_company_1950.import_items` i ON se.sku = i.PartNumber
  WHERE se.event_name IN ('VIEWED PRODUCT', 'CART UPDATE', 'ORDERED PRODUCT')
    AND i.PartType IS NOT NULL
    AND TRIM(i.PartType) != ''
)
SELECT
  user_id,
  PartType AS primary_category,
  event_ts AS last_activity_ts,
  TRUE AS has_recent_activity
FROM recent_activity
WHERE recency_rank = 1;

-- Add cold start users (no recent activity)
INSERT INTO user_primary_category
SELECT
  uv.user_id,
  'COLD_START' AS primary_category,
  TIMESTAMP '1900-01-01' AS last_activity_ts,
  FALSE AS has_recent_activity
FROM users_with_vehicles uv
WHERE NOT EXISTS (SELECT 1 FROM user_primary_category upc WHERE upc.user_id = uv.user_id);

SELECT 'Step 3: User primary category' AS step,
  COUNTIF(has_recent_activity) AS active_users,
  COUNTIF(NOT has_recent_activity) AS cold_start_users
FROM user_primary_category;

-- ==================================================================================================
-- STEP 4: ELIGIBLE PARTS (uses events-based price/image like v5.8)
-- ==================================================================================================

-- SKU Prices from events
CREATE TEMP TABLE sku_prices AS
SELECT sku, MAX(price) AS price
FROM staged_events
WHERE price IS NOT NULL
GROUP BY sku;

-- SKU Images from events
CREATE TEMP TABLE sku_images AS
SELECT sku, image_url
FROM (
  SELECT
    sku,
    CASE
      WHEN image_url_raw LIKE '//%' THEN CONCAT('https:', image_url_raw)
      WHEN LOWER(image_url_raw) LIKE 'http://%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
      ELSE image_url_raw
    END AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM staged_events
  WHERE image_url_raw IS NOT NULL
)
WHERE rn = 1 AND image_url LIKE 'https://%';

-- Eligible parts (fitment + price + image)
CREATE TEMP TABLE eligible_parts AS
WITH fitment_flat AS (
  SELECT DISTINCT
    SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku,
    COALESCE(cat.PartType, 'UNIVERSAL') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat
    ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
)
SELECT DISTINCT
  f.year, f.make, f.model, f.sku, f.part_type,
  COALESCE(price.price, min_price) AS price,
  COALESCE(img.image_url, 'https://placeholder') AS image_url
FROM fitment_flat f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
WHERE COALESCE(price.price, min_price) >= min_price;
-- NOTE: Image filter relaxed for backtest (production requires real images)

SELECT 'Step 4: Eligible parts' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts;

-- ==================================================================================================
-- STEP 5: INTENT SCORES WITH EXPONENTIAL DECAY (V5.9 NEW)
-- ==================================================================================================

CREATE TEMP TABLE intent_scores_decayed AS
WITH events_with_decay AS (
  SELECT
    user_id,
    sku,
    event_name,
    event_ts,
    DATE_DIFF(test_cutoff_date, DATE(event_ts), DAY) AS days_ago,
    -- Decay weight: 0.5 ^ (days_ago / halflife)
    POW(0.5, DATE_DIFF(test_cutoff_date, DATE(event_ts), DAY) / intent_decay_halflife) AS decay_weight
  FROM staged_events
),
scored AS (
  SELECT
    user_id,
    sku,
    SUM(CASE
      WHEN event_name IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER') THEN -10 * decay_weight  -- Negative: don't recommend what they bought
      WHEN event_name = 'CART UPDATE' THEN 5 * decay_weight
      WHEN event_name = 'VIEWED PRODUCT' THEN 1 * decay_weight
      ELSE 0
    END) AS intent_score_decayed
  FROM events_with_decay
  GROUP BY user_id, sku
)
SELECT user_id, sku, GREATEST(intent_score_decayed, 0) AS intent_score_decayed  -- Floor at 0
FROM scored
WHERE intent_score_decayed > 0;

SELECT 'Step 5: Intent scores (decayed)' AS step, COUNT(*) AS pairs FROM intent_scores_decayed;

-- ==================================================================================================
-- STEP 6: IMPORT ORDERS (for segment popularity)
-- ==================================================================================================

CREATE TEMP TABLE import_orders_filtered AS
SELECT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  UPPER(TRIM(ITEM)) AS sku,
  SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) AS order_date_parsed,
  1 AS is_popularity_window
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end;

-- ==================================================================================================
-- STEP 7: SEGMENT POPULARITY (V5.8 logic)
-- ==================================================================================================

CREATE TEMP TABLE segment_product_sales AS
SELECT
  CONCAT(UPPER(uv.v1_make), '|', UPPER(uv.v1_model), '|', CAST(uv.v1_year_int AS STRING)) AS segment_key,
  io.sku,
  COUNT(*) AS segment_orders
FROM import_orders_filtered io
JOIN users_with_vehicles uv ON io.email_lower = uv.email_lower
GROUP BY 1, 2
HAVING COUNT(*) >= 2;

CREATE TEMP TABLE segment_popularity AS
SELECT
  segment_key, sku, segment_orders,
  LOG(1 + segment_orders) * 10 AS segment_popularity_score
FROM segment_product_sales;

SELECT 'Step 7: Segment popularity' AS step, COUNT(DISTINCT segment_key) AS segments FROM segment_popularity;

-- ==================================================================================================
-- STEP 8: FITMENT BREADTH + NARROW FIT BONUS
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
-- STEP 9: CATEGORY CO-PURCHASES (V5.9 NEW)
-- ==================================================================================================

CREATE TEMP TABLE category_co_purchases AS
WITH order_baskets AS (
  SELECT email_lower, DATE(order_date_parsed) AS order_date, ARRAY_AGG(DISTINCT sku) AS basket_skus
  FROM import_orders_filtered
  GROUP BY email_lower, order_date
  HAVING ARRAY_LENGTH(ARRAY_AGG(DISTINCT sku)) BETWEEN 2 AND 10
),
sku_categories AS (
  SELECT UPPER(PartNumber) AS sku, COALESCE(PartType, 'UNIVERSAL') AS part_type
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartType IS NOT NULL
),
category_pairs AS (
  SELECT
    sc1.part_type AS category_a,
    sc2.part_type AS category_b,
    COUNT(*) AS co_purchase_count
  FROM order_baskets ob,
    UNNEST(basket_skus) AS sku_a,
    UNNEST(basket_skus) AS sku_b
  JOIN sku_categories sc1 ON sku_a = sc1.sku
  JOIN sku_categories sc2 ON sku_b = sc2.sku
  WHERE sku_a < sku_b
    AND sc1.part_type != sc2.part_type
  GROUP BY sc1.part_type, sc2.part_type
  HAVING COUNT(*) >= min_co_purchase_count
)
SELECT category_a, category_b, co_purchase_count
FROM category_pairs;

SELECT 'Step 9: Category co-purchases' AS step, COUNT(*) AS pairs FROM category_co_purchases;

-- ==================================================================================================
-- STEP 10: PURCHASE EXCLUSION (before Dec 15)
-- ==================================================================================================

CREATE TEMP TABLE purchase_exclusion AS
WITH from_events AS (
  SELECT DISTINCT user_id, sku
  FROM staged_events
  WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
)
SELECT DISTINCT user_id, sku FROM from_events;

-- ==================================================================================================
-- STEP 11: V5.9 BACKTEST RECOMMENDATIONS
-- ==================================================================================================

CREATE TEMP TABLE v5_9_backtest_recs AS
WITH candidates AS (
  SELECT
    uv.user_id,
    uv.email_lower,
    uv.v1_year,
    uv.v1_year_int,
    uv.v1_make,
    uv.v1_model,
    upc.primary_category,
    upc.has_recent_activity,
    ep.sku,
    ep.part_type,
    ep.price,
    ep.image_url,
    -- Category score (50 percent of total for V5.9)
    CASE
      WHEN upc.has_recent_activity AND ep.part_type = upc.primary_category THEN category_match_score
      WHEN ep.part_type = 'UNIVERSAL' THEN category_universal_score
      ELSE 0
    END AS category_score,
    COALESCE(int.intent_score_decayed, 0) AS intent_score,
    COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
    COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
    -- V5.9 scoring formula
    ROUND(
      CASE
        WHEN upc.has_recent_activity AND ep.part_type = upc.primary_category THEN category_match_score
        WHEN ep.part_type = 'UNIVERSAL' THEN category_universal_score
        ELSE 0
      END +
      COALESCE(int.intent_score_decayed, 0) +
      COALESCE(sp.segment_popularity_score, 0) +
      COALESCE(fb.narrow_fit_bonus, 0),
      2
    ) AS final_score_v59
  FROM users_with_vehicles uv
  JOIN user_primary_category upc ON uv.user_id = upc.user_id
  JOIN eligible_parts ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores_decayed int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN segment_popularity sp
    ON CONCAT(uv.v1_make, '|', uv.v1_model, '|', CAST(uv.v1_year_int AS STRING)) = sp.segment_key
    AND ep.sku = sp.sku
  LEFT JOIN fitment_breadth fb ON ep.sku = fb.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL  -- Exclude already purchased
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
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v59 DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v59 DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= 2
),
-- Top 4 per user
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v59 DESC, sku) AS rank_v59
  FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v59 <= 4;

-- Pivot to wide format
CREATE TEMP TABLE v5_9_recs_wide AS
WITH users_with_4_recs AS (
  SELECT user_id FROM v5_9_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  MAX(r.has_recent_activity) AS has_recent_activity,
  MAX(CASE WHEN rank_v59 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v59 = 1 THEN part_type END) AS rec1_part_type,
  MAX(CASE WHEN rank_v59 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v59 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v59 = 4 THEN sku END) AS rec_part_4
FROM v5_9_backtest_recs r
JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 11: V5.9 backtest recs' AS step,
  COUNT(*) AS users,
  COUNTIF(has_recent_activity) AS active_users,
  COUNTIF(NOT has_recent_activity) AS cold_start_users
FROM v5_9_recs_wide;

-- ==================================================================================================
-- STEP 12: V5.7 BASELINE RECOMMENDATIONS (for comparison)
-- ==================================================================================================

CREATE TEMP TABLE global_popularity AS
SELECT
  sku,
  COUNT(*) AS global_orders,
  LOG(1 + COUNT(*)) * 2 AS popularity_score
FROM import_orders_filtered
GROUP BY sku;

CREATE TEMP TABLE intent_scores AS
WITH events AS (
  SELECT user_id, sku,
    CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN 'order'
      WHEN UPPER(event_name) = 'CART UPDATE' THEN 'cart'
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN 'view'
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
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(gp.popularity_score, 0), 2) AS final_score_v57
  FROM users_with_vehicles uv
  JOIN eligible_parts ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN global_popularity gp ON ep.sku = gp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
normalized AS (
  SELECT *,
    REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var)
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v57 DESC, sku) AS rn_var FROM normalized)
  WHERE rn_var = 1
),
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v57 DESC, sku) AS rn_pt FROM dedup_variant)
  WHERE rn_pt <= 2
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v57 DESC, sku) AS rank_v57
  FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v57 <= 4;

CREATE TEMP TABLE v5_7_recs_wide AS
WITH users_with_4_recs AS (
  SELECT user_id FROM v5_7_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v57 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v57 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v57 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v57 = 4 THEN sku END) AS rec_part_4
FROM v5_7_backtest_recs r
JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 12: V5.7 baseline recs' AS step, COUNT(*) AS users FROM v5_7_recs_wide;

-- ==================================================================================================
-- STEP 13: ACTUAL PURCHASES (Dec 15 - Jan 5)
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
      OR LOWER(ep.property_name) = 'sku'
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

-- V5.9 matches
CREATE TEMP TABLE v5_9_matches AS
SELECT
  r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  p.sku AS purchased_sku,
  CASE
    WHEN p.sku = r.rec_part_1 THEN 1
    WHEN p.sku = r.rec_part_2 THEN 2
    WHEN p.sku = r.rec_part_3 THEN 3
    WHEN p.sku = r.rec_part_4 THEN 4
  END AS matched_slot
FROM v5_9_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- V5.7 matches
CREATE TEMP TABLE v5_7_matches AS
SELECT
  r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
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

SELECT '=== V5.9 BACKTEST RESULTS ===' AS section;

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
    'v5.9 (category-aware)' AS version,
    (SELECT COUNT(*) FROM v5_9_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_9_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_9_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_9_matches) AS total_matches
)
ORDER BY version;

-- Match slot distribution
SELECT 'V5.9 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_9_matches GROUP BY matched_slot ORDER BY matched_slot;

SELECT 'V5.7 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_7_matches GROUP BY matched_slot ORDER BY matched_slot;

-- Category alignment: Did users buy in their primary category?
SELECT 'Category Alignment Check' AS analysis,
  COUNT(*) AS total_purchases_by_active_users,
  COUNTIF(p.sku IN (SELECT sku FROM eligible_parts ep JOIN user_primary_category upc
                    ON ep.part_type = upc.primary_category WHERE upc.user_id = r.user_id)) AS purchases_in_primary_category
FROM v5_9_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE r.has_recent_activity = TRUE;

-- SKU diversity comparison
SELECT 'SKU Diversity' AS analysis, version,
  COUNT(DISTINCT rec_part_1) AS unique_rec1
FROM (
  SELECT 'v5.7' AS version, rec_part_1 FROM v5_7_recs_wide
  UNION ALL
  SELECT 'v5.9' AS version, rec_part_1 FROM v5_9_recs_wide
)
GROUP BY version;

-- Sample V5.9 matches
SELECT 'V5.9 Sample Matches' AS analysis,
  email_lower, v1_year, v1_make, v1_model, purchased_sku, matched_slot
FROM v5_9_matches
LIMIT 20;

SELECT '=== BACKTEST COMPLETE ===' AS status;
