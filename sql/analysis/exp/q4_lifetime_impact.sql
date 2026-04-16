-- Query 4: Estimate impact on rec coverage - how many current recs would be knocked out by lifetime exclusion?
WITH rec_unnested AS (
  SELECT
    email_lower as email,
    fitment_count,
    rec_slot,
    REGEXP_REPLACE(UPPER(sku), r'([0-9])[BRGP]$', r'\1') as sku_norm
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`,
  UNNEST([
    STRUCT(1 as rec_slot, rec_part_1 as sku),
    STRUCT(2, rec_part_2),
    STRUCT(3, rec_part_3),
    STRUCT(4, rec_part_4)
  ])
  WHERE sku IS NOT NULL AND sku != ''
),
purchases_lifetime AS (
  SELECT DISTINCT
    LOWER(TRIM(SHIP_TO_EMAIL)) as email,
    REGEXP_REPLACE(UPPER(TRIM(ITEM)), r'([0-9])[BRGP]$', r'\1') as sku_norm
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ITEM IS NOT NULL AND TRIM(ITEM) != ''
    AND SHIP_TO_EMAIL IS NOT NULL
),
matched AS (
  SELECT
    r.email,
    r.fitment_count,
    r.rec_slot,
    CASE WHEN p.sku_norm IS NOT NULL THEN 1 ELSE 0 END as is_purchased
  FROM rec_unnested r
  LEFT JOIN purchases_lifetime p ON r.email = p.email AND r.sku_norm = p.sku_norm
),
per_user AS (
  SELECT
    email,
    MAX(fitment_count) as fitment_count,
    SUM(is_purchased) as recs_purchased
  FROM matched
  GROUP BY email
)
SELECT
  COUNT(*) as total_users,
  COUNTIF(recs_purchased > 0) as users_with_any_overlap,
  ROUND(COUNTIF(recs_purchased > 0) * 100.0 / COUNT(*), 2) as pct_users_affected,
  SUM(recs_purchased) as total_rec_overlaps,
  ROUND(AVG(recs_purchased), 3) as avg_recs_purchased_per_user,
  COUNTIF(fitment_count - recs_purchased < 3) as users_dropping_below_3_recs,
  ROUND(COUNTIF(fitment_count - recs_purchased < 3) * 100.0 / COUNT(*), 3) as pct_dropping_below_3
FROM per_user;
