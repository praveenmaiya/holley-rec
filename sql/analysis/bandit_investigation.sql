-- ============================================================
-- Bandit Model Investigation: Is Model 195001001 Learning?
-- ============================================================
-- Date: 2026-02-06
-- Objective: Determine why the bandit model (arm 4689, model 195001001)
--   is not improving CTR. Diagnose whether the model is updating daily,
--   quantify the performance impact, and identify root causes.
--
-- Context:
--   - Arm 4103 (model_id=1): Random, boost-weighted selection
--   - Arm 4689 (model_id=195001001): Bandit, Thompson Sampling
--   - 50/50 split since Jan 14, 2026 (was ~90/10 before)
--   - Bandit scores ~10x lower than Random (0.08 vs 0.87)
--   - All campaigns: Browse Recovery (73%), Abandon Cart (13%), Post Purchase (14%)
--
-- Run each query individually:
--   bq query --use_legacy_sql=false "QUERY"
-- ============================================================


-- ============================================================
-- PHASE 1: IS THE MODEL UPDATING? (Run first)
-- ============================================================

-- ============================================================
-- QUERY 1: Daily Score Drift Detection
-- ============================================================
-- If the model is learning, daily avg/stddev scores should shift.
-- If NOT learning, scores will be identical across all days (frozen params).
SELECT
  DATE(treatment_sent_timestamp) AS send_date,
  CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
  COUNT(*) AS sends,
  ROUND(AVG(score), 6) AS avg_score,
  ROUND(STDDEV(score), 6) AS stddev_score,
  ROUND(MIN(score), 6) AS min_score,
  ROUND(MAX(score), 6) AS max_score,
  COUNT(DISTINCT ROUND(score, 4)) AS distinct_scores
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929
  AND request_source = 'LIVE'
  AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-10' AND CURRENT_DATE()
GROUP BY send_date, arm
ORDER BY send_date, arm;


-- ============================================================
-- QUERY 2: Per-Treatment Score Evolution
-- ============================================================
-- Shows whether the same treatment's score changes day-to-day.
-- Frozen per-treatment scores = definitive proof the model is not updating.
-- Focuses on bandit arm (model_id = 195001001) and top 5 treatments by volume.
WITH top_treatments AS (
  SELECT treatment_id
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-10' AND CURRENT_DATE()
  GROUP BY treatment_id
  ORDER BY COUNT(*) DESC
  LIMIT 5
)
SELECT
  DATE(h.treatment_sent_timestamp) AS send_date,
  h.treatment_id,
  COUNT(*) AS sends,
  ROUND(AVG(h.score), 6) AS avg_score,
  ROUND(STDDEV(h.score), 6) AS stddev_score,
  ROUND(MIN(h.score), 6) AS min_score,
  ROUND(MAX(h.score), 6) AS max_score
FROM `auxia-gcp.company_1950.treatment_history_sent` h
JOIN top_treatments t ON h.treatment_id = t.treatment_id
WHERE h.surface_id = 929
  AND h.request_source = 'LIVE'
  AND h.model_id = 195001001
  AND DATE(h.treatment_sent_timestamp) BETWEEN '2026-01-10' AND CURRENT_DATE()
GROUP BY send_date, h.treatment_id
ORDER BY h.treatment_id, send_date;


-- ============================================================
-- QUERY 6: Click Feedback Loop Verification
-- ============================================================
-- Tests the causal chain: click on day D → score increase on day D+1.
-- If the model learns, treatments that got clicked should see score bumps.
WITH daily_scores AS (
  SELECT
    DATE(treatment_sent_timestamp) AS send_date,
    treatment_id,
    ROUND(AVG(score), 6) AS avg_score,
    COUNT(*) AS sends
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND model_id = 195001001
    AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-10' AND CURRENT_DATE()
  GROUP BY send_date, treatment_id
),
daily_clicks AS (
  SELECT
    DATE(h.treatment_sent_timestamp) AS send_date,
    h.treatment_id,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN h.treatment_tracking_id END) AS clicks,
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN h.treatment_tracking_id END) AS opens
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND h.model_id = 195001001
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2026-01-10' AND CURRENT_DATE()
  GROUP BY send_date, h.treatment_id
)
SELECT
  s.send_date,
  s.treatment_id,
  s.sends,
  s.avg_score,
  COALESCE(c.opens, 0) AS opens,
  COALESCE(c.clicks, 0) AS clicks,
  -- Next day's score for this treatment
  LEAD(s.avg_score) OVER (PARTITION BY s.treatment_id ORDER BY s.send_date) AS next_day_score,
  ROUND(LEAD(s.avg_score) OVER (PARTITION BY s.treatment_id ORDER BY s.send_date) - s.avg_score, 6) AS score_delta
