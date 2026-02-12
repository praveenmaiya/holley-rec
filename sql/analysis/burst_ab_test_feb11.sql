-- ============================================================
-- A/B Burst Campaign Analysis — Feb 11, 2026
-- Arm A: 29113222 (MSD Highlight)
-- Arm B: 29113227 (Personalized Vehicle Fitment Recs)
-- Run: bq query --use_legacy_sql=false < sql/analysis/burst_ab_test_feb11.sql
-- ============================================================

-- Q1: Engagement Summary (Open Rate, CTR)
SELECT
  s.treatment_id,
  CASE s.treatment_id
    WHEN 29113222 THEN 'A: MSD Highlight'
    WHEN 29113227 THEN 'B: Personalized Fitment'
  END AS arm,
  COUNT(DISTINCT s.treatment_tracking_id) AS sends,
  COUNT(DISTINCT s.user_id) AS unique_users,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN s.treatment_tracking_id END) AS opens,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.treatment_tracking_id END) AS clicks,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN s.treatment_tracking_id END),
    COUNT(DISTINCT s.treatment_tracking_id)
  ) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.treatment_tracking_id END),
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN s.treatment_tracking_id END)
  ) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.treatment_tracking_id END),
    COUNT(DISTINCT s.treatment_tracking_id)
  ) * 100, 2) AS ctr_of_sends_pct
FROM `auxia-gcp.company_1950.treatment_history_sent` s
LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
  ON s.treatment_tracking_id = i.treatment_tracking_id
WHERE DATE(s.treatment_sent_timestamp) = '2026-02-11'
  AND s.treatment_id IN (29113222, 29113227)
GROUP BY 1, 2
ORDER BY 1;

-- Q2: Hourly engagement curve (when are opens/clicks coming in?)
SELECT
  s.treatment_id,
  CASE s.treatment_id
    WHEN 29113222 THEN 'A: MSD Highlight'
    WHEN 29113227 THEN 'B: Personalized Fitment'
  END AS arm,
  EXTRACT(HOUR FROM i.interaction_timestamp_micros) AS hour_utc,
  i.interaction_type,
  COUNT(DISTINCT s.treatment_tracking_id) AS unique_events
FROM `auxia-gcp.company_1950.treatment_history_sent` s
INNER JOIN `auxia-gcp.company_1950.treatment_interaction` i
  ON s.treatment_tracking_id = i.treatment_tracking_id
WHERE DATE(s.treatment_sent_timestamp) = '2026-02-11'
  AND s.treatment_id IN (29113222, 29113227)
  AND i.interaction_type IN ('VIEWED', 'CLICKED')
GROUP BY 1, 2, 3, 4
ORDER BY 1, 3, 4;

-- Q3: Revenue attribution (orders from burst recipients within 24h)
SELECT
  s.treatment_id,
  CASE s.treatment_id
    WHEN 29113222 THEN 'A: MSD Highlight'
    WHEN 29113227 THEN 'B: Personalized Fitment'
  END AS arm,
  COUNT(DISTINCT s.user_id) AS users_sent,
  COUNT(DISTINCT clickers.user_id) AS users_clicked,
  COUNT(DISTINCT buyers.external_user_id) AS users_ordered,
  COUNT(DISTINCT buyers.order_id) AS total_orders,
  ROUND(SUM(buyers.total), 2) AS total_revenue,
  ROUND(SAFE_DIVIDE(SUM(buyers.total), COUNT(DISTINCT buyers.order_id)), 2) AS aov,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT buyers.external_user_id),
    COUNT(DISTINCT clickers.user_id)
  ) * 100, 2) AS click_to_order_pct,
  ROUND(SAFE_DIVIDE(SUM(buyers.total), COUNT(DISTINCT s.user_id)), 2) AS revenue_per_user
FROM `auxia-gcp.company_1950.treatment_history_sent` s
-- Get clickers
LEFT JOIN (
  SELECT DISTINCT s2.user_id
  FROM `auxia-gcp.company_1950.treatment_history_sent` s2
  JOIN `auxia-gcp.company_1950.treatment_interaction` i2
    ON s2.treatment_tracking_id = i2.treatment_tracking_id
  WHERE DATE(s2.treatment_sent_timestamp) = '2026-02-11'
    AND s2.treatment_id IN (29113222, 29113227)
    AND i2.interaction_type = 'CLICKED'
) clickers ON s.user_id = clickers.user_id
-- Get post-send orders (within 24h window)
LEFT JOIN `auxia-gcp.data_company_1950.import_orders` buyers
  ON s.user_id = buyers.external_user_id
  AND buyers.order_date >= s.treatment_sent_timestamp
  AND buyers.order_date < TIMESTAMP_ADD(s.treatment_sent_timestamp, INTERVAL 24 HOUR)
WHERE DATE(s.treatment_sent_timestamp) = '2026-02-11'
  AND s.treatment_id IN (29113222, 29113227)
GROUP BY 1, 2
ORDER BY 1;

-- Q4: Statistical significance check (z-test for CTR difference)
WITH stats AS (
  SELECT
    s.treatment_id,
    COUNT(DISTINCT s.treatment_tracking_id) AS n,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.treatment_tracking_id END) AS clicks,
    SAFE_DIVIDE(
      COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.treatment_tracking_id END),
      COUNT(DISTINCT s.treatment_tracking_id)
    ) AS p
  FROM `auxia-gcp.company_1950.treatment_history_sent` s
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON s.treatment_tracking_id = i.treatment_tracking_id
  WHERE DATE(s.treatment_sent_timestamp) = '2026-02-11'
    AND s.treatment_id IN (29113222, 29113227)
  GROUP BY 1
)
SELECT
  a.treatment_id AS arm_a_id,
  b.treatment_id AS arm_b_id,
  a.n AS a_sends, a.clicks AS a_clicks, ROUND(a.p * 100, 3) AS a_ctr_pct,
  b.n AS b_sends, b.clicks AS b_clicks, ROUND(b.p * 100, 3) AS b_ctr_pct,
  ROUND((b.p - a.p) * 100, 3) AS lift_pp,
  ROUND(SAFE_DIVIDE(b.p - a.p,
    SQRT(a.p*(1-a.p)/a.n + b.p*(1-b.p)/b.n)
  ), 3) AS z_score,
  CASE
    WHEN ABS(SAFE_DIVIDE(b.p - a.p,
      SQRT(a.p*(1-a.p)/a.n + b.p*(1-b.p)/b.n))) >= 2.576 THEN 'YES (p<0.01)'
    WHEN ABS(SAFE_DIVIDE(b.p - a.p,
      SQRT(a.p*(1-a.p)/a.n + b.p*(1-b.p)/b.n))) >= 1.96 THEN 'YES (p<0.05)'
    ELSE 'NO'
  END AS significant
FROM stats a, stats b
WHERE a.treatment_id = 29113222
  AND b.treatment_id = 29113227;
