-- ============================================================
-- Bandit Model Investigation Phase 2: Why Can't the Model Learn?
-- ============================================================
-- Date: 2026-02-07
-- Objective: Deep investigation into the root causes of bandit model
--   failure. Phase 1 confirmed the model updates but doesn't learn.
--   Phase 2 tests three hypotheses:
--     H1: Data quality issue (bad training data)
--     H2: Configuration issue (wrong priors, too many treatments)
--     H3: Structural limitation (NIG TS can't learn at this volume)
--
-- Model: 195001001 (arm 4689, NIG Thompson Sampling)
-- Prior: NIG(alpha=1, beta=1, mu=0, lambda=1) — stateless, retrained daily
-- Training window: ~120 days
--
-- Run each query individually:
--   bq query --use_legacy_sql=false "QUERY"
-- ============================================================


-- ============================================================
-- Q11: Training Data Quality Audit
-- ============================================================
-- Purpose: Check if the model is being trained on bad data.
-- Tests: phantom clicks, duplicate sends, non-LIVE leakage,
--        time-travel clicks (click before send).
--
-- Expected: Clean data = structural issue; dirty data = fixable.

WITH send_data AS (
  SELECT
    h.treatment_tracking_id,
    h.treatment_id,
    h.user_id,
    h.treatment_sent_timestamp,
    h.request_source,
    h.model_id,
    h.score,
    MAX(CASE WHEN i.interaction_type = 'VIEWED' THEN 1 ELSE 0 END) AS opened,
    MAX(CASE WHEN i.interaction_type = 'CLICKED' THEN 1 ELSE 0 END) AS clicked,
    MIN(CASE WHEN i.interaction_type = 'VIEWED' THEN i.interaction_timestamp_micros END) AS first_open_ts,
    MIN(CASE WHEN i.interaction_type = 'CLICKED' THEN i.interaction_timestamp_micros END) AS first_click_ts
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2025-10-01' AND CURRENT_DATE()
  GROUP BY h.treatment_tracking_id, h.treatment_id, h.user_id,
           h.treatment_sent_timestamp, h.request_source, h.model_id, h.score
)
SELECT
  'Total sends in training window' AS metric,
  COUNT(*) AS value
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Phantom clicks (clicked=1, opened=0)',
  COUNTIF(clicked = 1 AND opened = 0)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Phantom clicks - Bandit arm only',
  COUNTIF(clicked = 1 AND opened = 0 AND model_id = 195001001)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Duplicate treatment_tracking_ids',
  COUNT(*) - COUNT(DISTINCT treatment_tracking_id)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Non-LIVE sends (SIMULATION/QA) on surface 929',
  COUNT(*)
FROM send_data
WHERE request_source != 'LIVE'

UNION ALL

SELECT
  'Time-travel clicks (click before send)',
  COUNTIF(first_click_ts < treatment_sent_timestamp AND clicked = 1)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Time-travel opens (open before send)',
  COUNTIF(first_open_ts < treatment_sent_timestamp AND opened = 1)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Sends with score <= 0',
  COUNTIF(score <= 0 AND model_id = 195001001)
FROM send_data
WHERE request_source = 'LIVE'

UNION ALL

SELECT
  'Sends with score > 1.0 (invalid)',
  COUNTIF(score > 1.0 AND model_id = 195001001)
FROM send_data
WHERE request_source = 'LIVE'

ORDER BY metric;


-- ============================================================
-- Q12: Treatment Count & Effective Competition
-- ============================================================
-- Purpose: How many treatments compete per day? 30+ may be too many
--   for NIG TS to learn at this data volume.
-- Shows daily treatment count, concentration (top treatment share),
--   and campaign type breakdown.

WITH daily_treatments AS (
  SELECT
    DATE(treatment_sent_timestamp) AS send_date,
    treatment_id,
    COUNT(*) AS sends
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
  GROUP BY send_date, treatment_id
),
daily_summary AS (
  SELECT
    send_date,
    COUNT(DISTINCT treatment_id) AS num_treatments,
    SUM(sends) AS total_sends,
    MAX(sends) AS top_treatment_sends,
    ROUND(MAX(sends) * 100.0 / SUM(sends), 2) AS top_treatment_pct,
    -- Herfindahl-Hirschman Index (HHI) for concentration
    ROUND(SUM(POW(sends * 1.0 / SUM(sends) OVER (PARTITION BY send_date), 2)), 4) AS hhi
  FROM daily_treatments
  GROUP BY send_date
)
SELECT
  send_date,
  num_treatments,
  total_sends,
  top_treatment_sends,
  top_treatment_pct,
  hhi,
  -- HHI interpretation: 1/N = perfectly uniform, 1.0 = monopoly
  ROUND(1.0 / num_treatments, 4) AS uniform_hhi
FROM daily_summary
ORDER BY send_date;


-- ============================================================
-- Q13: NIG Math Verification
-- ============================================================
-- Purpose: Can we reproduce the platform's NIG posterior from raw data?
--
-- NIG prior: alpha=1, beta=1, mu=0, lambda=1
-- After n observations with sum of rewards k and sum of squared rewards ss:
--   lambda_new = lambda + n = 1 + n
--   mu_new = (lambda*mu + k) / lambda_new = k / (1 + n)
--   alpha_new = alpha + n/2 = 1 + n/2
--   beta_new = beta + 0.5*(ss - k^2/lambda_new) + 0.5*lambda*(k/n - mu)^2*n/lambda_new
--
-- For Bernoulli rewards (click=1/0): ss = k (since 1^2 = 1)
--
-- The posterior mean (expected CTR) = mu_new = k / (1 + n)
-- This should match the avg bandit score for each treatment.

WITH treatment_stats AS (
  SELECT
    h.treatment_id,
    COUNT(*) AS n_sends,
    SUM(CASE WHEN i.interaction_type = 'CLICKED' THEN 1 ELSE 0 END) AS n_clicks,
    SUM(CASE WHEN i.interaction_type = 'VIEWED' THEN 1 ELSE 0 END) AS n_opens
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND h.model_id = 195001001
    -- Training window: ~120 days before current date
    AND DATE(h.treatment_sent_timestamp) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY) AND CURRENT_DATE()
  GROUP BY h.treatment_id
),
recent_scores AS (
  -- Get the most recent avg score for each treatment (last 3 days)
  SELECT
    treatment_id,
    ROUND(AVG(score), 6) AS recent_avg_score,
    ROUND(STDDEV(score), 6) AS recent_stddev_score,
    COUNT(*) AS recent_sends
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND DATE(treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 DAY)
  GROUP BY treatment_id
),
nig_calc AS (
  SELECT
    ts.treatment_id,
    ts.n_sends,
    ts.n_clicks,
    ts.n_opens,
    -- NIG posterior mean: mu_new = k / (lambda + n) = k / (1 + n)
    ROUND(SAFE_DIVIDE(ts.n_clicks, 1 + ts.n_sends), 6) AS expected_mu,
    -- NIG posterior parameters
    1 + ts.n_sends AS lambda_new,
    1 + ts.n_sends / 2.0 AS alpha_new,
    -- Actual observed CTR (clicks / sends)
    ROUND(SAFE_DIVIDE(ts.n_clicks, ts.n_sends) * 100, 2) AS actual_ctr_pct,
    rs.recent_avg_score,
    rs.recent_stddev_score,
    rs.recent_sends
  FROM treatment_stats ts
  LEFT JOIN recent_scores rs ON ts.treatment_id = rs.treatment_id
  WHERE ts.n_sends >= 100  -- Only treatments with enough data
)
SELECT
  treatment_id,
  n_sends,
  n_clicks,
  actual_ctr_pct,
  expected_mu,
  recent_avg_score,
  -- Difference between expected and actual score
  ROUND(recent_avg_score - expected_mu, 6) AS score_vs_expected_delta,
  -- Ratio: how far off is the actual score from expected?
  ROUND(SAFE_DIVIDE(recent_avg_score, expected_mu), 2) AS score_vs_expected_ratio,
  recent_stddev_score,
  -- Expected stddev: sqrt(beta / (lambda * (alpha - 0.5)))
  -- For Bernoulli with NIG(1,1,0,1) after n obs, k clicks:
  -- Approximate: sqrt(1 / ((1+n) * (0.5 + n/2)))
  ROUND(SQRT(SAFE_DIVIDE(1.0, (1 + n_sends) * (0.5 + n_sends / 2.0))), 6) AS expected_approx_stddev,
  CASE
    WHEN ABS(recent_avg_score - expected_mu) < 0.005 THEN 'MATCH (<0.5pp)'
    WHEN ABS(recent_avg_score - expected_mu) < 0.01 THEN 'CLOSE (<1pp)'
    WHEN ABS(recent_avg_score - expected_mu) < 0.02 THEN 'DIVERGENT (1-2pp)'
    ELSE 'MISMATCH (>2pp)'
  END AS verdict
