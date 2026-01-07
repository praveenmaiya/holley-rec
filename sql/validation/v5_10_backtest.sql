-- ==================================================================================================
-- V5.10 Co-Purchase Patterns Backtest
-- --------------------------------------------------------------------------------------------------
-- Hypothesis: Users buy products that are frequently purchased together.
--             If user shows intent for product A, recommend products commonly bought with A.
-- ==================================================================================================

-- Backtest parameters
DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';

-- Intent window (60 days before cutoff)
DECLARE intent_window_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL 60 DAY);
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;

-- Historical popularity window
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';

-- Parameters
DECLARE min_co_purchase_count INT64 DEFAULT 5;  -- Minimum times bought together
DECLARE min_price FLOAT64 DEFAULT 50.0;

-- Year patterns for ORDER_DATE parsing
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM test_cutoff_date) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(test_cutoff_date, INTERVAL 365 DAY)) AS STRING), '%');

SELECT '=== V5.10 CO-PURCHASE PATTERNS BACKTEST ===' AS status;

-- ==================================================================================================
-- STEP 1: USERS WITH VEHICLES
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
-- STEP 2: STAGED EVENTS (intent signals)
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
        THEN SAFE_CAST(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS FLOAT64)
      WHEN REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.itemprice$')
        THEN SAFE_CAST(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS FLOAT64)
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
WHERE sku IS NOT NULL AND LENGTH(sku) > 0
GROUP BY user_id, sku, event_ts, event_name;

SELECT 'Step 2: Staged events' AS step, COUNT(*) AS count, COUNT(DISTINCT user_id) AS users FROM staged_events;

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

-- ==================================================================================================
-- STEP 4: ELIGIBLE PARTS (fitment + price)
-- ==================================================================================================

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

SELECT 'Step 4: Eligible parts' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts;

-- ==================================================================================================
-- STEP 5: HISTORICAL ORDERS (for co-purchase matrix)
-- ==================================================================================================

CREATE TEMP TABLE import_orders_filtered AS
SELECT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  UPPER(TRIM(ITEM)) AS sku,
  SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) AS order_date_parsed,
  ORDER_NUMBER
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end
  AND ITEM IS NOT NULL;

SELECT 'Step 5: Historical orders' AS step, COUNT(*) AS orders, COUNT(DISTINCT ORDER_NUMBER) AS unique_orders
FROM import_orders_filtered;

-- ==================================================================================================
-- STEP 6: CO-PURCHASE MATRIX (SKU pairs bought in same order)
-- ==================================================================================================

CREATE TEMP TABLE co_purchase_matrix AS
WITH order_baskets AS (
  -- Group items by order
  SELECT
    ORDER_NUMBER,
    email_lower,
    order_date_parsed,
    ARRAY_AGG(DISTINCT sku) AS basket_skus
  FROM import_orders_filtered
  GROUP BY ORDER_NUMBER, email_lower, order_date_parsed
  HAVING ARRAY_LENGTH(ARRAY_AGG(DISTINCT sku)) BETWEEN 2 AND 20  -- Multi-item orders only
),
sku_pairs AS (
  -- Generate all pairs from each basket
  SELECT
    sku_a,
    sku_b,
    COUNT(DISTINCT ORDER_NUMBER) AS times_bought_together
  FROM order_baskets,
    UNNEST(basket_skus) AS sku_a,
    UNNEST(basket_skus) AS sku_b
  WHERE sku_a < sku_b  -- Avoid duplicates
  GROUP BY sku_a, sku_b
  HAVING COUNT(DISTINCT ORDER_NUMBER) >= min_co_purchase_count
)
-- Create bidirectional lookup
SELECT sku_a AS sku_source, sku_b AS sku_target, times_bought_together,
       LOG(1 + times_bought_together) * 5 AS co_purchase_score
FROM sku_pairs
UNION ALL
SELECT sku_b AS sku_source, sku_a AS sku_target, times_bought_together,
       LOG(1 + times_bought_together) * 5 AS co_purchase_score
FROM sku_pairs;

SELECT 'Step 6: Co-purchase matrix' AS step,
  COUNT(*) AS total_pairs,
  COUNT(DISTINCT sku_source) AS source_skus,
  COUNT(DISTINCT sku_target) AS target_skus
FROM co_purchase_matrix;

-- ==================================================================================================
-- STEP 7: USER INTENT PRODUCTS (what each user has shown interest in)
-- ==================================================================================================

CREATE TEMP TABLE user_intent_products AS
WITH scored_intent AS (
  SELECT
    user_id,
    sku,
    SUM(CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN 20
      WHEN UPPER(event_name) = 'CART UPDATE' THEN 10
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN 2
      ELSE 0
    END) AS intent_strength
  FROM staged_events
  GROUP BY user_id, sku
)
SELECT user_id, sku, intent_strength
FROM scored_intent
WHERE intent_strength > 0;

SELECT 'Step 7: User intent products' AS step,
  COUNT(*) AS intent_pairs,
  COUNT(DISTINCT user_id) AS users_with_intent
FROM user_intent_products;

-- ==================================================================================================
-- STEP 8: PURCHASE EXCLUSION
-- ==================================================================================================

CREATE TEMP TABLE purchase_exclusion AS
SELECT DISTINCT user_id, sku
FROM staged_events
WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER');

-- ==================================================================================================
-- STEP 9: GLOBAL POPULARITY (fallback signal)
-- ==================================================================================================

CREATE TEMP TABLE global_popularity AS
SELECT
  sku,
  COUNT(*) AS global_orders,
  LOG(1 + COUNT(*)) * 2 AS popularity_score
FROM import_orders_filtered
GROUP BY sku;

