-- ============================================================
-- Personalized vs Static Uplift: Analysis Queries
-- ============================================================
-- Prerequisites: Run uplift_base_table.sql first
-- Base table: auxia-reporting.temp_holley_v5_17.uplift_base
--
-- Each section is a standalone query. Run individually via:
--   bq query --use_legacy_sql=false "QUERY"
--
-- Or copy-paste sections into BigQuery console.
-- ============================================================


-- ============================================================
-- 0. DATA QUALITY CHECKS
-- ============================================================

-- 0a. Overall row counts by period and treatment type
SELECT
  period,
  treatment_type,
  COUNT(*) AS total_sends,
  COUNT(DISTINCT user_id) AS unique_users,
  SUM(opened) AS total_opens,
  SUM(clicked) AS total_clicks,
  COUNTIF(fitment_eligible) AS fitment_eligible_sends,
  COUNTIF(NOT fitment_eligible) AS not_fitment_sends,
  COUNTIF(in_crash_window) AS crash_window_sends,
  COUNTIF(NOT in_crash_window) AS clean_sends
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
GROUP BY period, treatment_type
ORDER BY period, treatment_type;

-- 0b. Which Static treatments actually sent?
SELECT
  treatment_id,
  treatment_type,
  COUNT(*) AS sends,
  COUNT(DISTINCT user_id) AS users,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
WHERE treatment_type = 'Static'
GROUP BY treatment_id, treatment_type
ORDER BY sends DESC;

-- 0c. Arm distribution by period (check for 50/50 crash)
SELECT
  period,
  arm_id,
  in_crash_window,
  COUNT(*) AS sends,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(clicked), SUM(opened)) * 100, 2) AS ctr_of_opens_pct
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
GROUP BY period, arm_id, in_crash_window
ORDER BY period, arm_id, in_crash_window;

-- 0d. Daily send volume (check for gaps/anomalies)
SELECT
  send_date,
  treatment_type,
  COUNT(*) AS sends,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
WHERE period = 'v5.17'
GROUP BY send_date, treatment_type
ORDER BY send_date, treatment_type;


-- ============================================================
-- 1. METHOD A: MECE COMPARISON
-- ============================================================
-- Compare Personalized vs Static among FITMENT-ELIGIBLE users only.
-- Excludes crash window (Jan 14+) from v5.17 period.
-- This controls for user population differences.
-- ============================================================

-- 1a. MECE by period (primary result)
SELECT
  period,
  treatment_type,
  COUNT(*) AS sends,
  COUNT(DISTINCT user_id) AS unique_users,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), SUM(opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), COUNT(*)) * 100, 2) AS ctr_of_sends_pct
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
WHERE fitment_eligible = TRUE
  AND NOT in_crash_window
GROUP BY period, treatment_type
ORDER BY period, treatment_type;

-- 1b. MECE with 95% CI (Wilson score interval for proportions)
-- CTR of opens with confidence interval
WITH mece_stats AS (
  SELECT
    period,
    treatment_type,
    SUM(opened) AS n,
    SUM(clicked) AS k,
    SAFE_DIVIDE(SUM(clicked), SUM(opened)) AS p_hat
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE fitment_eligible = TRUE
    AND NOT in_crash_window
  GROUP BY period, treatment_type
)
SELECT
  period,
  treatment_type,
  n AS opens,
  k AS clicks,
  ROUND(p_hat * 100, 2) AS ctr_pct,
  -- Wilson 95% CI
  ROUND((p_hat + 1.96*1.96/(2*n) - 1.96 * SQRT((p_hat*(1-p_hat) + 1.96*1.96/(4*n))/n))
    / (1 + 1.96*1.96/n) * 100, 2) AS ci_lower_pct,
  ROUND((p_hat + 1.96*1.96/(2*n) + 1.96 * SQRT((p_hat*(1-p_hat) + 1.96*1.96/(4*n))/n))
    / (1 + 1.96*1.96/n) * 100, 2) AS ci_upper_pct
FROM mece_stats
WHERE n > 0
ORDER BY period, treatment_type;

-- 1c. MECE by period x arm (diagnostic)
SELECT
  period,
  treatment_type,
  arm_id,
  COUNT(*) AS sends,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), SUM(opened)) * 100, 2) AS ctr_of_opens_pct
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
WHERE fitment_eligible = TRUE
  AND NOT in_crash_window
