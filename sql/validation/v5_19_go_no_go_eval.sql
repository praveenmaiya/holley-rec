-- ====================================================================================
-- V5.19 Go/No-Go Evaluation (Post-Run) — Shared Fitment + Non-Fitment Table
-- ------------------------------------------------------------------------------------
-- Purpose:
--   Release safety gate for the V5.19 shared-table release. Validates:
--   - Shared-table invariants (single pipeline_version, disjoint audiences,
--     cross-slot rec*_type consistency, allowed rec*_type vocabulary,
--     non-fitment YMM='UNKNOWN' placeholder)
--   - Policy compliance (price floor, diversity cap, HTTPS images, no refurb/services,
--     purchase exclusion — fitment=365d / non-fitment=lifetime)
--   - Ranking quality (score ordering, no NULL gaps, slot consistency, no duplicates)
--   - V5.18 fitment invariants scoped to rec1_type='fitment'
--     (engagement_tier ∈ {hot,cold}, fitment_count ∈ {3,4}, YMM×SKU authoritative match)
--   - Non-fitment invariants scoped to rec1_type='non_fitment'
--     (engagement_tier IS NULL, fitment_count IS NULL, YMM='UNKNOWN')
--   - Coverage gates per audience
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/validation/v5_19_go_no_go_eval.sql
--
-- Notes:
--   - Run AFTER v5.19 pipeline completes (produces final_vehicle_recommendations).
--   - Output is a severity-ranked checklist (CRITICAL/HIGH/MEDIUM/INFO).
-- ====================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_19';
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE fitment_purchase_window_days INT64 DEFAULT 365;  -- v5.18 uses 365d exclusion
DECLARE min_final_users INT64 DEFAULT 150000;            -- non-fitment coverage floor
DECLARE min_fitment_users INT64 DEFAULT 400000;          -- fitment coverage floor (v5.18 target)
DECLARE max_parttype_per_user INT64 DEFAULT 2;
DECLARE w_bestseller FLOAT64 DEFAULT 1.0;                -- mirrors pipeline; pure-bestseller rows have rec1_score ≈ 1.0

DECLARE final_table STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);
DECLARE ymm_table   STRING DEFAULT FORMAT('`%s.%s.ymm_users_for_exclusion`', target_project, target_dataset);

