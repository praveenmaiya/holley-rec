-- AUX-13883 v2: Summary Metrics
-- Addresses HIGH 6 (rank-weighted metrics), CRITICAL 2 (within-covered analysis), MEDIUM 9 (CSV shape)
-- Run AFTER aux_13883_v2_enrichment.sql

WITH
src AS (
  SELECT * FROM `auxia-reporting.temp_holley_v5_18.david_top_sales_enriched_v2`
),

--------------------------------------------------------------------------------
-- MEDIUM 9: CSV shape stats
--------------------------------------------------------------------------------
csv_shape AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) AS distinct_ymm,
    COUNTIF(RANK = 1) AS ymm_with_rank_1,
    (SELECT COUNT(*) FROM (
      SELECT year, make, model FROM src GROUP BY 1, 2, 3 HAVING COUNT(*) = 5
    )) AS ymm_with_exactly_5_rows,
    (SELECT COUNT(*) FROM (
      SELECT year, make, model FROM src GROUP BY 1, 2, 3 HAVING COUNT(*) < 5
    )) AS ymm_with_fewer_than_5_rows
  FROM src
),

--------------------------------------------------------------------------------
-- HIGH 6: Coverage metrics — exact vs base SKU, overall + rank-weighted
--------------------------------------------------------------------------------
coverage_metrics AS (
  SELECT
    -- Overall exact/base coverage
    SAFE_DIVIDE(COUNTIF(in_recs_exact_sku = 'YES'), COUNT(*)) AS overall_exact_coverage,
    SAFE_DIVIDE(COUNTIF(in_recs_base_sku = 'YES'), COUNT(*)) AS overall_base_coverage,

    -- Top-1 hit rate (rank 1 parts only)
    SAFE_DIVIDE(
      COUNTIF(in_recs_exact_sku = 'YES' AND RANK = 1),
      COUNTIF(RANK = 1)
    ) AS top1_exact_hit_rate,
    SAFE_DIVIDE(
      COUNTIF(in_recs_base_sku = 'YES' AND RANK = 1),
      COUNTIF(RANK = 1)
    ) AS top1_base_hit_rate,

    -- Any-of-top-3 hit rate (per YMM: does any rank 1-3 part appear?)
    (SELECT SAFE_DIVIDE(
      COUNTIF(has_hit),
      COUNT(*)
    ) FROM (
      SELECT
        year, make, model,
        MAX(CASE WHEN RANK <= 3 AND in_recs_base_sku = 'YES' THEN TRUE ELSE FALSE END) AS has_hit
      FROM src
      GROUP BY 1, 2, 3
    )) AS any_top3_base_hit_rate,

    -- Mean hits per covered YMM (among YMMs in final recs)
    (SELECT AVG(hits) FROM (
      SELECT
        year, make, model,
        COUNTIF(in_recs_base_sku = 'YES') AS hits
      FROM src
      WHERE ymm_in_final_recs = 'YES'
      GROUP BY 1, 2, 3
    )) AS mean_hits_per_covered_ymm,

    -- Reciprocal-rank weighted coverage (sum of 1/rank for hits, normalized)
    SAFE_DIVIDE(
      SUM(CASE WHEN in_recs_base_sku = 'YES' THEN 1.0 / RANK ELSE 0 END),
      SUM(1.0 / RANK)
    ) AS reciprocal_rank_weighted_coverage
  FROM src
),

--------------------------------------------------------------------------------
-- CRITICAL 2: Within-covered-YMM analysis
--------------------------------------------------------------------------------
within_covered AS (
  SELECT
    SAFE_DIVIDE(COUNTIF(in_recs_exact_sku = 'YES'), COUNT(*)) AS covered_ymm_exact_coverage,
    SAFE_DIVIDE(COUNTIF(in_recs_base_sku = 'YES'), COUNT(*)) AS covered_ymm_base_coverage,
    SAFE_DIVIDE(
      COUNTIF(in_recs_base_sku = 'YES' AND RANK = 1),
      COUNTIF(RANK = 1)
    ) AS covered_ymm_top1_base_hit_rate
  FROM src
  WHERE ymm_in_final_recs = 'YES'
),

