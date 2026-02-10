-- ============================================================
-- FINDING 1 FIX: Per-Campaign Within-User Overlap
-- The original SQL used cross-campaign overlap (users who got P
-- anywhere AND S anywhere). This fixes it to per-campaign overlap.
-- ============================================================

DECLARE analysis_start DATE DEFAULT '2025-12-04';
DECLARE analysis_end DATE DEFAULT '2026-02-09';
DECLARE interaction_end DATE DEFAULT '2026-02-16';

CREATE TEMP TABLE treatment_metadata AS
SELECT * FROM EXTERNAL_QUERY(
  'projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb',
  'SELECT treatment_id, name FROM treatment WHERE company_id = 1950'
);

CREATE TEMP TABLE treatment_classified AS
SELECT
  treatment_id,
  name,
  CASE
    WHEN LOWER(name) LIKE '%browse recovery%' THEN 'Browse Recovery'
    WHEN LOWER(name) LIKE '%abandon cart%' THEN 'Abandon Cart'
    WHEN LOWER(name) LIKE '%post purchase%' THEN 'Post Purchase'
    WHEN LOWER(name) LIKE '%burst%' THEN 'Burst'
    ELSE 'Other'
  END AS campaign,
  CASE
    WHEN LOWER(name) LIKE '%personalized%' OR LOWER(name) LIKE '%fitment%' THEN 'Personalized'
    WHEN LOWER(name) LIKE '%static%' OR LOWER(name) LIKE '%no rec%' THEN 'Static'
    ELSE 'Other'
  END AS treatment_type
FROM treatment_metadata;

CREATE TEMP TABLE fitment_users AS
SELECT user_id
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
  UNNEST(user_properties) AS p
WHERE LOWER(p.property_name) IN ('v1_year', 'v1_make', 'v1_model')
  AND (NULLIF(TRIM(p.string_value), '') IS NOT NULL OR p.long_value IS NOT NULL)
GROUP BY user_id
HAVING COUNT(DISTINCT LOWER(p.property_name)) = 3;

CREATE TEMP TABLE opens AS
SELECT DISTINCT treatment_tracking_id
FROM `auxia-gcp.company_1950.treatment_interaction`
WHERE interaction_type = 'VIEWED'
  AND DATE(interaction_timestamp_micros) BETWEEN analysis_start AND interaction_end;

CREATE TEMP TABLE clicks AS
SELECT DISTINCT treatment_tracking_id
FROM `auxia-gcp.company_1950.treatment_interaction`
WHERE interaction_type = 'CLICKED'
  AND DATE(interaction_timestamp_micros) BETWEEN analysis_start AND interaction_end;

CREATE TEMP TABLE base AS
SELECT
  th.user_id,
  th.treatment_id,
  th.treatment_tracking_id,
  DATE(th.treatment_sent_timestamp) AS send_date,
  th.arm_id,
  CASE WHEN th.arm_id = 4103 THEN 'Random' WHEN th.arm_id = 4689 THEN 'Bandit' ELSE CAST(th.arm_id AS STRING) END AS arm_name,
  tc.campaign,
  tc.treatment_type,
  tc.name AS treatment_name,
  fu.user_id IS NOT NULL AS fitment_eligible,
  CASE WHEN o.treatment_tracking_id IS NOT NULL THEN 1 ELSE 0 END AS opened,
  CASE WHEN c.treatment_tracking_id IS NOT NULL THEN 1 ELSE 0 END AS clicked
FROM `auxia-gcp.company_1950.treatment_history_sent` th
JOIN treatment_classified tc ON th.treatment_id = tc.treatment_id
LEFT JOIN fitment_users fu ON th.user_id = fu.user_id
LEFT JOIN opens o ON th.treatment_tracking_id = o.treatment_tracking_id
LEFT JOIN clicks c ON th.treatment_tracking_id = c.treatment_tracking_id
WHERE th.request_source = 'LIVE'
  AND DATE(th.treatment_sent_timestamp) BETWEEN analysis_start AND analysis_end
  AND tc.campaign IN ('Browse Recovery', 'Abandon Cart', 'Post Purchase')
  AND tc.treatment_type IN ('Personalized', 'Static');

-- ============================================================
-- Pre-compute per-campaign overlap users (avoids correlated subquery)
-- ============================================================

-- Per-campaign overlap for RANDOM arm
CREATE TEMP TABLE overlap_random AS
SELECT p.user_id, p.campaign
FROM (SELECT DISTINCT user_id, campaign FROM base WHERE arm_name = 'Random' AND treatment_type = 'Personalized') p
JOIN (SELECT DISTINCT user_id, campaign FROM base WHERE arm_name = 'Random' AND treatment_type = 'Static') s
  ON p.user_id = s.user_id AND p.campaign = s.campaign;

