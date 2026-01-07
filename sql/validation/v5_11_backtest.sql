-- ==================================================================================================
-- V5.11 Pure Segment Popularity Backtest
-- --------------------------------------------------------------------------------------------------
-- Hypothesis: Intent signals might be HURTING matches. Users don't buy what they browsed.
--             Try only segment popularity - what do other owners of the same vehicle buy?
-- ==================================================================================================

DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';
DECLARE intent_window_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL 60 DAY);
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM test_cutoff_date) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(test_cutoff_date, INTERVAL 365 DAY)) AS STRING), '%');

SELECT '=== V5.11 PURE SEGMENT POPULARITY BACKTEST ===' AS status;

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
-- STEP 2: STAGED EVENTS (for prices/images only)
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

-- ==================================================================================================
-- STEP 3: SKU PRICES & IMAGES
-- ==================================================================================================

CREATE TEMP TABLE sku_prices AS
SELECT sku, MAX(price) AS price FROM staged_events WHERE price IS NOT NULL GROUP BY sku;

CREATE TEMP TABLE sku_images AS
SELECT sku, image_url
FROM (
  SELECT sku,
    CASE WHEN image_url_raw LIKE '//%' THEN CONCAT('https:', image_url_raw)
         WHEN LOWER(image_url_raw) LIKE 'http://%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
         ELSE image_url_raw END AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM staged_events WHERE image_url_raw IS NOT NULL
)
WHERE rn = 1 AND image_url LIKE 'https://%';

-- ==================================================================================================
-- STEP 4: ELIGIBLE PARTS
-- ==================================================================================================

CREATE TEMP TABLE eligible_parts AS
WITH fitment_flat AS (
  SELECT DISTINCT
    SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku,
    COALESCE(cat.PartType, 'UNIVERSAL') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit, UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
)
SELECT DISTINCT f.year, f.make, f.model, f.sku, f.part_type,
  COALESCE(price.price, min_price) AS price,
  COALESCE(img.image_url, 'https://placeholder') AS image_url
FROM fitment_flat f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
WHERE COALESCE(price.price, min_price) >= min_price;

SELECT 'Step 4: Eligible parts' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts;

-- ==================================================================================================
-- STEP 5: HISTORICAL ORDERS
-- ==================================================================================================

CREATE TEMP TABLE import_orders_filtered AS
SELECT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  UPPER(TRIM(ITEM)) AS sku,
  SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) AS order_date_parsed
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end
  AND ITEM IS NOT NULL;

-- ==================================================================================================
-- STEP 6: SEGMENT POPULARITY (core signal for V5.11)
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
SELECT segment_key, sku, segment_orders,
  LOG(1 + segment_orders) * 10 AS segment_popularity_score
FROM segment_product_sales;

SELECT 'Step 6: Segment popularity' AS step,
  COUNT(*) AS pairs,
  COUNT(DISTINCT segment_key) AS segments,
  COUNT(DISTINCT sku) AS skus
FROM segment_popularity;

-- ==================================================================================================
-- STEP 7: FITMENT BREADTH (narrow fit bonus)
-- ==================================================================================================

CREATE TEMP TABLE fitment_breadth AS
SELECT sku,
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
-- STEP 8: PURCHASE EXCLUSION
-- ==================================================================================================

CREATE TEMP TABLE purchase_exclusion AS
SELECT DISTINCT user_id, sku
FROM staged_events
WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER');

-- ==================================================================================================
-- STEP 9: GLOBAL POPULARITY (fallback for segments with no data)
-- ==================================================================================================

CREATE TEMP TABLE global_popularity AS
SELECT sku, COUNT(*) AS global_orders, LOG(1 + COUNT(*)) * 2 AS popularity_score
FROM import_orders_filtered GROUP BY sku;

-- ==================================================================================================
-- STEP 10: V5.11 SCORING - Pure segment popularity (NO INTENT)
-- ==================================================================================================

CREATE TEMP TABLE v5_11_backtest_recs AS
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
    ep.price,
    ep.image_url,
    COALESCE(sp.segment_popularity_score, 0) AS segment_popularity_score,
    COALESCE(fb.narrow_fit_bonus, 0) AS narrow_fit_bonus,
    COALESCE(gp.popularity_score, 0) AS global_popularity_score,
    -- V5.11: Segment popularity + narrow fit (NO INTENT)
    ROUND(
      COALESCE(sp.segment_popularity_score, 0) +
      COALESCE(fb.narrow_fit_bonus, 0) +
      COALESCE(gp.popularity_score, 0) * 0.1,  -- Minimal global fallback
      2
    ) AS final_score_v511
  FROM users_with_vehicles uv
  JOIN eligible_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN segment_popularity sp
    ON CONCAT(uv.v1_make, '|', uv.v1_model, '|', CAST(uv.v1_year_int AS STRING)) = sp.segment_key AND ep.sku = sp.sku
  LEFT JOIN fitment_breadth fb ON ep.sku = fb.sku
  LEFT JOIN global_popularity gp ON ep.sku = gp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v511 DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v511 DESC, sku) AS rn_pt FROM dedup_variant
  ) WHERE rn_pt <= 2
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v511 DESC, sku) AS rank_v511 FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v511 <= 4;