SELECT 'Step 9: Global popularity' AS step, COUNT(*) AS skus FROM global_popularity;

-- ==================================================================================================
-- STEP 10: V5.10 SCORING - Co-purchase boosted recommendations
-- ==================================================================================================
-- Formula:
--   co_purchase_boost = SUM of co_purchase_scores from user's intent products
--   final_score = co_purchase_boost + intent_score + popularity_score

CREATE TEMP TABLE v5_10_backtest_recs AS
WITH user_co_purchase_scores AS (
  -- For each user, calculate co-purchase score for each eligible product
  SELECT
    uip.user_id,
    cpm.sku_target AS sku,
    SUM(cpm.co_purchase_score * LOG(1 + uip.intent_strength)) AS co_purchase_boost
  FROM user_intent_products uip
  JOIN co_purchase_matrix cpm ON uip.sku = cpm.sku_source
  GROUP BY uip.user_id, cpm.sku_target
),
intent_scores AS (
  SELECT user_id, sku,
    SUM(CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN LOG(1 + 1) * 20
      WHEN UPPER(event_name) = 'CART UPDATE' THEN LOG(1 + 1) * 10
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN LOG(1 + 1) * 2
      ELSE 0
    END) AS intent_score
  FROM staged_events
  GROUP BY user_id, sku
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
    COALESCE(cps.co_purchase_boost, 0) AS co_purchase_boost,
    COALESCE(int.intent_score, 0) AS intent_score,
    COALESCE(gp.popularity_score, 0) AS popularity_score,
    -- V5.10: Co-purchase weighted scoring
    ROUND(
      COALESCE(cps.co_purchase_boost, 0) * 2 +  -- Double weight on co-purchase
      COALESCE(int.intent_score, 0) +
      COALESCE(gp.popularity_score, 0) * 0.5,   -- Reduce popularity weight
      2
    ) AS final_score_v510
  FROM users_with_vehicles uv
  JOIN eligible_parts ep
    ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN user_co_purchase_scores cps ON uv.user_id = cps.user_id AND ep.sku = cps.sku
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
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v510 DESC, sku) AS rn_var
    FROM normalized
  )
  WHERE rn_var = 1
),
-- Diversity: max 2 per PartType
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt)
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v510 DESC, sku) AS rn_pt
    FROM dedup_variant
  )
  WHERE rn_pt <= 2
),
-- Top 4 per user
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v510 DESC, sku) AS rank_v510
  FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v510 <= 4;

-- ==================================================================================================
-- STEP 11: PIVOT TO WIDE FORMAT
-- ==================================================================================================

CREATE TEMP TABLE v5_10_recs_wide AS
WITH users_with_4_recs AS (
  SELECT user_id FROM v5_10_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4
)
SELECT
  r.user_id,
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  MAX(CASE WHEN rank_v510 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v510 = 1 THEN co_purchase_boost END) AS rec1_copurchase,
  MAX(CASE WHEN rank_v510 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v510 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v510 = 4 THEN sku END) AS rec_part_4
FROM v5_10_backtest_recs r
JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 11: V5.10 recs' AS step, COUNT(*) AS users FROM v5_10_recs_wide;

-- ==================================================================================================
-- STEP 12: V5.7 BASELINE (for comparison)
-- ==================================================================================================

CREATE TEMP TABLE v5_7_backtest_recs AS
WITH intent_scores AS (
  SELECT user_id, sku,
    SUM(CASE
      WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN LOG(1 + 1) * 20
      WHEN UPPER(event_name) = 'CART UPDATE' THEN LOG(1 + 1) * 10
      WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN LOG(1 + 1) * 2
      ELSE 0
    END) AS intent_score
  FROM staged_events
  GROUP BY user_id, sku
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
-- STEP 13: ACTUAL PURCHASES (evaluation window)
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

CREATE TEMP TABLE v5_10_matches AS
SELECT
  r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  p.sku AS purchased_sku,
  CASE
    WHEN p.sku = r.rec_part_1 THEN 1
    WHEN p.sku = r.rec_part_2 THEN 2
    WHEN p.sku = r.rec_part_3 THEN 3
    WHEN p.sku = r.rec_part_4 THEN 4
  END AS matched_slot
FROM v5_10_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

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
-- RESULTS
-- ==================================================================================================

SELECT '=== V5.10 BACKTEST RESULTS ===' AS section;

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
    'v5.10 (co-purchase)' AS version,
    (SELECT COUNT(*) FROM v5_10_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_10_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_10_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_10_matches) AS total_matches
)
ORDER BY version;

-- Slot distribution
SELECT 'V5.10 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_10_matches GROUP BY matched_slot ORDER BY matched_slot;

SELECT 'V5.7 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_7_matches GROUP BY matched_slot ORDER BY matched_slot;

-- SKU diversity
SELECT 'SKU Diversity' AS analysis, version, COUNT(DISTINCT rec_part_1) AS unique_rec1
FROM (
  SELECT 'v5.7' AS version, rec_part_1 FROM v5_7_recs_wide
  UNION ALL
  SELECT 'v5.10' AS version, rec_part_1 FROM v5_10_recs_wide
)
GROUP BY version;

-- Co-purchase boost analysis
SELECT 'Co-purchase boost distribution' AS analysis,
  COUNTIF(rec1_copurchase > 0) AS users_with_copurchase_boost,
  COUNTIF(rec1_copurchase = 0) AS users_without_copurchase_boost,
  ROUND(AVG(rec1_copurchase), 2) AS avg_copurchase_boost
FROM v5_10_recs_wide;

-- Sample matches
SELECT 'V5.10 Sample Matches' AS analysis,
  email_lower, v1_year, v1_make, v1_model, purchased_sku, matched_slot
FROM v5_10_matches
LIMIT 20;
