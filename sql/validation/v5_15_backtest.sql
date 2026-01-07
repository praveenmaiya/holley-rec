-- ==================================================================================================
-- V5.15 Universal + Fitment Products Backtest
-- --------------------------------------------------------------------------------------------------
-- Hypothesis: V5.12 only recommends fitment products, missing 64% of VFU purchases.
--             Adding universal products (gauges, sensors, etc.) should improve match rate.
-- Changes:
--   - Fitment products: Still require YMM match
--   - Universal products: Can be recommended to ANY user (no YMM filter)
-- ==================================================================================================

DECLARE test_cutoff_date DATE DEFAULT DATE '2025-12-15';
DECLARE eval_window_end DATE DEFAULT DATE '2026-01-05';
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';
DECLARE intent_window_end DATE DEFAULT test_cutoff_date;
DECLARE pop_hist_start DATE DEFAULT DATE '2025-01-10';
DECLARE pop_hist_end DATE DEFAULT DATE '2025-08-31';
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE max_universal_products INT64 DEFAULT 500;  -- V5.15: Limit universal pool size
DECLARE current_year_pattern STRING DEFAULT '%2025%';
DECLARE previous_year_pattern STRING DEFAULT '%2024%';

SELECT '=== V5.15 UNIVERSAL + FITMENT BACKTEST ===' AS status;

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

-- STEP 4a: ELIGIBLE FITMENT PARTS (YMM-specific)
-- Note: Use placeholder image for backtest (production uses events images)
CREATE TEMP TABLE eligible_fitment_parts AS
WITH fitment_flat AS (
  SELECT DISTINCT SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS year,
    UPPER(TRIM(fit.v1_make)) AS make, UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku, COALESCE(cat.PartType, 'UNKNOWN') AS part_type
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit, UNNEST(fit.products) prod
  LEFT JOIN `auxia-gcp.data_company_1950.import_items` cat ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(cat.PartNumber))
  WHERE prod.product_number IS NOT NULL
)
SELECT DISTINCT f.year, f.make, f.model, f.sku, f.part_type,
  COALESCE(price.price, min_price) AS price,
  COALESCE(img.image_url, 'https://placeholder') AS image_url  -- Allow placeholder for backtest
FROM fitment_flat f
LEFT JOIN sku_images img ON f.sku = img.sku
LEFT JOIN sku_prices price ON f.sku = price.sku
WHERE COALESCE(price.price, min_price) >= min_price
  AND NOT (f.sku LIKE 'EXT-%' OR f.sku LIKE 'GIFT-%' OR f.sku LIKE 'WARRANTY-%' OR f.sku LIKE 'SERVICE-%' OR f.sku LIKE 'PREAUTH-%');

SELECT 'Step 4a: Fitment parts' AS step, COUNT(DISTINCT sku) AS unique_skus FROM eligible_fitment_parts;

-- STEP 4b: ELIGIBLE UNIVERSAL PARTS (NOT in fitment catalog - available to ALL users)
-- Note: Use placeholder image for backtest
CREATE TEMP TABLE eligible_universal_parts AS
WITH fitment_skus AS (
  SELECT DISTINCT UPPER(TRIM(prod.product_number)) AS sku
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit, UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
),
all_catalog AS (
  SELECT UPPER(TRIM(PartNumber)) AS sku, COALESCE(PartType, 'UNKNOWN') AS part_type
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL
),
universal_base AS (
  SELECT ac.sku, ac.part_type
  FROM all_catalog ac
  LEFT JOIN fitment_skus fs ON ac.sku = fs.sku
  WHERE fs.sku IS NULL  -- Not in fitment catalog = universal
),
with_prices_images AS (
  SELECT ub.sku, ub.part_type,
    COALESCE(img.image_url, 'https://placeholder') AS image_url,  -- Allow placeholder for backtest
    COALESCE(price.price, min_price) AS price
  FROM universal_base ub
  LEFT JOIN sku_images img ON ub.sku = img.sku
  LEFT JOIN sku_prices price ON ub.sku = price.sku
  WHERE COALESCE(price.price, min_price) >= min_price
    AND NOT (ub.sku LIKE 'EXT-%' OR ub.sku LIKE 'GIFT-%' OR ub.sku LIKE 'WARRANTY-%' OR ub.sku LIKE 'SERVICE-%' OR ub.sku LIKE 'PREAUTH-%')
)
SELECT sku, part_type, image_url, price
FROM with_prices_images;

