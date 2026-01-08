-- Investigation Part 4: Are December buyers NEW users not in VFU set at cutoff?
-- Check when buyers got their vehicle data

-- VFU users at Nov 15 cutoff
CREATE TEMP TABLE vfu_at_nov15 AS
SELECT DISTINCT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name = "v1_year"
  AND p.string_value IS NOT NULL
  AND auxia_insertion_timestamp <= TIMESTAMP("2025-11-15 23:59:59");

-- VFU users at Dec 15 cutoff
CREATE TEMP TABLE vfu_at_dec15 AS
SELECT DISTINCT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name = "v1_year"
  AND p.string_value IS NOT NULL
  AND auxia_insertion_timestamp <= TIMESTAMP("2025-12-15 23:59:59");

-- All current VFU users
CREATE TEMP TABLE vfu_current AS
SELECT DISTINCT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name = "v1_year" AND p.string_value IS NOT NULL;

-- November buyers (Nov 16 - Dec 5)
CREATE TEMP TABLE nov_buyers AS
SELECT DISTINCT e.user_id
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE DATE(e.client_event_timestamp) BETWEEN DATE("2025-11-16") AND DATE("2025-12-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- December buyers (Dec 16 - Jan 5)
CREATE TEMP TABLE dec_buyers AS
SELECT DISTINCT e.user_id
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE DATE(e.client_event_timestamp) BETWEEN DATE("2025-12-16") AND DATE("2026-01-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- Compare VFU coverage at cutoff time
SELECT
  "November Buyers" as period,
  COUNT(DISTINCT nb.user_id) as total_buyers,
  COUNT(DISTINCT CASE WHEN v15.user_id IS NOT NULL THEN nb.user_id END) as vfu_at_cutoff,
  COUNT(DISTINCT CASE WHEN vc.user_id IS NOT NULL THEN nb.user_id END) as vfu_now,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN v15.user_id IS NOT NULL THEN nb.user_id END) / COUNT(DISTINCT nb.user_id), 1) as pct_vfu_at_cutoff,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN vc.user_id IS NOT NULL THEN nb.user_id END) / COUNT(DISTINCT nb.user_id), 1) as pct_vfu_now
FROM nov_buyers nb
LEFT JOIN vfu_at_nov15 v15 ON nb.user_id = v15.user_id
LEFT JOIN vfu_current vc ON nb.user_id = vc.user_id

UNION ALL

SELECT
  "December Buyers" as period,
  COUNT(DISTINCT db.user_id) as total_buyers,
  COUNT(DISTINCT CASE WHEN v15.user_id IS NOT NULL THEN db.user_id END) as vfu_at_cutoff,
  COUNT(DISTINCT CASE WHEN vc.user_id IS NOT NULL THEN db.user_id END) as vfu_now,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN v15.user_id IS NOT NULL THEN db.user_id END) / COUNT(DISTINCT db.user_id), 1) as pct_vfu_at_cutoff,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN vc.user_id IS NOT NULL THEN db.user_id END) / COUNT(DISTINCT db.user_id), 1) as pct_vfu_now
FROM dec_buyers db
LEFT JOIN vfu_at_dec15 v15 ON db.user_id = v15.user_id
LEFT JOIN vfu_current vc ON db.user_id = vc.user_id

ORDER BY period;