-- Per-campaign overlap for BOTH arms
CREATE TEMP TABLE overlap_both AS
SELECT p.user_id, p.campaign
FROM (SELECT DISTINCT user_id, campaign FROM base WHERE treatment_type = 'Personalized') p
JOIN (SELECT DISTINCT user_id, campaign FROM base WHERE treatment_type = 'Static') s
  ON p.user_id = s.user_id AND p.campaign = s.campaign;


-- ============================================================
-- A1-A3: Within-user, Random arm, PER-CAMPAIGN overlap (FIXED)
-- ============================================================

SELECT
  'A1-A3: Within-User P vs S (Random Arm, Per-Campaign Overlap)' AS comparison,
  b.campaign,
  b.treatment_type,
  COUNT(DISTINCT b.user_id) AS users,
  COUNT(*) AS sends,
  SUM(b.opened) AS opens,
  SUM(CASE WHEN b.opened = 1 AND b.clicked = 1 THEN 1 ELSE 0 END) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(b.opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN b.opened = 1 AND b.clicked = 1 THEN 1 ELSE 0 END), SUM(b.opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN b.clicked = 1 THEN b.user_id END),
    COUNT(DISTINCT b.user_id)
  ) * 100, 2) AS pct_users_clicked,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN b.opened = 1 THEN b.user_id END),
    COUNT(DISTINCT b.user_id)
  ) * 100, 2) AS pct_users_opened
FROM base b
JOIN overlap_random o ON b.user_id = o.user_id AND b.campaign = o.campaign
WHERE b.arm_name = 'Random'
GROUP BY b.campaign, b.treatment_type
ORDER BY b.campaign, b.treatment_type;


-- ============================================================
-- A4-A6: Within-user, Both arms, PER-CAMPAIGN overlap (FIXED)
-- ============================================================

SELECT
  'A4-A6: Within-User P vs S (Both Arms, Per-Campaign Overlap)' AS comparison,
  b.campaign,
  b.treatment_type,
  COUNT(DISTINCT b.user_id) AS users,
  COUNT(*) AS sends,
  SUM(b.opened) AS opens,
  SUM(CASE WHEN b.opened = 1 AND b.clicked = 1 THEN 1 ELSE 0 END) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(b.opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(CASE WHEN b.opened = 1 AND b.clicked = 1 THEN 1 ELSE 0 END), SUM(b.opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN b.clicked = 1 THEN b.user_id END),
    COUNT(DISTINCT b.user_id)
  ) * 100, 2) AS pct_users_clicked,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN b.opened = 1 THEN b.user_id END),
    COUNT(DISTINCT b.user_id)
  ) * 100, 2) AS pct_users_opened
FROM base b
JOIN overlap_both o ON b.user_id = o.user_id AND b.campaign = o.campaign
GROUP BY b.campaign, b.treatment_type
ORDER BY b.campaign, b.treatment_type;


-- ============================================================
-- Finding 2: Section F user preference with per-campaign overlap (FIXED)
-- ============================================================

WITH user_clicks AS (
  SELECT
    b.user_id,
    b.campaign,
    MAX(CASE WHEN b.treatment_type = 'Personalized' AND b.clicked = 1 THEN 1 ELSE 0 END) AS clicked_p,
    MAX(CASE WHEN b.treatment_type = 'Static' AND b.clicked = 1 THEN 1 ELSE 0 END) AS clicked_s
  FROM base b
  JOIN overlap_random o ON b.user_id = o.user_id AND b.campaign = o.campaign
  WHERE b.arm_name = 'Random'
  GROUP BY b.user_id, b.campaign
)
SELECT
  'F: User Preference (Random Arm, Per-Campaign Overlap)' AS comparison,
  campaign,
  COUNTIF(clicked_p = 1 AND clicked_s = 0) AS clicked_P_only,
  COUNTIF(clicked_p = 0 AND clicked_s = 1) AS clicked_S_only,
  COUNTIF(clicked_p = 1 AND clicked_s = 1) AS clicked_both,
  COUNTIF(clicked_p = 0 AND clicked_s = 0) AS clicked_neither,
  COUNT(*) AS total_overlap_users
FROM user_clicks
GROUP BY campaign
ORDER BY campaign;


-- ============================================================
-- Finding 3: Actual arm split ratio
-- ============================================================

SELECT
  'Finding 3: Arm Split' AS comparison,
  arm_name,
  COUNT(DISTINCT user_id) AS users,
  COUNT(*) AS sends,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS pct_of_sends
FROM base
GROUP BY arm_name
ORDER BY arm_name;

-- Arm split over time (weekly)
WITH weekly AS (
  SELECT
    DATE_TRUNC(send_date, WEEK) AS week_start,
    arm_name,
    COUNT(*) AS sends
  FROM base
  GROUP BY 1, 2
)
SELECT
  'Finding 3: Arm Split by Week' AS comparison,
  week_start,
  arm_name,
  sends,
  ROUND(sends * 100.0 / SUM(sends) OVER(PARTITION BY week_start), 2) AS pct_of_week_sends
FROM weekly
ORDER BY week_start, arm_name;