GROUP BY period, treatment_type, arm_id
HAVING sends >= 10
ORDER BY period, treatment_type, arm_id;


-- ============================================================
-- 2. METHOD B: WITHIN-USER PAIRED COMPARISON
-- ============================================================
-- Users who received BOTH Personalized and Static treatments.
-- Gold standard: controls for user-level confounders.
-- Excludes crash window.
-- ============================================================

-- 2a. Identify overlap users per period
WITH user_types AS (
  SELECT
    user_id,
    period,
    MAX(CASE WHEN treatment_type = 'Personalized' THEN 1 ELSE 0 END) AS got_personalized,
    MAX(CASE WHEN treatment_type = 'Static' THEN 1 ELSE 0 END) AS got_static,
    -- Personalized metrics
    SUM(CASE WHEN treatment_type = 'Personalized' THEN 1 ELSE 0 END) AS p_sends,
    SUM(CASE WHEN treatment_type = 'Personalized' THEN opened ELSE 0 END) AS p_opens,
    SUM(CASE WHEN treatment_type = 'Personalized' THEN clicked ELSE 0 END) AS p_clicks,
    -- Static metrics
    SUM(CASE WHEN treatment_type = 'Static' THEN 1 ELSE 0 END) AS s_sends,
    SUM(CASE WHEN treatment_type = 'Static' THEN opened ELSE 0 END) AS s_opens,
    SUM(CASE WHEN treatment_type = 'Static' THEN clicked ELSE 0 END) AS s_clicks
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
  GROUP BY user_id, period
)
SELECT
  period,
  COUNT(*) AS overlap_users,
  -- Personalized
  SUM(p_sends) AS p_total_sends,
  SUM(p_opens) AS p_total_opens,
  SUM(p_clicks) AS p_total_clicks,
  ROUND(SAFE_DIVIDE(SUM(p_opens), SUM(p_sends)) * 100, 2) AS p_open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(p_clicks), SUM(p_opens)) * 100, 2) AS p_ctr_of_opens_pct,
  -- Static
  SUM(s_sends) AS s_total_sends,
  SUM(s_opens) AS s_total_opens,
  SUM(s_clicks) AS s_total_clicks,
  ROUND(SAFE_DIVIDE(SUM(s_opens), SUM(s_sends)) * 100, 2) AS s_open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(s_clicks), SUM(s_opens)) * 100, 2) AS s_ctr_of_opens_pct,
  -- Delta
  ROUND(
    SAFE_DIVIDE(SUM(p_clicks), SUM(p_opens)) * 100
    - SAFE_DIVIDE(SUM(s_clicks), SUM(s_opens)) * 100, 2
  ) AS ctr_delta_pp
FROM user_types
WHERE got_personalized = 1 AND got_static = 1
GROUP BY period
ORDER BY period;

-- 2b. Within-user: user-level click rates (at-least-once)
-- Per-user binary: did they click at least once per type?
WITH user_types AS (
  SELECT
    user_id,
    period,
    MAX(CASE WHEN treatment_type = 'Personalized' THEN 1 ELSE 0 END) AS got_personalized,
    MAX(CASE WHEN treatment_type = 'Static' THEN 1 ELSE 0 END) AS got_static,
    MAX(CASE WHEN treatment_type = 'Personalized' AND clicked = 1 THEN 1 ELSE 0 END) AS clicked_personalized,
    MAX(CASE WHEN treatment_type = 'Static' AND clicked = 1 THEN 1 ELSE 0 END) AS clicked_static
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
  GROUP BY user_id, period
),
overlap AS (
  SELECT *
  FROM user_types
  WHERE got_personalized = 1 AND got_static = 1
)
SELECT
  period,
  COUNT(*) AS overlap_users,
  SUM(clicked_personalized) AS users_clicked_personalized,
  SUM(clicked_static) AS users_clicked_static,
  SUM(CASE WHEN clicked_personalized = 1 AND clicked_static = 1 THEN 1 ELSE 0 END) AS clicked_both,
  SUM(CASE WHEN clicked_personalized = 0 AND clicked_static = 0 THEN 1 ELSE 0 END) AS clicked_neither,
  ROUND(SAFE_DIVIDE(SUM(clicked_personalized), COUNT(*)) * 100, 2) AS pct_clicked_personalized,
  ROUND(SAFE_DIVIDE(SUM(clicked_static), COUNT(*)) * 100, 2) AS pct_clicked_static,
  ROUND(
    SAFE_DIVIDE(SUM(clicked_personalized), COUNT(*)) * 100
    - SAFE_DIVIDE(SUM(clicked_static), COUNT(*)) * 100, 2
  ) AS delta_pp
