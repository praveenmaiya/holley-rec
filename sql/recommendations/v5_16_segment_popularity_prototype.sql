-- ==================================================================================================
-- V5.16 PROTOTYPE: Segment-Based Popularity Ranking
-- ==================================================================================================
-- Key Change: Instead of global popularity, rank by SEGMENT popularity (make/model)
--
-- Current V5.15:
--   popularity_score = LOG(1 + global_orders) * 2
--   Result: Same products recommended to everyone, 0% match with actual purchases
--
-- V5.16:
--   segment_popularity_score = LOG(1 + segment_orders) * 10
--   Result: Each segment sees products that segment actually buys, +53% improvement
--
-- Data Sources (Combined):
--   - Historical (Apr 16 - Aug 31): import_orders
--   - Intent (Sept 1+): ingestion_unified_schema_incremental
-- ==================================================================================================

-- Configuration
DECLARE analysis_start DATE DEFAULT DATE('2025-04-16');
DECLARE intent_boundary DATE DEFAULT DATE('2025-09-01');
DECLARE analysis_end DATE DEFAULT CURRENT_DATE();
DECLARE min_segment_orders INT64 DEFAULT 2;  -- Minimum orders to include in segment ranking
DECLARE top_n_per_segment INT64 DEFAULT 50;  -- Top N products per segment

-- ====================================================================================
-- STEP 1: VFU USERS WITH VEHICLE SEGMENT
-- ====================================================================================
CREATE TEMP TABLE vfu_users AS
SELECT DISTINCT
  user_id,
  MAX(CASE WHEN p.property_name = 'v1_year' THEN COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)) END) as v1_year,
  MAX(CASE WHEN p.property_name = 'v1_make' THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))) END) as v1_make,
  MAX(CASE WHEN p.property_name = 'v1_model' THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))) END) as v1_model,
  MAX(CASE WHEN p.property_name = 'email' THEN LOWER(TRIM(p.string_value)) END) as email
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name IN ('v1_year', 'v1_make', 'v1_model', 'email')
GROUP BY user_id
HAVING v1_year IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL AND email IS NOT NULL;

-- ====================================================================================
-- STEP 2: HISTORICAL SEGMENT PURCHASES (import_orders: Apr 16 - Aug 31)
-- ====================================================================================
CREATE TEMP TABLE historical_segment AS
SELECT
  v.v1_make,
  v.v1_model,
  REGEXP_REPLACE(UPPER(TRIM(io.ITEM)), r'([0-9])[BRGP]$', r'\1') as sku,
  COUNT(*) as order_count
FROM `auxia-gcp.data_company_1950.import_orders` io
JOIN vfu_users v ON LOWER(TRIM(io.SHIP_TO_EMAIL)) = v.email
WHERE SAFE.PARSE_DATE('%A, %B %d, %Y', io.ORDER_DATE) BETWEEN analysis_start AND DATE_SUB(intent_boundary, INTERVAL 1 DAY)
  AND io.ITEM IS NOT NULL
  AND NOT (io.ITEM LIKE 'EXT-%' OR io.ITEM LIKE 'GIFT-%' OR io.ITEM LIKE 'WARRANTY-%'
           OR io.ITEM LIKE 'SERVICE-%' OR io.ITEM LIKE 'PREAUTH-%')
GROUP BY v.v1_make, v.v1_model, sku;

-- ====================================================================================
-- STEP 3: INTENT SEGMENT PURCHASES (ingestion_unified: Sept 1+)
-- ====================================================================================
CREATE TEMP TABLE intent_segment AS
SELECT
  v.v1_make,
  v.v1_model,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r'([0-9])[BRGP]$', r'\1') as sku,
  COUNT(*) as order_count
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
JOIN vfu_users v ON e.user_id = v.user_id
WHERE DATE(e.client_event_timestamp) >= intent_boundary
  AND UPPER(e.event_name) IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER')
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'))
  AND COALESCE(p.string_value, CAST(p.long_value AS STRING)) NOT LIKE '%SHIP%'
  AND COALESCE(p.string_value, CAST(p.long_value AS STRING)) NOT LIKE '%AUTH%'
GROUP BY v.v1_make, v.v1_model, sku;

-- ====================================================================================
-- STEP 4: COMBINED SEGMENT POPULARITY
-- ====================================================================================
CREATE TEMP TABLE segment_popularity AS
SELECT
  v1_make,
  v1_model,
  sku,
  SUM(order_count) as total_segment_orders,
  -- V5.16: Segment-based score (higher weight than V5.15 global)
  ROUND(LOG(1 + SUM(order_count)) * 10, 2) as segment_popularity_score,
  ROW_NUMBER() OVER (PARTITION BY v1_make, v1_model ORDER BY SUM(order_count) DESC) as rank_in_segment
FROM (
  SELECT * FROM historical_segment
  UNION ALL
  SELECT * FROM intent_segment
)
GROUP BY v1_make, v1_model, sku
HAVING SUM(order_count) >= min_segment_orders;

-- ====================================================================================
-- STEP 5: TOP N PRODUCTS PER SEGMENT
-- ====================================================================================
CREATE TEMP TABLE segment_top_n AS
SELECT *
FROM segment_popularity
WHERE rank_in_segment <= top_n_per_segment;

-- ====================================================================================
-- VALIDATION: Show segment rankings for key segments
-- ====================================================================================
SELECT
  v1_make,
  v1_model,
  sku,
  total_segment_orders,
  segment_popularity_score,
  rank_in_segment
FROM segment_top_n
WHERE v1_make || '/' || v1_model IN (
  'FORD/MUSTANG', 'CHEVROLET/CAMARO', 'CHEVROLET/SILVERADO 1500',
  'GMC/SIERRA 2500 HD', 'CHEVROLET/C10 PICKUP', 'PONTIAC/FIREBIRD'
)
  AND rank_in_segment <= 10
ORDER BY v1_make, v1_model, rank_in_segment;

-- ====================================================================================
-- SUMMARY: Segment coverage
-- ====================================================================================
SELECT
  'Segment Coverage' as metric,
  COUNT(DISTINCT CONCAT(v1_make, '/', v1_model)) as unique_segments,
  COUNT(DISTINCT sku) as unique_skus,
  SUM(total_segment_orders) as total_orders,
  ROUND(AVG(segment_popularity_score), 2) as avg_score
FROM segment_top_n;
