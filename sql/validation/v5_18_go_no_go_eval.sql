-- ====================================================================================
-- V5.18 Go/No-Go Evaluation (Post-Run)
-- ------------------------------------------------------------------------------------
-- Purpose:
--   Make release decisions with strict fitment and quality safety gates.
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/validation/v5_18_go_no_go_eval.sql
--
-- Notes:
--   - Run AFTER v5.18 pipeline completes.
--   - This script assumes intermediate popularity tables exist in target_dataset.
-- ====================================================================================

DECLARE target_project STRING DEFAULT 'auxia-reporting';
DECLARE target_dataset STRING DEFAULT 'temp_holley_v5_18';
DECLARE min_price FLOAT64 DEFAULT 50.0;
DECLARE purchase_window_days INT64 DEFAULT 365;

DECLARE final_table STRING DEFAULT FORMAT('`%s.%s.final_vehicle_recommendations`', target_project, target_dataset);
DECLARE segment_table STRING DEFAULT FORMAT('`%s.%s.segment_popularity`', target_project, target_dataset);
DECLARE make_table STRING DEFAULT FORMAT('`%s.%s.make_popularity`', target_project, target_dataset);
DECLARE global_table STRING DEFAULT FORMAT('`%s.%s.global_popularity_fallback`', target_project, target_dataset);

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
  SAFE_CAST(rw.v1_year AS INT64) AS v1_year,
  UPPER(rw.v1_make) AS v1_make,
  UPPER(rw.v1_model) AS v1_model,
  r.slot AS rec_slot,
  UPPER(r.sku) AS sku,
  REGEXP_REPLACE(UPPER(r.sku), r'([0-9])[BRGP]$', r'\1') AS sku_norm,
  r.price AS rec_price,
  r.score AS rec_score,
  r.product_type,
  r.pop_source
FROM recs_wide rw
CROSS JOIN UNNEST([
  STRUCT(1 AS slot, rw.rec_part_1 AS sku, rw.rec1_price AS price, rw.rec1_score AS score, rw.rec1_type AS product_type, rw.rec1_pop_source AS pop_source),
  STRUCT(2 AS slot, rw.rec_part_2 AS sku, rw.rec2_price AS price, rw.rec2_score AS score, rw.rec2_type AS product_type, rw.rec2_pop_source AS pop_source),
  STRUCT(3 AS slot, rw.rec_part_3 AS sku, rw.rec3_price AS price, rw.rec3_score AS score, rw.rec3_type AS product_type, rw.rec3_pop_source AS pop_source),
  STRUCT(4 AS slot, rw.rec_part_4 AS sku, rw.rec4_price AS price, rw.rec4_score AS score, rw.rec4_type AS product_type, rw.rec4_pop_source AS pop_source)
]) r
WHERE r.sku IS NOT NULL;

CREATE TEMP TABLE fitment_map AS
SELECT DISTINCT
  SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS v1_year,
  UPPER(TRIM(fit.v1_make)) AS v1_make,
  UPPER(TRIM(fit.v1_model)) AS v1_model,
  UPPER(TRIM(prod.product_number)) AS sku
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

CREATE TEMP TABLE sku_catalog AS
SELECT
  UPPER(TRIM(PartNumber)) AS sku,
  MAX(PartType) AS part_type,
  MAX(Tags) AS tags
FROM `auxia-gcp.data_company_1950.import_items`
WHERE PartNumber IS NOT NULL
GROUP BY sku;

