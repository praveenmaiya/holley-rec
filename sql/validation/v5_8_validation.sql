-- V5.8 User-Centric Recommendations Validation
-- Run after v5_8_vehicle_fitment_recommendations.sql to validate output
-- Dataset: auxia-reporting.temp_holley_v5_8

-- ============================================================================
-- SECTION 1: HEALTH DASHBOARD (Run First)
-- ============================================================================

-- Quick Health Check - All critical metrics in one view
WITH
user_count AS (
  SELECT COUNT(*) as total_users
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
),
tier_distribution AS (
  SELECT
    COUNTIF(rec1_tier = 'fitment') as slot1_fitment,
    COUNTIF(rec1_tier = 'segment_popular') as slot1_segment,
    COUNTIF(rec2_tier = 'fitment') as slot2_fitment,
    COUNTIF(rec2_tier = 'segment_popular') as slot2_segment,
    COUNTIF(rec3_tier = 'segment_popular') as slot3_segment,
    COUNTIF(rec4_tier = 'segment_popular') as slot4_segment
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
),
score_stats AS (
  SELECT
    MIN(rec1_score) as min_score,
    MAX(rec1_score) as max_score,
    ROUND(AVG(rec1_score), 2) as avg_score
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
),
price_stats AS (
  SELECT
    MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)) as min_price,
    MAX(GREATEST(rec1_price, rec2_price, rec3_price, rec4_price)) as max_price
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
),
duplicate_check AS (
  SELECT
    COUNTIF(
      rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
      rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
    ) as duplicate_users
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
)
SELECT
  'USERS' as metric,
  CAST((SELECT total_users FROM user_count) AS STRING) as value,
  '~450K expected' as expected,
  CASE WHEN (SELECT total_users FROM user_count) >= 400000 THEN 'PASS' ELSE 'FAIL' END as status
UNION ALL
SELECT 'MIN_PRICE',
  CONCAT('$', CAST((SELECT min_price FROM price_stats) AS STRING)),
  '>=$50 required',
  CASE WHEN (SELECT min_price FROM price_stats) >= 50 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'DUPLICATES',
  CAST((SELECT duplicate_users FROM duplicate_check) AS STRING),
  '0 required',
  CASE WHEN (SELECT duplicate_users FROM duplicate_check) = 0 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'SLOT1_FITMENT_PCT',
  CONCAT(CAST(ROUND((SELECT slot1_fitment FROM tier_distribution) * 100.0 / (SELECT total_users FROM user_count), 1) AS STRING), '%'),
  '>80% expected',
  CASE WHEN (SELECT slot1_fitment FROM tier_distribution) * 100.0 / (SELECT total_users FROM user_count) >= 80 THEN 'PASS' ELSE 'WARN' END
UNION ALL
SELECT 'SLOT3_SEGMENT_PCT',
  CONCAT(CAST(ROUND((SELECT slot3_segment FROM tier_distribution) * 100.0 / (SELECT total_users FROM user_count), 1) AS STRING), '%'),
  '>80% expected',
  CASE WHEN (SELECT slot3_segment FROM tier_distribution) * 100.0 / (SELECT total_users FROM user_count) >= 80 THEN 'PASS' ELSE 'WARN' END;


-- ============================================================================
-- SECTION 2: TIERED SLOT DISTRIBUTION (v5.8 Specific)
-- ============================================================================

-- Verify slots 1-2 are primarily fitment tier, slots 3-4 are segment_popular
SELECT
  'rec1' as slot,
  COUNTIF(rec1_tier = 'fitment') as fitment_count,
  COUNTIF(rec1_tier = 'segment_popular') as segment_popular_count,
  ROUND(COUNTIF(rec1_tier = 'fitment') * 100.0 / COUNT(*), 1) as fitment_pct
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
UNION ALL
SELECT
  'rec2',
  COUNTIF(rec2_tier = 'fitment'),
  COUNTIF(rec2_tier = 'segment_popular'),
  ROUND(COUNTIF(rec2_tier = 'fitment') * 100.0 / COUNT(*), 1)
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
UNION ALL
SELECT
  'rec3',
  COUNTIF(rec3_tier = 'fitment'),
  COUNTIF(rec3_tier = 'segment_popular'),
  ROUND(COUNTIF(rec3_tier = 'segment_popular') * 100.0 / COUNT(*), 1)
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
UNION ALL
SELECT
  'rec4',
  COUNTIF(rec4_tier = 'fitment'),
  COUNTIF(rec4_tier = 'segment_popular'),
  ROUND(COUNTIF(rec4_tier = 'segment_popular') * 100.0 / COUNT(*), 1)
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
ORDER BY slot;