FROM nig_calc
ORDER BY n_sends DESC
LIMIT 20;


-- ============================================================
-- Q14: Score > 1.0 Forensics
-- ============================================================
-- Purpose: What caused the Jan 23-30 anomaly?
-- Tests which treatments had invalid scores, their click patterns
-- before the anomaly, and daily volume of invalid scores.

-- Part A: Daily volume of invalid scores
SELECT
  'A: Daily invalid score counts' AS section,
  DATE(treatment_sent_timestamp) AS send_date,
  CAST(NULL AS INT64) AS treatment_id,
  COUNT(*) AS sends_with_score_gt_1,
  ROUND(AVG(score), 4) AS avg_invalid_score,
  ROUND(MAX(score), 4) AS max_score,
  ROUND(MIN(score), 4) AS min_invalid_score
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929
  AND request_source = 'LIVE'
  AND model_id = 195001001
  AND score > 1.0
  AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-20' AND '2026-02-05'
GROUP BY send_date
ORDER BY send_date;


-- ============================================================
-- Q14B: Which treatments had scores > 1.0?
-- ============================================================
SELECT
  treatment_id,
  COUNT(*) AS invalid_score_sends,
  ROUND(AVG(score), 4) AS avg_invalid_score,
  ROUND(MAX(score), 4) AS max_score,
  MIN(DATE(treatment_sent_timestamp)) AS first_invalid_date,
  MAX(DATE(treatment_sent_timestamp)) AS last_invalid_date
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929
  AND request_source = 'LIVE'
  AND model_id = 195001001
  AND score > 1.0
  AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
