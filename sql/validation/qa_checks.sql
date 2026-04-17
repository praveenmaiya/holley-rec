-- Holley Recommendations QA Validation Queries
-- Run these checks after pipeline execution to validate data quality
-- Default dataset: auxia-reporting.temp_holley_v5_19 (shared fitment + non-fitment staging)
--
-- Shared-table scope (V5.19+):
--   - Checks that apply to BOTH audiences have no WHERE filter
--   - Checks that apply ONLY to fitment rows add `WHERE rec1_type = 'fitment'`
--     (fitment_count, engagement_tier, YMM×SKU match, fitment_count-driven NULL rec4 check)
--   - Checks that apply ONLY to non-fitment rows add `WHERE rec1_type = 'non_fitment'`
--     (currently none beyond invariants covered by the per-audience go/no-go file)
--   - Two new shared-table invariants at the bottom: single pipeline_version, cross-slot
--     rec*_type consistency.
-- Note: email consent gating is intentionally not enforced in pipeline output.

-- ============================================================================
-- QUICK HEALTH CHECK (run first)
-- ============================================================================

-- Health Check Dashboard
WITH
user_count AS (
  SELECT COUNT(*) as total_users
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
),
score_stats AS (
  SELECT
    MIN(rec1_score) as min_score,
    MAX(rec1_score) as max_score,
    ROUND(AVG(rec1_score), 2) as avg_score
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
),
price_stats AS (
  SELECT
    MIN(LEAST(rec1_price, COALESCE(rec2_price, rec1_price), COALESCE(rec3_price, rec1_price))) as min_price,
    MAX(GREATEST(rec1_price, COALESCE(rec2_price, 0), COALESCE(rec3_price, 0), COALESCE(rec4_price, 0))) as max_price,
    -- Per-row avg price across populated slots; SAFE for non-fitment rows (fitment_count NULL)
    ROUND(AVG(SAFE_DIVIDE(
      COALESCE(rec1_price, 0) + COALESCE(rec2_price, 0) + COALESCE(rec3_price, 0) + COALESCE(rec4_price, 0),
      IF(rec1_price IS NOT NULL, 1, 0) + IF(rec2_price IS NOT NULL, 1, 0) +
      IF(rec3_price IS NOT NULL, 1, 0) + IF(rec4_price IS NOT NULL, 1, 0)
    )), 2) as avg_price
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
),
duplicate_check AS (
  SELECT
    COUNTIF(
      rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
      rec_part_2 = rec_part_3 OR
      (rec_part_4 IS NOT NULL AND (
        rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
      ))
    ) as duplicate_users
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
)
SELECT
  'USERS' as metric,
  CAST((SELECT total_users FROM user_count) AS STRING) as value,
  '>=400K expected' as expected
UNION ALL
SELECT 'SCORE_RANGE', CONCAT(CAST((SELECT min_score FROM score_stats) AS STRING), ' - ', CAST((SELECT max_score FROM score_stats) AS STRING)), '>=0 expected; segment/make tiers can exceed 25'
UNION ALL
SELECT 'AVG_SCORE', CAST((SELECT avg_score FROM score_stats) AS STRING), 'monitor trend vs previous run'
UNION ALL
SELECT 'PRICE_RANGE', CONCAT('$', CAST((SELECT min_price FROM price_stats) AS STRING), ' - $', CAST((SELECT max_price FROM price_stats) AS STRING)), '>=$50 required'
UNION ALL
SELECT 'DUPLICATES', CAST((SELECT duplicate_users FROM duplicate_check) AS STRING), '0 required';


-- ============================================================================
-- CHECK 1: No Duplicate SKUs per User
-- ============================================================================
-- Expected: 0 users with duplicate recommendations
-- Handles NULL rec4 for 3-rec users
SELECT
  COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_2 = rec_part_3 OR
    (rec_part_4 IS NOT NULL AND (
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ))
  ) as users_with_duplicates
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 2: No Refurbished Items
-- ============================================================================
-- Expected: 0 refurbished SKUs
WITH all_recommended_skus AS (
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_1), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') as sku FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_2), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_3), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_4), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNT(*) as total_skus,
  COUNTIF(LOWER(it.Tags) LIKE '%refurbished%') as refurbished_count