CREATE TEMP TABLE v5_11_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_11_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v511 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v511 = 1 THEN segment_popularity_score END) AS rec1_segment_score,
  MAX(CASE WHEN rank_v511 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v511 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v511 = 4 THEN sku END) AS rec_part_4
FROM v5_11_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 10: V5.11 recs' AS step, COUNT(*) AS users FROM v5_11_recs_wide;

-- ==================================================================================================
-- STEP 11: V5.7 BASELINE
-- ==================================================================================================

CREATE TEMP TABLE intent_scores AS
SELECT user_id, sku,
  SUM(CASE
    WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN LOG(1 + 1) * 20
    WHEN UPPER(event_name) = 'CART UPDATE' THEN LOG(1 + 1) * 10
    WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN LOG(1 + 1) * 2
    ELSE 0
  END) AS intent_score
FROM staged_events GROUP BY user_id, sku;

CREATE TEMP TABLE v5_7_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model, ep.sku, ep.part_type,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(gp.popularity_score, 0), 2) AS final_score_v57
  FROM users_with_vehicles uv
  JOIN eligible_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN global_popularity gp ON ep.sku = gp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v57 DESC, sku) AS rn_var FROM normalized) WHERE rn_var = 1
),
diversity_filtered AS (
  SELECT * EXCEPT(rn_pt) FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score_v57 DESC, sku) AS rn_pt FROM dedup_variant) WHERE rn_pt <= 2
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v57 DESC, sku) AS rank_v57 FROM diversity_filtered
)
SELECT * FROM ranked WHERE rank_v57 <= 4;

CREATE TEMP TABLE v5_7_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_7_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v57 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v57 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v57 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v57 = 4 THEN sku END) AS rec_part_4
FROM v5_7_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'Step 11: V5.7 baseline recs' AS step, COUNT(*) AS users FROM v5_7_recs_wide;

-- ==================================================================================================
-- STEP 12: ACTUAL PURCHASES
-- ==================================================================================================

CREATE TEMP TABLE actual_purchases AS
WITH order_events AS (
  SELECT t.user_id, t.client_event_timestamp AS event_ts,
    UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))) AS sku
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep
  WHERE DATE(t.client_event_timestamp) BETWEEN test_cutoff_date AND eval_window_end
    AND UPPER(t.event_name) IN ('PLACED ORDER', 'ORDERED PRODUCT', 'CONSUMER WEBSITE ORDER')
    AND (REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$')
      OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
      OR LOWER(ep.property_name) = 'sku')
)
SELECT DISTINCT uv.email_lower, oe.sku, DATE(oe.event_ts) AS order_date
FROM order_events oe JOIN users_with_vehicles uv ON oe.user_id = uv.user_id
WHERE oe.sku IS NOT NULL;

SELECT 'Step 12: Actual purchases' AS step, COUNT(DISTINCT email_lower) AS buyers, COUNT(DISTINCT sku) AS products FROM actual_purchases;

-- ==================================================================================================
-- STEP 13: MATCH ANALYSIS
-- ==================================================================================================

CREATE TEMP TABLE v5_11_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_11_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

CREATE TEMP TABLE v5_7_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_7_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- ==================================================================================================
-- RESULTS
-- ==================================================================================================

SELECT '=== V5.11 BACKTEST RESULTS ===' AS section;

SELECT version, users_with_recs, users_who_purchased, users_matched,
  ROUND(100.0 * users_matched / NULLIF(users_with_recs, 0), 4) AS match_rate_pct, total_matches
FROM (
  SELECT 'v5.7 (baseline)' AS version,
    (SELECT COUNT(*) FROM v5_7_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_7_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_7_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_7_matches) AS total_matches
  UNION ALL
  SELECT 'v5.11 (segment-only)' AS version,
    (SELECT COUNT(*) FROM v5_11_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_11_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_11_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_11_matches) AS total_matches
)
ORDER BY version;

SELECT 'V5.11 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_11_matches GROUP BY matched_slot ORDER BY matched_slot;

SELECT 'SKU Diversity' AS analysis, version, COUNT(DISTINCT rec_part_1) AS unique_rec1
FROM (SELECT 'v5.7' AS version, rec_part_1 FROM v5_7_recs_wide UNION ALL SELECT 'v5.11' AS version, rec_part_1 FROM v5_11_recs_wide)
GROUP BY version;

SELECT 'Segment score distribution' AS analysis,
  COUNTIF(rec1_segment_score > 0) AS users_with_segment_score,
  COUNTIF(rec1_segment_score = 0) AS users_without_segment_score,
  ROUND(AVG(rec1_segment_score), 2) AS avg_segment_score
FROM v5_11_recs_wide;

SELECT 'V5.11 Sample Matches' AS analysis, email_lower, v1_year, v1_make, v1_model, purchased_sku, matched_slot
FROM v5_11_matches LIMIT 20;