GROUP BY treatment_id
ORDER BY invalid_score_sends DESC
LIMIT 15;


-- ============================================================
-- Q14C: Click patterns of anomalous treatments before Jan 23
-- ============================================================
-- Were the treatments with scores > 1.0 high-click treatments
-- or low-volume ones where a single click inflated the posterior?
WITH anomalous_treatments AS (
  SELECT DISTINCT treatment_id
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND score > 1.0
),
pre_anomaly AS (
  SELECT
    h.treatment_id,
    COUNT(*) AS sends_before,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN h.treatment_tracking_id END) AS clicks_before,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN h.treatment_tracking_id END) AS opens_before,
    ROUND(SAFE_DIVIDE(
      COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN h.treatment_tracking_id END),
      COUNT(*)
    ) * 100, 2) AS ctr_before_pct
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  JOIN anomalous_treatments a ON h.treatment_id = a.treatment_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND h.model_id = 195001001
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2025-10-01' AND '2026-01-22'
  GROUP BY h.treatment_id
)
SELECT
  p.treatment_id,
  p.sends_before,
  p.clicks_before,
  p.opens_before,
  p.ctr_before_pct,
  CASE
    WHEN p.sends_before < 50 THEN 'LOW volume'
    WHEN p.sends_before < 200 THEN 'MEDIUM volume'
    ELSE 'HIGH volume'
  END AS volume_category
FROM pre_anomaly p
ORDER BY p.sends_before ASC;


-- ============================================================
-- Q15: Click Latency — Is Training Data Fresh?
-- ============================================================
-- Purpose: When a click happens, how quickly does it affect scores?
-- Approach: For each click event, find the next day's score for
-- that treatment and measure the delta.
--
-- If clicks from day D appear in day D+1 scores: pipeline is fresh.
-- If lag > 1 day: the model may be training on stale data.