-- -----------------------------------------------------------------------------
-- Base Tables
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE TEMP TABLE recs_wide AS
SELECT *
FROM %s
""", final_table);

-- Unpivoted per-slot view. `row_audience` (= rec1_type) identifies which audience
-- a row belongs to — every populated rec*_type in a row equals rec1_type (see
-- cross_slot_type_consistency check).
CREATE TEMP TABLE recs_long AS
SELECT
  rw.email_lower,
  rw.v1_year,
  rw.v1_make,
  rw.v1_model,
  rw.rec1_type AS row_audience,
  r.slot AS rec_slot,
  UPPER(r.sku) AS sku,
  REGEXP_REPLACE(
    REGEXP_REPLACE(UPPER(r.sku), r'([0-9])[BRGP]$', r'\1'),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm,
  r.price AS rec_price,
  r.score AS rec_score,
  r.rec_type,
  r.image AS rec_image
FROM recs_wide rw
CROSS JOIN UNNEST([
  STRUCT(1 AS slot, rw.rec_part_1 AS sku, rw.rec1_price AS price, rw.rec1_score AS score, rw.rec1_type AS rec_type, rw.rec1_image AS image),
  STRUCT(2 AS slot, rw.rec_part_2 AS sku, rw.rec2_price AS price, rw.rec2_score AS score, rw.rec2_type AS rec_type, rw.rec2_image AS image),
  STRUCT(3 AS slot, rw.rec_part_3 AS sku, rw.rec3_price AS price, rw.rec3_score AS score, rw.rec3_type AS rec_type, rw.rec3_image AS image),
  STRUCT(4 AS slot, rw.rec_part_4 AS sku, rw.rec4_price AS price, rw.rec4_score AS score, rw.rec4_type AS rec_type, rw.rec4_image AS image)
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

-- user_id → email_lower map (for event-side purchase lookup)
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

-- Fitment audit (365d): applies to rec1_type='fitment' rows only.
-- Lifetime audit (all-time): applies to rec1_type='non_fitment' rows only.
-- Each audit is a UNION of import-side (import_orders) and event-side
-- (ingestion_unified_schema_incremental) so a missing source doesn't mask a leak.
CREATE TEMP TABLE purchased_365d_import AS
SELECT DISTINCT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  REGEXP_REPLACE(
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\1'),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE ITEM IS NOT NULL
  AND NOT (
    ITEM LIKE 'EXT-%' OR ITEM LIKE 'GIFT-%' OR ITEM LIKE 'WARRANTY-%' OR
    ITEM LIKE 'SERVICE-%' OR ITEM LIKE 'PREAUTH-%'
  )
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL fitment_purchase_window_days DAY) AND CURRENT_DATE();

CREATE TEMP TABLE purchased_365d_events AS
SELECT DISTINCT
  em.email_lower,
  REGEXP_REPLACE(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))),
      r'([0-9])[BRGP]$', r'\1'
    ),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t,
     UNNEST(t.event_properties) ep
JOIN user_email_map em USING (user_id)
WHERE DATE(t.client_event_timestamp) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL fitment_purchase_window_days DAY) AND CURRENT_DATE()
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

-- Lifetime (all-time) purchases — import-side is authoritative for historical orders.
CREATE TEMP TABLE purchased_lifetime_import AS
SELECT DISTINCT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  REGEXP_REPLACE(
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\1'),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE ITEM IS NOT NULL
  AND NOT (
    ITEM LIKE 'EXT-%' OR ITEM LIKE 'GIFT-%' OR ITEM LIKE 'WARRANTY-%' OR
    ITEM LIKE 'SERVICE-%' OR ITEM LIKE 'PREAUTH-%'
  )
  AND SHIP_TO_EMAIL IS NOT NULL
  -- Year prefilter for bytes optimization (matches pipeline's min_prefilter_year=2000)
  AND SAFE_CAST(REGEXP_EXTRACT(ORDER_DATE, r'\b(20[0-9]{2})\b') AS INT64) BETWEEN 2000 AND EXTRACT(YEAR FROM CURRENT_DATE())
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) IS NOT NULL;

-- Event-side purchases — only last 365d exist in the events table, but that's
-- the lifetime event-side upper bound anyway (the events table doesn't extend further back).
CREATE TEMP TABLE purchased_lifetime_events AS
SELECT DISTINCT
  em.email_lower,
  REGEXP_REPLACE(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))),
      r'([0-9])[BRGP]$', r'\1'
    ),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t,
     UNNEST(t.event_properties) ep
JOIN user_email_map em USING (user_id)
WHERE DATE(t.client_event_timestamp) BETWEEN DATE '2020-01-01' AND CURRENT_DATE()
  AND UPPER(t.event_name) IN ('ORDERED PRODUCT', 'PLACED ORDER', 'CONSUMER WEBSITE ORDER')
  AND (
    (UPPER(t.event_name) = 'ORDERED PRODUCT' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$'))
    OR (UPPER(t.event_name) = 'PLACED ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$'))
    OR (UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$'))
  )
  AND COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)) IS NOT NULL;

CREATE TEMP TABLE purchased_lifetime_all AS
SELECT email_lower, sku_norm FROM purchased_lifetime_import
UNION DISTINCT
SELECT email_lower, sku_norm FROM purchased_lifetime_events;

-- Authoritative fitment map (YMM × normalized SKU) for fitment-row invariant check
CREATE TEMP TABLE fitment_map AS
SELECT DISTINCT
  SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS v1_year,
  UPPER(TRIM(fit.v1_make)) AS v1_make,
  UPPER(TRIM(fit.v1_model)) AS v1_model,
  REGEXP_REPLACE(
    REGEXP_REPLACE(UPPER(TRIM(prod.product_number)), r'([0-9])[BRGP]$', r'\1'),
    r'(-KIT|-BLK|-POL|-CHR|-RAW)$', ''
  ) AS sku_norm
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

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

-- ============================================================================
-- SHARED-TABLE INVARIANTS (CRITICAL)
-- ============================================================================

-- CRITICAL: audiences are disjoint by email
INSERT INTO go_no_go_checks
WITH per_email AS (
  SELECT email_lower, COUNT(DISTINCT rec1_type) AS audience_count
  FROM recs_wide
  GROUP BY email_lower
)
SELECT
  'disjoint_audiences_check',
  'CRITICAL',
  CAST(COUNTIF(audience_count > 1) AS STRING),
  '0',
  CASE WHEN COUNTIF(audience_count > 1) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No email may appear under both rec1_type=fitment and rec1_type=non_fitment'
FROM per_email;

-- CRITICAL: exactly one pipeline_version tag across the shared table
INSERT INTO go_no_go_checks
SELECT
  'single_pipeline_version_check',
  'CRITICAL',
  CAST(COUNT(DISTINCT pipeline_version) AS STRING),
  '1',
  CASE WHEN COUNT(DISTINCT pipeline_version) = 1 THEN 'PASS' ELSE 'FAIL' END,
  'Shared table must carry exactly one pipeline_version tag (locked contract #4)'
FROM recs_wide;

-- CRITICAL: rec*_type vocabulary
INSERT INTO go_no_go_checks
SELECT
  'rec_type_vocabulary',
  'CRITICAL',
  CAST(
    COUNTIF(rec1_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec2_type IS NOT NULL AND rec2_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec3_type IS NOT NULL AND rec3_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec4_type IS NOT NULL AND rec4_type NOT IN ('fitment','non_fitment'))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec1_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec2_type IS NOT NULL AND rec2_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec3_type IS NOT NULL AND rec3_type NOT IN ('fitment','non_fitment'))
    + COUNTIF(rec4_type IS NOT NULL AND rec4_type NOT IN ('fitment','non_fitment'))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Every populated rec*_type must be in {fitment, non_fitment}'
FROM recs_wide;

-- CRITICAL: cross-slot rec*_type consistency within a row
INSERT INTO go_no_go_checks
SELECT
  'cross_slot_type_consistency',
  'CRITICAL',
  CAST(COUNTIF(
    (rec2_type IS NOT NULL AND rec2_type != rec1_type) OR
    (rec3_type IS NOT NULL AND rec3_type != rec1_type) OR
    (rec4_type IS NOT NULL AND rec4_type != rec1_type)
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    (rec2_type IS NOT NULL AND rec2_type != rec1_type) OR
    (rec3_type IS NOT NULL AND rec3_type != rec1_type) OR
    (rec4_type IS NOT NULL AND rec4_type != rec1_type)
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Every populated rec*_type within a row must equal rec1_type (rows carry one audience)'
FROM recs_wide;

-- CRITICAL: non-fitment rows must have YMM='UNKNOWN' placeholders (locked contract #5)
INSERT INTO go_no_go_checks
SELECT
  'non_fitment_ymm_placeholder',
  'CRITICAL',
  CAST(COUNTIF(
    rec1_type = 'non_fitment' AND
    (v1_year != 'UNKNOWN' OR v1_make != 'UNKNOWN' OR v1_model != 'UNKNOWN')
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    rec1_type = 'non_fitment' AND
    (v1_year != 'UNKNOWN' OR v1_make != 'UNKNOWN' OR v1_model != 'UNKNOWN')
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment rows must stamp all three YMM fields as UNKNOWN'
FROM recs_wide;

-- CRITICAL: non-fitment rows must carry NULL engagement_tier (V5.18-only field)
INSERT INTO go_no_go_checks
SELECT
  'non_fitment_engagement_tier_null',
  'CRITICAL',
  CAST(COUNTIF(rec1_type = 'non_fitment' AND engagement_tier IS NOT NULL) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec1_type = 'non_fitment' AND engagement_tier IS NOT NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment rows do not compute an engagement_tier — must be NULL'
FROM recs_wide;

-- CRITICAL: non-fitment rows must carry NULL fitment_count (V5.18-only field)
INSERT INTO go_no_go_checks
SELECT
  'non_fitment_fitment_count_null',
  'CRITICAL',
  CAST(COUNTIF(rec1_type = 'non_fitment' AND fitment_count IS NOT NULL) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec1_type = 'non_fitment' AND fitment_count IS NOT NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment rows have no YMM — fitment_count must be NULL'
FROM recs_wide;

-- ============================================================================
-- POLICY COMPLIANCE (applies to both audiences)
-- ============================================================================

-- CRITICAL: price floor
INSERT INTO go_no_go_checks
SELECT
  'price_floor_violations',
  'CRITICAL',
  CAST(COUNTIF(rec_price IS NOT NULL AND rec_price < min_price) AS STRING),
  FORMAT('0 (min price >= %.0f)', min_price),
  CASE WHEN COUNTIF(rec_price IS NOT NULL AND rec_price < min_price) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'All populated prices must satisfy floor'
FROM recs_long;

-- CRITICAL: non-negative scores
INSERT INTO go_no_go_checks
SELECT
  'negative_scores',
  'CRITICAL',
  CAST(COUNTIF(rec_score < 0) AS STRING),
  '0',
  CASE WHEN COUNTIF(rec_score < 0) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'All populated scores must be >= 0'
FROM recs_long;

-- CRITICAL: score ordering (monotonic non-increasing within a row)
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
  'rec1_score >= rec2_score >= rec3_score >= rec4_score (NULL-safe downstream)'
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

-- CRITICAL: every filled slot has an https image
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

-- HIGH: duplicate SKUs within a row
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

-- HIGH: slot consistency (NULL rec_part means all rec*_N_* fields NULL)
INSERT INTO go_no_go_checks
SELECT
  'slot_consistency_violations',
  'HIGH',
  CAST(
    COUNTIF(rec_part_2 IS NULL AND (rec2_price IS NOT NULL OR rec2_score IS NOT NULL OR rec2_image IS NOT NULL OR rec2_type IS NOT NULL OR rec2_pop_source IS NOT NULL)) +
    COUNTIF(rec_part_3 IS NULL AND (rec3_price IS NOT NULL OR rec3_score IS NOT NULL OR rec3_image IS NOT NULL OR rec3_type IS NOT NULL OR rec3_pop_source IS NOT NULL)) +
    COUNTIF(rec_part_4 IS NULL AND (rec4_price IS NOT NULL OR rec4_score IS NOT NULL OR rec4_image IS NOT NULL OR rec4_type IS NOT NULL OR rec4_pop_source IS NOT NULL))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec_part_2 IS NULL AND (rec2_price IS NOT NULL OR rec2_score IS NOT NULL OR rec2_image IS NOT NULL OR rec2_type IS NOT NULL OR rec2_pop_source IS NOT NULL)) +
    COUNTIF(rec_part_3 IS NULL AND (rec3_price IS NOT NULL OR rec3_score IS NOT NULL OR rec3_image IS NOT NULL OR rec3_type IS NOT NULL OR rec3_pop_source IS NOT NULL)) +
    COUNTIF(rec_part_4 IS NULL AND (rec4_price IS NOT NULL OR rec4_score IS NOT NULL OR rec4_image IS NOT NULL OR rec4_type IS NOT NULL OR rec4_pop_source IS NOT NULL))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'If rec_part_N is NULL, all rec*_N_* fields must also be NULL'
FROM recs_wide;

-- HIGH: refurbished products in output
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

-- HIGH: service/commodity SKU prefixes
INSERT INTO go_no_go_checks
SELECT
  'service_sku_prefixes_in_output',
  'HIGH',
  CAST(COUNTIF(
    sku LIKE 'EXT-%' OR sku LIKE 'GIFT-%' OR sku LIKE 'WARRANTY-%' OR
    sku LIKE 'SERVICE-%' OR sku LIKE 'PREAUTH-%'
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    sku LIKE 'EXT-%' OR sku LIKE 'GIFT-%' OR sku LIKE 'WARRANTY-%' OR
    sku LIKE 'SERVICE-%' OR sku LIKE 'PREAUTH-%'
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No EXT/GIFT/WARRANTY/SERVICE/PREAUTH SKUs in output'
FROM recs_long;

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

-- ============================================================================
-- PURCHASE EXCLUSION (split by audience — fitment=365d, non-fitment=lifetime)
-- ============================================================================

-- CRITICAL: fitment rows — no recommended SKU in last 365d purchases
INSERT INTO go_no_go_checks
SELECT
  'purchase_exclusion_fitment_365d',
  'CRITICAL',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment rows: no recommended SKU should appear in last-365-day purchases (import+events, variant-normalized)'
FROM recs_long r
JOIN purchased_365d_all p
  ON r.email_lower = p.email_lower
 AND r.sku_norm = p.sku_norm
WHERE r.row_audience = 'fitment';

-- CRITICAL: non-fitment rows — no recommended SKU in lifetime purchases (locked contract #6)
INSERT INTO go_no_go_checks
SELECT
  'purchase_exclusion_non_fitment_lifetime',
  'CRITICAL',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment rows: no recommended SKU should appear in lifetime purchases (all-time import + 365d events)'
FROM recs_long r
JOIN purchased_lifetime_all p
  ON r.email_lower = p.email_lower
 AND r.sku_norm = p.sku_norm
WHERE r.row_audience = 'non_fitment';

-- ============================================================================
-- FITMENT-SPECIFIC INVARIANTS (rec1_type='fitment')
-- ============================================================================

-- CRITICAL: engagement_tier ∈ {hot, cold}, no NULLs — fitment rows only
INSERT INTO go_no_go_checks
SELECT
  'engagement_tier_fitment',
  'CRITICAL',
  CAST(
    COUNTIF(rec1_type = 'fitment' AND engagement_tier IS NULL) +
    COUNTIF(rec1_type = 'fitment' AND engagement_tier NOT IN ('hot','cold'))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec1_type = 'fitment' AND engagement_tier IS NULL) +
    COUNTIF(rec1_type = 'fitment' AND engagement_tier NOT IN ('hot','cold'))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment rows: engagement_tier must be hot or cold — no NULLs, no other values'
FROM recs_wide;

-- CRITICAL: fitment_count ∈ {3,4} AND matches actual filled slots — fitment rows only
INSERT INTO go_no_go_checks
SELECT
  'fitment_count_check',
  'CRITICAL',
  CAST(
    COUNTIF(rec1_type = 'fitment' AND fitment_count NOT IN (3,4)) +
    COUNTIF(rec1_type = 'fitment' AND fitment_count != (
      IF(rec_part_1 IS NOT NULL, 1, 0) +
      IF(rec_part_2 IS NOT NULL, 1, 0) +
      IF(rec_part_3 IS NOT NULL, 1, 0) +
      IF(rec_part_4 IS NOT NULL, 1, 0)
    ))
  AS STRING),
  '0',
  CASE WHEN
    COUNTIF(rec1_type = 'fitment' AND fitment_count NOT IN (3,4)) +
    COUNTIF(rec1_type = 'fitment' AND fitment_count != (
      IF(rec_part_1 IS NOT NULL, 1, 0) +
      IF(rec_part_2 IS NOT NULL, 1, 0) +
      IF(rec_part_3 IS NOT NULL, 1, 0) +
      IF(rec_part_4 IS NOT NULL, 1, 0)
    ))
    = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment rows: fitment_count must be 3 or 4 AND equal number of filled rec_part_* slots'
FROM recs_wide;

-- CRITICAL: YMM × SKU authoritative match — fitment rows only
INSERT INTO go_no_go_checks
WITH rec_map AS (
  SELECT
    r.email_lower,
    r.rec_slot,
    SAFE_CAST(r.v1_year AS INT64) AS v1_year,
    UPPER(r.v1_make) AS v1_make,
    UPPER(r.v1_model) AS v1_model,
    r.sku_norm
  FROM recs_long r
  WHERE r.row_audience = 'fitment'
),
joined AS (
  SELECT
    rm.email_lower,
    rm.rec_slot,
    f.sku_norm AS matched_sku
  FROM rec_map rm
  LEFT JOIN fitment_map f
    ON rm.v1_year = f.v1_year
   AND rm.v1_make = f.v1_make
   AND rm.v1_model = f.v1_model
   AND rm.sku_norm = f.sku_norm
)
SELECT
  'fitment_ymm_sku_match',
  'CRITICAL',
  CAST(COUNTIF(matched_sku IS NULL) AS STRING),
  '0',
  CASE WHEN COUNTIF(matched_sku IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment rows: every (v1_year, v1_make, v1_model, rec_part_N) must match vehicle_product_fitment_data'
FROM joined;

-- HIGH: fitment rows — email must exist in ymm_users_for_exclusion (sanity check)
EXECUTE IMMEDIATE FORMAT("""
INSERT INTO go_no_go_checks
SELECT
  'fitment_email_in_ymm_set',
  'HIGH',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment rows: every email should be present in ymm_users_for_exclusion (pipeline anti-join sanity)'