SELECT 'Step 4b: Universal parts' AS step, COUNT(DISTINCT sku) AS unique_skus FROM eligible_universal_parts;

-- STEP 5: POPULARITY SCORES
CREATE TEMP TABLE popularity_scores AS
WITH historical AS (
  SELECT UPPER(TRIM(ITEM)) AS sku, COUNT(*) AS order_count
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE (ORDER_DATE LIKE current_year_pattern OR ORDER_DATE LIKE previous_year_pattern)
    AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) BETWEEN pop_hist_start AND pop_hist_end
    AND ITEM IS NOT NULL
  GROUP BY UPPER(TRIM(ITEM))
),
recent AS (
  SELECT sku, COUNT(*) AS order_count
  FROM staged_events
  WHERE UPPER(event_name) IN ('PLACED ORDER','ORDERED PRODUCT','CONSUMER WEBSITE ORDER')
  GROUP BY sku
),
combined AS (
  SELECT COALESCE(h.sku, r.sku) AS sku, COALESCE(h.order_count, 0) + COALESCE(r.order_count, 0) AS total_orders
  FROM historical h FULL OUTER JOIN recent r ON h.sku = r.sku
)
SELECT sku, total_orders, LOG(1 + total_orders) * 2 AS popularity_score
FROM combined;

-- Top universal products by popularity (limit to max_universal_products)
CREATE TEMP TABLE top_universal_parts AS
SELECT up.sku, up.part_type, up.image_url, up.price, COALESCE(ps.popularity_score, 0) AS popularity_score
FROM eligible_universal_parts up
LEFT JOIN popularity_scores ps ON up.sku = ps.sku
ORDER BY COALESCE(ps.popularity_score, 0) DESC
LIMIT 500;  -- max_universal_products

SELECT 'Top universal parts' AS step, COUNT(*) AS count, ROUND(AVG(popularity_score), 2) AS avg_pop FROM top_universal_parts;

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
-- V5.12: FITMENT ONLY BASELINE (for comparison)
-- ==================================================================================================

CREATE TEMP TABLE v5_12_backtest_recs AS
WITH candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model,
    ep.sku, ep.part_type, 'fitment' AS product_type,
    COALESCE(int.intent_score, 0) AS intent_score,
    COALESCE(ps.popularity_score, 0) AS popularity_score,
    ROUND(COALESCE(int.intent_score, 0) + COALESCE(ps.popularity_score, 0), 2) AS final_score
  FROM users_with_vehicles uv
  JOIN eligible_fitment_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN popularity_scores ps ON ep.sku = ps.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score DESC, sku) AS rank_num FROM dedup_variant
)
SELECT * FROM ranked WHERE rank_num <= 4;

CREATE TEMP TABLE v5_12_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_12_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_num = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_num = 1 THEN product_type END) AS rec1_type,
  MAX(CASE WHEN rank_num = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_num = 2 THEN product_type END) AS rec2_type,
  MAX(CASE WHEN rank_num = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_num = 3 THEN product_type END) AS rec3_type,
  MAX(CASE WHEN rank_num = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rank_num = 4 THEN product_type END) AS rec4_type
FROM v5_12_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'V5.12 recs (fitment only)' AS step, COUNT(*) AS users FROM v5_12_recs_wide;

-- ==================================================================================================
-- V5.15: FITMENT + UNIVERSAL
-- ==================================================================================================

CREATE TEMP TABLE v5_15_backtest_recs AS
WITH
-- Fitment candidates (YMM-specific)
fitment_candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model,
    ep.sku, ep.part_type, 'fitment' AS product_type,
    COALESCE(int.intent_score, 0) AS intent_score,
    COALESCE(ps.popularity_score, 0) AS popularity_score
  FROM users_with_vehicles uv
  JOIN eligible_fitment_parts ep ON uv.v1_year_int = ep.year AND uv.v1_make = ep.make AND uv.v1_model = ep.model
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND ep.sku = int.sku
  LEFT JOIN popularity_scores ps ON ep.sku = ps.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND ep.sku = purch.sku
  WHERE purch.sku IS NULL
),
-- Universal candidates (available to ALL users - no YMM filter)
universal_candidates AS (
  SELECT uv.user_id, uv.email_lower, uv.v1_year, uv.v1_year_int, uv.v1_make, uv.v1_model,
    up.sku, up.part_type, 'universal' AS product_type,
    COALESCE(int.intent_score, 0) AS intent_score,
    up.popularity_score
  FROM users_with_vehicles uv
  CROSS JOIN top_universal_parts up
  LEFT JOIN intent_scores int ON uv.user_id = int.user_id AND up.sku = int.sku
  LEFT JOIN purchase_exclusion purch ON uv.user_id = purch.user_id AND up.sku = purch.sku
  WHERE purch.sku IS NULL
),
-- Union both
all_candidates AS (
  SELECT *, ROUND(intent_score + popularity_score, 2) AS final_score FROM fitment_candidates
  UNION ALL
  SELECT *, ROUND(intent_score + popularity_score, 2) AS final_score FROM universal_candidates
),
normalized AS (
  SELECT *, REGEXP_REPLACE(REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''), r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM all_candidates
),
dedup_variant AS (
  SELECT * EXCEPT(rn_var) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku) AS rn_var FROM normalized
  ) WHERE rn_var = 1
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY final_score DESC, sku) AS rank_num FROM dedup_variant
)
SELECT * FROM ranked WHERE rank_num <= 4;