FROM all_recommended_skus rs
LEFT JOIN (
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(PartNumber)), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') as PartNumber, MAX(Tags) as Tags
  FROM `auxia-gcp.data_company_1950.import_items`
  GROUP BY PartNumber
) it ON rs.sku = it.PartNumber;


-- ============================================================================
-- CHECK 3: No Service SKUs
-- ============================================================================
-- Expected: All counts = 0
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNTIF(sku LIKE 'EXT-%') as ext_count,
  COUNTIF(sku LIKE 'GIFT-%') as gift_count,
  COUNTIF(sku LIKE 'WARRANTY-%') as warranty_count,
  COUNTIF(sku LIKE 'SERVICE-%') as service_count,
  COUNTIF(sku LIKE 'PREAUTH-%') as preauth_count
FROM all_recommended_skus;


-- ============================================================================
-- CHECK 4: Price Filter (>= $50) — applies to both audiences
-- ============================================================================
-- Expected: min_price >= $50, violations = 0
-- Every populated rec*_price must be >= $50. Non-fitment rows may have NULL rec2..4
-- if the fallback produced fewer slots; NULLs are not violations.
SELECT
  COUNT(*) as total_users,
  MIN(LEAST(rec1_price, COALESCE(rec2_price, rec1_price), COALESCE(rec3_price, rec1_price))) as min_price,
  GREATEST(MAX(rec1_price), COALESCE(MAX(rec2_price), 0), COALESCE(MAX(rec3_price), 0), COALESCE(MAX(rec4_price), 0)) as max_price,
  ROUND(AVG(SAFE_DIVIDE(
    COALESCE(rec1_price, 0) + COALESCE(rec2_price, 0) + COALESCE(rec3_price, 0) + COALESCE(rec4_price, 0),
    IF(rec1_price IS NOT NULL, 1, 0) + IF(rec2_price IS NOT NULL, 1, 0) +
    IF(rec3_price IS NOT NULL, 1, 0) + IF(rec4_price IS NOT NULL, 1, 0)
  )), 2) as avg_price,
  COUNTIF((rec1_price IS NOT NULL AND rec1_price < 50)
       OR (rec2_price IS NOT NULL AND rec2_price < 50)
       OR (rec3_price IS NOT NULL AND rec3_price < 50)) as below_50_violations_1_3,
  COUNTIF(rec4_price IS NOT NULL AND rec4_price < 50) as below_50_violations_4
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 5: HTTPS Images Only
-- ============================================================================
-- Expected: https_pct = 100%, null_count = 0 for recs 1-3
-- rec4 images may be NULL for 3-rec users
WITH all_images AS (
  SELECT rec1_image as image_url FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT rec2_image FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT rec3_image FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT rec4_image FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations` WHERE rec4_image IS NOT NULL
)
SELECT
  COUNT(*) as total_images,
  COUNTIF(STARTS_WITH(image_url, 'https://')) as https_count,
  COUNTIF(STARTS_WITH(image_url, 'http://')) as http_count,
  COUNTIF(STARTS_WITH(image_url, '//')) as protocol_relative_count,
  COUNTIF(image_url IS NULL) as null_count,
  ROUND(COUNTIF(STARTS_WITH(image_url, 'https://')) * 100.0 / COUNT(*), 2) as https_pct
FROM all_images;


-- ============================================================================
-- CHECK 6: Score Ordering (Monotonic Decrease Within a Row) [I7 CRITICAL]
-- ============================================================================
-- Expected: violations = 0, correct_ordering_pct = 100%.
-- Applies to both audiences (score semantics differ across audiences, but within a
-- row scores must decrease). NULL-slot treatment: a NULL downstream score does not
-- violate ordering.
SELECT
  COUNT(*) as total_users,
  COUNTIF(
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  ) as correctly_ordered,
  COUNTIF(NOT (
    (rec2_score IS NULL OR rec1_score >= rec2_score) AND
    (rec3_score IS NULL OR rec2_score >= rec3_score) AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  )) as violations,
  ROUND(
    COUNTIF(
      (rec2_score IS NULL OR rec1_score >= rec2_score) AND
      (rec3_score IS NULL OR rec2_score >= rec3_score) AND
      (rec4_score IS NULL OR rec3_score >= rec4_score)
    ) * 100.0 / COUNT(*), 2
  ) as correct_ordering_pct
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7: Diversity Filter (max 2 per PartType)
-- ============================================================================
-- Expected: max_same_parttype <= 2
WITH user_recs_long AS (
  SELECT email_lower, REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_1), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') as sku FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_2), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_3), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_4), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
),
user_parttype_counts AS (
  SELECT
    ur.email_lower,
    it.PartType,
    COUNT(*) as parttype_count
  FROM user_recs_long ur
  LEFT JOIN (
    SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(PartNumber)), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') as PartNumber, MAX(PartType) as PartType
    FROM `auxia-gcp.data_company_1950.import_items`
    GROUP BY PartNumber
  ) it ON ur.sku = it.PartNumber
  GROUP BY ur.email_lower, it.PartType
)
SELECT
  MAX(parttype_count) as max_same_parttype,
  COUNTIF(parttype_count > 2) as violations
FROM user_parttype_counts;


-- ============================================================================
-- CHECK 7b: Fitment Count = Filled Slots [I6 CRITICAL] — FITMENT ROWS ONLY
-- ============================================================================
-- Expected: fitment_count is 3 or 4 for fitment rows; must match actual non-null
-- rec_part_* count. Non-fitment rows carry fitment_count=NULL and are excluded here.
SELECT
  'fitment_count_check' AS check_name,
  COUNTIF(fitment_count = 3) AS with_3_recs,
  COUNTIF(fitment_count = 4) AS with_4_recs,
  COUNTIF(fitment_count NOT IN (3, 4)) AS invalid_values,
  COUNTIF(fitment_count = 3 AND rec_part_4 IS NOT NULL) AS miscount_3,
  COUNTIF(fitment_count = 4 AND rec_part_4 IS NULL) AS miscount_4,
  ROUND(AVG(fitment_count), 2) AS avg_fitment_count
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
WHERE rec1_type = 'fitment';


-- ============================================================================
-- CHECK 7c: Engagement Tier Binary Hot/Cold [I10 CRITICAL] — FITMENT ROWS ONLY
-- ============================================================================
-- Expected: only "hot" and "cold", no NULLs, no other values — for fitment rows.
-- Non-fitment rows carry engagement_tier=NULL (V5.19 does not compute a tier) and
-- are excluded here. A NULL engagement_tier in a fitment row is a violation.
SELECT
  'engagement_tier_check' AS check_name,
  COUNTIF(engagement_tier = 'hot') AS hot_users,
  COUNTIF(engagement_tier = 'cold') AS cold_users,
  COUNTIF(engagement_tier IS NULL) AS null_users,
  COUNTIF(engagement_tier NOT IN ('hot', 'cold')) AS invalid_values,
  COUNT(*) AS total_users
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
WHERE rec1_type = 'fitment';


-- ============================================================================
-- CHECK 7d: Allowed rec*_type Vocabulary (shared table)
-- ============================================================================
-- Expected: 0 rows where any rec*_type falls outside {'fitment','non_fitment'}.
-- Replaces the old "no universal products" check with the generalized vocabulary
-- gate — 'universal' was never in the allowed set, and now 'non_fitment' is added.
SELECT
  'allowed_rec_type_vocab' AS check_name,
  COUNTIF(rec1_type NOT IN ('fitment','non_fitment')) AS rec1_invalid,
  COUNTIF(rec2_type IS NOT NULL AND rec2_type NOT IN ('fitment','non_fitment')) AS rec2_invalid,
  COUNTIF(rec3_type IS NOT NULL AND rec3_type NOT IN ('fitment','non_fitment')) AS rec3_invalid,
  COUNTIF(rec4_type IS NOT NULL AND rec4_type NOT IN ('fitment','non_fitment')) AS rec4_invalid,
  CASE WHEN COUNTIF(rec1_type NOT IN ('fitment','non_fitment'))
          + COUNTIF(rec2_type IS NOT NULL AND rec2_type NOT IN ('fitment','non_fitment'))
          + COUNTIF(rec3_type IS NOT NULL AND rec3_type NOT IN ('fitment','non_fitment'))
          + COUNTIF(rec4_type IS NOT NULL AND rec4_type NOT IN ('fitment','non_fitment')) = 0
       THEN 'OK' ELSE 'ERROR: rec*_type outside allowed vocabulary' END AS status
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7e: Category Coverage
-- ============================================================================
-- Expected: >= 400 unique PartTypes
WITH all_skus AS (
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_1), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') AS sku FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_2), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_3), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_4), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNT(DISTINCT cat.PartType) AS unique_part_types,
  CASE WHEN COUNT(DISTINCT cat.PartType) >= 400 THEN 'OK'
       ELSE 'WARNING: Low category coverage'
  END AS status
FROM all_skus s
LEFT JOIN (
  SELECT REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(PartNumber)), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') AS PartNumber, MAX(PartType) AS PartType
  FROM `auxia-gcp.data_company_1950.import_items`
  GROUP BY PartNumber
) cat ON s.sku = cat.PartNumber;


-- ============================================================================
-- CHECK 7f: Authoritative Fitment Match (YMM x SKU) — FITMENT ROWS ONLY
-- ============================================================================
-- Expected: mismatch_rows = 0, users_with_mismatch = 0 for fitment rows.
-- Non-fitment rows (v1_year=v1_make=v1_model='UNKNOWN') are excluded — they have no
-- vehicle to cross-reference against the fitment catalog.
-- Both sides normalize with: (1) BRGP color suffix, (2) explicit finish/packaging suffixes
-- so that e.g. 10416-KIT, 10416-BLK, 10416B all compare as 10416.
WITH recs_long AS (
  SELECT
    email_lower,
    SAFE_CAST(v1_year AS INT64) AS v1_year,
    UPPER(v1_make) AS v1_make,
    UPPER(v1_model) AS v1_model,
    REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_1), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') AS sku
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  WHERE rec1_type = 'fitment'
  UNION ALL
  SELECT email_lower, SAFE_CAST(v1_year AS INT64), UPPER(v1_make), UPPER(v1_model),
    REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_2), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '')
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  WHERE rec1_type = 'fitment'
  UNION ALL
  SELECT email_lower, SAFE_CAST(v1_year AS INT64), UPPER(v1_make), UPPER(v1_model),
    REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_3), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '')
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  WHERE rec1_type = 'fitment'
  UNION ALL
  SELECT email_lower, SAFE_CAST(v1_year AS INT64), UPPER(v1_make), UPPER(v1_model),
    REGEXP_REPLACE(REGEXP_REPLACE(UPPER(rec_part_4), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '')
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  WHERE rec1_type = 'fitment' AND rec_part_4 IS NOT NULL
),
fitment_map AS (
  SELECT DISTINCT
    SAFE_CAST(COALESCE(TRIM(fit.v1_year), CAST(fit.v1_year AS STRING)) AS INT64) AS v1_year,
    UPPER(TRIM(fit.v1_make)) AS v1_make,
    UPPER(TRIM(fit.v1_model)) AS v1_model,
    REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(prod.product_number)), r'([0-9])[BRGP]$', r'\1'), r'(-KIT|-BLK|-POL|-CHR|-RAW)$', '') AS sku
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
)
SELECT
  'fitment_match_check' AS check_name,
  COUNT(*) AS total_rec_rows,
  COUNTIF(f.sku IS NULL) AS mismatch_rows,
  COUNT(DISTINCT IF(
    f.sku IS NULL,
    CONCAT(r.email_lower, '|', CAST(r.v1_year AS STRING), '|', r.v1_make, '|', r.v1_model),
    NULL
  )) AS users_with_mismatch,
  CASE WHEN COUNTIF(f.sku IS NULL) = 0
       THEN 'OK'
       ELSE 'ERROR: Non-fitment recommendations found'
  END AS status
FROM recs_long r
LEFT JOIN fitment_map f
  ON r.v1_year = f.v1_year
 AND r.v1_make = f.v1_make
 AND r.v1_model = f.v1_model
 AND r.sku = f.sku;


-- ============================================================================
-- CHECK 7g: No NULL Gaps Between Filled Slots [I8 CRITICAL]
-- ============================================================================
-- Expected: violations = 0
-- A NULL slot must never be followed by a non-NULL slot.
SELECT
  'no_null_gaps_check' AS check_name,
  COUNTIF(rec_part_2 IS NULL AND rec_part_3 IS NOT NULL) AS gap_at_slot_2,
  COUNTIF(rec_part_3 IS NULL AND rec_part_4 IS NOT NULL) AS gap_at_slot_3,
  COUNTIF(
    (rec_part_2 IS NULL AND rec_part_3 IS NOT NULL) OR
    (rec_part_3 IS NULL AND rec_part_4 IS NOT NULL)
  ) AS total_violations
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7h: No NULL/Empty Images in Filled Slots [I9 CRITICAL]
-- ============================================================================
-- Expected: violations = 0
-- Every non-NULL rec_part_N must have a non-NULL, non-empty image URL.
SELECT
  'no_null_images_check' AS check_name,
  COUNTIF(rec_part_1 IS NOT NULL AND (rec1_image IS NULL OR rec1_image = '')) AS slot1_violations,
  COUNTIF(rec_part_2 IS NOT NULL AND (rec2_image IS NULL OR rec2_image = '')) AS slot2_violations,
  COUNTIF(rec_part_3 IS NOT NULL AND (rec3_image IS NULL OR rec3_image = '')) AS slot3_violations,
  COUNTIF(rec_part_4 IS NOT NULL AND (rec4_image IS NULL OR rec4_image = '')) AS slot4_violations,
  COUNTIF(rec_part_1 IS NOT NULL AND (rec1_image IS NULL OR rec1_image = '')) +
  COUNTIF(rec_part_2 IS NOT NULL AND (rec2_image IS NULL OR rec2_image = '')) +
  COUNTIF(rec_part_3 IS NOT NULL AND (rec3_image IS NULL OR rec3_image = '')) +
  COUNTIF(rec_part_4 IS NOT NULL AND (rec4_image IS NULL OR rec4_image = ''))
  AS total_violations
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7i: Slot 4 Consistency [I11]
-- ============================================================================
-- Expected: violations = 0
-- If rec_part_4 is NULL, all rec4_* fields must also be NULL.
SELECT
  'slot4_consistency_check' AS check_name,
  COUNTIF(
    rec_part_4 IS NULL AND (
      rec4_price IS NOT NULL OR rec4_score IS NOT NULL OR
      rec4_image IS NOT NULL OR rec4_type IS NOT NULL OR
      rec4_pop_source IS NOT NULL
    )
  ) AS violations
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 8: Score Distribution — per audience (score semantics differ)
-- ============================================================================
-- Fitment: popularity tiers (segment/make can exceed 25)
-- Non-fitment: recency-weighted behavior score; bestseller floor ≈ 1.0
SELECT
  rec1_type AS audience,
  MIN(rec1_score) as min_score,
  MAX(rec1_score) as max_score,
  ROUND(AVG(rec1_score), 2) as avg_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(50)] as median_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(95)] as p95_score,
  COUNTIF(rec1_score = 0) as zero_scores,
  COUNTIF(rec1_score < 0) as negative_scores,
  COUNTIF(rec1_score > 25) as above_25_monitor,
  COUNTIF(rec1_score > 40) as above_40_monitor
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
GROUP BY rec1_type;


-- ============================================================================
-- CHECK 9: NULL rec4 Check (acceptable for 3-rec users)
-- ============================================================================
-- `unexpected_null_rec4` uses fitment_count and therefore only makes sense for
-- fitment rows; non-fitment rows carry fitment_count=NULL. NULL rec4 is allowed
-- for non-fitment rows that didn't reach 4 candidates after filters+fallback.
SELECT
  'null_rec4_check' AS check_name,
  COUNTIF(rec_part_4 IS NULL) AS users_with_null_rec4,
  COUNTIF(rec_part_4 IS NOT NULL) AS users_with_rec4,
  COUNT(*) AS total_users,
  ROUND(COUNTIF(rec_part_4 IS NULL) * 100.0 / COUNT(*), 2) AS pct_null_rec4,
  -- Fitment rows only: NULL rec4 must correspond to fitment_count = 3
  COUNTIF(rec1_type = 'fitment' AND rec_part_4 IS NULL AND fitment_count != 3) AS unexpected_null_rec4_fitment
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 10: Single Pipeline Version [V5.19 shared-table invariant]
-- ============================================================================
-- Expected: distinct_versions = 1, value = 'v5.19'. The shared table is stamped
-- with one release tag across every row (locked contract #4).
SELECT
  'single_pipeline_version_check' AS check_name,
  COUNT(DISTINCT pipeline_version) AS distinct_versions,
  ARRAY_AGG(DISTINCT pipeline_version) AS versions_present,
  CASE WHEN COUNT(DISTINCT pipeline_version) = 1
       THEN 'OK' ELSE 'ERROR: multiple pipeline_version values in shared table' END AS status
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 11: Cross-Slot rec*_type Consistency [V5.19 shared-table invariant]
-- ============================================================================
-- Expected: violations = 0. Within a row, every populated rec*_type must equal
-- rec1_type. A row can't have rec1_type='fitment' and rec2_type='non_fitment'.
SELECT
  'cross_slot_type_consistency' AS check_name,
  COUNTIF(rec2_type IS NOT NULL AND rec2_type != rec1_type) AS slot2_mismatch,
  COUNTIF(rec3_type IS NOT NULL AND rec3_type != rec1_type) AS slot3_mismatch,
  COUNTIF(rec4_type IS NOT NULL AND rec4_type != rec1_type) AS slot4_mismatch,
  COUNTIF(
    (rec2_type IS NOT NULL AND rec2_type != rec1_type) OR
    (rec3_type IS NOT NULL AND rec3_type != rec1_type) OR
    (rec4_type IS NOT NULL AND rec4_type != rec1_type)
  ) AS total_violations
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 12: Disjointness — No Email in Both Audiences [V5.19 shared-table invariant]
-- ============================================================================
-- Expected: violations = 0. An email must appear in exactly one audience partition.
SELECT
  'disjoint_audiences_check' AS check_name,
  COUNT(*) AS violations
FROM (
  SELECT email_lower
  FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`
  GROUP BY email_lower
  HAVING COUNT(DISTINCT rec1_type) > 1
);


-- ============================================================================
-- CHECK 13: Non-Fitment YMM Placeholder [V5.19 shared-table invariant]
-- ============================================================================
-- Expected: violations = 0. Non-fitment rows must stamp all three YMM fields as
-- 'UNKNOWN' (locked contract #5). Fitment rows are exempt.
SELECT
  'non_fitment_ymm_placeholder' AS check_name,
  COUNTIF(rec1_type = 'non_fitment' AND v1_year  != 'UNKNOWN') AS bad_year,
  COUNTIF(rec1_type = 'non_fitment' AND v1_make  != 'UNKNOWN') AS bad_make,
  COUNTIF(rec1_type = 'non_fitment' AND v1_model != 'UNKNOWN') AS bad_model,
  COUNTIF(rec1_type = 'non_fitment' AND
          (v1_year != 'UNKNOWN' OR v1_make != 'UNKNOWN' OR v1_model != 'UNKNOWN')) AS total_violations
FROM `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`;