--------------------------------------------------------------------------------
-- CRITICAL 2: Miss reason breakdown
--------------------------------------------------------------------------------
miss_reasons AS (
  SELECT
    miss_reason,
    COUNT(*) AS row_count,
    SAFE_DIVIDE(COUNT(*), (SELECT COUNT(*) FROM src)) AS pct_of_total
  FROM src
  GROUP BY 1
),

--------------------------------------------------------------------------------
-- CRITICAL 1: Universal/fitment classification breakdown
--------------------------------------------------------------------------------
universal_breakdown AS (
  SELECT
    COUNTIF(missing_fitment_mapping = 'YES') AS parts_missing_fitment_mapping,
    COUNTIF(universal_flag_from_catalog = 'YES') AS parts_catalog_universal,
    COUNTIF(missing_fitment_mapping = 'YES' AND universal_flag_from_catalog = 'YES') AS both_missing_and_universal,
    COUNTIF(missing_fitment_mapping = 'YES' AND universal_flag_from_catalog = 'NO') AS missing_but_not_universal,
    COUNTIF(missing_fitment_mapping = 'NO' AND universal_flag_from_catalog = 'YES') AS in_fitment_but_catalog_universal,
    COUNT(*) AS total
  FROM src
),

--------------------------------------------------------------------------------
-- MEDIUM 7: Fitment breadth bucket breakdown
--------------------------------------------------------------------------------
breadth_breakdown AS (
  SELECT
    fitment_breadth_bucket,
    COUNT(*) AS row_count,
    SAFE_DIVIDE(COUNTIF(in_recs_base_sku = 'YES'), COUNT(*)) AS base_coverage_rate,
    SAFE_DIVIDE(COUNT(*), (SELECT COUNT(*) FROM src)) AS pct_of_total
  FROM src
  GROUP BY 1
),

--------------------------------------------------------------------------------
-- HIGH 5: Pipeline funnel stats
--------------------------------------------------------------------------------
funnel_stats AS (
  SELECT
    COUNT(DISTINCT CONCAT(year, '|', make, '|', model)) AS total_ymm_in_sales,
    COUNT(DISTINCT CASE WHEN ymm_in_fitment_map = 'YES'
      THEN CONCAT(year, '|', make, '|', model) END) AS ymm_in_fitment_map,
    COUNT(DISTINCT CASE WHEN ymm_in_eligible_parts = 'YES'
      THEN CONCAT(year, '|', make, '|', model) END) AS ymm_in_eligible_parts,
    COUNT(DISTINCT CASE WHEN ymm_in_final_recs = 'YES'
      THEN CONCAT(year, '|', make, '|', model) END) AS ymm_in_final_recs
  FROM src
)

--------------------------------------------------------------------------------
-- Output all sections
--------------------------------------------------------------------------------
SELECT '=== CSV SHAPE ===' AS section, TO_JSON_STRING(cs) AS data FROM csv_shape cs
UNION ALL
SELECT '=== COVERAGE METRICS ===' AS section, TO_JSON_STRING(cm) AS data FROM coverage_metrics cm
UNION ALL
SELECT '=== WITHIN-COVERED YMM ===' AS section, TO_JSON_STRING(wc) AS data FROM within_covered wc
UNION ALL
SELECT '=== MISS REASONS ===' AS section, TO_JSON_STRING(STRUCT(mr.miss_reason, mr.row_count, mr.pct_of_total)) AS data FROM miss_reasons mr
UNION ALL
SELECT '=== UNIVERSAL BREAKDOWN ===' AS section, TO_JSON_STRING(ub) AS data FROM universal_breakdown ub
UNION ALL
SELECT '=== FITMENT BREADTH ===' AS section, TO_JSON_STRING(STRUCT(bb.fitment_breadth_bucket, bb.row_count, bb.base_coverage_rate, bb.pct_of_total)) AS data FROM breadth_breakdown bb
UNION ALL
SELECT '=== PIPELINE FUNNEL ===' AS section, TO_JSON_STRING(fs) AS data FROM funnel_stats fs
ORDER BY section
;