WITH daily_clicks AS (
  SELECT
    h.treatment_id,
    DATE(h.treatment_sent_timestamp) AS send_date,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN h.treatment_tracking_id END) AS clicks,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN h.treatment_tracking_id END) AS opens,
    COUNT(*) AS sends
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND h.model_id = 195001001
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
  GROUP BY h.treatment_id, send_date
),
daily_scores AS (
  SELECT
    treatment_id,
    DATE(treatment_sent_timestamp) AS send_date,
    ROUND(AVG(score), 6) AS avg_score
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
  GROUP BY treatment_id, send_date
),
joined AS (
  SELECT
    c.treatment_id,
    c.send_date,
    c.clicks,
    c.sends,
    s.avg_score AS score_today,
    LEAD(s.avg_score) OVER (PARTITION BY c.treatment_id ORDER BY c.send_date) AS score_tomorrow,
    LEAD(s.avg_score, 2) OVER (PARTITION BY c.treatment_id ORDER BY c.send_date) AS score_day_after
  FROM daily_clicks c
  JOIN daily_scores s ON c.treatment_id = s.treatment_id AND c.send_date = s.send_date
  WHERE c.clicks > 0  -- Only days with clicks
)
SELECT
  treatment_id,
  send_date AS click_date,
  clicks,
  sends,
  score_today,
  score_tomorrow,
  ROUND(score_tomorrow - score_today, 6) AS delta_d1,
  score_day_after,
  ROUND(score_day_after - score_today, 6) AS delta_d2,
  CASE
    WHEN score_tomorrow > score_today THEN 'UP (expected)'
    WHEN score_tomorrow < score_today THEN 'DOWN (unexpected)'
    ELSE 'FLAT'
  END AS d1_direction
FROM joined
WHERE score_tomorrow IS NOT NULL
ORDER BY treatment_id, send_date;


-- ============================================================
-- Q16: Per-Treatment Data Volume for NIG Convergence Simulation
-- ============================================================
-- Purpose: Extract real per-treatment data to feed into the
--   Python NIG convergence simulation.
-- Output: For each active treatment in bandit arm:
--   total_sends, total_opens, total_clicks, actual_ctr
--   Grouped by campaign type.
-- This directly feeds src/nig_convergence_simulation.py.

WITH treatment_data AS (
  SELECT
    h.treatment_id,
    CASE
      WHEN h.treatment_id IN (16150700, 20142778, 20142785, 20142804, 20142811,
                               20142818, 20142825, 20142832, 20142839, 20142846)
        THEN 'Post Purchase - Personalized'
      WHEN h.treatment_id IN (16490932, 16490939, 16518436, 16518443, 16564380,
                               16564387, 16564394, 16564401, 16564408, 16564415,
                               16564423, 16564431, 16564439, 16564447, 16564455,
                               16564463, 16593451, 16593459, 16593467, 16593475,
                               16593483, 16593491)
        THEN 'Post Purchase - Static'
      ELSE 'Browse Recovery / Abandon Cart'
    END AS campaign_type,
    COUNT(DISTINCT h.treatment_tracking_id) AS total_sends,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN h.treatment_tracking_id END) AS total_opens,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN h.treatment_tracking_id END) AS total_clicks,
    -- Date range for this treatment
    MIN(DATE(h.treatment_sent_timestamp)) AS first_send_date,
    MAX(DATE(h.treatment_sent_timestamp)) AS last_send_date,
    DATE_DIFF(MAX(DATE(h.treatment_sent_timestamp)), MIN(DATE(h.treatment_sent_timestamp)), DAY) + 1 AS active_days
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND h.model_id = 195001001
    AND DATE(h.treatment_sent_timestamp) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY) AND CURRENT_DATE()
  GROUP BY h.treatment_id, campaign_type
)
SELECT
  treatment_id,
  campaign_type,
  total_sends,
  total_opens,
  total_clicks,
  ROUND(SAFE_DIVIDE(total_opens, total_sends) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(total_clicks, total_sends) * 100, 2) AS ctr_of_sends_pct,
  ROUND(SAFE_DIVIDE(total_clicks, total_opens) * 100, 2) AS ctr_of_opens_pct,
  first_send_date,
  last_send_date,
  active_days,
  -- Derived: avg sends per day and clicks per week
  ROUND(SAFE_DIVIDE(total_sends, active_days), 1) AS sends_per_day,
  ROUND(SAFE_DIVIDE(total_clicks, active_days) * 7, 1) AS clicks_per_week
FROM treatment_data
ORDER BY total_sends DESC;