FROM overlap
GROUP BY period
ORDER BY period;

-- 2c. Within-user across BOTH periods (combined)
WITH user_types AS (
  SELECT
    user_id,
    MAX(CASE WHEN treatment_type = 'Personalized' THEN 1 ELSE 0 END) AS got_personalized,
    MAX(CASE WHEN treatment_type = 'Static' THEN 1 ELSE 0 END) AS got_static,
    MAX(CASE WHEN treatment_type = 'Personalized' AND clicked = 1 THEN 1 ELSE 0 END) AS clicked_personalized,
    MAX(CASE WHEN treatment_type = 'Static' AND clicked = 1 THEN 1 ELSE 0 END) AS clicked_static
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
  GROUP BY user_id
),
overlap AS (
  SELECT *
  FROM user_types
  WHERE got_personalized = 1 AND got_static = 1
)
SELECT
  'All periods (excl crash)' AS scope,
  COUNT(*) AS overlap_users,
  SUM(clicked_personalized) AS users_clicked_personalized,
  SUM(clicked_static) AS users_clicked_static,
  SUM(CASE WHEN clicked_personalized = 1 AND clicked_static = 1 THEN 1 ELSE 0 END) AS clicked_both,
  SUM(CASE WHEN clicked_personalized = 0 AND clicked_static = 0 THEN 1 ELSE 0 END) AS clicked_neither,
  ROUND(SAFE_DIVIDE(SUM(clicked_personalized), COUNT(*)) * 100, 2) AS pct_clicked_personalized,
  ROUND(SAFE_DIVIDE(SUM(clicked_static), COUNT(*)) * 100, 2) AS pct_clicked_static,
  ROUND(
    SAFE_DIVIDE(SUM(clicked_personalized), COUNT(*)) * 100
    - SAFE_DIVIDE(SUM(clicked_static), COUNT(*)) * 100, 2
  ) AS delta_pp
FROM overlap;


-- ============================================================
-- 3. METHOD C: DEPLOYMENT UPLIFT (Difference-in-Differences)
-- ============================================================
-- Compare the CHANGE in performance from v5.7 to v5.17 for
-- Personalized vs Static. Static is the control trend.
-- If Personalized improved MORE than Static, that's the
-- causal uplift from v5.17 algorithm deployment.
-- Excludes crash window.
-- ============================================================

