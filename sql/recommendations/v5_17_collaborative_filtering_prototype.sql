-- ==================================================================================================
-- V5.17 PROTOTYPE: Collaborative Filtering - Co-Purchase Patterns
-- ==================================================================================================
-- Key Idea: "Users who bought X also bought Y"
--
-- If a user has purchased product A, recommend products that OTHER users
-- who also bought A frequently purchased.
--
-- This helps surface niche products that pure popularity misses.
-- ==================================================================================================

-- Configuration
DECLARE analysis_start DATE DEFAULT DATE('2025-04-16');
DECLARE intent_boundary DATE DEFAULT DATE('2025-09-01');
DECLARE analysis_end DATE DEFAULT DATE('2025-12-15');
DECLARE min_co_purchases INT64 DEFAULT 3;  -- Minimum times products bought together
DECLARE min_support INT64 DEFAULT 5;       -- Minimum users who bought both products

-- ====================================================================================
-- STEP 1: GET ALL USER-PRODUCT PURCHASES (VFU USERS ONLY)
-- ====================================================================================

-- First get VFU users
CREATE TEMP TABLE vfu_users AS
SELECT DISTINCT
  user_id,
  MAX(CASE WHEN p.property_name = 'v1_make' THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))) END) as v1_make,
  MAX(CASE WHEN p.property_name = 'v1_model' THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))) END) as v1_model,
  MAX(CASE WHEN p.property_name = 'email' THEN LOWER(TRIM(p.string_value)) END) as email
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name IN ('v1_year', 'v1_make', 'v1_model', 'email')
GROUP BY user_id
HAVING v1_make IS NOT NULL AND v1_model IS NOT NULL AND email IS NOT NULL;

-- Historical purchases (import_orders)
CREATE TEMP TABLE historical_purchases AS
SELECT DISTINCT
  v.user_id,
  v.v1_make,
  v.v1_model,
  REGEXP_REPLACE(UPPER(TRIM(io.ITEM)), r'([0-9])[BRGP]$', r'\1') as sku
FROM `auxia-gcp.data_company_1950.import_orders` io
JOIN vfu_users v ON LOWER(TRIM(io.SHIP_TO_EMAIL)) = v.email
WHERE SAFE.PARSE_DATE('%A, %B %d, %Y', io.ORDER_DATE) BETWEEN analysis_start AND analysis_end
  AND io.ITEM IS NOT NULL
  AND NOT (io.ITEM LIKE 'EXT-%' OR io.ITEM LIKE 'GIFT-%' OR io.ITEM LIKE 'WARRANTY-%'
           OR io.ITEM LIKE 'SERVICE-%' OR io.ITEM LIKE 'PREAUTH-%');

-- Intent purchases (ingestion_unified)
CREATE TEMP TABLE intent_purchases AS
SELECT DISTINCT
  v.user_id,
  v.v1_make,
  v.v1_model,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r'([0-9])[BRGP]$', r'\1') as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
JOIN vfu_users v ON e.user_id = v.user_id
WHERE DATE(e.client_event_timestamp) BETWEEN intent_boundary AND analysis_end
  AND UPPER(e.event_name) IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER')
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'))
  AND COALESCE(p.string_value, CAST(p.long_value AS STRING)) NOT LIKE '%SHIP%'
  AND COALESCE(p.string_value, CAST(p.long_value AS STRING)) NOT LIKE '%AUTH%';

-- Combined purchases
CREATE TEMP TABLE all_purchases AS
SELECT DISTINCT user_id, v1_make, v1_model, sku FROM historical_purchases
UNION DISTINCT
SELECT DISTINCT user_id, v1_make, v1_model, sku FROM intent_purchases;

-- ====================================================================================
-- STEP 2: BUILD CO-PURCHASE MATRIX
-- ====================================================================================
-- Find pairs of products bought by the same user (within same segment)

CREATE TEMP TABLE co_purchases AS
SELECT
  p1.v1_make,
  p1.v1_model,
  p1.sku as sku_a,
  p2.sku as sku_b,
  COUNT(DISTINCT p1.user_id) as users_bought_both
FROM all_purchases p1
JOIN all_purchases p2
  ON p1.user_id = p2.user_id
  AND p1.v1_make = p2.v1_make
  AND p1.v1_model = p2.v1_model
  AND p1.sku < p2.sku  -- Avoid duplicates and self-pairs
