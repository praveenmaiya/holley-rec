-- ==================================================================================================
-- V5.14 Recency-Weighted Popularity Backtest
-- --------------------------------------------------------------------------------------------------
-- Hypothesis: Recent purchases (last 60 days) are better predictors than old purchases.
-- Changes: Weight recent popularity 3x higher than historical
-- ==================================================================================================

DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';
DECLARE intent_window_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL 60 DAY);
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';
-- NEW: Recent popularity window (60 days before cutoff)
DECLARE pop_recent_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL 60 DAY);
DECLARE pop_recent_end DATE DEFAULT test_cutoff_date;
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE current_year_pattern STRING DEFAULT '%2025%';
DECLARE previous_year_pattern STRING DEFAULT '%2024%';

SELECT '=== V5.14 RECENCY-WEIGHTED POPULARITY BACKTEST ===' AS status;

-- STEP 1: USERS WITH VEHICLES
CREATE TEMP TABLE users_with_vehicles AS
SELECT DISTINCT user_id, LOWER(email_val) AS email_lower, v1_year_str AS v1_year,
  SAFE_CAST(v1_year_str AS INT64) AS v1_year_int, v1_make, v1_model
FROM (
  SELECT user_id,
    MAX(IF(LOWER(p.property_name) = 'email', TRIM(p.string_value), NULL)) AS email_val,
    MAX(IF(LOWER(p.property_name) = 'v1_year', COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year_str,
    MAX(IF(LOWER(p.property_name) = 'v1_make', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_make,
    MAX(IF(LOWER(p.property_name) = 'v1_model', COALESCE(UPPER(TRIM(p.string_value)), UPPER(CAST(p.long_value AS STRING))), NULL)) AS v1_model
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`, UNNEST(user_properties) AS p
  WHERE LOWER(p.property_name) IN ('email','v1_year','v1_make','v1_model')
  GROUP BY user_id
) WHERE email_val IS NOT NULL AND v1_year_str IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL;

SELECT 'Step 1: Users' AS step, COUNT(*) AS count FROM users_with_vehicles;

-- STEP 2: STAGED EVENTS (for prices/images/intent)
CREATE TEMP TABLE staged_events AS
WITH raw_events AS (
  SELECT t.user_id, t.client_event_timestamp AS event_ts, UPPER(t.event_name) AS event_name,
    CASE
      WHEN UPPER(t.event_name) IN ('VIEWED PRODUCT', 'ORDERED PRODUCT') AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      WHEN UPPER(t.event_name) IN ('CART UPDATE', 'PLACED ORDER') AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
      WHEN UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$')
        THEN UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING))))
    END AS sku,
    CASE WHEN LOWER(ep.property_name) IN ('price','itemprice') OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.itemprice$')
      THEN SAFE_CAST(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS FLOAT64) END AS price_val,
    CASE WHEN LOWER(ep.property_name) = 'imageurl' OR REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.imageurl$')
      THEN ep.string_value END AS image_val
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t, UNNEST(t.event_properties) ep
  WHERE DATE(t.client_event_timestamp) BETWEEN intent_window_start AND intent_window_end
    AND UPPER(t.event_name) IN ('VIEWED PRODUCT','ORDERED PRODUCT','CART UPDATE','PLACED ORDER','CONSUMER WEBSITE ORDER')
)
SELECT user_id, sku, event_ts, event_name, MAX(price_val) AS price, MAX(image_val) AS image_url_raw
FROM raw_events WHERE sku IS NOT NULL AND LENGTH(sku) > 0
GROUP BY user_id, sku, event_ts, event_name;

-- STEP 3: SKU PRICES & IMAGES
CREATE TEMP TABLE sku_prices AS SELECT sku, MAX(price) AS price FROM staged_events WHERE price IS NOT NULL GROUP BY sku;
CREATE TEMP TABLE sku_images AS
SELECT sku, image_url FROM (
  SELECT sku, CASE WHEN image_url_raw LIKE '//%' THEN CONCAT('https:', image_url_raw)
    WHEN LOWER(image_url_raw) LIKE 'http://%' THEN REGEXP_REPLACE(image_url_raw, '^http://', 'https://')
    ELSE image_url_raw END AS image_url,
    ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC) AS rn
  FROM staged_events WHERE image_url_raw IS NOT NULL
) WHERE rn = 1 AND image_url LIKE 'https://%';

-- STEP 4: ELIGIBLE PARTS
CREATE TEMP TABLE eligible_parts AS
WITH fitment_flat AS (
  SELECT DISTINCT SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make, UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku, COALESCE(cat.PartType, 'UNIVERSAL') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit, UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
)
SELECT DISTINCT f.year, f.make, f.model, f.sku, f.part_type,
  COALESCE(price.price, min_price) AS price, COALESCE(img.image_url, 'https://placeholder') AS image_url
FROM fitment_flat f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
WHERE COALESCE(price.price, min_price) >= min_price;

SELECT 'Step 4: Eligible parts' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts;

-- STEP 5: HISTORICAL POPULARITY (Jan 10 - Aug 31)
CREATE TEMP TABLE historical_popularity AS
SELECT UPPER(TRIM(ITEM)) AS sku, COUNT(*) AS hist_orders
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end
  AND ITEM IS NOT NULL
GROUP BY UPPER(TRIM(ITEM));

-- STEP 6: RECENT POPULARITY (Oct 16 - Dec 15) - 60 days before cutoff
CREATE TEMP TABLE recent_popularity AS
SELECT UPPER(TRIM(ITEM)) AS sku, COUNT(*) AS recent_orders
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_recent_start AND pop_recent_end
  AND ITEM IS NOT NULL
GROUP BY UPPER(TRIM(ITEM));

-- Combine into weighted popularity score
CREATE TEMP TABLE weighted_popularity AS
SELECT
  COALESCE(h.sku, r.sku) AS sku,
  COALESCE(h.hist_orders, 0) AS hist_orders,
  COALESCE(r.recent_orders, 0) AS recent_orders,
  -- V5.14: Weight recent 3x higher than historical
  LOG(1 + COALESCE(h.hist_orders, 0)) * 2 + LOG(1 + COALESCE(r.recent_orders, 0)) * 6 AS popularity_score
FROM historical_popularity h
FULL OUTER JOIN recent_popularity r ON h.sku = r.sku;

SELECT 'Popularity data' AS step,
  COUNT(DISTINCT sku) AS total_skus,
  SUM(CASE WHEN recent_orders > 0 THEN 1 ELSE 0 END) AS skus_with_recent,
  SUM(CASE WHEN hist_orders > 0 THEN 1 ELSE 0 END) AS skus_with_hist
FROM weighted_popularity;

-- STEP 7: INTENT SCORES
CREATE TEMP TABLE intent_scores AS
SELECT user_id, sku, SUM(CASE
  WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN LOG(1 + 1) * 20
  WHEN UPPER(event_name) = 'CART UPDATE' THEN LOG(1 + 1) * 10
  WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN LOG(1 + 1) * 2
  ELSE 0 END) AS intent_score
FROM staged_events GROUP BY user_id, sku;

-- STEP 8: PURCHASE EXCLUSION
CREATE TEMP TABLE purchase_exclusion AS
SELECT DISTINCT user_id, sku FROM staged_events WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER');

-- ==================================================================================================
-- V5.14: RECENCY-WEIGHTED POPULARITY + NO DIVERSITY FILTER
-- ==================================================================================================

CREATE TEMP TABLE v5_14_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model, ep.sku, ep.part_type,
    COALESCE(int.intent_score, 0) AS intent_score,
    COALESCE(wp.popularity_score, 0) AS popularity_score,
    COALESCE(wp.recent_orders, 0) AS recent_orders,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(wp.popularity_score, 0), 2) AS final_score_v514
  FROM users_with_vehicles uv
  JOIN eligible_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN weighted_popularity wp ON ep.sku = wp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
-- Variant dedup
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v514 DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
-- NO DIVERSITY FILTER (from V5.12)
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v514 DESC, sku) AS rank_v514 FROM dedup_variant
)
SELECT * FROM ranked WHERE rank_v514 <= 4;

CREATE TEMP TABLE v5_14_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_14_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v514 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v514 = 1 THEN recent_orders END) AS rec1_recent,
  MAX(CASE WHEN rank_v514 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v514 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v514 = 4 THEN sku END) AS rec_part_4
FROM v5_14_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'V5.14 recs' AS step, COUNT(*) AS users FROM v5_14_recs_wide;

-- V5.12 BASELINE (no diversity, original popularity)
CREATE TEMP TABLE baseline_popularity AS
SELECT UPPER(TRIM(ITEM)) AS sku, LOG(1 + COUNT(*)) * 2 AS popularity_score
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end AND ITEM IS NOT NULL
GROUP BY UPPER(TRIM(ITEM));

CREATE TEMP TABLE v5_12_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model, ep.sku, ep.part_type,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(bp.popularity_score, 0), 2) AS final_score_v512
  FROM users_with_vehicles uv
  JOIN eligible_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN baseline_popularity bp ON ep.sku = bp.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v512 DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v512 DESC, sku) AS rank_v512 FROM dedup_variant
)
SELECT * FROM ranked WHERE rank_v512 <= 4;

CREATE TEMP TABLE v5_12_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_12_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v512 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v512 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v512 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v512 = 4 THEN sku END) AS rec_part_4
FROM v5_12_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'V5.12 baseline' AS step, COUNT(*) AS users FROM v5_12_recs_wide;

-- ACTUAL PURCHASES
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
FROM order_events oe JOIN users_with_vehicles uv ON oe.user_id = uv.user_id WHERE oe.sku IS NOT NULL;

SELECT 'Purchases' AS step, COUNT(DISTINCT email_lower) AS buyers, COUNT(DISTINCT sku) AS products FROM actual_purchases;

-- MATCHES
CREATE TEMP TABLE v5_14_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_14_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

CREATE TEMP TABLE v5_12_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_12_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- RESULTS
SELECT '=== V5.14 BACKTEST RESULTS ===' AS section;

SELECT version, users_with_recs, users_who_purchased, users_matched,
  ROUND(100.0 * users_matched / NULLIF(users_with_recs, 0), 4) AS match_rate_pct, total_matches
FROM (
  SELECT 'v5.12 (baseline)' AS version,
    (SELECT COUNT(*) FROM v5_12_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_12_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_12_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_12_matches) AS total_matches
  UNION ALL
  SELECT 'v5.14 (recency)' AS version,
    (SELECT COUNT(*) FROM v5_14_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_14_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_14_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_14_matches) AS total_matches
) ORDER BY version;

-- How many recs changed between V5.12 and V5.14?
SELECT 'Recommendation changes' AS analysis,
  SUM(CASE WHEN v12.rec_part_1 != v14.rec_part_1 THEN 1 ELSE 0 END) AS rec1_changed,
  SUM(CASE WHEN v12.rec_part_2 != v14.rec_part_2 THEN 1 ELSE 0 END) AS rec2_changed,
  COUNT(*) AS total_users
FROM v5_12_recs_wide v12
JOIN v5_14_recs_wide v14 ON v12.user_id = v14.user_id;

-- Check if recently popular items are being recommended more
SELECT 'V5.14 Sample Matches' AS analysis, email_lower, v1_year, v1_make, v1_model, purchased_sku, matched_slot
FROM v5_14_matches LIMIT 20;