-- 3a. DiD summary table (fitment-eligible only for fair comparison)
WITH period_stats AS (
  SELECT
    period,
    treatment_type,
    COUNT(*) AS sends,
    SUM(opened) AS opens,
    SUM(clicked) AS clicks,
    SAFE_DIVIDE(SUM(opened), COUNT(*)) AS open_rate,
    SAFE_DIVIDE(SUM(clicked), SUM(opened)) AS ctr_of_opens,
    SAFE_DIVIDE(SUM(clicked), COUNT(*)) AS ctr_of_sends
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
    AND fitment_eligible = TRUE
  GROUP BY period, treatment_type
)
SELECT
  treatment_type,
  -- v5.7 metrics
  MAX(CASE WHEN period = 'v5.7' THEN sends END) AS v57_sends,
  ROUND(MAX(CASE WHEN period = 'v5.7' THEN open_rate END) * 100, 2) AS v57_open_rate_pct,
  ROUND(MAX(CASE WHEN period = 'v5.7' THEN ctr_of_opens END) * 100, 2) AS v57_ctr_opens_pct,
  ROUND(MAX(CASE WHEN period = 'v5.7' THEN ctr_of_sends END) * 100, 2) AS v57_ctr_sends_pct,
  -- v5.17 metrics
  MAX(CASE WHEN period = 'v5.17' THEN sends END) AS v517_sends,
  ROUND(MAX(CASE WHEN period = 'v5.17' THEN open_rate END) * 100, 2) AS v517_open_rate_pct,
  ROUND(MAX(CASE WHEN period = 'v5.17' THEN ctr_of_opens END) * 100, 2) AS v517_ctr_opens_pct,
  ROUND(MAX(CASE WHEN period = 'v5.17' THEN ctr_of_sends END) * 100, 2) AS v517_ctr_sends_pct,
  -- Absolute change (pp)
  ROUND((MAX(CASE WHEN period = 'v5.17' THEN open_rate END)
       - MAX(CASE WHEN period = 'v5.7' THEN open_rate END)) * 100, 2) AS open_rate_delta_pp,
  ROUND((MAX(CASE WHEN period = 'v5.17' THEN ctr_of_opens END)
       - MAX(CASE WHEN period = 'v5.7' THEN ctr_of_opens END)) * 100, 2) AS ctr_opens_delta_pp,
  ROUND((MAX(CASE WHEN period = 'v5.17' THEN ctr_of_sends END)
       - MAX(CASE WHEN period = 'v5.7' THEN ctr_of_sends END)) * 100, 2) AS ctr_sends_delta_pp,
  -- Relative change (%)
  ROUND(SAFE_DIVIDE(
    MAX(CASE WHEN period = 'v5.17' THEN open_rate END) - MAX(CASE WHEN period = 'v5.7' THEN open_rate END),
    MAX(CASE WHEN period = 'v5.7' THEN open_rate END)
  ) * 100, 1) AS open_rate_relative_pct,
  ROUND(SAFE_DIVIDE(
    MAX(CASE WHEN period = 'v5.17' THEN ctr_of_opens END) - MAX(CASE WHEN period = 'v5.7' THEN ctr_of_opens END),
    MAX(CASE WHEN period = 'v5.7' THEN ctr_of_opens END)
  ) * 100, 1) AS ctr_opens_relative_pct
FROM period_stats
GROUP BY treatment_type
ORDER BY treatment_type;

-- 3b. DiD calculation (the key number)
-- DiD = (Personalized_v517 - Personalized_v57) - (Static_v517 - Static_v57)
-- Positive = Personalized improved MORE than Static after v5.17 deployment
WITH period_stats AS (
  SELECT
    period,
    treatment_type,
    SAFE_DIVIDE(SUM(opened), COUNT(*)) AS open_rate,
    SAFE_DIVIDE(SUM(clicked), SUM(opened)) AS ctr_of_opens,
    SAFE_DIVIDE(SUM(clicked), COUNT(*)) AS ctr_of_sends
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
    AND fitment_eligible = TRUE
  GROUP BY period, treatment_type
),
pivoted AS (
  SELECT
    treatment_type,
    MAX(CASE WHEN period = 'v5.7' THEN open_rate END) AS v57_or,
    MAX(CASE WHEN period = 'v5.17' THEN open_rate END) AS v517_or,
    MAX(CASE WHEN period = 'v5.7' THEN ctr_of_opens END) AS v57_ctr,
    MAX(CASE WHEN period = 'v5.17' THEN ctr_of_opens END) AS v517_ctr,
    MAX(CASE WHEN period = 'v5.7' THEN ctr_of_sends END) AS v57_ctr_s,
    MAX(CASE WHEN period = 'v5.17' THEN ctr_of_sends END) AS v517_ctr_s
  FROM period_stats
  GROUP BY treatment_type
)
SELECT
  'DiD Estimate' AS metric,
  -- Open rate DiD
  ROUND(((MAX(CASE WHEN treatment_type='Personalized' THEN v517_or END)
        - MAX(CASE WHEN treatment_type='Personalized' THEN v57_or END))
       - (MAX(CASE WHEN treatment_type='Static' THEN v517_or END)
        - MAX(CASE WHEN treatment_type='Static' THEN v57_or END))) * 100, 2)
    AS open_rate_did_pp,
  -- CTR of opens DiD
  ROUND(((MAX(CASE WHEN treatment_type='Personalized' THEN v517_ctr END)
        - MAX(CASE WHEN treatment_type='Personalized' THEN v57_ctr END))
       - (MAX(CASE WHEN treatment_type='Static' THEN v517_ctr END)
        - MAX(CASE WHEN treatment_type='Static' THEN v57_ctr END))) * 100, 2)
    AS ctr_of_opens_did_pp,
  -- CTR of sends DiD
  ROUND(((MAX(CASE WHEN treatment_type='Personalized' THEN v517_ctr_s END)
        - MAX(CASE WHEN treatment_type='Personalized' THEN v57_ctr_s END))
       - (MAX(CASE WHEN treatment_type='Static' THEN v517_ctr_s END)
        - MAX(CASE WHEN treatment_type='Static' THEN v57_ctr_s END))) * 100, 2)
    AS ctr_of_sends_did_pp
