-- Holley Recommendations QA Validation Queries
-- Run these checks after pipeline execution to validate data quality
-- Dataset: auxia-reporting.temp_holley_v5_7

-- ============================================================================
-- QUICK HEALTH CHECK (run first)
-- ============================================================================

-- Health Check Dashboard
WITH
user_count AS (
  SELECT COUNT(*) as total_users
  FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
),
score_stats AS (
  SELECT
    MIN(rec1_score) as min_score,
    MAX(rec1_score) as max_score,
    ROUND(AVG(rec1_score), 2) as avg_score
  FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
),
price_stats AS (
  SELECT
    MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)) as min_price,
    MAX(GREATEST(rec1_price, rec2_price, rec3_price, rec4_price)) as max_price,
    ROUND(AVG((rec1_price + rec2_price + rec3_price + rec4_price) / 4), 2) as avg_price
  FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
),
duplicate_check AS (
  SELECT
    COUNTIF(
      rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
      rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ) as duplicate_users
  FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
)
SELECT
  'USERS' as metric,
  CAST((SELECT total_users FROM user_count) AS STRING) as value,
  '~450K expected' as expected
UNION ALL
SELECT 'SCORE_RANGE', CONCAT(CAST((SELECT min_score FROM score_stats) AS STRING), ' - ', CAST((SELECT max_score FROM score_stats) AS STRING)), '0-90 expected'
UNION ALL
SELECT 'AVG_SCORE', CAST((SELECT avg_score FROM score_stats) AS STRING), '10-25 expected'
UNION ALL
SELECT 'PRICE_RANGE', CONCAT('$', CAST((SELECT min_price FROM price_stats) AS STRING), ' - $', CAST((SELECT max_price FROM price_stats) AS STRING)), '>=$50 required'
UNION ALL
SELECT 'DUPLICATES', CAST((SELECT duplicate_users FROM duplicate_check) AS STRING), '0 required';


-- ============================================================================
-- CHECK 1: No Duplicate SKUs per User
-- ============================================================================
-- Expected: 0 users with duplicate recommendations
SELECT
  COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
    rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
  ) as users_with_duplicates
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 2: No Refurbished Items
-- ============================================================================
-- Expected: 0 refurbished SKUs
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
)
SELECT
  COUNT(*) as total_skus,
  COUNTIF(it.Tags = 'Refurbished') as refurbished_count
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
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
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
SELECT
  COUNT(*) as total_users,
  MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)) as min_price,
  MAX(GREATEST(rec1_price, rec2_price, rec3_price, rec4_price)) as max_price,
  ROUND(AVG((rec1_price + rec2_price + rec3_price + rec4_price) / 4), 2) as avg_price,
  COUNTIF(rec1_price < 50 OR rec2_price < 50 OR rec3_price < 50 OR rec4_price < 50) as below_50_violations
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 5: HTTPS Images Only
-- ============================================================================
-- Expected: https_pct = 100%, null_count = 0
WITH all_images AS (
  SELECT rec1_image as image_url FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT rec2_image FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT rec3_image FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT rec4_image FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
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
SELECT
  COUNT(*) as total_users,
  COUNTIF(
    rec1_score >= rec2_score AND
    rec2_score >= rec3_score AND
    rec3_score >= rec4_score
  ) as correctly_ordered,
  ROUND(
    COUNTIF(rec1_score >= rec2_score AND rec2_score >= rec3_score AND rec3_score >= rec4_score)
    * 100.0 / COUNT(*), 2
  ) as correct_ordering_pct
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`;


-- ============================================================================
-- CHECK 7: Diversity Filter (max 2 per PartType)
-- ============================================================================
-- Expected: max_same_parttype <= 2
WITH user_recs_long AS (
  SELECT email_lower, rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_2 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_3 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_4 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
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
-- CHECK 8: Score Distribution
-- ============================================================================
-- Info: Review score distribution for anomalies
SELECT
  MIN(rec1_score) as min_score,
  MAX(rec1_score) as max_score,
  ROUND(AVG(rec1_score), 2) as avg_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(50)] as median_score,
  COUNTIF(rec1_score = 0) as zero_scores,
  COUNTIF(rec1_score > 0 AND rec1_score <= 12) as popularity_only,
  COUNTIF(rec1_score > 12) as has_intent
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`;
