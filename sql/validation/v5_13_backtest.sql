-- ==================================================================================================
-- V5.13 Lower Price Threshold Backtest
-- --------------------------------------------------------------------------------------------------
-- Hypothesis: $50 minimum price may exclude products users actually buy.
--             Try $25 instead.
-- Changes: min_price $50 -> $25, keep no diversity filter from V5.12
-- ==================================================================================================

DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';
DECLARE intent_window_start DATE DEFAULT DATE_SUB(test_cutoff_date, INTERVAL 60 DAY);
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';
DECLARE min_price FLOAT64 DEFAULT 25.0;  -- CHANGED: $50 -> $25
DECLARE current_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM test_cutoff_date) AS STRING), '%');
DECLARE previous_year_pattern STRING DEFAULT CONCAT('%', CAST(EXTRACT(YEAR FROM DATE_SUB(test_cutoff_date, INTERVAL 365 DAY)) AS STRING), '%');

SELECT '=== V5.13 LOWER PRICE ($25) BACKTEST ===' AS status;

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

-- STEP 2: STAGED EVENTS
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

-- STEP 4: ELIGIBLE PARTS (with $25 min price)
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
WHERE COALESCE(price.price, min_price) >= min_price;  -- $25 threshold

SELECT 'Step 4: Eligible parts ($25+)' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts;

-- STEP 5: HISTORICAL ORDERS & GLOBAL POPULARITY
CREATE TEMP TABLE import_orders_filtered AS
SELECT LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower, UPPER(TRIM(ITEM)) AS sku
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end AND ITEM IS NOT NULL;

CREATE TEMP TABLE global_popularity AS
SELECT sku, COUNT(*) AS global_orders, LOG(1 + COUNT(*)) * 2 AS popularity_score FROM import_orders_filtered GROUP BY sku;

-- STEP 6: INTENT SCORES
CREATE TEMP TABLE intent_scores AS
SELECT user_id, sku, SUM(CASE
  WHEN UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER') THEN LOG(1 + 1) * 20
  WHEN UPPER(event_name) = 'CART UPDATE' THEN LOG(1 + 1) * 10
  WHEN UPPER(event_name) = 'VIEWED PRODUCT' THEN LOG(1 + 1) * 2
  ELSE 0 END) AS intent_score
FROM staged_events GROUP BY user_id, sku;

-- STEP 7: PURCHASE EXCLUSION
CREATE TEMP TABLE purchase_exclusion AS
SELECT DISTINCT user_id, sku FROM staged_events WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER');

-- ==================================================================================================
-- V5.13: LOWER PRICE ($25) + NO DIVERSITY FILTER
-- ==================================================================================================

CREATE TEMP TABLE v5_13_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model, ep.sku, ep.part_type,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(gp.popularity_score, 0), 2) AS final_score_v513
  FROM users_with_vehicles uv
  JOIN eligible_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN global_popularity gp ON ep.sku = gp.sku
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
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score_v513 DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
-- NO DIVERSITY FILTER (from V5.12)
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score_v513 DESC, sku) AS rank_v513 FROM dedup_variant
)
SELECT * FROM ranked WHERE rank_v513 <= 4;

CREATE TEMP TABLE v5_13_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_13_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_v513 = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_v513 = 1 THEN part_type END) AS rec1_part_type,
  MAX(CASE WHEN rank_v513 = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_v513 = 2 THEN part_type END) AS rec2_part_type,
  MAX(CASE WHEN rank_v513 = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_v513 = 3 THEN part_type END) AS rec3_part_type,
  MAX(CASE WHEN rank_v513 = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rank_v513 = 4 THEN part_type END) AS rec4_part_type
FROM v5_13_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'V5.13 recs' AS step, COUNT(*) AS users FROM v5_13_recs_wide;

-- V5.12 BASELINE (no diversity, $50 price)
CREATE TEMP TABLE eligible_parts_v512 AS
WITH fitment_flat AS (
  SELECT DISTINCT SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make, UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku, COALESCE(cat.PartType, 'UNIVERSAL') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit, UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
)
SELECT DISTINCT f.year, f.make, f.model, f.sku, f.part_type,
  COALESCE(price.price, 50.0) AS price, COALESCE(img.image_url, 'https://placeholder') AS image_url
FROM fitment_flat f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
WHERE COALESCE(price.price, 50.0) >= 50.0;  -- $50 threshold for baseline

SELECT 'Eligible parts ($50+)' AS step, COUNT(DISTINCT sku) AS skus FROM eligible_parts_v512;

CREATE TEMP TABLE v5_12_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model, ep.sku, ep.part_type,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(gp.popularity_score, 0), 2) AS final_score_v512
  FROM users_with_vehicles uv
  JOIN eligible_parts_v512 ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
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
CREATE TEMP TABLE v5_13_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_13_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

CREATE TEMP TABLE v5_12_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_12_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- RESULTS
SELECT '=== V5.13 BACKTEST RESULTS ===' AS section;

SELECT version, users_with_recs, users_who_purchased, users_matched,
  ROUND(100.0 * users_matched / NULLIF(users_with_recs, 0), 4) AS match_rate_pct, total_matches
FROM (
  SELECT 'v5.12 ($50 min)' AS version,
    (SELECT COUNT(*) FROM v5_12_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_12_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_12_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_12_matches) AS total_matches
  UNION ALL
  SELECT 'v5.13 ($25 min)' AS version,
    (SELECT COUNT(*) FROM v5_13_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_13_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_13_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_13_matches) AS total_matches
) ORDER BY version;

-- ANALYSIS: What price range do actual purchases fall into?
SELECT 'Purchased product price distribution' AS analysis,
  price_tier, COUNT(*) AS purchases
FROM (
  SELECT CASE
    WHEN sp.price < 25 THEN '<$25'
    WHEN sp.price < 50 THEN '$25-49'
    WHEN sp.price < 100 THEN '$50-99'
    WHEN sp.price < 200 THEN '$100-199'
    ELSE '$200+'
  END AS price_tier
  FROM actual_purchases ap
  JOIN sku_prices sp ON ap.sku = sp.sku
)
GROUP BY price_tier ORDER BY price_tier;

SELECT 'V5.13 Match Slot Distribution' AS analysis, matched_slot, COUNT(*) AS match_count
FROM v5_13_matches GROUP BY matched_slot ORDER BY matched_slot;

SELECT 'New products with $25-49 price' AS analysis, COUNT(DISTINCT sku) AS new_skus
FROM eligible_parts WHERE price >= 25 AND price < 50;

SELECT 'V5.13 Sample Matches' AS analysis, email_lower, v1_year, v1_make, v1_model, purchased_sku, matched_slot
FROM v5_13_matches LIMIT 20;