FROM pivoted;

-- 3c. Same-user deployment uplift
-- Users who received Personalized in BOTH periods (excl crash)
WITH user_period AS (
  SELECT
    user_id,
    period,
    SUM(opened) AS opens,
    SUM(clicked) AS clicks,
    COUNT(*) AS sends
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE treatment_type = 'Personalized'
    AND NOT in_crash_window
  GROUP BY user_id, period
),
both_periods AS (
  SELECT user_id
  FROM user_period
  GROUP BY user_id
  HAVING COUNT(DISTINCT period) = 2
)
SELECT
  up.period,
  COUNT(DISTINCT up.user_id) AS users,
  SUM(up.sends) AS sends,
  SUM(up.opens) AS opens,
  SUM(up.clicks) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(up.opens), SUM(up.sends)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(up.clicks), SUM(up.opens)) * 100, 2) AS ctr_of_opens_pct
FROM user_period up
JOIN both_periods bp ON up.user_id = bp.user_id
GROUP BY up.period
ORDER BY up.period;


-- ============================================================
-- 4. REVERSAL STORY
-- ============================================================
-- Show how the winner changed across periods.
-- Dec 2025: Static won by ~2x on CTR
-- Jan 2026 (post-v5.17): Personalized pulls ahead
-- ============================================================

-- 4a. Side-by-side comparison across periods
SELECT
  period,
  -- Personalized
  ROUND(MAX(CASE WHEN treatment_type = 'Personalized'
    THEN SAFE_DIVIDE(opens, sends) END) * 100, 2) AS p_open_rate,
  ROUND(MAX(CASE WHEN treatment_type = 'Personalized'
    THEN SAFE_DIVIDE(clicks, opens) END) * 100, 2) AS p_ctr_opens,
  -- Static
  ROUND(MAX(CASE WHEN treatment_type = 'Static'
    THEN SAFE_DIVIDE(opens, sends) END) * 100, 2) AS s_open_rate,
  ROUND(MAX(CASE WHEN treatment_type = 'Static'
    THEN SAFE_DIVIDE(clicks, opens) END) * 100, 2) AS s_ctr_opens,
  -- Winner
  CASE
    WHEN MAX(CASE WHEN treatment_type = 'Personalized'
      THEN SAFE_DIVIDE(clicks, opens) END)
      > MAX(CASE WHEN treatment_type = 'Static'
      THEN SAFE_DIVIDE(clicks, opens) END)
    THEN 'Personalized'
    ELSE 'Static'
  END AS ctr_winner
FROM (
  SELECT
    period,
    treatment_type,
    COUNT(*) AS sends,
    SUM(opened) AS opens,
    SUM(clicked) AS clicks
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE fitment_eligible = TRUE
    AND NOT in_crash_window
  GROUP BY period, treatment_type
)
GROUP BY period
ORDER BY period;


-- ============================================================
-- 5. REVENUE ATTRIBUTION (Directional Only)
-- ============================================================
-- Revenue analysis uses fuzzy email+time matching.
-- Treat as directional signal, not causal proof.
-- Uses ingestion_unified_schema_incremental for recent orders
-- (import_orders only covers through Aug 2025).
--
-- FIXES (ChatGPT review 2026-02-04):
-- 1. Excludes overlap users (users who received both P and S) to prevent
--    double-counting the same orders in both treatment groups.
-- 2. Uses TIMESTAMP comparison (order must be AFTER send, not same-day).
-- 3. Order-level dedupe using user_id + date + amount (approximate, no OrderId).
-- 4. Per-send attribution: each order attributed to nearest preceding send
--    (not just first send), avoiding bias from different send frequencies.
-- ============================================================