CREATE TEMP TABLE v5_15_recs_wide AS
WITH users_with_4_recs AS (SELECT user_id FROM v5_15_backtest_recs GROUP BY user_id HAVING COUNT(*) = 4)
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model,
  MAX(CASE WHEN rank_num = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN rank_num = 1 THEN product_type END) AS rec1_type,
  MAX(CASE WHEN rank_num = 2 THEN sku END) AS rec_part_2,
  MAX(CASE WHEN rank_num = 2 THEN product_type END) AS rec2_type,
  MAX(CASE WHEN rank_num = 3 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN rank_num = 3 THEN product_type END) AS rec3_type,
  MAX(CASE WHEN rank_num = 4 THEN sku END) AS rec_part_4,
  MAX(CASE WHEN rank_num = 4 THEN product_type END) AS rec4_type
FROM v5_15_backtest_recs r JOIN users_with_4_recs u4 ON r.user_id = u4.user_id
GROUP BY r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model;

SELECT 'V5.15 recs (fitment + universal)' AS step, COUNT(*) AS users FROM v5_15_recs_wide;

-- Product type distribution in V5.15
SELECT 'V5.15 Product Type Distribution' AS analysis,
  SUM(CASE WHEN rec1_type = 'fitment' THEN 1 ELSE 0 END) AS rec1_fitment,
  SUM(CASE WHEN rec1_type = 'universal' THEN 1 ELSE 0 END) AS rec1_universal,
  SUM(CASE WHEN rec2_type = 'fitment' THEN 1 ELSE 0 END) AS rec2_fitment,
  SUM(CASE WHEN rec2_type = 'universal' THEN 1 ELSE 0 END) AS rec2_universal,
  COUNT(*) AS total_users
FROM v5_15_recs_wide;

-- ==================================================================================================
-- ACTUAL PURCHASES (Dec 16 - Jan 5)
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
FROM order_events oe JOIN users_with_vehicles uv ON oe.user_id = uv.user_id WHERE oe.sku IS NOT NULL;

-- Classify purchases as fitment vs universal
CREATE TEMP TABLE purchases_classified AS
SELECT ap.email_lower, ap.sku, ap.order_date,
  CASE WHEN fs.sku IS NOT NULL THEN 'fitment' ELSE 'universal' END AS product_type
FROM actual_purchases ap
LEFT JOIN (SELECT DISTINCT sku FROM eligible_fitment_parts) fs ON ap.sku = fs.sku;

SELECT 'Purchases by type' AS analysis,
  SUM(CASE WHEN product_type = 'fitment' THEN 1 ELSE 0 END) AS fitment_purchases,
  SUM(CASE WHEN product_type = 'universal' THEN 1 ELSE 0 END) AS universal_purchases,
  COUNT(*) AS total_purchases,
  COUNT(DISTINCT email_lower) AS unique_buyers
FROM purchases_classified;

-- ==================================================================================================
-- MATCHES
-- ==================================================================================================

CREATE TEMP TABLE v5_12_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  pc.product_type AS purchased_type,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_12_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
JOIN purchases_classified pc ON p.email_lower = pc.email_lower AND p.sku = pc.sku
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

