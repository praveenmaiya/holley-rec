-- ==================================================================================================
-- GNN Option A: Node Export
-- Exports user, product, and vehicle nodes from BigQuery to temp_holley_gnn
-- See docs/plans/2026-02-16-gnn-option-a-design.md Section 3
-- ==================================================================================================

-- Parameters (override via BQClient placeholder substitution)
DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE source_project STRING DEFAULT '${SOURCE_PROJECT}';
DECLARE min_price FLOAT64 DEFAULT 25.0;
DECLARE intent_start DATE DEFAULT DATE '2025-09-01';
DECLARE test_window_days INT64 DEFAULT 30;
-- Train cutoff must match export_edges.sql to prevent popularity feature leaking test-window data
DECLARE train_cutoff DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);

-- ==========================================
-- 1. User Nodes (~504K fitment users)
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.user_nodes` AS
WITH users_raw AS (
  SELECT
    LOWER(TRIM(a.string_value)) AS email_lower,
    MAX(CASE WHEN b.key = 'v1_make' THEN UPPER(TRIM(COALESCE(b.string_value, CAST(b.long_value AS STRING)))) END) AS v1_make,
    MAX(CASE WHEN b.key = 'v1_model' THEN UPPER(TRIM(COALESCE(b.string_value, CAST(b.long_value AS STRING)))) END) AS v1_model,
    MAX(CASE WHEN b.key = 'v1_year' THEN COALESCE(b.string_value, CAST(b.long_value AS STRING)) END) AS v1_year,
    MAX(CASE WHEN b.key = 'email_marketing_consent' THEN COALESCE(b.string_value, CAST(b.long_value AS STRING)) END) AS email_consent
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_attributes_schema_incremental` a,
    UNNEST(a.attributes) AS b
  WHERE a.key = 'email'
    AND a.string_value IS NOT NULL
    AND TRIM(a.string_value) != ''
  GROUP BY 1
)
SELECT
  email_lower,
  v1_make,
  v1_model,
  v1_year,
  CASE WHEN LOWER(email_consent) IN ('subscribed', 'true', '1') THEN TRUE ELSE FALSE END AS has_email_consent,
  -- Engagement tier computed in export_edges.sql after interaction edges are built
  'cold' AS engagement_tier
FROM users_raw
WHERE v1_year IS NOT NULL
  AND v1_make IS NOT NULL
  AND v1_model IS NOT NULL
  AND TRIM(v1_make) != ''
  AND TRIM(v1_model) != '';

-- ==========================================
-- 2. Product Nodes (~25K eligible products)
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.product_nodes` AS
WITH sku_prices AS (
  SELECT
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
    MIN(sku) AS canonical_sku,
    MAX(price) AS price
  FROM (
    SELECT
      ii.ExternalID AS sku,
      SAFE_CAST(ii.Price AS FLOAT64) AS price
    FROM `${SOURCE_PROJECT}.data_company_1950.import_items` ii
    WHERE ii.Price IS NOT NULL
      AND SAFE_CAST(ii.Price AS FLOAT64) >= min_price
  )
  GROUP BY 1
),
order_counts AS (
  SELECT
    REGEXP_REPLACE(ProductID, r'([0-9])[BRGP]$', r'\1') AS base_sku,
    COUNT(*) AS order_count
  FROM `${SOURCE_PROJECT}.data_company_1950.import_orders`
  WHERE SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(ORDER_DATE, 1, 10))
    BETWEEN intent_start AND train_cutoff
  GROUP BY 1
),
fitment_breadth AS (
  SELECT
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
    COUNT(DISTINCT CONCAT(make, '|', model)) AS fitment_breadth
  FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data`
  GROUP BY 1
),
excluded_skus AS (
  SELECT DISTINCT ExternalID AS sku
  FROM `${SOURCE_PROJECT}.data_company_1950.import_items_tags`
  WHERE LOWER(tags) LIKE '%refurbished%'
),
product_categories AS (
  SELECT
    ExternalID AS sku,
    PartType,
    CASE WHEN SAFE_CAST(UniversalPart AS INT64) = 1 THEN TRUE ELSE FALSE END AS is_universal
  FROM `${SOURCE_PROJECT}.data_company_1950.import_items`
)
SELECT
  sp.canonical_sku AS sku,
  sp.base_sku,
  pc.PartType AS part_type,
  sp.price,
  LOG(1 + COALESCE(oc.order_count, 0)) AS log_popularity,
  COALESCE(fb.fitment_breadth, 0) AS fitment_breadth,
  COALESCE(pc.is_universal, FALSE) AS is_universal
FROM sku_prices sp
LEFT JOIN order_counts oc ON sp.base_sku = oc.base_sku
LEFT JOIN fitment_breadth fb ON sp.base_sku = fb.base_sku
LEFT JOIN excluded_skus es ON sp.canonical_sku = es.sku
LEFT JOIN product_categories pc ON sp.canonical_sku = pc.sku
WHERE es.sku IS NULL  -- Exclude refurbished
  AND COALESCE(pc.PartType, '') NOT IN ('Service', 'Commodity');

-- ==========================================
-- 3. Vehicle Nodes (~2K unique make/model)
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` AS
WITH user_vehicles AS (
  SELECT v1_make, v1_model, COUNT(*) AS user_count
  FROM `${PROJECT_ID}.${GNN_DATASET}.user_nodes`
  GROUP BY 1, 2
),
fitment_products AS (
  SELECT
    UPPER(TRIM(make)) AS v_make,
    UPPER(TRIM(model)) AS v_model,
    COUNT(DISTINCT REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1')) AS product_count
  FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data`
  GROUP BY 1, 2
)
SELECT
  uv.v1_make AS make,
  uv.v1_model AS model,
  uv.user_count,
  COALESCE(fp.product_count, 0) AS product_count
FROM user_vehicles uv
LEFT JOIN fitment_products fp
  ON uv.v1_make = fp.v_make AND uv.v1_model = fp.v_model;