-- ============================================================================
-- SECTION 3: 1969 CAMARO SANITY CHECK
-- ============================================================================

-- LFRB155 (the problematic broad-fit headlight) should NOT be top recommendation
-- for 1969 Camaro users anymore
WITH camaro_1969_users AS (
  SELECT
    email_lower,
    rec_part_1,
    rec_part_2,
    rec_part_3,
    rec_part_4,
    rec1_tier,
    rec1_score
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  WHERE v1_year = '1969'
    AND UPPER(v1_make) = 'CHEVROLET'
    AND UPPER(v1_model) LIKE '%CAMARO%'
)
SELECT
  COUNT(*) as total_1969_camaro_users,
  COUNTIF(rec_part_1 = 'LFRB155') as lfrb155_as_top_rec,
  COUNTIF(rec_part_1 = 'LFRB155' OR rec_part_2 = 'LFRB155' OR
          rec_part_3 = 'LFRB155' OR rec_part_4 = 'LFRB155') as lfrb155_in_any_slot,
  ROUND(COUNTIF(rec_part_1 = 'LFRB155') * 100.0 / NULLIF(COUNT(*), 0), 1) as lfrb155_top_pct,
  CASE
    WHEN COUNTIF(rec_part_1 = 'LFRB155') = 0 THEN 'PASS - LFRB155 not in slot 1'
    WHEN COUNTIF(rec_part_1 = 'LFRB155') < COUNT(*) * 0.1 THEN 'WARN - LFRB155 < 10% of slot 1'
    ELSE 'FAIL - LFRB155 still dominating slot 1'
  END as status
FROM camaro_1969_users;

-- Show top recommendations for 1969 Camaro (should be vehicle-specific parts)
SELECT
  rec_part_1 as sku,
  COUNT(*) as user_count,
  MIN(rec1_tier) as tier
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
WHERE v1_year = '1969'
  AND UPPER(v1_make) = 'CHEVROLET'
  AND UPPER(v1_model) LIKE '%CAMARO%'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;


-- ============================================================================
-- SECTION 4: RECOMMENDATION DIVERSITY (v5.8 vs v5.7 Comparison)
-- ============================================================================

-- Count unique SKUs recommended - v5.8 should have MORE diversity
WITH v58_skus AS (
  SELECT DISTINCT sku FROM (
    SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  )
),
v57_skus AS (
  SELECT DISTINCT sku FROM (
    SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
    UNION DISTINCT
    SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`
  )
)
SELECT
  'v5.7' as version,
  (SELECT COUNT(*) FROM v57_skus) as unique_skus,
  NULL as improvement
UNION ALL
SELECT
  'v5.8',
  (SELECT COUNT(*) FROM v58_skus),
  CONCAT('+', CAST((SELECT COUNT(*) FROM v58_skus) - (SELECT COUNT(*) FROM v57_skus) AS STRING), ' SKUs')
ORDER BY version;

-- Top 20 most recommended SKUs - check for concentration
SELECT
  rec_part_1 as sku,
  COUNT(*) as times_recommended,
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`), 2) as pct_of_users
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
GROUP BY 1
ORDER BY 2 DESC
LIMIT 20;


-- ============================================================================
-- SECTION 5: FITMENT BREADTH COMPARISON
-- ============================================================================

-- v5.8 should recommend narrower-fit products than v5.7
WITH v58_fitment AS (
  SELECT
    r.rec_part_1 as sku,
    COUNT(DISTINCT CONCAT(f.Year, '-', f.Make, '-', f.Model)) as vehicles_fit
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations` r
  LEFT JOIN `auxia-gcp.data_company_1950.vehicle_product_fitment_data` f
    ON r.rec_part_1 = UPPER(TRIM(f.SKU))
  GROUP BY 1
),
v57_fitment AS (
  SELECT
    r.rec_part_1 as sku,
    COUNT(DISTINCT CONCAT(f.Year, '-', f.Make, '-', f.Model)) as vehicles_fit
  FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations` r
  LEFT JOIN `auxia-gcp.data_company_1950.vehicle_product_fitment_data` f
    ON r.rec_part_1 = UPPER(TRIM(f.SKU))
  GROUP BY 1
)
SELECT
  'v5.7' as version,
  ROUND(AVG(vehicles_fit), 0) as avg_vehicles_fit,
  APPROX_QUANTILES(vehicles_fit, 100)[OFFSET(50)] as median_vehicles_fit,
  MAX(vehicles_fit) as max_vehicles_fit