CREATE TEMP TABLE v5_15_matches AS
SELECT r.user_id, r.email_lower, r.v1_year, r.v1_make, r.v1_model, p.sku AS purchased_sku,
  pc.product_type AS purchased_type,
  CASE WHEN p.sku = r.rec_part_1 THEN r.rec1_type
       WHEN p.sku = r.rec_part_2 THEN r.rec2_type
       WHEN p.sku = r.rec_part_3 THEN r.rec3_type
       WHEN p.sku = r.rec_part_4 THEN r.rec4_type END AS rec_type,
  CASE WHEN p.sku = r.rec_part_1 THEN 1 WHEN p.sku = r.rec_part_2 THEN 2
       WHEN p.sku = r.rec_part_3 THEN 3 WHEN p.sku = r.rec_part_4 THEN 4 END AS matched_slot
FROM v5_15_recs_wide r
JOIN actual_purchases p ON r.email_lower = p.email_lower
JOIN purchases_classified pc ON p.email_lower = pc.email_lower AND p.sku = pc.sku
WHERE p.sku IN (r.rec_part_1, r.rec_part_2, r.rec_part_3, r.rec_part_4);

-- ==================================================================================================
-- RESULTS COMPARISON
-- ==================================================================================================

SELECT '=== V5.15 BACKTEST RESULTS ===' AS section;

SELECT version, users_with_recs, users_who_purchased, users_matched,
  ROUND(100.0 * users_matched / NULLIF(users_with_recs, 0), 4) AS match_rate_pct,
  total_matches,
  fitment_matches,
  universal_matches
FROM (
  SELECT 'v5.12 (fitment only)' AS version,
    (SELECT COUNT(*) FROM v5_12_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_12_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_12_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_12_matches) AS total_matches,
    (SELECT COUNT(*) FROM v5_12_matches WHERE purchased_type = 'fitment') AS fitment_matches,
    (SELECT COUNT(*) FROM v5_12_matches WHERE purchased_type = 'universal') AS universal_matches
  UNION ALL
  SELECT 'v5.15 (fitment + universal)' AS version,
    (SELECT COUNT(*) FROM v5_15_recs_wide) AS users_with_recs,
    (SELECT COUNT(DISTINCT r.email_lower) FROM v5_15_recs_wide r JOIN actual_purchases p ON r.email_lower = p.email_lower) AS users_who_purchased,
    (SELECT COUNT(DISTINCT email_lower) FROM v5_15_matches) AS users_matched,
    (SELECT COUNT(*) FROM v5_15_matches) AS total_matches,
    (SELECT COUNT(*) FROM v5_15_matches WHERE purchased_type = 'fitment') AS fitment_matches,
    (SELECT COUNT(*) FROM v5_15_matches WHERE purchased_type = 'universal') AS universal_matches
) ORDER BY version;

-- Match type breakdown for V5.15
SELECT 'V5.15 Match Breakdown' AS analysis,
  SUM(CASE WHEN rec_type = 'fitment' AND purchased_type = 'fitment' THEN 1 ELSE 0 END) AS fitment_rec_fitment_purchase,
  SUM(CASE WHEN rec_type = 'universal' AND purchased_type = 'universal' THEN 1 ELSE 0 END) AS universal_rec_universal_purchase,
  SUM(CASE WHEN rec_type = 'fitment' AND purchased_type = 'universal' THEN 1 ELSE 0 END) AS fitment_rec_universal_purchase,
  SUM(CASE WHEN rec_type = 'universal' AND purchased_type = 'fitment' THEN 1 ELSE 0 END) AS universal_rec_fitment_purchase,
  COUNT(*) AS total_matches
FROM v5_15_matches;

-- Sample V5.15 matches
SELECT 'V5.15 Sample Matches' AS analysis, email_lower, v1_year, v1_make, v1_model,
  purchased_sku, purchased_type, rec_type, matched_slot
FROM v5_15_matches LIMIT 20;

-- Recommendation changes: how many users have different recs in V5.15?
SELECT 'Recommendation Changes' AS analysis,
  SUM(CASE WHEN v12.rec_part_1 != v15.rec_part_1 THEN 1 ELSE 0 END) AS rec1_changed,
  SUM(CASE WHEN v12.rec_part_2 != v15.rec_part_2 THEN 1 ELSE 0 END) AS rec2_changed,
  SUM(CASE WHEN v12.rec_part_3 != v15.rec_part_3 THEN 1 ELSE 0 END) AS rec3_changed,
  SUM(CASE WHEN v12.rec_part_4 != v15.rec_part_4 THEN 1 ELSE 0 END) AS rec4_changed,
  COUNT(*) AS total_users
FROM v5_12_recs_wide v12
JOIN v5_15_recs_wide v15 ON v12.user_id = v15.user_id;
