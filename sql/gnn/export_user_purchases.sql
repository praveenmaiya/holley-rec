-- ==================================================================================================
-- GNN Option A: User Purchase History Export (365-day lookback)
-- For purchase exclusion: recently bought products should not be re-recommended
-- See docs/plans/2026-02-16-gnn-option-a-design.md Section 6
-- ==================================================================================================

DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE source_project STRING DEFAULT '${SOURCE_PROJECT}';
DECLARE purchase_lookback_days INT64 DEFAULT 365;

DECLARE purchase_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL purchase_lookback_days DAY);

CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.user_purchases` AS
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
    ) AS sku
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_schema_incremental` a
  WHERE a.key_type = 'email'
    AND a.event_name = 'Placed Order'
    AND DATE(a.event_timestamp) >= purchase_start
)
SELECT DISTINCT
  e.email_lower,
  REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku
FROM events_raw e
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u ON e.email_lower = u.email_lower
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p
  ON REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
WHERE e.sku IS NOT NULL;
