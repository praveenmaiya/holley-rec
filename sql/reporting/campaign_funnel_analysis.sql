-- ============================================================================
-- HOLLEY EMAIL CAMPAIGN FUNNEL ANALYSIS
-- Campaign: Post-Purchase Recommendations
-- Launch Date: Dec 4, 2025
-- Surface ID: 929
-- ============================================================================

-- ============================================================================
-- 1. COMPLETE FUNNEL: Sent → Delivered → Opened → Clicked → Ordered
-- ============================================================================
WITH sent_users AS (
  SELECT user_id, MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
delivered AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_delivery_result_for_batch_decision`
  WHERE delivery_status = 'DELIVERY_SUCCESSFUL'
    AND DATE(treatment_delivery_timestamp) = '2025-12-04'
),
opened AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
clicked AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
ordered AS (
  SELECT user_id, MIN(client_event_timestamp) as order_time
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  'A. Sent' as stage,
  COUNT(DISTINCT s.user_id) as users,
  '100%' as rate
FROM sent_users s
UNION ALL
SELECT 'B. Delivered', COUNT(DISTINCT s.user_id),
  CONCAT(ROUND(100.0 * COUNT(DISTINCT s.user_id) / (SELECT COUNT(DISTINCT user_id) FROM sent_users), 1), '%')
FROM sent_users s JOIN delivered d ON s.user_id = d.user_id
UNION ALL
SELECT 'C. Opened', COUNT(DISTINCT s.user_id),
  CONCAT(ROUND(100.0 * COUNT(DISTINCT s.user_id) / (SELECT COUNT(DISTINCT user_id) FROM sent_users), 1), '%')
FROM sent_users s JOIN opened o ON s.user_id = o.user_id
UNION ALL
SELECT 'D. Clicked', COUNT(DISTINCT s.user_id),
  CONCAT(ROUND(100.0 * COUNT(DISTINCT s.user_id) / (SELECT COUNT(DISTINCT user_id) FROM sent_users), 2), '%')
FROM sent_users s JOIN clicked c ON s.user_id = c.user_id
UNION ALL
SELECT 'E. Ordered (after email)', COUNT(DISTINCT s.user_id),
  CONCAT(ROUND(100.0 * COUNT(DISTINCT s.user_id) / (SELECT COUNT(DISTINCT user_id) FROM sent_users), 2), '%')
FROM sent_users s JOIN ordered o ON s.user_id = o.user_id WHERE o.order_time > s.sent_time
ORDER BY stage;


-- ============================================================================
-- 2. CONVERSION PATHS WITH REVENUE
-- ============================================================================
WITH sent_users AS (
  SELECT
    user_id,
    MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
delivered AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_delivery_result_for_batch_decision`
  WHERE delivery_status = 'DELIVERY_SUCCESSFUL'
    AND DATE(treatment_delivery_timestamp) = '2025-12-04'
),
opened AS (
  SELECT user_id, MIN(interaction_timestamp_micros) as open_time
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
),
clicked AS (
  SELECT user_id, MIN(interaction_timestamp_micros) as click_time
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
),
ordered AS (
  SELECT
    user_id,
    MIN(client_event_timestamp) as order_time,
    SUM(COALESCE(
      (SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1),
      0
    )) as total_spent
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  CASE
    WHEN c.click_time IS NOT NULL AND ord.order_time > c.click_time THEN '1. Clicked → Ordered'
    WHEN o.open_time IS NOT NULL AND ord.order_time > o.open_time THEN '2. Opened → Ordered (no click)'
    WHEN d.user_id IS NOT NULL AND ord.order_time > s.sent_time THEN '3. Delivered → Ordered (no open tracked)'
    WHEN ord.order_time > s.sent_time THEN '4. Sent → Ordered (delivery unknown)'
    ELSE '5. No Order'
  END as conversion_path,
  COUNT(DISTINCT s.user_id) as users,
  ROUND(SUM(ord.total_spent), 2) as revenue
FROM sent_users s
LEFT JOIN delivered d ON s.user_id = d.user_id
LEFT JOIN opened o ON s.user_id = o.user_id
LEFT JOIN clicked c ON s.user_id = c.user_id
LEFT JOIN ordered ord ON s.user_id = ord.user_id AND ord.order_time > s.sent_time
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- 3. REVENUE BY DATE
-- ============================================================================
WITH sent_users AS (
  SELECT
    user_id,
    MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
ordered AS (
  SELECT
    user_id,
    client_event_timestamp as order_time,
    COALESCE(
      (SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1),
      0
    ) as subtotal
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
)
SELECT
  DATE(ord.order_time) as order_date,
  COUNT(DISTINCT s.user_id) as users_ordered,
  COUNT(*) as total_orders,
  ROUND(SUM(ord.subtotal), 2) as total_revenue,
  ROUND(AVG(ord.subtotal), 2) as avg_order_value
FROM sent_users s
JOIN ordered ord ON s.user_id = ord.user_id AND ord.order_time > s.sent_time
GROUP BY 1
ORDER BY 1;


-- ============================================================================
-- 4. TIME TO PURCHASE DISTRIBUTION
-- ============================================================================
WITH sent_users AS (
  SELECT user_id, MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
ordered AS (
  SELECT
    user_id,
    MIN(client_event_timestamp) as order_time
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  CASE
    WHEN hours_to_order < 1 THEN '< 1 hour'
    WHEN hours_to_order < 6 THEN '1-6 hours'
    WHEN hours_to_order < 12 THEN '6-12 hours'
    WHEN hours_to_order < 24 THEN '12-24 hours'
    WHEN hours_to_order < 48 THEN '1-2 days'
    ELSE '2+ days'
  END as time_bucket,
  COUNT(*) as orders
FROM (
  SELECT
    s.user_id,
    TIMESTAMP_DIFF(o.order_time, s.sent_time, HOUR) as hours_to_order
  FROM sent_users s
  JOIN ordered o ON s.user_id = o.user_id AND o.order_time > s.sent_time
)
GROUP BY 1
ORDER BY
  CASE time_bucket
    WHEN '< 1 hour' THEN 1
    WHEN '1-6 hours' THEN 2
    WHEN '6-12 hours' THEN 3
    WHEN '12-24 hours' THEN 4
    WHEN '1-2 days' THEN 5
    ELSE 6
  END;


-- ============================================================================
-- 5. FUNNEL BY TREATMENT ID
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
  COALESCE(c.users_clicked, 0) as users_clicked,
  ROUND(100.0 * COALESCE(c.users_clicked, 0) / NULLIF(o.users_opened, 0), 2) as ctr
FROM sent s
LEFT JOIN opens o ON s.treatment_id = o.treatment_id
LEFT JOIN clicks c ON s.treatment_id = c.treatment_id
WHERE s.users_sent >= 100
ORDER BY s.users_sent DESC;


-- ============================================================================
-- 6. FAILURE ANALYSIS
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
-- 7. EMAIL RECIPIENTS VS NON-RECIPIENTS COMPARISON
-- ============================================================================
WITH all_dec4_orders AS (
  SELECT
    user_id,
    COUNT(*) as orders,
    SUM((SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1)) as total_spent
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
),
email_recipients AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
)
SELECT
  CASE WHEN e.user_id IS NOT NULL THEN 'Email Recipients' ELSE 'Non-Recipients' END as group_name,
  COUNT(DISTINCT o.user_id) as users_who_ordered,
  ROUND(SUM(o.total_spent), 2) as total_revenue,
  ROUND(AVG(o.total_spent), 2) as avg_order_value
FROM all_dec4_orders o
LEFT JOIN email_recipients e ON o.user_id = e.user_id
GROUP BY 1;


-- ============================================================================
-- 8. HOURLY ENGAGEMENT PATTERN
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
-- 9. OPENED THEN ORDERED - DETAILED VIEW
-- ============================================================================
WITH sent_users AS (
  SELECT
    user_id,
    MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
opened AS (
  SELECT user_id, MIN(interaction_timestamp_micros) as open_time
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
  GROUP BY 1
),
ordered AS (
  SELECT
    user_id,
    client_event_timestamp as order_time,
    (SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1) as order_value,
    (SELECT ep.string_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'SKUs_1' LIMIT 1) as sku
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
)
SELECT
  s.user_id,
  s.sent_time,
  o.open_time,
  TIMESTAMP_DIFF(o.open_time, s.sent_time, MINUTE) as mins_to_open,
  ord.order_time,
  TIMESTAMP_DIFF(ord.order_time, o.open_time, MINUTE) as mins_open_to_order,
  ord.order_value,
  ord.sku
FROM sent_users s
JOIN opened o ON s.user_id = o.user_id
JOIN ordered ord ON s.user_id = ord.user_id
  AND ord.order_time > o.open_time
ORDER BY ord.order_time;


-- ============================================================================
-- 10. SUMMARY METRICS (Single Row)
-- ============================================================================
WITH sent_users AS (
  SELECT user_id, MIN(treatment_sent_timestamp) as sent_time
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) = '2025-12-04'
  GROUP BY 1
),
delivered AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_delivery_result_for_batch_decision`
  WHERE delivery_status = 'DELIVERY_SUCCESSFUL'
    AND DATE(treatment_delivery_timestamp) = '2025-12-04'
),
opened AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
clicked AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
ordered AS (
  SELECT
    user_id,
    MIN(client_event_timestamp) as order_time,
    SUM((SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1)) as total_spent
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  (SELECT COUNT(DISTINCT user_id) FROM sent_users) as emails_sent,
  (SELECT COUNT(DISTINCT s.user_id) FROM sent_users s JOIN delivered d ON s.user_id = d.user_id) as delivered,
  (SELECT COUNT(DISTINCT s.user_id) FROM sent_users s JOIN opened o ON s.user_id = o.user_id) as opened,
  (SELECT COUNT(DISTINCT s.user_id) FROM sent_users s JOIN clicked c ON s.user_id = c.user_id) as clicked,
  (SELECT COUNT(DISTINCT s.user_id) FROM sent_users s JOIN ordered o ON s.user_id = o.user_id WHERE o.order_time > s.sent_time) as ordered_after_email,
  (SELECT ROUND(SUM(o.total_spent), 2) FROM sent_users s JOIN ordered o ON s.user_id = o.user_id WHERE o.order_time > s.sent_time) as total_revenue;
