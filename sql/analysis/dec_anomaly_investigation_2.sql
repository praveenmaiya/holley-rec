-- Investigation Part 2: Are December purchases concentrated in different products?
-- Check overlap between what users buy vs what V5.15 recommends

-- Step 1: Create fitment catalog
CREATE TEMP TABLE fitment_catalog AS
SELECT DISTINCT UPPER(prod.product_number) as sku
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

-- Step 2: Create top 500 universal with order counts
CREATE TEMP TABLE top500_universal AS
SELECT sku, order_count, rank_num FROM (
  SELECT
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r"([0-9])[BRGP]$", r"\1") as sku,
    COUNT(*) as order_count,
    ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) as rank_num
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) >= DATE("2025-04-16")
    AND SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) < DATE("2025-12-16")
  GROUP BY 1
  ORDER BY order_count DESC
  LIMIT 2000
)
WHERE sku NOT IN (SELECT sku FROM fitment_catalog)
LIMIT 500;

-- Step 3: VFU users
CREATE TEMP TABLE vfu_users AS
SELECT DISTINCT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name = "v1_year" AND p.string_value IS NOT NULL;

-- Step 4: November Universal Purchases (only Top 500)
CREATE TEMP TABLE nov_universal_purchases AS
SELECT
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku,
  COUNT(*) as purchase_count
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-11-16") AND DATE("2025-12-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'))
GROUP BY 1;

-- Step 5: December Universal Purchases (only Top 500)
CREATE TEMP TABLE dec_universal_purchases AS
SELECT
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku,
  COUNT(*) as purchase_count
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-12-16") AND DATE("2026-01-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'))
GROUP BY 1;

-- Step 6: Compare top purchased products vs Top 500 rank
SELECT
  "November" as month,
  SUM(np.purchase_count) as total_universal_purchases,
  SUM(CASE WHEN t5.rank_num <= 50 THEN np.purchase_count ELSE 0 END) as in_top50,
  SUM(CASE WHEN t5.rank_num BETWEEN 51 AND 100 THEN np.purchase_count ELSE 0 END) as in_51_100,
  SUM(CASE WHEN t5.rank_num BETWEEN 101 AND 200 THEN np.purchase_count ELSE 0 END) as in_101_200,
  SUM(CASE WHEN t5.rank_num BETWEEN 201 AND 500 THEN np.purchase_count ELSE 0 END) as in_201_500,
  SUM(CASE WHEN t5.rank_num IS NULL THEN np.purchase_count ELSE 0 END) as not_in_top500,
  ROUND(100.0 * SUM(CASE WHEN t5.rank_num <= 50 THEN np.purchase_count ELSE 0 END) / SUM(np.purchase_count), 1) as top50_pct,
  ROUND(100.0 * SUM(CASE WHEN t5.rank_num <= 100 THEN np.purchase_count ELSE 0 END) / SUM(np.purchase_count), 1) as top100_pct
FROM nov_universal_purchases np
LEFT JOIN top500_universal t5 ON np.sku = t5.sku
WHERE np.sku NOT IN (SELECT sku FROM fitment_catalog)

UNION ALL

SELECT
  "December" as month,
  SUM(dp.purchase_count) as total_universal_purchases,
  SUM(CASE WHEN t5.rank_num <= 50 THEN dp.purchase_count ELSE 0 END) as in_top50,
  SUM(CASE WHEN t5.rank_num BETWEEN 51 AND 100 THEN dp.purchase_count ELSE 0 END) as in_51_100,
  SUM(CASE WHEN t5.rank_num BETWEEN 101 AND 200 THEN dp.purchase_count ELSE 0 END) as in_101_200,
  SUM(CASE WHEN t5.rank_num BETWEEN 201 AND 500 THEN dp.purchase_count ELSE 0 END) as in_201_500,
  SUM(CASE WHEN t5.rank_num IS NULL THEN dp.purchase_count ELSE 0 END) as not_in_top500,
  ROUND(100.0 * SUM(CASE WHEN t5.rank_num <= 50 THEN dp.purchase_count ELSE 0 END) / SUM(dp.purchase_count), 1) as top50_pct,
  ROUND(100.0 * SUM(CASE WHEN t5.rank_num <= 100 THEN dp.purchase_count ELSE 0 END) / SUM(dp.purchase_count), 1) as top100_pct
FROM dec_universal_purchases dp
LEFT JOIN top500_universal t5 ON dp.sku = t5.sku
WHERE dp.sku NOT IN (SELECT sku FROM fitment_catalog)

ORDER BY month;