FROM v57_fitment
UNION ALL
SELECT
  'v5.8',
  ROUND(AVG(vehicles_fit), 0),
  APPROX_QUANTILES(vehicles_fit, 100)[OFFSET(50)],
  MAX(vehicles_fit)
FROM v58_fitment
ORDER BY version;


-- ============================================================================
-- SECTION 6: SEGMENT RELEVANCE SCORE
-- ============================================================================

-- Primary success metric: Do recommendations match what the segment actually buys?
-- Compare rec1_part against actual segment purchase patterns
WITH user_segments AS (
  SELECT
    email_lower,
    CONCAT(v1_year, '-', UPPER(v1_make), '-', UPPER(v1_model)) as segment,
    rec_part_1
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
),
segment_purchases AS (
  SELECT
    CONCAT(ua.Year, '-', UPPER(ua.Make), '-', UPPER(ua.Model)) as segment,
    UPPER(TRIM(o.ProductID)) as sku,
    COUNT(*) as purchase_count
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` ua
  JOIN `auxia-gcp.data_company_1950.import_orders` o
    ON LOWER(TRIM(ua.email)) = LOWER(TRIM(o.Email))
  WHERE o.OrderDate >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
    AND ua.Year IS NOT NULL
    AND ua.Make IS NOT NULL
  GROUP BY 1, 2
  HAVING COUNT(*) >= 5  -- Minimum 5 purchases to count
)
SELECT
  COUNT(*) as total_users,
  COUNTIF(sp.sku IS NOT NULL) as rec_matches_segment_purchase,
  ROUND(COUNTIF(sp.sku IS NOT NULL) * 100.0 / COUNT(*), 2) as segment_relevance_pct,
  CASE
    WHEN COUNTIF(sp.sku IS NOT NULL) * 100.0 / COUNT(*) >= 30 THEN 'GOOD - 30%+ relevance'
    WHEN COUNTIF(sp.sku IS NOT NULL) * 100.0 / COUNT(*) >= 15 THEN 'OK - 15-30% relevance'
    ELSE 'LOW - <15% relevance'
  END as status
FROM user_segments us
LEFT JOIN segment_purchases sp
  ON us.segment = sp.segment AND us.rec_part_1 = sp.sku;


-- ============================================================================
-- SECTION 7: STANDARD QA CHECKS (reused from v5.7)
-- ============================================================================

-- CHECK 1: No Duplicate SKUs per User
SELECT
  COUNTIF(
    rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
    rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
    rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
  ) as users_with_duplicates,
  CASE
    WHEN COUNTIF(rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
                 rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
                 rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4) = 0
    THEN 'PASS' ELSE 'FAIL'
  END as status
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`;


-- CHECK 2: No Refurbished Items
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
)
SELECT
  COUNT(*) as total_skus,
  COUNTIF(it.Tags = 'Refurbished') as refurbished_count,
  CASE WHEN COUNTIF(it.Tags = 'Refurbished') = 0 THEN 'PASS' ELSE 'FAIL' END as status
FROM all_recommended_skus rs
LEFT JOIN (
  SELECT UPPER(TRIM(PartNumber)) as PartNumber, MAX(Tags) as Tags
  FROM `auxia-gcp.data_company_1950.import_items`
  GROUP BY PartNumber
) it ON rs.sku = it.PartNumber;


-- CHECK 3: No Service SKUs
WITH all_recommended_skus AS (
  SELECT rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_2 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_3 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION DISTINCT
  SELECT rec_part_4 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
)
SELECT
  COUNTIF(sku LIKE 'EXT-%') as ext_count,
  COUNTIF(sku LIKE 'GIFT-%') as gift_count,
  COUNTIF(sku LIKE 'WARRANTY-%') as warranty_count,
  COUNTIF(sku LIKE 'SERVICE-%') as service_count,
  COUNTIF(sku LIKE 'PREAUTH-%') as preauth_count,
  CASE
    WHEN COUNTIF(sku LIKE 'EXT-%') + COUNTIF(sku LIKE 'GIFT-%') +
         COUNTIF(sku LIKE 'WARRANTY-%') + COUNTIF(sku LIKE 'SERVICE-%') +
         COUNTIF(sku LIKE 'PREAUTH-%') = 0
    THEN 'PASS' ELSE 'FAIL'
  END as status
FROM all_recommended_skus;


