-- ==================================================================================================
-- GNN Option A: SQL Baseline Export
-- Reshape Phase-1-fixed SQL recommendations to long format for comparison
-- See docs/plans/2026-02-16-gnn-option-a-design.md Section 5
-- ==================================================================================================

DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE baseline_table STRING DEFAULT '${BASELINE_TABLE}';
DECLARE min_price FLOAT64 DEFAULT 25.0;

-- Export current SQL recommendations in long format
-- Note: Must be re-run against Phase-1-fixed SQL baseline with $25 price floor
-- IMPORTANT: baseline_table should be snapshotted at training time to avoid drift
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.sql_baseline` AS
WITH wide_recs AS (
  SELECT
    email_lower,
    rec1_sku, rec1_price,
    rec2_sku, rec2_price,
    rec3_sku, rec3_price,
    rec4_sku, rec4_price
  FROM `${BASELINE_TABLE}`
)
SELECT email_lower, sku, rank
FROM (
  SELECT email_lower, rec1_sku AS sku, 1 AS rank, rec1_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec2_sku AS sku, 2 AS rank, rec2_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec3_sku AS sku, 3 AS rank, rec3_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec4_sku AS sku, 4 AS rank, rec4_price AS price FROM wide_recs
)
WHERE sku IS NOT NULL
  AND price >= min_price
ORDER BY email_lower, rank;