FROM daily_scores s
LEFT JOIN daily_clicks c ON s.send_date = c.send_date AND s.treatment_id = c.treatment_id
ORDER BY s.treatment_id, s.send_date;


-- ============================================================
-- PHASE 2: PERFORMANCE ASSESSMENT
-- ============================================================

-- ============================================================
-- QUERY 4: Weekly CTR by Arm (All Campaigns)
-- ============================================================
-- Uses corrected CTR formula. Covers all campaigns, not just Post Purchase.
-- If learning: Bandit CTR should trend upward week-over-week.
WITH base AS (
  SELECT
    h.treatment_tracking_id,
    DATE(h.treatment_sent_timestamp) AS send_date,
    DATE_TRUNC(DATE(h.treatment_sent_timestamp), WEEK(MONDAY)) AS week_start,
    CASE WHEN h.model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
    MAX(CASE WHEN i.interaction_type = 'VIEWED' THEN 1 ELSE 0 END) AS opened,
    MAX(CASE WHEN i.interaction_type = 'CLICKED' THEN 1 ELSE 0 END) AS clicked
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2025-12-16' AND CURRENT_DATE()
  GROUP BY h.treatment_tracking_id, send_date, week_start, arm
)
SELECT
  week_start,
  arm,
  COUNT(*) AS sends,
  SUM(opened) AS opens,
  SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END), SUM(opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END), COUNT(*)) * 100, 2) AS ctr_of_sends_pct
FROM base
GROUP BY week_start, arm
ORDER BY week_start, arm;


-- ============================================================
-- QUERY 7: All-Campaign Bandit Performance (Pre vs Post 50/50)
-- ============================================================
-- Covers Browse Recovery (73%), Abandon Cart (13%), Post Purchase (14%).
-- Pre-50/50: before Jan 14, Post-50/50: Jan 14 onwards.
WITH base AS (
  SELECT
    h.treatment_tracking_id,
    h.treatment_id,
    CASE WHEN h.model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
    CASE
      WHEN DATE(h.treatment_sent_timestamp) < '2026-01-14' THEN 'Pre-50/50'
      ELSE 'Post-50/50'
    END AS period,
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
    MAX(CASE WHEN i.interaction_type = 'VIEWED' THEN 1 ELSE 0 END) AS opened,
    MAX(CASE WHEN i.interaction_type = 'CLICKED' THEN 1 ELSE 0 END) AS clicked
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND DATE(h.treatment_sent_timestamp) BETWEEN '2025-12-16' AND CURRENT_DATE()
  GROUP BY h.treatment_tracking_id, h.treatment_id, arm, period, campaign_type
)
SELECT
  period,
  arm,
  campaign_type,
  COUNT(*) AS sends,
  SUM(opened) AS opens,
  SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END), SUM(opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END), COUNT(*)) * 100, 2) AS ctr_of_sends_pct
FROM base
GROUP BY period, arm, campaign_type
ORDER BY campaign_type, period, arm;


-- ============================================================
-- QUERY 10: Last 7 Days Health Check
-- ============================================================
-- Daily bandit stats for immediate actionability.
WITH base AS (
  SELECT
    h.treatment_tracking_id,
    DATE(h.treatment_sent_timestamp) AS send_date,
    CASE WHEN h.model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
    h.score,
    MAX(CASE WHEN i.interaction_type = 'VIEWED' THEN 1 ELSE 0 END) AS opened,
    MAX(CASE WHEN i.interaction_type = 'CLICKED' THEN 1 ELSE 0 END) AS clicked
  FROM `auxia-gcp.company_1950.treatment_history_sent` h
  LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
    ON h.treatment_tracking_id = i.treatment_tracking_id
  WHERE h.surface_id = 929
    AND h.request_source = 'LIVE'
    AND DATE(h.treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
  GROUP BY h.treatment_tracking_id, send_date, arm, h.score
)
SELECT
  send_date,
  arm,
  COUNT(*) AS sends,
  ROUND(AVG(score), 4) AS avg_score,
  ROUND(STDDEV(score), 4) AS stddev_score,
  SUM(opened) AS opens,
  SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN opened = 1 AND clicked = 1 THEN 1 ELSE 0 END), SUM(opened)) * 100, 2) AS ctr_of_opens_pct
