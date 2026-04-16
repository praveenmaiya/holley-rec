-- ====================================================================================
-- V5.19 Go/No-Go Evaluation (Post-Run)
-- ------------------------------------------------------------------------------------
-- Purpose:
--   Release safety gate for no-YMM (non-fitment) recommendations. Confirms:
--   - Disjoint from v5.18 YMM output (no user gets both)
--   - Valid signal types, engagement tiers
--   - Policy compliance (price floor, diversity cap, images, purchase exclusion)
--   - Ranking quality (score ordering, no duplicates, contiguous slots)
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/validation/v5_19_go_no_go_eval.sql
--
-- Notes:
--   - Run AFTER v5.19 pipeline completes.
--   - Output is a severity-ranked checklist (CRITICAL/HIGH/MEDIUM/INFO).
-- ====================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_19';
DECLARE min_price FLOAT64 DEFAULT 25.0;
DECLARE purchase_window_days INT64 DEFAULT 365;
DECLARE min_final_users INT64 DEFAULT 150000;
DECLARE min_signal_users INT64 DEFAULT 150000;  -- spec target: ≥150K users with non-bestseller (signal-based) recs
DECLARE max_parttype_per_user INT64 DEFAULT 2;

DECLARE final_table STRING DEFAULT FORMAT('`%s.%s.final_non_fitment_recommendations`', target_project, target_dataset);
DECLARE ymm_table   STRING DEFAULT FORMAT('`%s.%s.ymm_users_for_exclusion`', target_project, target_dataset);
DECLARE hist_purch  STRING DEFAULT FORMAT('`%s.%s.hist_purchase_signals`', target_project, target_dataset);

-- -----------------------------------------------------------------------------
-- Base Tables
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE TEMP TABLE recs_wide AS
SELECT *
FROM %s
""", final_table);

CREATE TEMP TABLE recs_long AS
SELECT
  rw.email_lower,
  r.slot AS rec_slot,
  UPPER(r.sku) AS sku,
  REGEXP_REPLACE(UPPER(r.sku), r'([0-9])[BRGP]$', r'\1') AS sku_norm,
  r.price AS rec_price,
  r.score AS rec_score,
  r.rec_type,
  r.signal_age_days
FROM recs_wide rw
CROSS JOIN UNNEST([
  STRUCT(1 AS slot, rw.rec_part_1 AS sku, rw.rec1_price AS price, rw.rec1_score AS score, rw.rec1_type AS rec_type, rw.rec1_signal_age_days AS signal_age_days),
  STRUCT(2 AS slot, rw.rec_part_2 AS sku, rw.rec2_price AS price, rw.rec2_score AS score, rw.rec2_type AS rec_type, rw.rec2_signal_age_days AS signal_age_days),
  STRUCT(3 AS slot, rw.rec_part_3 AS sku, rw.rec3_price AS price, rw.rec3_score AS score, rw.rec3_type AS rec_type, rw.rec3_signal_age_days AS signal_age_days),
  STRUCT(4 AS slot, rw.rec_part_4 AS sku, rw.rec4_price AS price, rw.rec4_score AS score, rw.rec4_type AS rec_type, rw.rec4_signal_age_days AS signal_age_days)
]) r
WHERE r.sku IS NOT NULL;

CREATE TEMP TABLE sku_catalog AS
SELECT
  UPPER(TRIM(PartNumber)) AS sku,
  MAX(PartType) AS part_type,
  MAX(Tags) AS tags
FROM `auxia-gcp.data_company_1950.import_items`
WHERE PartNumber IS NOT NULL
GROUP BY sku;

-- Reconstruct 365d purchases for independent exclusion audit.
-- Two sources, UNION'd so one missing side doesn't mask a leak:
--   import-side: import_orders in last 365 days (authoritative historical + recent)
--   event-side : ingestion_unified_schema_incremental purchase events in last 365 days
-- Both normalized via the same variant regex the pipeline uses.
CREATE TEMP TABLE purchased_365d_import AS
SELECT DISTINCT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\1') AS sku_norm
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE ITEM IS NOT NULL
  AND NOT (
    ITEM LIKE 'EXT-%' OR ITEM LIKE 'GIFT-%' OR ITEM LIKE 'WARRANTY-%' OR
    ITEM LIKE 'SERVICE-%' OR ITEM LIKE 'PREAUTH-%'
  )
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL purchase_window_days DAY) AND CURRENT_DATE();

-- Build user_id → email_lower map from the user attribute table.
CREATE TEMP TABLE user_email_map AS
WITH attr_ranked AS (
  SELECT
    t.user_id,
    LOWER(p.property_name) AS property_name,
    LOWER(TRIM(p.string_value)) AS property_value,
    ROW_NUMBER() OVER (
      PARTITION BY t.user_id, LOWER(p.property_name)
      ORDER BY t.update_timestamp DESC, t.auxia_insertion_timestamp DESC
    ) AS rn
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` t,
       UNNEST(t.user_properties) AS p
  WHERE LOWER(p.property_name) = 'email'
)
SELECT DISTINCT user_id, property_value AS email_lower
FROM attr_ranked
WHERE rn = 1
  AND property_value IS NOT NULL
  AND property_value != '';

CREATE TEMP TABLE purchased_365d_events AS
SELECT DISTINCT
  em.email_lower,
  REGEXP_REPLACE(
    UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))),
    r'([0-9])[BRGP]$', r'\1'
  ) AS sku_norm
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t,
     UNNEST(t.event_properties) ep
JOIN user_email_map em USING (user_id)
WHERE DATE(t.client_event_timestamp) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL purchase_window_days DAY) AND CURRENT_DATE()
  AND UPPER(t.event_name) IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER')
  AND (
    (UPPER(t.event_name) = 'ORDERED PRODUCT' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$'))
    OR (UPPER(t.event_name) = 'PLACED ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$'))
    OR (UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$'))
  )
  AND COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)) IS NOT NULL;

CREATE TEMP TABLE purchased_365d_all AS
SELECT email_lower, sku_norm FROM purchased_365d_import
UNION DISTINCT
SELECT email_lower, sku_norm FROM purchased_365d_events;

-- -----------------------------------------------------------------------------
-- Go/No-Go Checks
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE go_no_go_checks (
  check_name STRING,
  severity STRING,
  metric_value STRING,
  threshold STRING,
  status STRING,
  notes STRING
);

-- CRITICAL: disjoint from v5.18 YMM universe (the defining invariant)
EXECUTE IMMEDIATE FORMAT("""
INSERT INTO go_no_go_checks
SELECT
  'ymm_user_overlap',
  'CRITICAL',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'v5.19 output must be disjoint from v5.18 YMM universe (no email in both)'
