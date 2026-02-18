-- ==================================================================================================
-- GNN Option A: Test Set Export
-- Last 30 days of interactions for val/test split users
-- See docs/plans/2026-02-16-gnn-option-a-design.md Section 5
-- ==================================================================================================

DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE source_project STRING DEFAULT '${SOURCE_PROJECT}';
DECLARE test_window_days INT64 DEFAULT 30;

-- Test starts AFTER train cutoff to prevent 1-day overlap (train uses <= cutoff, test uses > cutoff)
DECLARE test_start DATE DEFAULT DATE_ADD(DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY), INTERVAL 1 DAY);
DECLARE test_end DATE DEFAULT CURRENT_DATE();

CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.test_interactions` AS
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
    a.event_timestamp
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_schema_incremental` a
  WHERE a.key_type = 'email'
    AND a.event_name IN ('Viewed Product', 'Added to Cart', 'Placed Order')
    AND DATE(a.event_timestamp) BETWEEN test_start AND test_end
),
events AS (
  SELECT DISTINCT
    email_lower,
    sku,
    event_name,
    event_timestamp
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
  e.event_timestamp
FROM events e
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u ON e.email_lower = u.email_lower
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p
  ON REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
WHERE e.sku IS NOT NULL;
