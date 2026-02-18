-- ==================================================================================================
-- GNN Option A: Edge Export
-- Exports interaction, fitment, ownership, and co-purchase edges
-- See docs/plans/2026-02-16-gnn-option-a-design.md Section 3
-- ==================================================================================================

DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE source_project STRING DEFAULT '${SOURCE_PROJECT}';
DECLARE intent_start DATE DEFAULT DATE '2025-09-01';
DECLARE test_window_days INT64 DEFAULT 30;
DECLARE time_decay_halflife FLOAT64 DEFAULT 30.0;
DECLARE co_purchase_threshold INT64 DEFAULT 2;
DECLARE co_purchase_top_k INT64 DEFAULT 50;

-- Training cutoff: T-30 days
DECLARE train_cutoff DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);

-- ==========================================
-- 1. Interaction Edges (User -> Product)
--    Sep 1, 2025 to T-30, train-split users only
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.interaction_edges` AS
WITH events_raw AS (
  SELECT
    LOWER(TRIM(a.key_value)) AS email_lower,
    COALESCE(
      (
        SELECT COALESCE(p.string_value, CAST(p.long_value AS STRING))
        FROM UNNEST(a.properties) AS p
        WHERE p.key = 'ProductId'
        LIMIT 1
      ),
      (
        SELECT COALESCE(p.string_value, CAST(p.long_value AS STRING))
        FROM UNNEST(a.properties) AS p
        WHERE p.key = 'ProductID'
        LIMIT 1
      )
    ) AS sku,
    a.event_name,
    a.event_timestamp,
    DATE(a.event_timestamp) AS event_date
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_schema_incremental` a
  WHERE a.key_type = 'email'
    AND a.event_name IN ('Viewed Product', 'Added to Cart', 'Placed Order')
    AND DATE(a.event_timestamp) BETWEEN intent_start AND train_cutoff
),
events AS (
  SELECT DISTINCT
    email_lower,
    sku,
    event_name,
    event_timestamp,
    event_date
  FROM events_raw
  WHERE sku IS NOT NULL
)
SELECT
  e.email_lower,
  REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
  CASE
    WHEN e.event_name = 'Viewed Product' THEN 'view'
    WHEN e.event_name = 'Added to Cart' THEN 'cart'
    WHEN e.event_name = 'Placed Order' THEN 'order'
  END AS interaction_type,
  -- Time decay weight: base_weight * exp(-ln(2) * days / halflife)
  CASE
    WHEN e.event_name = 'Viewed Product' THEN 1.0
    WHEN e.event_name = 'Added to Cart' THEN 3.0
    WHEN e.event_name = 'Placed Order' THEN 5.0
  END * EXP(-LN(2) * DATE_DIFF(train_cutoff, e.event_date, DAY) / time_decay_halflife) AS weight
FROM events e
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u ON e.email_lower = u.email_lower
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
WHERE e.sku IS NOT NULL;

-- ==========================================
-- 2. Update user engagement tiers based on interactions
-- ==========================================
UPDATE `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u
SET engagement_tier = COALESCE(tiers.tier, 'cold')
FROM (
  SELECT
    email_lower,
    CASE
      WHEN SUM(CASE WHEN interaction_type IN ('cart', 'order') THEN 1 ELSE 0 END) > 0 THEN 'hot'
      WHEN COUNT(*) > 0 THEN 'warm'
      ELSE 'cold'
    END AS tier
  FROM `${PROJECT_ID}.${GNN_DATASET}.interaction_edges`
  GROUP BY 1
) tiers
WHERE u.email_lower = tiers.email_lower;

-- ==========================================
-- 3. Fitment Edges (Product -> Vehicle)
--    Full catalog, atemporal
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.fitment_edges` AS
SELECT DISTINCT
  REGEXP_REPLACE(f.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
  UPPER(TRIM(f.make)) AS make,
  UPPER(TRIM(f.model)) AS model
FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data` f
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p
  ON REGEXP_REPLACE(f.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` v
  ON UPPER(TRIM(f.make)) = v.make AND UPPER(TRIM(f.model)) = v.model;

-- ==========================================
-- 4. Ownership Edges (User -> Vehicle)
--    From user attributes, atemporal
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.ownership_edges` AS
SELECT DISTINCT
  u.email_lower,
  u.v1_make AS make,
  u.v1_model AS model
FROM `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` v
  ON u.v1_make = v.make AND u.v1_model = v.model;

-- ==========================================
-- 5. Co-purchase Edges (Product <-> Product)
--    Sep 1, 2025 to T-30, with PMI filter and top-K
-- ==========================================
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.copurchase_edges` AS
WITH order_items AS (
  SELECT
    CustomerID,
    OrderID,
    REGEXP_REPLACE(ProductID, r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM `${SOURCE_PROJECT}.data_company_1950.import_orders`
  WHERE SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(ORDER_DATE, 1, 10)) BETWEEN intent_start AND train_cutoff
),
-- Only keep products in our graph
valid_orders AS (
  SELECT oi.*
  FROM order_items oi
  INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON oi.base_sku = p.base_sku
),
-- Co-purchase pairs within same order
pairs AS (
  SELECT
    a.base_sku AS sku_a,
    b.base_sku AS sku_b,
    COUNT(DISTINCT a.OrderID) AS co_count
  FROM valid_orders a
  INNER JOIN valid_orders b
    ON a.OrderID = b.OrderID AND a.base_sku < b.base_sku
  GROUP BY 1, 2
  HAVING co_count >= co_purchase_threshold
),
-- Product frequencies for PMI
product_freq AS (
  SELECT base_sku, COUNT(DISTINCT OrderID) AS freq
  FROM valid_orders
  GROUP BY 1
),
total_orders AS (
  SELECT COUNT(DISTINCT OrderID) AS total FROM valid_orders
),
-- PMI-filtered pairs
pmi_pairs AS (
  SELECT
    p.sku_a,
    p.sku_b,
    p.co_count,
    LOG(
      (p.co_count * t.total * 1.0) /
      (fa.freq * fb.freq)
    ) AS pmi,
    LOG(1 + p.co_count) AS weight
  FROM pairs p
  CROSS JOIN total_orders t
  INNER JOIN product_freq fa ON p.sku_a = fa.base_sku
  INNER JOIN product_freq fb ON p.sku_b = fb.base_sku
),
-- Top-K per product (both directions)
ranked AS (
  SELECT
    sku_a, sku_b, co_count, pmi, weight,
    ROW_NUMBER() OVER (PARTITION BY sku_a ORDER BY weight DESC) AS rank_a,
    ROW_NUMBER() OVER (PARTITION BY sku_b ORDER BY weight DESC) AS rank_b
  FROM pmi_pairs
  WHERE pmi > 0  -- Only keep positive PMI (co-occur more than chance)
)
SELECT sku_a, sku_b, co_count, pmi, weight
FROM ranked
WHERE rank_a <= co_purchase_top_k OR rank_b <= co_purchase_top_k;
