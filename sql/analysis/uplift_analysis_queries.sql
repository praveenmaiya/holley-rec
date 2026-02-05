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
  ) AS delta_pp;


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
-- ============================================================

-- 5a. Revenue by treatment type (7-day and 30-day attribution)
-- NOTE: Pre-aggregates each attribution window separately to avoid
-- Cartesian product from dual LEFT JOIN.
-- Revenue property is 'Subtotal' (case-sensitive, per campaign_funnel_analysis.sql)
WITH send_users AS (
  SELECT
    user_id,
    treatment_type,
    period,
    MIN(send_date) AS first_send_date
  FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
  WHERE NOT in_crash_window
  GROUP BY user_id, treatment_type, period
),
-- Orders from unified events (Dec 2025+)
user_orders AS (
  SELECT
    user_id,
    DATE(client_event_timestamp) AS order_date,
    -- Subtotal is the revenue property (matches campaign_funnel_analysis.sql)
    MAX(CASE WHEN ep.property_name = 'Subtotal'
      THEN COALESCE(
        ep.double_value,
        SAFE_CAST(ep.string_value AS FLOAT64),
        CAST(ep.long_value AS FLOAT64)
      ) END) AS order_total
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`,
    UNNEST(event_properties) AS ep
  WHERE event_name IN ('Placed Order', 'Consumer Website Order')
    AND DATE(client_event_timestamp) BETWEEN '2025-12-07' AND '2026-03-06'
  GROUP BY user_id, DATE(client_event_timestamp)
),
-- 7-day attribution: pre-aggregate per user+treatment+period
rev_7d AS (
  SELECT
    su.user_id,
    su.treatment_type,
    su.period,
    COUNT(DISTINCT o.order_date) AS order_count_7d,
    SUM(o.order_total) AS revenue_7d
  FROM send_users su
  LEFT JOIN user_orders o
    ON su.user_id = o.user_id
    AND o.order_date BETWEEN su.first_send_date
        AND DATE_ADD(su.first_send_date, INTERVAL 7 DAY)
  GROUP BY su.user_id, su.treatment_type, su.period
),
-- 30-day attribution: pre-aggregate per user+treatment+period
rev_30d AS (
  SELECT
    su.user_id,
    su.treatment_type,
    su.period,
    COUNT(DISTINCT o.order_date) AS order_count_30d,
    SUM(o.order_total) AS revenue_30d
  FROM send_users su
  LEFT JOIN user_orders o
    ON su.user_id = o.user_id
    AND o.order_date BETWEEN su.first_send_date
        AND DATE_ADD(su.first_send_date, INTERVAL 30 DAY)
  GROUP BY su.user_id, su.treatment_type, su.period
)
SELECT
  r7.treatment_type,
  r7.period,
  COUNT(DISTINCT r7.user_id) AS users_sent,
  -- 7-day attribution
  COUNTIF(r7.order_count_7d > 0) AS buyers_7d,
  ROUND(SAFE_DIVIDE(COUNTIF(r7.order_count_7d > 0),
    COUNT(DISTINCT r7.user_id)) * 100, 2) AS conversion_rate_7d_pct,
  ROUND(SUM(r7.revenue_7d), 2) AS revenue_7d,
  ROUND(SAFE_DIVIDE(SUM(r7.revenue_7d),
    COUNT(DISTINCT r7.user_id)), 2) AS revenue_per_user_7d,
  -- 30-day attribution
  COUNTIF(r30.order_count_30d > 0) AS buyers_30d,
  ROUND(SAFE_DIVIDE(COUNTIF(r30.order_count_30d > 0),
    COUNT(DISTINCT r7.user_id)) * 100, 2) AS conversion_rate_30d_pct,
  ROUND(SUM(r30.revenue_30d), 2) AS revenue_30d,
  ROUND(SAFE_DIVIDE(SUM(r30.revenue_30d),
    COUNT(DISTINCT r7.user_id)), 2) AS revenue_per_user_30d
FROM rev_7d r7
JOIN rev_30d r30
  ON r7.user_id = r30.user_id
  AND r7.treatment_type = r30.treatment_type
  AND r7.period = r30.period
GROUP BY r7.treatment_type, r7.period
ORDER BY r7.period, r7.treatment_type;


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