CREATE TEMP TABLE user_attrs_base AS
WITH attr_ranked AS (
  SELECT
    t.user_id,
    LOWER(p.property_name) AS property_name,
    CASE
      WHEN LOWER(p.property_name) = 'email'
        THEN LOWER(TRIM(p.string_value))
      WHEN LOWER(p.property_name) = 'v1_year'
        THEN TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))
      WHEN LOWER(p.property_name) = 'v1_make'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      WHEN LOWER(p.property_name) = 'v1_model'
        THEN UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING))))
      ELSE NULL
    END AS property_value,
    ROW_NUMBER() OVER (
      PARTITION BY t.user_id, LOWER(p.property_name)
      ORDER BY t.update_timestamp DESC, t.auxia_insertion_timestamp DESC
    ) AS rn
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` t,
       UNNEST(t.user_properties) p
  WHERE LOWER(p.property_name) IN ('email', 'v1_year', 'v1_make', 'v1_model')
)
SELECT
  user_id,
  MAX(IF(property_name = 'email', property_value, NULL)) AS email_lower,
  MAX(IF(property_name = 'v1_year', property_value, NULL)) AS v1_year,
  MAX(IF(property_name = 'v1_make', property_value, NULL)) AS v1_make,
  MAX(IF(property_name = 'v1_model', property_value, NULL)) AS v1_model
FROM attr_ranked
WHERE rn = 1
  AND property_value IS NOT NULL
  AND property_value != ''
GROUP BY user_id;

CREATE TEMP TABLE base_universe AS
SELECT DISTINCT
  email_lower,
  SAFE_CAST(v1_year AS INT64) AS v1_year,
  v1_make,
  v1_model
FROM user_attrs_base
WHERE email_lower IS NOT NULL
  AND v1_year IS NOT NULL
  AND v1_make IS NOT NULL
  AND v1_model IS NOT NULL;

CREATE TEMP TABLE final_user_keys AS
SELECT DISTINCT
  email_lower,
  SAFE_CAST(v1_year AS INT64) AS v1_year,
  UPPER(v1_make) AS v1_make,
  UPPER(v1_model) AS v1_model
FROM recs_wide;

-- -----------------------------------------------------------------------------
-- Purchase exclusion audit (independent reconstruction)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE purchased_365d_import AS
SELECT DISTINCT
  LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower,
  REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\1') AS sku_norm
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE ITEM IS NOT NULL
  AND NOT (
    ITEM LIKE 'EXT-%' OR
    ITEM LIKE 'GIFT-%' OR
    ITEM LIKE 'WARRANTY-%' OR
    ITEM LIKE 'SERVICE-%' OR
    ITEM LIKE 'PREAUTH-%'
  )
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL purchase_window_days DAY) AND CURRENT_DATE();

CREATE TEMP TABLE user_id_email AS
SELECT DISTINCT user_id, email_lower
FROM user_attrs_base
WHERE user_id IS NOT NULL AND email_lower IS NOT NULL;

CREATE TEMP TABLE purchased_365d_events AS
SELECT DISTINCT
  ue.email_lower,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(CAST(ep.string_value AS STRING), CAST(ep.long_value AS STRING)))), r'([0-9])[BRGP]$', r'\1') AS sku_norm
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` t
JOIN user_id_email ue
  ON t.user_id = ue.user_id,
UNNEST(t.event_properties) ep
WHERE DATE(t.client_event_timestamp)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL purchase_window_days DAY) AND CURRENT_DATE()
  AND (
    (UPPER(t.event_name) = 'ORDERED PRODUCT' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^prod(?:uct)?id$')) OR
    (UPPER(t.event_name) = 'PLACED ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^items_[0-9]+\.productid$')) OR
    (UPPER(t.event_name) = 'CONSUMER WEBSITE ORDER' AND REGEXP_CONTAINS(LOWER(ep.property_name), r'^skus_[0-9]+$'))
  );

CREATE TEMP TABLE purchased_365d_all AS
SELECT * FROM purchased_365d_import
UNION DISTINCT
SELECT * FROM purchased_365d_events;

-- -----------------------------------------------------------------------------
-- Popularity source consistency audit
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
CREATE TEMP TABLE source_support AS
SELECT
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  r.rec_slot,
  r.sku,
  LOWER(COALESCE(r.pop_source, '')) AS pop_source,
  seg.sku AS seg_hit,
  mk.sku AS make_hit,
  glob.sku AS global_hit
