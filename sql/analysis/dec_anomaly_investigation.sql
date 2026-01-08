-- Investigation: Why is December showing only +16% improvement vs +221-461% in other months?

-- Step 1: Create fitment catalog first
CREATE TEMP TABLE fitment_catalog AS
SELECT DISTINCT UPPER(prod.product_number) as sku
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

-- Step 2: Create top 2000 products by order count
CREATE TEMP TABLE all_popular AS
SELECT
  REGEXP_REPLACE(UPPER(TRIM(ITEM)), r"([0-9])[BRGP]$", r"\1") as sku,
  COUNT(*) as order_count
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) >= DATE("2025-04-16")
  AND SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) < DATE("2025-12-16")
GROUP BY 1
ORDER BY order_count DESC
LIMIT 2000;

-- Step 3: Filter to get top 500 universal (not in fitment)
CREATE TEMP TABLE top500_universal AS
SELECT ap.sku FROM all_popular ap
LEFT JOIN fitment_catalog fc ON ap.sku = fc.sku
WHERE fc.sku IS NULL
ORDER BY ap.order_count DESC
LIMIT 500;

-- Step 4: VFU users
CREATE TEMP TABLE vfu_users AS
SELECT DISTINCT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name = "v1_year" AND p.string_value IS NOT NULL;

-- Step 5: November purchases
CREATE TEMP TABLE nov_purch AS
SELECT
  "November" as month,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-11-16") AND DATE("2025-12-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- Step 6: December purchases
CREATE TEMP TABLE dec_purch AS
SELECT
  "December" as month,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-12-16") AND DATE("2026-01-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- Step 7: Combine and classify
SELECT
  ap.month,
  COUNT(*) as total,
  COUNTIF(fc.sku IS NOT NULL) as fitment,
  COUNTIF(fc.sku IS NULL AND t5.sku IS NOT NULL) as top500_univ,
  COUNTIF(fc.sku IS NULL AND t5.sku IS NULL) as longtail,
  ROUND(100.0 * COUNTIF(fc.sku IS NOT NULL) / COUNT(*), 1) as fitment_pct,
  ROUND(100.0 * COUNTIF(fc.sku IS NULL AND t5.sku IS NOT NULL) / COUNT(*), 1) as top500_pct,
  ROUND(100.0 * COUNTIF(fc.sku IS NULL AND t5.sku IS NULL) / COUNT(*), 1) as longtail_pct
FROM (
  SELECT * FROM nov_purch UNION ALL SELECT * FROM dec_purch
) ap
LEFT JOIN fitment_catalog fc ON ap.sku = fc.sku
LEFT JOIN top500_universal t5 ON ap.sku = t5.sku
GROUP BY ap.month
ORDER BY ap.month;