-- 5a. Revenue by treatment type (7-day and 30-day attribution)
-- Per-send attribution: orders attributed to the most recent preceding send.
-- Order dedupe: approximate using user_id + date + amount.
-- IMPORTANT: Filters to fitment_eligible=TRUE for fair population comparison
WITH all_sends AS (
  -- Keep all sends (not just first) for per-send attribution
  SELECT
    user_id,
    treatment_type,
    period,
    treatment_tracking_id,
    treatment_sent_timestamp AS send_ts
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
    AND fitment_eligible = TRUE
),
-- Identify users who received BOTH treatment types (overlap users)
-- These are excluded to prevent double-counting revenue
overlap_users AS (
  SELECT user_id
  FROM all_sends
  GROUP BY user_id
  HAVING COUNT(DISTINCT treatment_type) > 1
),
-- Filter to non-overlap users only
sends_clean AS (
  SELECT s.*
  FROM all_sends s
  LEFT JOIN overlap_users ou ON s.user_id = ou.user_id
  WHERE ou.user_id IS NULL
),
-- Get unique users per treatment/period (for denominator)
users_per_group AS (
  SELECT
    treatment_type,
    period,
    COUNT(DISTINCT user_id) AS user_count
  FROM sends_clean
  GROUP BY treatment_type, period
),
-- Orders from unified events (Dec 2025+)
-- Dedupe by user_id + date + amount (approximate, no OrderId available)
user_orders_raw AS (
  SELECT
    user_id,
    client_event_timestamp AS order_ts,
    DATE(client_event_timestamp) AS order_date,
    COALESCE(
      ep.double_value,
      SAFE_CAST(ep.string_value AS FLOAT64),
      CAST(ep.long_value AS FLOAT64)
    ) AS order_total
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`,
    UNNEST(event_properties) AS ep
  WHERE event_name IN ('Placed Order', 'Consumer Website Order')
    AND ep.property_name = 'Subtotal'
    AND client_event_timestamp BETWEEN '2025-12-07' AND '2026-03-06'
),
-- Dedupe orders: keep one per user + date + amount
user_orders AS (
  SELECT
    user_id,
    MIN(order_ts) AS order_ts,  -- Take earliest timestamp for the dedupe key
    order_date,
    order_total
  FROM user_orders_raw
  GROUP BY user_id, order_date, order_total
),
-- For each order, find the most recent preceding send (per-send attribution)
-- This avoids bias from different send frequencies between treatments
order_send_match AS (
  SELECT
    o.user_id,
    o.order_ts,
    o.order_date,
    o.order_total,
    s.treatment_type,
    s.period,
    s.send_ts,
    -- Rank sends by recency (most recent send before this order = rank 1)
    -- Cast order_total to STRING for partitioning (FLOAT64 not allowed in PARTITION BY)
    ROW_NUMBER() OVER (
      PARTITION BY o.user_id, o.order_date, CAST(o.order_total AS STRING)
      ORDER BY s.send_ts DESC
    ) AS send_rank
  FROM user_orders o
  JOIN sends_clean s
    ON o.user_id = s.user_id
    AND o.order_ts > s.send_ts  -- Order must be AFTER send
    AND o.order_ts <= TIMESTAMP_ADD(s.send_ts, INTERVAL 30 DAY)  -- Within 30-day window
),
-- Keep only the most recent send attribution per order
orders_attributed AS (
  SELECT
    user_id,
    order_ts,
    order_date,
    order_total,
    treatment_type,
    period,
    send_ts,
    -- Flag for 7-day vs 30-day window
    CASE WHEN order_ts <= TIMESTAMP_ADD(send_ts, INTERVAL 7 DAY) THEN 1 ELSE 0 END AS in_7d_window
  FROM order_send_match
  WHERE send_rank = 1  -- Most recent preceding send gets credit
),
-- Aggregate revenue by treatment/period
revenue_summary AS (
  SELECT
    treatment_type,
    period,
    -- 7-day metrics
    COUNT(DISTINCT CASE WHEN in_7d_window = 1 THEN user_id END) AS buyers_7d,
    SUM(CASE WHEN in_7d_window = 1 THEN order_total ELSE 0 END) AS revenue_7d,
    -- 30-day metrics
    COUNT(DISTINCT user_id) AS buyers_30d,
    SUM(order_total) AS revenue_30d
  FROM orders_attributed
  GROUP BY treatment_type, period
)
SELECT
  u.treatment_type,
  u.period,
  u.user_count AS users_sent,
  -- 7-day attribution
  COALESCE(r.buyers_7d, 0) AS buyers_7d,
  ROUND(SAFE_DIVIDE(r.buyers_7d, u.user_count) * 100, 2) AS conversion_rate_7d_pct,
  ROUND(COALESCE(r.revenue_7d, 0), 2) AS revenue_7d,
  ROUND(SAFE_DIVIDE(r.revenue_7d, u.user_count), 2) AS revenue_per_user_7d,
  -- 30-day attribution
  COALESCE(r.buyers_30d, 0) AS buyers_30d,
  ROUND(SAFE_DIVIDE(r.buyers_30d, u.user_count) * 100, 2) AS conversion_rate_30d_pct,
  ROUND(COALESCE(r.revenue_30d, 0), 2) AS revenue_30d,
  ROUND(SAFE_DIVIDE(r.revenue_30d, u.user_count), 2) AS revenue_per_user_30d
FROM users_per_group u
LEFT JOIN revenue_summary r
  ON u.treatment_type = r.treatment_type
  AND u.period = r.period
ORDER BY u.period, u.treatment_type;

-- 5b. Overlap user count (diagnostic - how many excluded?)
SELECT
  period,
  COUNT(DISTINCT su.user_id) AS total_users,
  COUNT(DISTINCT ou.user_id) AS overlap_users,
  COUNT(DISTINCT su.user_id) - COUNT(DISTINCT ou.user_id) AS clean_users
FROM (
  SELECT user_id, treatment_type, period
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window AND fitment_eligible = TRUE
  GROUP BY user_id, treatment_type, period
) su
LEFT JOIN (
  SELECT user_id
  FROM (
    SELECT user_id, treatment_type
    FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
    WHERE NOT in_crash_window AND fitment_eligible = TRUE
    GROUP BY user_id, treatment_type
  )
  GROUP BY user_id
  HAVING COUNT(DISTINCT treatment_type) > 1
) ou ON su.user_id = ou.user_id
GROUP BY period
ORDER BY period;

-- 5c. Order dedupe diagnostic (how many orders deduped?)
WITH orders_raw AS (
  SELECT
    user_id,
    client_event_timestamp AS order_ts,
    DATE(client_event_timestamp) AS order_date,
    event_name,
    COALESCE(
      ep.double_value,
      SAFE_CAST(ep.string_value AS FLOAT64),
      CAST(ep.long_value AS FLOAT64)
    ) AS order_total
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`,
    UNNEST(event_properties) AS ep
  WHERE event_name IN ('Placed Order', 'Consumer Website Order')
    AND ep.property_name = 'Subtotal'
    AND client_event_timestamp BETWEEN '2025-12-07' AND '2026-03-06'
),
orders_deduped AS (
  SELECT user_id, order_date, order_total
  FROM orders_raw
  GROUP BY user_id, order_date, order_total
)
SELECT
  'Raw order events' AS metric,
  COUNT(*) AS count
FROM orders_raw
UNION ALL
SELECT
  'After dedupe (user+date+amount)' AS metric,
  COUNT(*) AS count
FROM orders_deduped
UNION ALL
SELECT
  'Orders removed by dedupe' AS metric,
  (SELECT COUNT(*) FROM orders_raw) - (SELECT COUNT(*) FROM orders_deduped) AS count;


-- ============================================================
-- 6. CRASH WINDOW DIAGNOSTIC (Separate)
-- ============================================================
-- Jan 14+ data shown separately so it doesn't contaminate
-- the primary uplift analysis.
-- ============================================================

-- 6a. Pre-crash vs crash comparison within v5.17
SELECT
  in_crash_window,
  treatment_type,
  arm_id,
  COUNT(*) AS sends,
  COUNT(DISTINCT user_id) AS users,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), SUM(opened)) * 100, 2) AS ctr_of_opens_pct
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
WHERE period = 'v5.17'
GROUP BY in_crash_window, treatment_type, arm_id
ORDER BY in_crash_window, treatment_type, arm_id;
