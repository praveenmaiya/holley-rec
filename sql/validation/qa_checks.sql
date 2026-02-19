-- Holley Recommendations QA Validation Queries
-- Run these checks after pipeline execution to validate data quality
-- Default dataset: auxia-reporting.temp_holley_v5_18
-- Note: email consent gating is intentionally not enforced in v5.18 pipeline output.

-- ============================================================================
-- QUICK HEALTH CHECK (run first)
-- ============================================================================

-- Health Check Dashboard
WITH
user_count AS (
  SELECT COUNT(*) as total_users
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
),
score_stats AS (
  SELECT
    MIN(rec1_score) as min_score,
    MAX(rec1_score) as max_score,
    ROUND(AVG(rec1_score), 2) as avg_score
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
),
price_stats AS (
  SELECT
    MIN(LEAST(rec1_price, rec2_price, rec3_price)) as min_price,
    MAX(GREATEST(rec1_price, rec2_price, rec3_price, COALESCE(rec4_price, 0))) as max_price,
    ROUND(AVG((rec1_price + rec2_price + rec3_price + COALESCE(rec4_price, 0)) / fitment_count), 2) as avg_price
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
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
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
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
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 2: No Refurbished Items
-- ============================================================================
-- Expected: 0 refurbished SKUs
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNT(*) as total_skus,
  COUNTIF(LOWER(it.Tags) LIKE '%refurbished%') as refurbished_count
FROM all_recommended_skus rs
LEFT JOIN (
  SELECT UPPER(TRIM(PartNumber)) as PartNumber, MAX(Tags) as Tags
  FROM `auxia-gcp.data_company_1950.import_items`
  GROUP BY PartNumber
) it ON rs.sku = it.PartNumber;


-- ============================================================================
-- CHECK 3: No Service SKUs
-- ============================================================================
-- Expected: All counts = 0
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNTIF(sku LIKE 'EXT-%') as ext_count,
  COUNTIF(sku LIKE 'GIFT-%') as gift_count,
  COUNTIF(sku LIKE 'WARRANTY-%') as warranty_count,
  COUNTIF(sku LIKE 'SERVICE-%') as service_count,
  COUNTIF(sku LIKE 'PREAUTH-%') as preauth_count
FROM all_recommended_skus;


-- ============================================================================
-- CHECK 4: Price Filter (>= $50)
-- ============================================================================
-- Expected: min_price >= $50, violations = 0
-- Handles NULL rec4 for 3-rec users
SELECT
  COUNT(*) as total_users,
  MIN(LEAST(rec1_price, rec2_price, rec3_price)) as min_price,
  GREATEST(MAX(rec1_price), MAX(rec2_price), MAX(rec3_price), COALESCE(MAX(rec4_price), 0)) as max_price,
  ROUND(AVG((rec1_price + rec2_price + rec3_price + COALESCE(rec4_price, 0)) / fitment_count), 2) as avg_price,
  COUNTIF(rec1_price < 50 OR rec2_price < 50 OR rec3_price < 50) as below_50_violations_1_3,
  COUNTIF(rec4_price IS NOT NULL AND rec4_price < 50) as below_50_violations_4
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 5: HTTPS Images Only
-- ============================================================================
-- Expected: https_pct = 100%, null_count = 0 for recs 1-3
-- rec4 images may be NULL for 3-rec users
WITH all_images AS (
  SELECT rec1_image as image_url FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT rec2_image FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT rec3_image FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT rec4_image FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` WHERE rec4_image IS NOT NULL
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
-- CHECK 6: Score Ordering (Monotonic Decrease)
-- ============================================================================
-- Expected: correct_ordering_pct = 100%
-- Handles NULL rec4 for 3-rec users
SELECT
  COUNT(*) as total_users,
  COUNTIF(
    rec1_score >= rec2_score AND
    rec2_score >= rec3_score AND
    (rec4_score IS NULL OR rec3_score >= rec4_score)
  ) as correctly_ordered,
  ROUND(
    COUNTIF(rec1_score >= rec2_score AND rec2_score >= rec3_score AND
            (rec4_score IS NULL OR rec3_score >= rec4_score))
    * 100.0 / COUNT(*), 2
  ) as correct_ordering_pct
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7: Diversity Filter (max 2 per PartType)
-- ============================================================================
-- Expected: max_same_parttype <= 2
WITH user_recs_long AS (
  SELECT email_lower, rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_2 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_3 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_4 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
),
user_parttype_counts AS (
  SELECT
    ur.email_lower,
    it.PartType,
    COUNT(*) as parttype_count
  FROM user_recs_long ur
  LEFT JOIN (
    SELECT UPPER(TRIM(PartNumber)) as PartNumber, MAX(PartType) as PartType
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
-- CHECK 7b: Fitment Count Distribution
-- ============================================================================
-- Expected: fitment_count is 3 or 4 for all users
SELECT
  'fitment_count_distribution' AS check_name,
  COUNTIF(fitment_count = 3) AS with_3_recs,
  COUNTIF(fitment_count = 4) AS with_4_recs,
  COUNTIF(fitment_count NOT IN (3, 4)) AS unexpected_count,
  ROUND(AVG(fitment_count), 2) AS avg_fitment_count
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7c: Engagement Tier Distribution
-- ============================================================================
SELECT
  'engagement_tier_distribution' AS check_name,
  COUNTIF(engagement_tier = 'hot') AS hot_users,
  COUNTIF(engagement_tier = 'cold') AS cold_users,
  COUNT(*) AS total_users
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7d: No Universal Products (fitment-only pipeline)
-- ============================================================================
-- Expected: 0 universals across all slots
SELECT
  'no_universals_check' AS check_name,
  COUNTIF(rec1_type = 'universal') AS rec1_universal,
  COUNTIF(rec2_type = 'universal') AS rec2_universal,
  COUNTIF(rec3_type = 'universal') AS rec3_universal,
  COUNTIF(rec4_type IS NOT NULL AND rec4_type = 'universal') AS rec4_universal,
  CASE WHEN COUNTIF(rec1_type = 'universal') + COUNTIF(rec2_type = 'universal') +
            COUNTIF(rec3_type = 'universal') + COUNTIF(rec4_type IS NOT NULL AND rec4_type = 'universal') = 0
       THEN 'OK' ELSE 'ERROR: Universal products found' END AS status
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7e: Category Coverage
-- ============================================================================
-- Expected: >= 400 unique PartTypes
WITH all_skus AS (
  SELECT rec_part_1 AS sku FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` WHERE rec_part_4 IS NOT NULL
)
SELECT
  COUNT(DISTINCT cat.PartType) AS unique_part_types,
  CASE WHEN COUNT(DISTINCT cat.PartType) >= 400 THEN 'OK'
       ELSE 'WARNING: Low category coverage'
  END AS status
FROM all_skus s
LEFT JOIN (
  SELECT UPPER(TRIM(PartNumber)) AS PartNumber, MAX(PartType) AS PartType
  FROM `auxia-gcp.data_company_1950.import_items`
  GROUP BY PartNumber
) cat ON s.sku = cat.PartNumber;


-- ============================================================================
-- CHECK 8: Score Distribution
-- ============================================================================
-- V5.18: Popularity-only scores (segment/make tiers can exceed 25)
SELECT
  MIN(rec1_score) as min_score,
  MAX(rec1_score) as max_score,
  ROUND(AVG(rec1_score), 2) as avg_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(50)] as median_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(95)] as p95_score,
  COUNTIF(rec1_score = 0) as zero_scores,
  COUNTIF(rec1_score < 0) as negative_scores,
  COUNTIF(rec1_score > 25) as above_25_monitor,
  COUNTIF(rec1_score > 40) as above_40_monitor
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 9: NULL rec4 Check (acceptable for 3-rec users)
-- ============================================================================
SELECT
  'null_rec4_check' AS check_name,
  COUNTIF(rec_part_4 IS NULL) AS users_with_null_rec4,
  COUNTIF(rec_part_4 IS NOT NULL) AS users_with_rec4,
  COUNT(*) AS total_users,
  ROUND(COUNTIF(rec_part_4 IS NULL) * 100.0 / COUNT(*), 2) AS pct_null_rec4,
  -- Verify NULL rec4 only for 3-rec users
  COUNTIF(rec_part_4 IS NULL AND fitment_count != 3) AS unexpected_null_rec4
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;