FROM %s f
JOIN %s y ON f.email_lower = y.email_lower
""", final_table, ymm_table);

-- CRITICAL: price floor
INSERT INTO go_no_go_checks
SELECT
  'price_floor_violations',
  'CRITICAL',
  CAST(COUNTIF(rec_price < min_price) AS STRING),
  FORMAT('0 (min price >= %.0f)', min_price),
  CASE WHEN COUNTIF(rec_price < min_price) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'All recommended prices must satisfy floor'
FROM recs_long;

-- CRITICAL: negative scores
INSERT INTO go_no_go_checks
SELECT
  'negative_scores',
  'CRITICAL',
  CAST(COUNTIF(rec_score < 0) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec_score < 0) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'All scores must be >= 0'
FROM recs_long;

-- CRITICAL: rec_type is in valid set
INSERT INTO go_no_go_checks
SELECT
  'rec_type_invalid_values',
  'CRITICAL',
  CAST(COUNTIF(rec_type NOT IN ('cart','view','purchase_recent','purchase_historical','bestseller')) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec_type NOT IN ('cart','view','purchase_recent','purchase_historical','bestseller')) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'rec_type must be one of: cart, view, purchase_recent, purchase_historical, bestseller'
FROM recs_long;

-- CRITICAL: engagement_tier is in valid set
INSERT INTO go_no_go_checks
SELECT
  'engagement_tier_invalid',
  'CRITICAL',
  CAST(
    COUNTIF(engagement_tier IS NULL) +
    COUNTIF(engagement_tier NOT IN ('hot','warm','cold','fallback'))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(engagement_tier IS NULL) +
    COUNTIF(engagement_tier NOT IN ('hot','warm','cold','fallback'))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'engagement_tier must be hot/warm/cold/fallback — no NULLs, no other values'
FROM recs_wide;

-- CRITICAL: dominant_signal is valid and matches rec1_type
INSERT INTO go_no_go_checks
SELECT
  'dominant_signal_mismatch',
  'CRITICAL',
  CAST(COUNTIF(
    dominant_signal IS NULL OR
    dominant_signal != rec1_type OR
    dominant_signal NOT IN ('cart','view','purchase_recent','purchase_historical','bestseller')
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    dominant_signal IS NULL OR
    dominant_signal != rec1_type OR
    dominant_signal NOT IN ('cart','view','purchase_recent','purchase_historical','bestseller')
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'dominant_signal must equal rec1_type and be a valid signal'
FROM recs_wide;

-- HIGH: purchase exclusion (dual-source: import_orders ∪ event purchases)
INSERT INTO go_no_go_checks
SELECT
  'purchase_exclusion_violations',
  'HIGH',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No recommended SKU should appear in last-365-day purchases (import_orders OR purchase events) for same email'
FROM recs_long r
JOIN purchased_365d_all p
  ON r.email_lower = p.email_lower
 AND r.sku_norm = p.sku_norm;

-- HIGH: duplicate SKUs per user row
INSERT INTO go_no_go_checks
SELECT
  'duplicate_skus_per_user',
  'HIGH',
  CAST(COUNTIF(
    (rec_part_2 IS NOT NULL AND rec_part_1 = rec_part_2) OR
    (rec_part_3 IS NOT NULL AND (rec_part_1 = rec_part_3 OR rec_part_2 = rec_part_3)) OR
    (rec_part_4 IS NOT NULL AND (rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4))
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    (rec_part_2 IS NOT NULL AND rec_part_1 = rec_part_2) OR
    (rec_part_3 IS NOT NULL AND (rec_part_1 = rec_part_3 OR rec_part_2 = rec_part_3)) OR
    (rec_part_4 IS NOT NULL AND (rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4))
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No duplicate SKUs per user row'
FROM recs_wide;

-- HIGH: diversity cap (PartType)
INSERT INTO go_no_go_checks
WITH parttype_counts AS (
  SELECT
    email_lower,
    COALESCE(c.part_type, 'UNKNOWN') AS part_type,
    COUNT(*) AS n
  FROM recs_long r
  LEFT JOIN sku_catalog c ON r.sku = c.sku
  GROUP BY email_lower, part_type
)
SELECT
  'diversity_cap_violations',
  'HIGH',
  CAST(COUNTIF(n > max_parttype_per_user) AS STRING),
  FORMAT('0 (max %d per PartType)', max_parttype_per_user),
  CASE WHEN COUNTIF(n > max_parttype_per_user) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No user should have more than max_parttype_per_user recs in same PartType'
FROM parttype_counts;

-- CRITICAL: score ordering (monotonic non-increasing across slots)
INSERT INTO go_no_go_checks
SELECT
  'score_ordering_violations',
  'CRITICAL',
  CAST(COUNTIF(NOT (
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) AS STRING),
  '0',
  CASE WHEN COUNTIF(NOT (
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'rec1_score >= rec2_score >= rec3_score >= rec4_score'
FROM recs_wide;

-- CRITICAL: contiguous slots (no NULL gaps before a filled slot)
INSERT INTO go_no_go_checks
SELECT
  'null_slot_gaps',
  'CRITICAL',
  CAST(COUNTIF(
    (rec_part_1 IS NULL AND rec_part_2 IS NOT NULL) OR
    (rec_part_2 IS NULL AND rec_part_3 IS NOT NULL) OR
    (rec_part_3 IS NULL AND rec_part_4 IS NOT NULL)
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    (rec_part_1 IS NULL AND rec_part_2 IS NOT NULL) OR
    (rec_part_2 IS NULL AND rec_part_3 IS NOT NULL) OR
    (rec_part_3 IS NULL AND rec_part_4 IS NOT NULL)
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Slots must be contiguous from slot 1 (no NULL gaps before filled slots)'
FROM recs_wide;

-- CRITICAL: rec_count matches actual filled slots
INSERT INTO go_no_go_checks
SELECT
  'rec_count_slot_mismatch',
  'CRITICAL',
  CAST(COUNTIF(
    rec_count != (
      IF(rec_part_1 IS NOT NULL, 1, 0) +
      IF(rec_part_2 IS NOT NULL, 1, 0) +
      IF(rec_part_3 IS NOT NULL, 1, 0) +
      IF(rec_part_4 IS NOT NULL, 1, 0)
    )
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    rec_count != (
      IF(rec_part_1 IS NOT NULL, 1, 0) +
      IF(rec_part_2 IS NOT NULL, 1, 0) +
      IF(rec_part_3 IS NOT NULL, 1, 0) +
      IF(rec_part_4 IS NOT NULL, 1, 0)
    )
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'rec_count must equal number of filled rec_part_* slots'
FROM recs_wide;

-- CRITICAL: every filled slot has HTTPS image
INSERT INTO go_no_go_checks
SELECT
  'null_or_non_https_images',
  'CRITICAL',
  CAST(
    COUNTIF(rec_part_1 IS NOT NULL AND (rec1_image IS NULL OR NOT STARTS_WITH(rec1_image, 'https://'))) +
    COUNTIF(rec_part_2 IS NOT NULL AND (rec2_image IS NULL OR NOT STARTS_WITH(rec2_image, 'https://'))) +
    COUNTIF(rec_part_3 IS NOT NULL AND (rec3_image IS NULL OR NOT STARTS_WITH(rec3_image, 'https://'))) +
    COUNTIF(rec_part_4 IS NOT NULL AND (rec4_image IS NULL OR NOT STARTS_WITH(rec4_image, 'https://')))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec_part_1 IS NOT NULL AND (rec1_image IS NULL OR NOT STARTS_WITH(rec1_image, 'https://'))) +
    COUNTIF(rec_part_2 IS NOT NULL AND (rec2_image IS NULL OR NOT STARTS_WITH(rec2_image, 'https://'))) +
    COUNTIF(rec_part_3 IS NOT NULL AND (rec3_image IS NULL OR NOT STARTS_WITH(rec3_image, 'https://'))) +
    COUNTIF(rec_part_4 IS NOT NULL AND (rec4_image IS NULL OR NOT STARTS_WITH(rec4_image, 'https://')))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Every filled rec slot must have an https:// image URL'
FROM recs_wide;

-- HIGH: refurbished check
INSERT INTO go_no_go_checks
SELECT
  'refurbished_products_in_output',
  'HIGH',
  CAST(COUNTIF(LOWER(COALESCE(c.tags, '')) LIKE '%refurbished%') AS STRING),
  '0',
  CASE WHEN COUNTIF(LOWER(COALESCE(c.tags, '')) LIKE '%refurbished%') = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No refurbished products should appear in output'
FROM recs_long r
LEFT JOIN sku_catalog c ON r.sku = c.sku;

-- HIGH: slot consistency (NULL rec_part means all rec*_* fields NULL)
INSERT INTO go_no_go_checks
SELECT
  'slot_consistency_violations',
  'HIGH',
  CAST(
    COUNTIF(rec_part_2 IS NULL AND (rec2_price IS NOT NULL OR rec2_score IS NOT NULL OR rec2_image IS NOT NULL OR rec2_type IS NOT NULL)) +
    COUNTIF(rec_part_3 IS NULL AND (rec3_price IS NOT NULL OR rec3_score IS NOT NULL OR rec3_image IS NOT NULL OR rec3_type IS NOT NULL)) +
    COUNTIF(rec_part_4 IS NULL AND (rec4_price IS NOT NULL OR rec4_score IS NOT NULL OR rec4_image IS NOT NULL OR rec4_type IS NOT NULL))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec_part_2 IS NULL AND (rec2_price IS NOT NULL OR rec2_score IS NOT NULL OR rec2_image IS NOT NULL OR rec2_type IS NOT NULL)) +
    COUNTIF(rec_part_3 IS NULL AND (rec3_price IS NOT NULL OR rec3_score IS NOT NULL OR rec3_image IS NOT NULL OR rec3_type IS NOT NULL)) +
    COUNTIF(rec_part_4 IS NULL AND (rec4_price IS NOT NULL OR rec4_score IS NOT NULL OR rec4_image IS NOT NULL OR rec4_type IS NOT NULL))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'If rec_part_N is NULL, all rec*N_* fields must also be NULL'
FROM recs_wide;

-- HIGH: bestseller signal_age_days should be NULL (no decay applied)
INSERT INTO go_no_go_checks
SELECT
  'bestseller_signal_age_non_null',
  'MEDIUM',
  CAST(COUNTIF(rec_type = 'bestseller' AND signal_age_days > 0) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec_type = 'bestseller' AND signal_age_days > 0) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'bestseller recs have no decay — signal_age_days should be 0 or NULL'
FROM recs_long;

-- CRITICAL: final user count
INSERT INTO go_no_go_checks
SELECT
  'final_user_count',
  'CRITICAL',
  CAST(COUNT(*) AS STRING),
  FORMAT('>= %d', min_final_users),
  CASE WHEN COUNT(*) >= min_final_users THEN 'PASS' ELSE 'FAIL' END,
  'Final output row count gate'
FROM recs_wide;

-- CRITICAL: signal-based coverage — users with >=1 non-bestseller rec
-- Guards against a run silently regressing to mostly-fallback output while passing
-- final_user_count via bestsellers.
INSERT INTO go_no_go_checks
SELECT
  'signal_based_user_count',
  'CRITICAL',
  CAST(COUNTIF(
    COALESCE(rec1_type, '') != 'bestseller' OR
    COALESCE(rec2_type, '') != 'bestseller' OR
    COALESCE(rec3_type, '') != 'bestseller' OR
    COALESCE(rec4_type, '') != 'bestseller'
  ) AS STRING),
  FORMAT('>= %d', min_signal_users),
  CASE WHEN COUNTIF(
    COALESCE(rec1_type, '') != 'bestseller' OR
    COALESCE(rec2_type, '') != 'bestseller' OR
    COALESCE(rec3_type, '') != 'bestseller' OR
    COALESCE(rec4_type, '') != 'bestseller'
  ) >= min_signal_users THEN 'PASS' ELSE 'FAIL' END,
  'Users with at least one non-bestseller (signal-driven) rec — guards against fallback-dominated runs'
FROM recs_wide;

-- INFO: engagement tier share
INSERT INTO go_no_go_checks
SELECT
  'engagement_tier_hot_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(engagement_tier = 'hot'), COUNT(*)) * 100.0),
  'monitor trend',
  'INFO',
  'Percentage of users in hot tier (cart/view in last 7 days)'
FROM recs_wide;

INSERT INTO go_no_go_checks
SELECT
  'engagement_tier_fallback_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(engagement_tier = 'fallback'), COUNT(*)) * 100.0),
  'monitor trend',
  'INFO',
  'Percentage of users in fallback tier (bestseller-only)'
FROM recs_wide;

-- INFO: users with 4 recs pct
INSERT INTO go_no_go_checks
SELECT
  'users_with_4_recs_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(rec_count = 4), COUNT(*)) * 100.0),
  'monitor trend',
  'INFO',
  'Percentage of users receiving full 4 slots'
FROM recs_wide;

-- -----------------------------------------------------------------------------
-- Final Go/No-Go Dashboard
-- -----------------------------------------------------------------------------
SELECT
  check_name,
  severity,
  metric_value,
  threshold,
  status,
  notes
FROM go_no_go_checks
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'INFO' THEN 4
    ELSE 5
  END,
  check_name;

-- -----------------------------------------------------------------------------
-- Investigation Aids (only emitted if any FAIL is present)
-- -----------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM go_no_go_checks WHERE status = 'FAIL') THEN
  -- Sample of failing rows for each common violation type
  SELECT
    r.email_lower,
    r.rec_slot,
    r.sku,
    r.rec_price,
    r.rec_score,
    r.rec_type,
    r.signal_age_days
  FROM recs_long r
  WHERE r.rec_price < min_price
     OR r.rec_type NOT IN ('cart','view','purchase_recent','purchase_historical','bestseller')
  ORDER BY r.email_lower, r.rec_slot
  LIMIT 200;
ELSE
  SELECT '[SKIP] Investigation aids not emitted because no FAIL checks were found.' AS log;
END IF;
