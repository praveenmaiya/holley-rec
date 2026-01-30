-- ==================================================================================================
-- GNN Test Set Export — Holdout Clicks for Offline Evaluation
-- --------------------------------------------------------------------------------------------------
-- Last 30 days of treatment clicks as ground truth for evaluating GNN recommendations.
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/gnn/export_test_set.sql
-- ==================================================================================================

DECLARE test_window_days INT64 DEFAULT 30;
DECLARE test_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);
DECLARE test_end DATE DEFAULT CURRENT_DATE();

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_gnn.test_clicks` AS
SELECT DISTINCT
  ti.user_id,
  COALESCE(ti.treatment_content_item_id, ti.treatment_content_id) AS sku,
  DATE(ti.event_timestamp) AS click_date,
FROM `auxia-gcp.company_1950.treatment_interaction` ti
WHERE ti.interaction_type = 'CLICKED'
  AND DATE(ti.event_timestamp) BETWEEN test_start AND test_end
  AND ti.user_id IS NOT NULL
  AND COALESCE(ti.treatment_content_item_id, ti.treatment_content_id) IS NOT NULL
-- Only keep users/products in our graph
INNER JOIN `auxia-reporting.temp_holley_gnn.user_nodes` u ON ti.user_id = u.user_id
INNER JOIN `auxia-reporting.temp_holley_gnn.product_nodes` p
  ON COALESCE(ti.treatment_content_item_id, ti.treatment_content_id) = p.sku;