GROUP BY p1.v1_make, p1.v1_model, p1.sku, p2.sku
HAVING COUNT(DISTINCT p1.user_id) >= min_support;

-- ====================================================================================
-- STEP 3: CALCULATE CO-PURCHASE SCORES
-- ====================================================================================
-- Score = users_bought_both / users_bought_a (conditional probability)
-- "Given user bought A, what's probability they also bought B?"

CREATE TEMP TABLE sku_buyer_counts AS
SELECT
  v1_make,
  v1_model,
  sku,
  COUNT(DISTINCT user_id) as total_buyers
FROM all_purchases
GROUP BY v1_make, v1_model, sku;

CREATE TEMP TABLE co_purchase_scores AS
SELECT
  cp.v1_make,
  cp.v1_model,
  cp.sku_a,
  cp.sku_b,
  cp.users_bought_both,
  bc_a.total_buyers as buyers_of_a,
  bc_b.total_buyers as buyers_of_b,
  -- P(B|A) = users who bought both / users who bought A
  ROUND(cp.users_bought_both / bc_a.total_buyers, 3) as prob_b_given_a,
  -- P(A|B) = users who bought both / users who bought B
  ROUND(cp.users_bought_both / bc_b.total_buyers, 3) as prob_a_given_b,
  -- Lift = P(A,B) / (P(A) * P(B)) - how much more likely than random
  -- Simplified: users_bought_both * total_segment_users / (buyers_a * buyers_b)
  ROUND(LOG(1 + cp.users_bought_both) * 5, 2) as co_purchase_score
FROM co_purchases cp
JOIN sku_buyer_counts bc_a ON cp.v1_make = bc_a.v1_make AND cp.v1_model = bc_a.v1_model AND cp.sku_a = bc_a.sku
JOIN sku_buyer_counts bc_b ON cp.v1_make = bc_b.v1_make AND cp.v1_model = bc_b.v1_model AND cp.sku_b = bc_b.sku;

-- ====================================================================================
-- STEP 4: SAMPLE OUTPUT - Top co-purchase pairs by segment
-- ====================================================================================
SELECT
  v1_make,
  v1_model,
  sku_a,
  sku_b,
  users_bought_both,
  buyers_of_a,
  buyers_of_b,
  prob_b_given_a,
  prob_a_given_b,
  co_purchase_score
FROM co_purchase_scores
WHERE v1_make || '/' || v1_model IN (
  'FORD/MUSTANG', 'CHEVROLET/CAMARO', 'CHEVROLET/SILVERADO 1500'
)
ORDER BY v1_make, v1_model, users_bought_both DESC
LIMIT 50;

-- ====================================================================================
-- STEP 5: SUMMARY STATS
-- ====================================================================================
SELECT
  'Co-Purchase Stats' as metric,
  COUNT(*) as total_pairs,
  COUNT(DISTINCT v1_make || '/' || v1_model) as segments_with_pairs,
  ROUND(AVG(users_bought_both), 1) as avg_users_bought_both,
  ROUND(AVG(prob_b_given_a), 3) as avg_conditional_prob,
  MAX(users_bought_both) as max_users_bought_both
FROM co_purchase_scores;

-- ====================================================================================
-- STEP 6: HOW WOULD THIS HELP COVERAGE?
-- ====================================================================================
-- For users who made at least one purchase, what additional products could we recommend?

CREATE TEMP TABLE user_recommendations AS
SELECT DISTINCT
  ap.user_id,
  ap.v1_make,
  ap.v1_model,
  ap.sku as purchased_sku,
  cps.sku_b as recommended_sku,
  cps.co_purchase_score,
  cps.prob_b_given_a
FROM all_purchases ap
JOIN co_purchase_scores cps
  ON ap.v1_make = cps.v1_make
  AND ap.v1_model = cps.v1_model
  AND ap.sku = cps.sku_a
WHERE cps.sku_b NOT IN (
  SELECT sku FROM all_purchases ap2 WHERE ap2.user_id = ap.user_id
);

SELECT
  'CF Coverage Potential' as metric,
  COUNT(DISTINCT user_id) as users_with_cf_recs,
  COUNT(DISTINCT recommended_sku) as unique_cf_skus,
  COUNT(*) as total_cf_recommendations,
  ROUND(AVG(co_purchase_score), 2) as avg_cf_score
FROM user_recommendations;
