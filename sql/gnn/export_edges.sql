-- ==================================================================================================
-- GNN Edge Export — 4 Edge Types with Weights
-- --------------------------------------------------------------------------------------------------
-- Exports edge tables to auxia-reporting.temp_holley_gnn for GNN training.
-- Depends on: export_nodes.sql (must run first for node tables)
--
-- Edge types:
--   1. user → product (interaction: view/cart/order, time-decayed)
--   2. product → vehicle (fitment, binary)
--   3. user → vehicle (ownership, binary)
--   4. product → product (co-purchase, log-weighted, threshold ≥2)
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/gnn/export_edges.sql
-- ==================================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_gnn';

DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';
DECLARE intent_window_end DATE DEFAULT CURRENT_DATE();

-- Time decay half-life in days
DECLARE decay_halflife FLOAT64 DEFAULT 30.0;


-- ====================================================================================
-- EDGE TYPE 1: USER → PRODUCT (interaction edges, time-decayed)
-- ------------------------------------------------------------------------------------
-- Weight = base_weight * EXP(-days_since / decay_halflife)
-- base_weight: view=1, cart=3, order=5
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.edges_user_product` AS
WITH raw_events AS (
  SELECT
    e.user_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key = 'ProductId'),
      (SELECT CAST(ep.value.long_value AS STRING) FROM UNNEST(e.event_params) ep WHERE ep.key = 'ProductId'),
      (SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key = 'ProductID'),
      (SELECT CAST(ep.value.long_value AS STRING) FROM UNNEST(e.event_params) ep WHERE ep.key = 'ProductID')
    ) AS sku,
    e.event_name,
    DATE(e.event_timestamp) AS event_date,
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e
  WHERE DATE(e.event_timestamp) BETWEEN intent_window_start AND intent_window_end
    AND e.event_name IN ('view_item', 'add_to_cart', 'purchase')
),
weighted_events AS (
  SELECT
    r.user_id,
    r.sku,
    r.event_name,
    CASE r.event_name
      WHEN 'view_item' THEN 1.0
      WHEN 'add_to_cart' THEN 3.0
      WHEN 'purchase' THEN 5.0
    END AS base_weight,
    DATE_DIFF(intent_window_end, r.event_date, DAY) AS days_since,
  FROM raw_events r
  WHERE r.sku IS NOT NULL
),
-- Aggregate per user-product pair: sum of time-decayed weights
aggregated AS (
  SELECT
    user_id,
    sku,
    SUM(base_weight * EXP(-CAST(days_since AS FLOAT64) / decay_halflife)) AS weight,
    MAX(base_weight) AS max_interaction_type,
    COUNT(*) AS interaction_count,
  FROM weighted_events
  GROUP BY user_id, sku
)
SELECT
  a.user_id,
  a.sku,
  a.weight,
  a.max_interaction_type,
  a.interaction_count,
FROM aggregated a
-- Only keep edges where both nodes exist
INNER JOIN `auxia-reporting.temp_holley_gnn.user_nodes` u ON a.user_id = u.user_id
INNER JOIN `auxia-reporting.temp_holley_gnn.product_nodes` p ON a.sku = p.sku;


-- ====================================================================================
-- EDGE TYPE 2: PRODUCT → VEHICLE (fitment, binary)
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.edges_product_vehicle` AS
SELECT DISTINCT
  f.sku,
  CONCAT(f.make, '/', f.model) AS vehicle_id,
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` f
INNER JOIN `auxia-reporting.temp_holley_gnn.product_nodes` p ON f.sku = p.sku
INNER JOIN `auxia-reporting.temp_holley_gnn.vehicle_nodes` v ON CONCAT(f.make, '/', f.model) = v.vehicle_id;


-- ====================================================================================
-- EDGE TYPE 3: USER → VEHICLE (ownership, binary)
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.edges_user_vehicle` AS
SELECT DISTINCT
  u.user_id,
  CONCAT(u.v1_make, '/', u.v1_model) AS vehicle_id,
FROM `auxia-reporting.temp_holley_gnn.user_nodes` u
INNER JOIN `auxia-reporting.temp_holley_gnn.vehicle_nodes` v ON CONCAT(u.v1_make, '/', u.v1_model) = v.vehicle_id;


-- ====================================================================================
-- EDGE TYPE 4: PRODUCT → PRODUCT (co-purchase, threshold ≥2)
-- ------------------------------------------------------------------------------------
-- Self-join on import_orders: same order → co-purchase pair
-- Weight = LOG(1 + co_purchase_count)
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.edges_product_product` AS
WITH order_items AS (
  SELECT
    OrderID,
    ProductID AS sku,
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ProductID IS NOT NULL
    AND OrderID IS NOT NULL
),
co_purchases AS (
  SELECT
    a.sku AS sku_a,
    b.sku AS sku_b,
    COUNT(DISTINCT a.OrderID) AS co_purchase_count,
  FROM order_items a
  INNER JOIN order_items b ON a.OrderID = b.OrderID AND a.sku < b.sku
  GROUP BY a.sku, b.sku
  HAVING co_purchase_count >= 2
)
SELECT
  c.sku_a,
  c.sku_b,
  LOG(1 + c.co_purchase_count) AS weight,
  c.co_purchase_count,
FROM co_purchases c
INNER JOIN `auxia-reporting.temp_holley_gnn.product_nodes` pa ON c.sku_a = pa.sku
INNER JOIN `auxia-reporting.temp_holley_gnn.product_nodes` pb ON c.sku_b = pb.sku;