FROM base
GROUP BY send_date, arm
ORDER BY send_date, arm;


-- ============================================================
-- PHASE 3: ARCHITECTURE & CONFIGURATION
-- ============================================================

-- ============================================================
-- QUERY 3: Current Arm Split Over Time
-- ============================================================
-- Weekly arm split to confirm current allocation and detect any changes.
SELECT
  week_start,
  arm,
  sends,
  ROUND(sends * 100.0 / SUM(sends) OVER (PARTITION BY week_start), 1) AS pct_of_week
FROM (
  SELECT
    DATE_TRUNC(DATE(treatment_sent_timestamp), WEEK(MONDAY)) AS week_start,
    CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
    COUNT(*) AS sends
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND DATE(treatment_sent_timestamp) BETWEEN '2025-12-16' AND CURRENT_DATE()
  GROUP BY week_start, arm
)
ORDER BY week_start, arm;


-- ============================================================
-- QUERY 5: Treatment Selection Distribution by Arm
-- ============================================================
-- Is the bandit converging on better treatments (exploitation) or uniform (no learning)?
-- Compares pre vs post 50/50 split.
WITH base AS (
  SELECT
    treatment_id,
    CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
    CASE
      WHEN DATE(treatment_sent_timestamp) < '2026-01-14' THEN 'Pre-50/50'
      ELSE 'Post-50/50'
    END AS period
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND DATE(treatment_sent_timestamp) BETWEEN '2025-12-16' AND CURRENT_DATE()
)
SELECT
  period,
  arm,
  treatment_id,
  COUNT(*) AS sends,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY period, arm), 2) AS pct_of_arm
FROM base
GROUP BY period, arm, treatment_id
HAVING COUNT(*) >= 100
ORDER BY period, arm, sends DESC;


-- ============================================================
-- QUERY 8: Score Calibration (Why 10x Lower?)
-- ============================================================
-- Full score distribution histogram for both models.
-- Answers: Are bandit scores = raw CTR posteriors (~1-5%) vs random = normalized (0.5-0.99)?
SELECT
  CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END AS arm,
  CASE
    WHEN score < 0.01 THEN '[0.00, 0.01)'
    WHEN score < 0.05 THEN '[0.01, 0.05)'
    WHEN score < 0.10 THEN '[0.05, 0.10)'
    WHEN score < 0.20 THEN '[0.10, 0.20)'
    WHEN score < 0.30 THEN '[0.20, 0.30)'
    WHEN score < 0.50 THEN '[0.30, 0.50)'
    WHEN score < 0.70 THEN '[0.50, 0.70)'
    WHEN score < 0.90 THEN '[0.70, 0.90)'
    ELSE '[0.90, 1.00]'
  END AS score_bucket,
  COUNT(*) AS sends,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END), 2) AS pct_of_arm,
  ROUND(MIN(score), 4) AS bucket_min,
  ROUND(MAX(score), 4) AS bucket_max
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929
  AND request_source = 'LIVE'
  AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
GROUP BY arm, score_bucket
ORDER BY arm, score_bucket;


-- ============================================================
-- QUERY 9: User-Arm Stickiness
-- ============================================================
-- Do users stay on the same arm or switch between Random and Bandit?
-- Heavy switching = fragmented learning signal.
WITH user_arms AS (
  SELECT
    user_id,
    COUNT(DISTINCT CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END) AS num_arms,
    SUM(CASE WHEN model_id = 1 THEN 1 ELSE 0 END) AS random_sends,
    SUM(CASE WHEN model_id != 1 THEN 1 ELSE 0 END) AS bandit_sends,
    COUNT(*) AS total_sends
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929
    AND request_source = 'LIVE'
    AND DATE(treatment_sent_timestamp) BETWEEN '2026-01-14' AND CURRENT_DATE()
  GROUP BY user_id
)
SELECT
  CASE
    WHEN num_arms = 1 AND random_sends > 0 AND bandit_sends = 0 THEN 'Random Only'
    WHEN num_arms = 1 AND bandit_sends > 0 AND random_sends = 0 THEN 'Bandit Only'
    ELSE 'Both Arms'
  END AS user_segment,
  COUNT(*) AS users,
  SUM(total_sends) AS total_sends,
  ROUND(AVG(total_sends), 1) AS avg_sends_per_user,
  SUM(random_sends) AS random_sends,
  SUM(bandit_sends) AS bandit_sends
FROM user_arms
GROUP BY user_segment
ORDER BY users DESC;
