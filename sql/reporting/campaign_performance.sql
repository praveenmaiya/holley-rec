-- ============================================================================
-- HOLLEY EMAIL CAMPAIGN PERFORMANCE QUERIES
-- Campaign: Post-Purchase Recommendations (Dec 4, 2025+)
-- Surface ID: 929
-- ============================================================================

-- ============================================================================
-- 1. OVERALL FUNNEL: High-level campaign metrics
-- ============================================================================
WITH delivery AS (
  SELECT
    COUNT(*) as total_attempted,
    COUNTIF(delivery_status = 'DELIVERY_SUCCESSFUL') as delivered,
    COUNTIF(delivery_status = 'DELIVERY_FAILED') as failed
  FROM `auxia-gcp.company_1950.treatment_delivery_result_for_batch_decision`
  WHERE DATE(treatment_delivery_timestamp) >= '2025-12-04'
),
sent AS (
  SELECT COUNT(DISTINCT user_id) as unique_users_sent
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) >= '2025-12-04'
),
opens AS (
  SELECT
    COUNT(*) as total_opens,
    COUNT(DISTINCT user_id) as unique_users_opened
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
clicks AS (
  SELECT
    COUNT(*) as total_clicks,
    COUNT(DISTINCT user_id) as unique_users_clicked
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
)
SELECT
  d.total_attempted,
  d.delivered,
  d.failed,
  ROUND(100.0 * d.failed / d.total_attempted, 2) as failure_rate_pct,
  s.unique_users_sent,
  o.unique_users_opened,
  ROUND(100.0 * o.unique_users_opened / s.unique_users_sent, 2) as open_rate_pct,
  o.total_opens,
  c.unique_users_clicked,
  ROUND(100.0 * c.unique_users_clicked / o.unique_users_opened, 2) as click_thru_rate_pct,
  c.total_clicks
FROM delivery d, sent s, opens o, clicks c;


-- ============================================================================
-- 2. FUNNEL BY TREATMENT: Breakdown per treatment_id
-- ============================================================================
WITH sent AS (
  SELECT
    treatment_id,
    COUNT(*) as emails_sent,
    COUNT(DISTINCT user_id) as users_sent
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) >= '2025-12-04'
  GROUP BY 1
),
opens AS (
  SELECT
    treatment_id,
    COUNT(*) as total_opens,
    COUNT(DISTINCT user_id) as users_opened
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
),
clicks AS (
  SELECT
    treatment_id,
    COUNT(*) as total_clicks,
    COUNT(DISTINCT user_id) as users_clicked
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  s.treatment_id,
  s.users_sent,
  COALESCE(o.users_opened, 0) as users_opened,
  ROUND(100.0 * COALESCE(o.users_opened, 0) / s.users_sent, 2) as open_rate,
  COALESCE(o.total_opens, 0) as total_opens,
  COALESCE(c.users_clicked, 0) as users_clicked,
  ROUND(100.0 * COALESCE(c.users_clicked, 0) / NULLIF(o.users_opened, 0), 2) as ctr,
  COALESCE(c.total_clicks, 0) as total_clicks
FROM sent s
LEFT JOIN opens o ON s.treatment_id = o.treatment_id
LEFT JOIN clicks c ON s.treatment_id = c.treatment_id
WHERE s.users_sent >= 100
ORDER BY s.users_sent DESC;


-- ============================================================================
-- 3. DAY-OVER-DAY PERFORMANCE: Daily breakdown
-- ============================================================================
WITH daily_sent AS (
  SELECT
    DATE(treatment_sent_timestamp) as dt,
    COUNT(DISTINCT user_id) as users_sent
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) >= '2025-12-04'
  GROUP BY 1
),
daily_opens AS (
  SELECT
    DATE(interaction_timestamp_micros) as dt,
    COUNT(*) as opens,
    COUNT(DISTINCT user_id) as users_opened
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
),
daily_clicks AS (
  SELECT
    DATE(interaction_timestamp_micros) as dt,
    COUNT(*) as clicks,
    COUNT(DISTINCT user_id) as users_clicked
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  COALESCE(s.dt, o.dt, c.dt) as date,
  s.users_sent,
  o.users_opened,
  ROUND(100.0 * o.users_opened / NULLIF(s.users_sent, 0), 2) as open_rate,
  c.users_clicked,
  ROUND(100.0 * c.users_clicked / NULLIF(o.users_opened, 0), 2) as ctr
FROM daily_sent s
FULL OUTER JOIN daily_opens o ON s.dt = o.dt
FULL OUTER JOIN daily_clicks c ON COALESCE(s.dt, o.dt) = c.dt
ORDER BY date;


-- ============================================================================
-- 4. HOURLY ENGAGEMENT: Peak engagement times
-- ============================================================================
SELECT
  EXTRACT(HOUR FROM interaction_timestamp_micros) as hour_utc,
  interaction_type,
  COUNT(*) as events,
  COUNT(DISTINCT user_id) as unique_users
FROM `auxia-gcp.company_1950.treatment_interaction`
WHERE DATE(interaction_timestamp_micros) >= '2025-12-04'
GROUP BY 1, 2
ORDER BY 1, 2;


-- ============================================================================
-- 5. ENGAGEMENT DEPTH: Repeat opens/clicks
-- ============================================================================
WITH user_engagement AS (
  SELECT
    user_id,
    treatment_id,
    COUNTIF(interaction_type = 'VIEWED') as open_count,
    COUNTIF(interaction_type = 'CLICKED') as click_count
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1, 2
)
SELECT
  'Opens' as metric,
  SUM(CASE WHEN open_count = 1 THEN 1 ELSE 0 END) as once,
  SUM(CASE WHEN open_count = 2 THEN 1 ELSE 0 END) as twice,
  SUM(CASE WHEN open_count = 3 THEN 1 ELSE 0 END) as three_times,
  SUM(CASE WHEN open_count >= 4 THEN 1 ELSE 0 END) as four_plus
FROM user_engagement
UNION ALL
SELECT
  'Clicks' as metric,
  SUM(CASE WHEN click_count = 1 THEN 1 ELSE 0 END) as once,
  SUM(CASE WHEN click_count = 2 THEN 1 ELSE 0 END) as twice,
  SUM(CASE WHEN click_count = 3 THEN 1 ELSE 0 END) as three_times,
  SUM(CASE WHEN click_count >= 4 THEN 1 ELSE 0 END) as four_plus
FROM user_engagement;


-- ============================================================================
-- 6. TIME TO ENGAGEMENT: How fast users respond
-- ============================================================================
WITH sent AS (
  SELECT
    user_id,
    treatment_id,
    treatment_sent_timestamp as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) >= '2025-12-04'
),
interactions AS (
  SELECT
    user_id,
    treatment_id,
    interaction_type,
    MIN(interaction_timestamp_micros) as first_interaction
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1, 2, 3
)
SELECT
  i.interaction_type,
  COUNT(*) as count,
  ROUND(AVG(TIMESTAMP_DIFF(i.first_interaction, s.sent_time, MINUTE)), 1) as avg_minutes_to_action,
  ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(i.first_interaction, s.sent_time, MINUTE), 100)[OFFSET(50)], 1) as median_minutes