-- CHECK 4: Price Filter (>= $50)
SELECT
  COUNT(*) as total_users,
  MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)) as min_price,
  MAX(GREATEST(rec1_price, rec2_price, rec3_price, rec4_price)) as max_price,
  COUNTIF(rec1_price < 50 OR rec2_price < 50 OR rec3_price < 50 OR rec4_price < 50) as below_50_violations,
  CASE
    WHEN COUNTIF(rec1_price < 50 OR rec2_price < 50 OR rec3_price < 50 OR rec4_price < 50) = 0
    THEN 'PASS' ELSE 'FAIL'
  END as status
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`;


-- CHECK 5: HTTPS Images Only
WITH all_images AS (
  SELECT rec1_image as image_url FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT rec2_image FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT rec3_image FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT rec4_image FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
)
SELECT
  COUNT(*) as total_images,
  COUNTIF(STARTS_WITH(image_url, 'https://')) as https_count,
  COUNTIF(NOT STARTS_WITH(image_url, 'https://') AND image_url IS NOT NULL) as non_https_count,
  COUNTIF(image_url IS NULL) as null_count,
  ROUND(COUNTIF(STARTS_WITH(image_url, 'https://')) * 100.0 / COUNT(*), 2) as https_pct,
  CASE
    WHEN COUNTIF(NOT STARTS_WITH(image_url, 'https://') AND image_url IS NOT NULL) = 0
    THEN 'PASS' ELSE 'FAIL'
  END as status
FROM all_images;


-- CHECK 6: Score Ordering (Monotonic Decrease)
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
  ) as correct_ordering_pct,
  CASE
    WHEN COUNTIF(rec1_score >= rec2_score AND rec2_score >= rec3_score AND rec3_score >= rec4_score) = COUNT(*)
    THEN 'PASS' ELSE 'WARN - some out of order (may be OK for tiered)'
  END as status
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`;


-- CHECK 7: Diversity Filter (max 2 per PartType)
WITH user_recs_long AS (
  SELECT email_lower, rec_part_1 as sku FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_2 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_3 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  UNION ALL
  SELECT email_lower, rec_part_4 FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
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
  COUNTIF(parttype_count > 2) as violations,
  CASE WHEN MAX(parttype_count) <= 2 THEN 'PASS' ELSE 'FAIL' END as status
FROM user_parttype_counts;


-- ============================================================================
-- SECTION 8: SCORE COMPONENT ANALYSIS (v5.8 Specific)
-- ============================================================================

-- Analyze score composition to verify new scoring is working
SELECT
  ROUND(AVG(rec1_score), 2) as avg_total_score,
  MIN(rec1_score) as min_score,
  MAX(rec1_score) as max_score,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(25)] as p25,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(50)] as median,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(75)] as p75,
  APPROX_QUANTILES(rec1_score, 100)[OFFSET(95)] as p95
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`;


-- ============================================================================
-- SUMMARY: ALL CHECKS IN ONE VIEW
-- ============================================================================

-- Run this to get a quick pass/fail summary of all checks
WITH checks AS (
  SELECT 'User Count' as check_name,
    CASE WHEN COUNT(*) >= 400000 THEN 'PASS' ELSE 'FAIL' END as status
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`

  UNION ALL

  SELECT 'No Duplicates',
    CASE WHEN COUNTIF(rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR
                      rec_part_1 = rec_part_4 OR rec_part_2 = rec_part_3 OR
                      rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4) = 0
         THEN 'PASS' ELSE 'FAIL' END
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`

  UNION ALL

  SELECT 'Price >= $50',
    CASE WHEN COUNTIF(rec1_price < 50 OR rec2_price < 50 OR
                      rec3_price < 50 OR rec4_price < 50) = 0
         THEN 'PASS' ELSE 'FAIL' END
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`

  UNION ALL

  SELECT 'Slot1 Fitment Tier',
    CASE WHEN COUNTIF(rec1_tier = 'fitment') * 100.0 / COUNT(*) >= 70
         THEN 'PASS' ELSE 'WARN' END
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`

  UNION ALL

  SELECT 'Slot3 Segment Tier',
    CASE WHEN COUNTIF(rec3_tier = 'segment_popular') * 100.0 / COUNT(*) >= 70
         THEN 'PASS' ELSE 'WARN' END
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
)
SELECT * FROM checks
ORDER BY
  CASE status
    WHEN 'FAIL' THEN 1
    WHEN 'WARN' THEN 2
    ELSE 3
  END,
  check_name;
