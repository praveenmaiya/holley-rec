-- AUX-13883 v2: Improved Cross-Reference Analysis
-- Fixes all 9 Codex review findings (3 CRITICAL, 3 HIGH, 3 MEDIUM)
--
-- CRITICAL 1: Replace is_universal with missing_fitment_mapping + universal_flag_from_catalog + fitment_breadth_bucket
-- CRITICAL 2: Add miss_reason decomposition; rank-weighted metrics in summary query
-- CRITICAL 3: Canonical YMM-level recs (not user-level join)
-- HIGH 4:     Full v5.18 two-stage variant normalization, exact + base SKU matching
-- HIGH 5:     Pipeline stage funnel (fitment_map -> eligible_parts -> final_recs)
-- HIGH 6:     Rank-weighted metrics (in summary query)
-- MEDIUM 7:   Fitment breadth buckets
-- MEDIUM 8:   Time window note: CSV is dated 2026-03-13, sales window unknown.
--             v5.18 uses historical orders Jan 2024 - Aug 2025, recent Sep 2025+.
-- MEDIUM 9:   CSV is "up to 5 ranked products per YMM" (not uniform 5). Shape stats in summary.

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_18.david_top_sales_enriched_v2` AS

WITH

--------------------------------------------------------------------------------
-- Sales data with full v5.18 two-stage normalization (pipeline lines 769-770)
--------------------------------------------------------------------------------
sales AS (
  SELECT
    CAST(YEAR AS STRING) AS year,
    UPPER(TRIM(MAKE)) AS make,
    UPPER(TRIM(MODEL)) AS model,
    UPPER(TRIM(PARTNUMBER)) AS partnumber,
    DESCRIPTION,
    CATEGORY_BU,
    DIVISION,
    RANK,
    REGEXP_REPLACE(
      REGEXP_REPLACE(UPPER(TRIM(PARTNUMBER)), r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
      r'([0-9])[BRGP]$', r'\1'
    ) AS base_partnumber
  FROM `auxia-reporting.temp_holley_v5_18.david_top_sales_by_ymm`
),

--------------------------------------------------------------------------------
-- CRITICAL 3: Canonical YMM-level recs — DISTINCT (YMM, SKU) from production
-- Avoids user-level inflation from multiple users per YMM
--------------------------------------------------------------------------------
canonical_ymm_recs AS (
  SELECT DISTINCT
    CAST(SAFE_CAST(TRIM(CAST(v1_year AS STRING)) AS INT64) AS STRING) AS year,
    UPPER(TRIM(v1_make)) AS make,
    UPPER(TRIM(v1_model)) AS model,
    UPPER(TRIM(rec_part)) AS sku,
    REGEXP_REPLACE(
      REGEXP_REPLACE(UPPER(TRIM(rec_part)), r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
      r'([0-9])[BRGP]$', r'\1'
    ) AS base_sku
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`,
  UNNEST([rec_part_1, rec_part_2, rec_part_3, rec_part_4]) AS rec_part
  WHERE rec_part IS NOT NULL
),

--------------------------------------------------------------------------------
-- Fitment catalog: all YMM-SKU mappings (unnested)
--------------------------------------------------------------------------------
fitment_catalog AS (
  SELECT DISTINCT
    CAST(SAFE_CAST(TRIM(CAST(fit.v1_year AS STRING)) AS INT64) AS STRING) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model,
    UPPER(TRIM(prod.product_number)) AS sku
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
),

--------------------------------------------------------------------------------
-- CRITICAL 1: Parts that exist in fitment catalog for ANY vehicle
-- "missing_fitment_mapping" = part not in catalog at all (catalog gap)
--------------------------------------------------------------------------------
parts_in_fitment AS (
  SELECT DISTINCT UPPER(TRIM(prod.product_number)) AS sku
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
),

--------------------------------------------------------------------------------
-- CRITICAL 1: UniversalPart flag from import_items product catalog
-- This is the authoritative source, not "not in fitment catalog"
--------------------------------------------------------------------------------
universal_flags AS (
  SELECT
    UPPER(TRIM(PartNumber)) AS sku,
    CASE WHEN UniversalPart = 1 THEN TRUE ELSE FALSE END AS is_universal_catalog
  FROM `auxia-gcp.data_company_1950.import_items`
  WHERE PartNumber IS NOT NULL
),

