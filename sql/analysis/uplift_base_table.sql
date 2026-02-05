-- ============================================================
-- Personalized vs Static Uplift: Base Analysis Table
-- ============================================================
-- Purpose: Build one row per send with treatment_type, period,
--          opens, clicks, fitment_eligible for all 3 methods.
--
-- Grain: treatment_tracking_id (one row per email send)
-- Scope: Post Purchase only (surface_id=929, LIVE traffic)
-- Periods:
--   v5.7:  2025-12-07 to 2026-01-09
--   v5.17: 2026-01-10 to 2026-02-04 (crash flagged, not excluded)
--
-- Run:
--   bq query --use_legacy_sql=false < sql/analysis/uplift_base_table.sql
--
-- Output:
--   auxia-reporting.temp_holley_v5_17.uplift_base
-- ============================================================

-- Parameters
DECLARE v57_start DATE DEFAULT '2025-12-07';
DECLARE v57_end DATE DEFAULT '2026-01-09';
DECLARE v517_start DATE DEFAULT '2026-01-10';
DECLARE v517_end DATE DEFAULT '2026-02-04';
DECLARE crash_date DATE DEFAULT '2026-01-14';

-- Personalized Fitment treatment IDs (10)
-- Source of truth: configs/personalized_treatments.csv
DECLARE personalized_list ARRAY<INT64> DEFAULT [
  16150700, 20142778, 20142785, 20142804, 20142811,
  20142818, 20142825, 20142832, 20142839, 20142846
];

-- Static treatment IDs (22, but only 16490939 has actual sends)
-- Source of truth: configs/static_treatments.csv
DECLARE static_list ARRAY<INT64> DEFAULT [
  16490932, 16490939, 16518436, 16518443, 16564380,
  16564387, 16564394, 16564401, 16564408, 16564415,
  16564423, 16564431, 16564439, 16564447, 16564455,
  16564463, 16593451, 16593459, 16593467, 16593475,
  16593483, 16593491
];

-- ============================================================
-- Build base table
-- ============================================================
CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_17.uplift_base` AS

WITH
-- Fitment-eligible users: have full v1 YMM data (year + make + model)
eligible_users AS (
  SELECT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
    UNNEST(user_properties) AS p
  WHERE LOWER(p.property_name) IN ('v1_year', 'v1_make', 'v1_model')
    AND (NULLIF(TRIM(p.string_value), '') IS NOT NULL OR p.long_value IS NOT NULL)
  GROUP BY user_id
  HAVING COUNT(DISTINCT LOWER(p.property_name)) = 3
),

-- All Post Purchase sends in analysis window
sends AS (
  SELECT
    th.user_id,
    th.treatment_id,
    th.treatment_tracking_id,
    th.treatment_sent_timestamp,
    th.arm_id,
    DATE(th.treatment_sent_timestamp) AS send_date,

    -- Treatment type classification
    CASE
      WHEN th.treatment_id IN UNNEST(personalized_list) THEN 'Personalized'
      WHEN th.treatment_id IN UNNEST(static_list) THEN 'Static'
    END AS treatment_type,

    -- Period assignment
    CASE
      WHEN DATE(th.treatment_sent_timestamp) BETWEEN v57_start AND v57_end THEN 'v5.7'
      WHEN DATE(th.treatment_sent_timestamp) BETWEEN v517_start AND v517_end THEN 'v5.17'
    END AS period,

    -- Crash flag: 50/50 arm split on Jan 14 crashed CTR
    DATE(th.treatment_sent_timestamp) >= crash_date AS in_crash_window,

    -- Fitment eligibility
    eu.user_id IS NOT NULL AS fitment_eligible

  FROM `auxia-gcp.company_1950.treatment_history_sent` th
  LEFT JOIN eligible_users eu ON th.user_id = eu.user_id
  WHERE th.surface_id = 929
    AND th.request_source = 'LIVE'
    AND DATE(th.treatment_sent_timestamp) BETWEEN v57_start AND v517_end
    AND (
      th.treatment_id IN UNNEST(personalized_list)
      OR th.treatment_id IN UNNEST(static_list)
    )
),

-- Opens (VIEWED)
views AS (
  SELECT DISTINCT treatment_tracking_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) BETWEEN v57_start AND v517_end
),

-- Clicks (CLICKED)
clicks AS (
  SELECT DISTINCT treatment_tracking_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) BETWEEN v57_start AND v517_end
)

SELECT
  s.user_id,
  s.treatment_id,
  s.treatment_tracking_id,
  s.treatment_sent_timestamp,
  s.arm_id,
  s.send_date,
  s.treatment_type,
  s.period,
  s.in_crash_window,
  s.fitment_eligible,
  CASE WHEN v.treatment_tracking_id IS NOT NULL THEN 1 ELSE 0 END AS opened,
  CASE WHEN c.treatment_tracking_id IS NOT NULL THEN 1 ELSE 0 END AS clicked
FROM sends s
LEFT JOIN views v ON s.treatment_tracking_id = v.treatment_tracking_id
LEFT JOIN clicks c ON s.treatment_tracking_id = c.treatment_tracking_id;

-- ============================================================
-- Quick sanity check
-- ============================================================
SELECT
  period,
  treatment_type,
  in_crash_window,
  COUNT(*) AS sends,
  COUNT(DISTINCT user_id) AS unique_users,
  SUM(opened) AS opens,
  SUM(clicked) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(opened), COUNT(*)) * 100, 2) AS open_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), SUM(opened)) * 100, 2) AS ctr_of_opens_pct,
  ROUND(SAFE_DIVIDE(SUM(clicked), COUNT(*)) * 100, 2) AS ctr_of_sends_pct
FROM `auxia-reporting.temp_holley_v5_17.uplift_base`
GROUP BY period, treatment_type, in_crash_window
ORDER BY period, treatment_type, in_crash_window;