FROM %s f
LEFT JOIN %s y ON f.email_lower = y.email_lower
WHERE f.rec1_type = 'fitment' AND y.email_lower IS NULL
""", final_table, ymm_table);

-- HIGH: non-fitment rows — email must NOT be in ymm_users_for_exclusion
EXECUTE IMMEDIATE FORMAT("""
INSERT INTO go_no_go_checks
SELECT
  'non_fitment_email_not_in_ymm_set',
  'HIGH',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment rows: email must NOT be in ymm_users_for_exclusion (email-level disjoint invariant)'
FROM %s f
JOIN %s y ON f.email_lower = y.email_lower
WHERE f.rec1_type = 'non_fitment'
""", final_table, ymm_table);

-- ============================================================================
-- COVERAGE GATES
-- ============================================================================

-- CRITICAL: overall final user count
INSERT INTO go_no_go_checks
SELECT
  'final_user_count_total',
  'CRITICAL',
  CAST(COUNT(*) AS STRING),
  FORMAT('>= %d', min_final_users + min_fitment_users),
  CASE WHEN COUNT(*) >= (min_final_users + min_fitment_users) THEN 'PASS' ELSE 'FAIL' END,
  'Shared-table total row gate (fitment + non_fitment)'
FROM recs_wide;

-- CRITICAL: fitment coverage
INSERT INTO go_no_go_checks
SELECT
  'final_user_count_fitment',
  'CRITICAL',
  CAST(COUNTIF(rec1_type = 'fitment') AS STRING),
  FORMAT('>= %d', min_fitment_users),
  CASE WHEN COUNTIF(rec1_type = 'fitment') >= min_fitment_users THEN 'PASS' ELSE 'FAIL' END,
  'Fitment audience coverage (V5.18 slice of the shared table)'
FROM recs_wide;

-- CRITICAL: non-fitment coverage
INSERT INTO go_no_go_checks
SELECT
  'final_user_count_non_fitment',
  'CRITICAL',
  CAST(COUNTIF(rec1_type = 'non_fitment') AS STRING),
  FORMAT('>= %d', min_final_users),
  CASE WHEN COUNTIF(rec1_type = 'non_fitment') >= min_final_users THEN 'PASS' ELSE 'FAIL' END,
  'Non-fitment audience coverage (V5.19 slice)'
FROM recs_wide;

-- ============================================================================
-- INFO / MONITORING METRICS
-- ============================================================================

-- Non-fitment rows whose top score beats the bestseller floor.
-- Under the related-item-primary + floor-backfill design this is informational only:
-- the non-fitment floor is an accepted part of the release shape, not a go/no-go failure.
INSERT INTO go_no_go_checks
SELECT
  'non_fitment_above_bestseller_floor_count',
  'INFO',
  CAST(COUNTIF(rec1_type = 'non_fitment' AND rec1_score > w_bestseller) AS STRING),
  'monitor trend',
  'INFO',
  'Non-fitment rows whose top score exceeds the bestseller floor; no longer a release gate'
FROM recs_wide;

-- Engagement tier share among fitment rows
INSERT INTO go_no_go_checks
SELECT
  'engagement_tier_hot_pct_fitment',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(rec1_type = 'fitment' AND engagement_tier = 'hot'),
                             COUNTIF(rec1_type = 'fitment')) * 100.0),
  'monitor trend',
  'INFO',
  'Fitment rows: percentage in hot tier (cart/view in last 7 days)'
FROM recs_wide;

-- Users with 4 recs — per audience
INSERT INTO go_no_go_checks
SELECT
  'users_with_4_recs_pct_fitment',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(rec1_type = 'fitment' AND rec_part_4 IS NOT NULL),
                             COUNTIF(rec1_type = 'fitment')) * 100.0),
  'monitor trend',
  'INFO',
  'Fitment rows: percentage receiving full 4 slots'
FROM recs_wide;

INSERT INTO go_no_go_checks
SELECT
  'users_with_4_recs_pct_non_fitment',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(rec1_type = 'non_fitment' AND rec_part_4 IS NOT NULL),
                             COUNTIF(rec1_type = 'non_fitment')) * 100.0),
  'monitor trend',
  'INFO',
  'Non-fitment rows: percentage receiving full 4 slots'
FROM recs_wide;

-- Average rec1 price per audience
INSERT INTO go_no_go_checks
SELECT
  'avg_rec1_price_fitment',
  'INFO',
  FORMAT('%.2f', AVG(IF(rec1_type = 'fitment', rec1_price, NULL))),
  'monitor trend',
  'INFO',
  'Fitment rows: average rec1_price ($)'
FROM recs_wide;

INSERT INTO go_no_go_checks
SELECT
  'avg_rec1_price_non_fitment',
  'INFO',
  FORMAT('%.2f', AVG(IF(rec1_type = 'non_fitment', rec1_price, NULL))),
  'monitor trend',
  'INFO',
  'Non-fitment rows: average rec1_price ($)'
FROM recs_wide;

-- Fallback share (non-fitment only): rows where every score equals the bestseller floor
INSERT INTO go_no_go_checks
SELECT
  'fallback_share_non_fitment_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(
    COUNTIF(rec1_type = 'non_fitment' AND rec1_score <= w_bestseller),
    COUNTIF(rec1_type = 'non_fitment')
  ) * 100.0),
  'monitor trend',
  'INFO',
  'Non-fitment rows: share whose top score is at or below the bestseller floor (fallback-dominated)'
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
  SELECT
    r.email_lower,
    r.row_audience,
    r.rec_slot,
    r.sku,
    r.rec_price,
    r.rec_score,
    r.rec_type,
    r.v1_year,
    r.v1_make,
    r.v1_model
  FROM recs_long r
  WHERE r.rec_price < min_price
     OR r.rec_type NOT IN ('fitment','non_fitment')
     OR (r.row_audience = 'non_fitment' AND (r.v1_year != 'UNKNOWN' OR r.v1_make != 'UNKNOWN' OR r.v1_model != 'UNKNOWN'))
  ORDER BY r.email_lower, r.rec_slot
  LIMIT 200;
ELSE
  SELECT '[SKIP] Investigation aids not emitted because no FAIL checks were found.' AS log;
END IF;