--------------------------------------------------------------------------------
-- CRITICAL 1 + MEDIUM 7: Fitment breadth (make|model combos per product)
-- Distinguishes narrow fitment from broad-fitment generic products
--------------------------------------------------------------------------------
fitment_breadth AS (
  SELECT
    UPPER(TRIM(prod.product_number)) AS sku,
    COUNT(DISTINCT CONCAT(UPPER(TRIM(fit.v1_make)), '|', UPPER(TRIM(fit.v1_model)))) AS fitment_breadth
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
       UNNEST(fit.products) prod
  WHERE prod.product_number IS NOT NULL
  GROUP BY 1
),

--------------------------------------------------------------------------------
-- HIGH 5: Pipeline stage funnel — where do YMMs drop off?
--------------------------------------------------------------------------------

-- Stage 1: YMM exists in fitment map
ymm_in_fitment_map AS (
  SELECT DISTINCT
    CAST(SAFE_CAST(TRIM(CAST(fit.v1_year AS STRING)) AS INT64) AS STRING) AS year,
    UPPER(TRIM(fit.v1_make)) AS make,
    UPPER(TRIM(fit.v1_model)) AS model
  FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit
),

-- Stage 2: YMM has >= 4 eligible parts after pipeline filters
-- Approximates per_generation gate (v5.18 line 385-389)
ymm_in_eligible_parts AS (
  SELECT year, make, model
  FROM (
    SELECT
      CAST(SAFE_CAST(TRIM(CAST(fit.v1_year AS STRING)) AS INT64) AS STRING) AS year,
      UPPER(TRIM(fit.v1_make)) AS make,
      UPPER(TRIM(fit.v1_model)) AS model,
      COUNT(DISTINCT UPPER(TRIM(prod.product_number))) AS part_count
    FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
         UNNEST(fit.products) prod
    LEFT JOIN `auxia-gcp.data_company_1950.import_items` ii
      ON UPPER(TRIM(prod.product_number)) = UPPER(TRIM(ii.PartNumber))
    WHERE prod.product_number IS NOT NULL
      -- Note: price filter omitted here (import_items has no Price column;
      -- pipeline uses sku_prices CTE from order data). This is an approximation.
      AND COALESCE(ii.PartType, '') NOT IN ('Gasket', 'Decal', 'Key', 'Washer', 'Clamp', 'Bolt', 'Cap')
      AND LOWER(COALESCE(ii.Tags, '')) NOT LIKE '%refurbished%'
      AND UPPER(TRIM(prod.product_number)) NOT LIKE 'EXT-%'
      AND UPPER(TRIM(prod.product_number)) NOT LIKE 'GIFT-%'
      AND UPPER(TRIM(prod.product_number)) NOT LIKE 'WARRANTY-%'
      AND UPPER(TRIM(prod.product_number)) NOT LIKE 'SERVICE-%'
      AND UPPER(TRIM(prod.product_number)) NOT LIKE 'PREAUTH-%'
    GROUP BY 1, 2, 3
  )
  WHERE part_count >= 4
),

-- Stage 3: YMM in final production output
ymm_in_final_recs AS (
  SELECT DISTINCT
    CAST(SAFE_CAST(TRIM(CAST(v1_year AS STRING)) AS INT64) AS STRING) AS year,
    UPPER(TRIM(v1_make)) AS make,
    UPPER(TRIM(v1_model)) AS model
  FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
),

