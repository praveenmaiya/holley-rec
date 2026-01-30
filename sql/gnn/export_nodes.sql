-- ==================================================================================================
-- GNN Node Export — User, Product, and Vehicle Nodes
-- --------------------------------------------------------------------------------------------------
-- Exports node tables to auxia-reporting.temp_holley_gnn for GNN training.
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/gnn/export_nodes.sql
-- ==================================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_gnn';

-- Intent window (same as v5.7)
DECLARE intent_window_start DATE DEFAULT DATE '2025-09-01';
DECLARE intent_window_end DATE DEFAULT CURRENT_DATE();

-- ====================================================================================
-- USER NODES (~475K)
-- ------------------------------------------------------------------------------------
-- Attributes: user_id, v1_year, v1_make, v1_model, engagement_tier
-- engagement_tier: cold (no events), warm (views only), hot (cart/order)
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.user_nodes` AS
WITH user_attributes AS (
  SELECT
    user_id,
    MAX(CASE WHEN up.key = 'v1_year' THEN COALESCE(up.value.string_value, CAST(up.value.long_value AS STRING)) END) AS v1_year,
    MAX(CASE WHEN up.key = 'v1_make' THEN COALESCE(up.value.string_value, CAST(up.value.long_value AS STRING)) END) AS v1_make,
    MAX(CASE WHEN up.key = 'v1_model' THEN COALESCE(up.value.string_value, CAST(up.value.long_value AS STRING)) END) AS v1_model,
    MAX(CASE WHEN up.key = 'email' THEN COALESCE(up.value.string_value, CAST(up.value.long_value AS STRING)) END) AS email,
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
    UNNEST(user_properties) AS up
  WHERE up.key IN ('v1_year', 'v1_make', 'v1_model', 'email')
  GROUP BY user_id
),
users_with_vehicles AS (
  SELECT *
  FROM user_attributes
  WHERE email IS NOT NULL
    AND v1_year IS NOT NULL
    AND v1_make IS NOT NULL
    AND v1_model IS NOT NULL
),
-- Compute engagement tier from recent events
user_engagement AS (
  SELECT
    user_id,
    COUNTIF(event_name IN ('add_to_cart', 'purchase')) AS cart_order_count,
    COUNTIF(event_name = 'view_item') AS view_count,
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE DATE(event_timestamp) BETWEEN intent_window_start AND intent_window_end
    AND event_name IN ('view_item', 'add_to_cart', 'purchase')
  GROUP BY user_id
)
SELECT
  u.user_id,
  u.v1_year,
  u.v1_make,
  u.v1_model,
  CASE
    WHEN e.cart_order_count > 0 THEN 'hot'
    WHEN e.view_count > 0 THEN 'warm'
    ELSE 'cold'
  END AS engagement_tier,
FROM users_with_vehicles u
LEFT JOIN user_engagement e ON u.user_id = e.user_id;


-- ====================================================================================
-- PRODUCT NODES (~25K)
-- ------------------------------------------------------------------------------------
-- Attributes: sku, part_type, price, log_popularity, fitment_breadth
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.product_nodes` AS
WITH sku_prices AS (
  SELECT
    SKU_Number AS sku,
    SAFE_CAST(Regular_Price AS FLOAT64) AS price,
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE SKU_Number IS NOT NULL
    AND SAFE_CAST(Regular_Price AS FLOAT64) >= 50.0
),
sku_part_types AS (
  SELECT DISTINCT
    SKU_Number AS sku,
    PartType AS part_type,
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE SKU_Number IS NOT NULL
    AND PartType IS NOT NULL
),
-- Popularity: order count from import_orders
sku_popularity AS (
  SELECT
    ProductID AS sku,
    COUNT(*) AS order_count,
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ProductID IS NOT NULL
  GROUP BY ProductID
),
-- Fitment breadth: how many distinct vehicles this SKU fits
fitment_breadth AS (
  SELECT
    sku,
    COUNT(DISTINCT CONCAT(make, '/', model)) AS fitment_breadth,
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`
  WHERE sku IS NOT NULL
  GROUP BY sku
)
SELECT
  p.sku,
  pt.part_type,
  p.price,
  LOG(1 + COALESCE(pop.order_count, 0)) AS log_popularity,
  COALESCE(fb.fitment_breadth, 0) AS fitment_breadth,
FROM sku_prices p
LEFT JOIN sku_part_types pt ON p.sku = pt.sku
LEFT JOIN sku_popularity pop ON p.sku = pop.sku
LEFT JOIN fitment_breadth fb ON p.sku = fb.sku;


-- ====================================================================================
-- VEHICLE NODES (~2K)
-- ------------------------------------------------------------------------------------
-- Attributes: vehicle_id (make/model), user_count, product_count
-- ====================================================================================

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.vehicle_nodes` AS
WITH vehicle_users AS (
  SELECT
    CONCAT(v1_make, '/', v1_model) AS vehicle_id,
    COUNT(DISTINCT user_id) AS user_count,
  FROM `auxia-reporting.temp_holley_gnn.user_nodes`
  GROUP BY vehicle_id
),
vehicle_products AS (
  SELECT
    CONCAT(make, '/', model) AS vehicle_id,
    COUNT(DISTINCT sku) AS product_count,
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`
  GROUP BY vehicle_id
)
SELECT
  COALESCE(vu.vehicle_id, vp.vehicle_id) AS vehicle_id,
  COALESCE(vu.user_count, 0) AS user_count,
  COALESCE(vp.product_count, 0) AS product_count,
FROM vehicle_users vu
FULL OUTER JOIN vehicle_products vp ON vu.vehicle_id = vp.vehicle_id;
