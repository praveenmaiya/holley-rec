-- Analyze score distribution: Why are universal products displacing fitment?

-- Create fitment catalog
CREATE TEMP TABLE fitment_catalog AS
SELECT DISTINCT UPPER(prod.product_number) as sku
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data` fit,
     UNNEST(fit.products) prod
WHERE prod.product_number IS NOT NULL;

-- Get popularity scores
CREATE TEMP TABLE popularity AS
SELECT
  REGEXP_REPLACE(UPPER(TRIM(ITEM)), r"([0-9])[BRGP]$", r"\1") as sku,
  ROUND(LOG(1 + COUNT(*)) * 2, 2) as popularity_score
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) >= DATE("2025-04-16")
  AND SAFE.PARSE_DATE("%A, %B %e, %Y", ORDER_DATE) < DATE("2025-12-16")
GROUP BY 1;

-- Get top 500 universal
CREATE TEMP TABLE top500_universal AS
SELECT p.sku, p.popularity_score
FROM popularity p
LEFT JOIN fitment_catalog fc ON p.sku = fc.sku
WHERE fc.sku IS NULL
ORDER BY p.popularity_score DESC
LIMIT 500;

-- Get top 500 fitment
CREATE TEMP TABLE top500_fitment AS
SELECT p.sku, p.popularity_score
FROM popularity p
JOIN fitment_catalog fc ON p.sku = fc.sku
ORDER BY p.popularity_score DESC
LIMIT 500;

-- Compare score distributions
SELECT
  "Top 500 Universal" as product_type,
  COUNT(*) as count,
  ROUND(MIN(popularity_score), 2) as min_score,
  ROUND(AVG(popularity_score), 2) as avg_score,
  ROUND(MAX(popularity_score), 2) as max_score,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(1)], 2) as p25,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(2)], 2) as median,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(3)], 2) as p75
FROM top500_universal

UNION ALL

SELECT
  "Top 500 Fitment" as product_type,
  COUNT(*) as count,
  ROUND(MIN(popularity_score), 2) as min_score,
  ROUND(AVG(popularity_score), 2) as avg_score,
  ROUND(MAX(popularity_score), 2) as max_score,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(1)], 2) as p25,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(2)], 2) as median,
  ROUND(APPROX_QUANTILES(popularity_score, 4)[OFFSET(3)], 2) as p75
FROM top500_fitment;