--------------------------------------------------------------------------------
-- Main enrichment: join all dimensions
--------------------------------------------------------------------------------
enriched AS (
  SELECT
    s.year,
    s.make,
    s.model,
    s.partnumber,
    s.description,
    s.category_bu,
    s.division,
    s.RANK,
    s.base_partnumber,

    -- CRITICAL 1: Proper universal/fitment classification
    CASE WHEN pf.sku IS NULL THEN 'YES' ELSE 'NO' END AS missing_fitment_mapping,
    CASE WHEN uf.is_universal_catalog = TRUE THEN 'YES' ELSE 'NO' END AS universal_flag_from_catalog,
    CASE WHEN fc.sku IS NOT NULL THEN 'YES' ELSE 'NO' END AS in_fitment_for_this_ymm,
    COALESCE(fb.fitment_breadth, 0) AS fitment_breadth,
    CASE
      WHEN COALESCE(fb.fitment_breadth, 0) = 0 THEN '0_no_mapping'
      WHEN fb.fitment_breadth <= 5 THEN '1_narrow_1_5'
      WHEN fb.fitment_breadth <= 50 THEN '2_moderate_6_50'
      WHEN fb.fitment_breadth <= 500 THEN '3_broad_51_500'
      ELSE '4_universal_500plus'
    END AS fitment_breadth_bucket,

    -- CRITICAL 3 + HIGH 4: Canonical YMM-level matching (exact + base SKU)
    CASE WHEN cr_exact.sku IS NOT NULL THEN 'YES' ELSE 'NO' END AS in_recs_exact_sku,
    CASE WHEN cr_base.base_sku IS NOT NULL THEN 'YES' ELSE 'NO' END AS in_recs_base_sku,

    -- HIGH 5: Pipeline stage funnel
    CASE WHEN yfm.year IS NOT NULL THEN 'YES' ELSE 'NO' END AS ymm_in_fitment_map,
    CASE WHEN yep.year IS NOT NULL THEN 'YES' ELSE 'NO' END AS ymm_in_eligible_parts,
    CASE WHEN yfr.year IS NOT NULL THEN 'YES' ELSE 'NO' END AS ymm_in_final_recs,

    -- CRITICAL 2: MECE miss reason decomposition
    CASE
      WHEN cr_base.base_sku IS NOT NULL THEN 'COVERED'
      WHEN yfr.year IS NULL AND yep.year IS NULL AND yfm.year IS NULL THEN 'YMM_NOT_IN_FITMENT_MAP'
      WHEN yfr.year IS NULL AND yep.year IS NULL AND yfm.year IS NOT NULL THEN 'YMM_INSUFFICIENT_ELIGIBLE_PARTS'
      WHEN yfr.year IS NULL AND yep.year IS NOT NULL THEN 'YMM_NO_USERS_OR_ALL_FILTERED'
      WHEN yfr.year IS NOT NULL AND pf.sku IS NULL THEN 'PRODUCT_NO_FITMENT_MAPPING'
      WHEN yfr.year IS NOT NULL AND fc.sku IS NULL THEN 'PRODUCT_NOT_FITTED_TO_THIS_YMM'
      WHEN yfr.year IS NOT NULL AND fc.sku IS NOT NULL THEN 'PRODUCT_ELIGIBLE_BUT_NOT_SELECTED'
      ELSE 'UNKNOWN'
    END AS miss_reason

  FROM sales s

  -- Exact SKU match in canonical YMM recs
  LEFT JOIN (
    SELECT DISTINCT year, make, model, sku
    FROM canonical_ymm_recs
  ) cr_exact
    ON s.year = cr_exact.year
    AND s.make = cr_exact.make
    AND s.model = cr_exact.model
    AND s.partnumber = cr_exact.sku

  -- Base SKU match in canonical YMM recs (HIGH 4)
  LEFT JOIN (
    SELECT DISTINCT year, make, model, base_sku
    FROM canonical_ymm_recs
  ) cr_base
    ON s.year = cr_base.year
    AND s.make = cr_base.make
    AND s.model = cr_base.model
    AND s.base_partnumber = cr_base.base_sku

  -- Part in fitment catalog for ANY vehicle
  LEFT JOIN parts_in_fitment pf
    ON s.partnumber = pf.sku

  -- Part in fitment catalog for THIS specific YMM
  LEFT JOIN fitment_catalog fc
    ON s.year = fc.year
    AND s.make = fc.make
    AND s.model = fc.model
    AND s.partnumber = fc.sku

  -- Universal flag from catalog
  LEFT JOIN universal_flags uf
    ON s.partnumber = uf.sku

  -- Fitment breadth
  LEFT JOIN fitment_breadth fb
    ON s.partnumber = fb.sku

  -- Pipeline stage funnel
  LEFT JOIN ymm_in_fitment_map yfm
    ON s.year = yfm.year AND s.make = yfm.make AND s.model = yfm.model
  LEFT JOIN ymm_in_eligible_parts yep
    ON s.year = yep.year AND s.make = yep.make AND s.model = yep.model
  LEFT JOIN ymm_in_final_recs yfr
    ON s.year = yfr.year AND s.make = yfr.make AND s.model = yfr.model
)

SELECT * FROM enriched
ORDER BY year, make, model, RANK
;
