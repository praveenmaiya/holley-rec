-- Investigation Part 3: Compare recommendation coverage between Nov and Dec
-- Are recommendations being generated for the users who actually purchase?

-- Step 1: Create fitment catalog
CREATE TEMP TABLE fitment_catalog AS
SELECT DISTINCT UPPER(prod.product_number) as sku
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

-- Step 2: Get all VFU users with their vehicle info
CREATE TEMP TABLE vfu_users AS
SELECT DISTINCT
  user_id,
  MAX(CASE WHEN p.property_name = "v1_year" THEN COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)) END) as v1_year,
  MAX(CASE WHEN p.property_name = "v1_make" THEN UPPER(COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING))) END) as v1_make,
  MAX(CASE WHEN p.property_name = "v1_model" THEN UPPER(COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING))) END) as v1_model,
  MAX(CASE WHEN p.property_name = "email" THEN LOWER(TRIM(p.string_value)) END) as email
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
     UNNEST(user_properties) p
WHERE p.property_name IN ("v1_year", "v1_make", "v1_model", "email")
GROUP BY user_id
HAVING v1_year IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL AND email IS NOT NULL;

-- Step 3: Get November buyers
CREATE TEMP TABLE nov_buyers AS
SELECT DISTINCT
  e.user_id,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-11-16") AND DATE("2025-12-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- Step 4: Get December buyers
CREATE TEMP TABLE dec_buyers AS
SELECT DISTINCT
  e.user_id,
  REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.string_value, CAST(p.long_value AS STRING)))), r"([0-9])[BRGP]$", r"\1") as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental` e,
     UNNEST(e.event_properties) p
WHERE e.user_id IN (SELECT user_id FROM vfu_users)
  AND DATE(e.client_event_timestamp) BETWEEN DATE("2025-12-16") AND DATE("2026-01-05")
  AND UPPER(e.event_name) IN ("ORDERED PRODUCT", "PLACED ORDER", "CONSUMER WEBSITE ORDER")
  AND (REGEXP_CONTAINS(LOWER(p.property_name), r'^prod(?:uct)?id$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^items_[0-9]+\.productid$')
    OR REGEXP_CONTAINS(LOWER(p.property_name), r'^skus_[0-9]+$'));

-- Step 5: Check if buyers have matching vehicle in fitment catalog
SELECT
  "November" as month,
  COUNT(DISTINCT nb.user_id) as total_buyers,
  COUNT(DISTINCT CASE WHEN fc.sku IS NOT NULL THEN nb.user_id END) as buyers_with_fitment_match,
  COUNT(DISTINCT nb.sku) as unique_skus_purchased,
  COUNT(DISTINCT CASE WHEN fc.sku IS NOT NULL THEN nb.sku END) as fitment_skus,
  COUNT(DISTINCT CASE WHEN fc.sku IS NULL THEN nb.sku END) as universal_skus
FROM nov_buyers nb
LEFT JOIN fitment_catalog fc ON nb.sku = fc.sku

UNION ALL

SELECT
  "December" as month,
  COUNT(DISTINCT db.user_id) as total_buyers,
  COUNT(DISTINCT CASE WHEN fc.sku IS NOT NULL THEN db.user_id END) as buyers_with_fitment_match,
  COUNT(DISTINCT db.sku) as unique_skus_purchased,
  COUNT(DISTINCT CASE WHEN fc.sku IS NOT NULL THEN db.sku END) as fitment_skus,
  COUNT(DISTINCT CASE WHEN fc.sku IS NULL THEN db.sku END) as universal_skus
FROM dec_buyers db
LEFT JOIN fitment_catalog fc ON db.sku = fc.sku

ORDER BY month;