FROM recs_long r
LEFT JOIN %s seg
  ON r.v1_make = seg.v1_make AND r.v1_model = seg.v1_model AND r.sku = seg.sku
LEFT JOIN %s mk
  ON r.v1_make = mk.v1_make AND r.sku = mk.sku
LEFT JOIN %s glob
  ON r.sku = glob.sku
""", segment_table, make_table, global_table);

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

INSERT INTO go_no_go_checks
SELECT
  'fitment_mismatch_rows',
  'CRITICAL',
  CAST(COUNTIF(f.sku IS NULL) AS STRING),
  '0',
  CASE WHEN COUNTIF(f.sku IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Every recommended SKU must exist in fitment map for user YMM'
FROM recs_long r
LEFT JOIN fitment_map f
  ON r.v1_year = f.v1_year AND r.v1_make = f.v1_make AND r.v1_model = f.v1_model AND r.sku = f.sku;

INSERT INTO go_no_go_checks
SELECT
  'users_with_any_fitment_mismatch',
  'CRITICAL',
  CAST(COUNT(DISTINCT IF(f.sku IS NULL, FORMAT('%s|%d|%s|%s', r.email_lower, r.v1_year, r.v1_make, r.v1_model), NULL)) AS STRING),
  '0',
  CASE WHEN COUNT(DISTINCT IF(f.sku IS NULL, FORMAT('%s|%d|%s|%s', r.email_lower, r.v1_year, r.v1_make, r.v1_model), NULL)) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No user should receive any non-fitment part'
FROM recs_long r
LEFT JOIN fitment_map f
  ON r.v1_year = f.v1_year AND r.v1_make = f.v1_make AND r.v1_model = f.v1_model AND r.sku = f.sku;

INSERT INTO go_no_go_checks
SELECT
  'golf_segment_mismatch_rows',
  'CRITICAL',
  CAST(COUNTIF(f.sku IS NULL) AS STRING),
  '0',
  CASE WHEN COUNTIF(f.sku IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Explicit guardrail for known Golf fitment issue'
FROM recs_long r
LEFT JOIN fitment_map f
  ON r.v1_year = f.v1_year AND r.v1_make = f.v1_make AND r.v1_model = f.v1_model AND r.sku = f.sku
WHERE UPPER(r.v1_model) LIKE '%GOLF%';

INSERT INTO go_no_go_checks
SELECT
  'universal_recommendation_rows',
  'CRITICAL',
  CAST(COUNTIF(LOWER(product_type) = 'universal') AS STRING),
  '0',
  CASE WHEN COUNTIF(LOWER(product_type) = 'universal') = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Fitment-only pipeline must not output universal parts'
FROM recs_long;

INSERT INTO go_no_go_checks
SELECT
  'price_floor_violations',
  'CRITICAL',
  CAST(COUNTIF(rec_price < min_price) AS STRING),
  FORMAT('0 (min price >= %.0f)', min_price),
  CASE WHEN COUNTIF(rec_price < min_price) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'All recommended prices must satisfy floor'
FROM recs_long;

INSERT INTO go_no_go_checks
SELECT
  'purchase_exclusion_violations',
  'HIGH',
  CAST(COUNT(*) AS STRING),
  '0',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No recommended SKU should appear in last-365-day purchases for same email'
FROM recs_long r
JOIN purchased_365d_all p
  ON r.email_lower = p.email_lower
 AND r.sku_norm = p.sku_norm;

INSERT INTO go_no_go_checks
SELECT
  'duplicate_users',
  'HIGH',
  CAST(COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_2 = rec_part_3 OR
    (rec_part_4 IS NOT NULL AND (
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ))
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_2 = rec_part_3 OR
    (rec_part_4 IS NOT NULL AND (
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ))
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No duplicate SKUs per user row'
FROM recs_wide;

INSERT INTO go_no_go_checks
WITH parttype_counts AS (
  SELECT
    email_lower, v1_year, v1_make, v1_model,
    COALESCE(c.part_type, 'UNKNOWN') AS part_type,
    COUNT(*) AS n
  FROM recs_long r
  LEFT JOIN sku_catalog c
    ON r.sku = c.sku
  GROUP BY email_lower, v1_year, v1_make, v1_model, part_type
)
SELECT
  'diversity_cap_violations',
  'HIGH',
  CAST(COUNTIF(n > 2) AS STRING),
  '0',
  CASE WHEN COUNTIF(n > 2) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'No user should have more than 2 recs in same PartType'
FROM parttype_counts;

INSERT INTO go_no_go_checks
SELECT
  'popularity_source_none_rows',
  'HIGH',
  CAST(COUNTIF(pop_source = 'none' OR pop_source = '') AS STRING),
  '0',
  CASE WHEN COUNTIF(pop_source = 'none' OR pop_source = '') = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Purchase-only mode expects all recs to have segment/make/global source'
FROM source_support;

INSERT INTO go_no_go_checks
SELECT
  'popularity_source_join_mismatches',
  'HIGH',
  CAST(COUNTIF(
    (pop_source = 'segment' AND seg_hit IS NULL) OR
    (pop_source = 'make' AND make_hit IS NULL) OR
    (pop_source = 'global' AND global_hit IS NULL)
  ) AS STRING),
  '0',
  CASE WHEN COUNTIF(
    (pop_source = 'segment' AND seg_hit IS NULL) OR
    (pop_source = 'make' AND make_hit IS NULL) OR
    (pop_source = 'global' AND global_hit IS NULL)
  ) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'pop_source labels must match available popularity-table support'
FROM source_support;

INSERT INTO go_no_go_checks
SELECT
  'fitment_count_outside_3_or_4',
  'HIGH',
  CAST(COUNTIF(fitment_count NOT IN (3, 4)) AS STRING),
  '0',
  CASE WHEN COUNTIF(fitment_count NOT IN (3, 4)) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Output must include only users with 3 or 4 recommendations'
FROM recs_wide;

INSERT INTO go_no_go_checks
SELECT
  'score_ordering_violations',
  'MEDIUM',
  CAST(COUNTIF(NOT (
    rec1_score >= rec2_score AND
    rec2_score >= rec3_score AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) AS STRING),
  '0',
  CASE WHEN COUNTIF(NOT (
    rec1_score >= rec2_score AND
    rec2_score >= rec3_score AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'Top-N recommendations must be score sorted'
FROM recs_wide;

INSERT INTO go_no_go_checks
WITH b AS (
  SELECT COUNT(*) AS base_users FROM base_universe
),
f AS (
  SELECT COUNT(*) AS final_users FROM final_user_keys
)
SELECT
  'final_coverage_of_base_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(f.final_users, b.base_users) * 100.0),
  'monitor trend (higher is better)',
  'INFO',
  'Share of base fitment users receiving final recommendations'
FROM b, f;

INSERT INTO go_no_go_checks
SELECT
  'users_with_4_recommendations_pct',
  'INFO',
  FORMAT('%.2f', SAFE_DIVIDE(COUNTIF(fitment_count = 4), COUNT(*)) * 100.0),
  'monitor trend',
  'INFO',
  'Coverage quality: percent of users receiving full 4 slots'
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
-- Investigation Aids (only relevant if a FAIL is present)
-- -----------------------------------------------------------------------------

-- Top mismatches for triage
SELECT
  r.email_lower,
  r.v1_year,
  r.v1_make,
  r.v1_model,
  r.rec_slot,
  r.sku
FROM recs_long r
LEFT JOIN fitment_map f
  ON r.v1_year = f.v1_year AND r.v1_make = f.v1_make AND r.v1_model = f.v1_model AND r.sku = f.sku
WHERE f.sku IS NULL
ORDER BY r.v1_make, r.v1_model, r.email_lower, r.rec_slot
LIMIT 200;

-- Golf-specific output sample for manual audit
SELECT
  *
FROM recs_wide
WHERE UPPER(v1_model) LIKE '%GOLF%'
LIMIT 200;