FROM sent s
JOIN interactions i ON s.user_id = i.user_id AND s.treatment_id = i.treatment_id
WHERE i.first_interaction > s.sent_time
GROUP BY 1;


-- ============================================================================
-- 7. FAILURE ANALYSIS: Breakdown of delivery failures
-- ============================================================================
SELECT
  CASE
    WHEN failure_reason LIKE '%event limit%' THEN 'Event Limit Exceeded'
    WHEN failure_reason LIKE '%Klaviyo%' THEN 'Klaviyo API Error'
    WHEN failure_reason LIKE '%UNAVAILABLE%' THEN 'Service Unavailable'
    WHEN failure_reason = '' OR failure_reason IS NULL THEN 'Success'
    ELSE 'Other Error'
  END as failure_category,
  delivery_status,
  COUNT(*) as count,
  COUNT(DISTINCT user_id) as unique_users
FROM `auxia-gcp.company_1950.treatment_delivery_result_for_batch_decision`
WHERE DATE(treatment_delivery_timestamp) >= '2025-12-04'
GROUP BY 1, 2
ORDER BY count DESC;


-- ============================================================================
-- 8. CONVERSION ATTRIBUTION: Click to purchase tracking
-- Note: Automotive parts have long consideration cycles, expect low short-term conversion
-- ============================================================================
WITH clicked_users AS (
  SELECT
    user_id,
    treatment_id,
    MIN(interaction_timestamp_micros) as first_click_time
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1, 2
),
orders AS (
  SELECT
    user_id,
    MIN(client_event_timestamp) as first_order_time
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name IN ('Placed Order', 'Consumer Website Order')
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  c.treatment_id,
  COUNT(DISTINCT c.user_id) as clicked_users,
  COUNT(DISTINCT CASE WHEN o.first_order_time > c.first_click_time THEN c.user_id END) as converted_after_click,
  COUNT(DISTINCT CASE WHEN o.first_order_time < c.first_click_time THEN c.user_id END) as already_ordered_before_click,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.first_order_time > c.first_click_time THEN c.user_id END)
    / NULLIF(COUNT(DISTINCT c.user_id), 0), 2) as click_to_order_rate
FROM clicked_users c
LEFT JOIN orders o ON c.user_id = o.user_id
GROUP BY 1
ORDER BY clicked_users DESC;


-- ============================================================================
-- 9. SENT VS INTERACTIONS BY TREATMENT: Quick health check
-- ============================================================================
SELECT
  h.treatment_id,
  h.surface_id,
  COUNT(DISTINCT h.user_id) as users_sent,
  COUNT(DISTINCT i.user_id) as users_interacted,
  ROUND(100.0 * COUNT(DISTINCT i.user_id) / COUNT(DISTINCT h.user_id), 2) as interaction_rate
FROM `auxia-gcp.company_1950.treatment_history` h
LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
  ON h.user_id = i.user_id AND h.treatment_id = i.treatment_id
WHERE h.treatment_sent_status = 'TREATMENT_SENT'
  AND DATE(h.treatment_sent_timestamp) >= '2025-12-04'
GROUP BY 1, 2
HAVING users_sent >= 100
ORDER BY users_sent DESC;
