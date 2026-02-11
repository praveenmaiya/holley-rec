---
name: uplift
description: Compare Personalized vs Static treatment performance with unbiased methodology. Use for A/B analysis and treatment comparison.
allowed-tools: Bash, Read, Glob, Grep
---

# Uplift Analysis Skill

Compares treatment performance using unbiased methodology (MECE framework).

## When to Use
- Comparing Personalized Fitment vs Static recommendations
- Measuring true uplift of personalization
- Detecting selection bias in comparisons
- Preparing optimization recommendations

## Process

### Step 1: Load Treatment Categories

```bash
# Personalized treatments
cat configs/personalized_treatments.csv

# Static treatments
cat configs/static_treatments.csv
```

### Step 2: Run Unbiased Comparison

**Key principle**: Only compare users eligible for BOTH treatment types (users with vehicle data).

```sql
-- Eligible users: those with vehicle data
WITH eligible_users AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
  WHERE DATE(event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
    AND property_key IN ('v1_year', 'v1_make', 'v1_model')
    AND COALESCE(string_value, CAST(long_value AS STRING)) IS NOT NULL
),

-- Treatments sent to eligible users
sent AS (
  SELECT
    s.user_id,
    s.treatment_id,
    CASE
      WHEN s.treatment_id IN (16150700, 20142778, 20143044, 20143063, 20143082,
                               20143121, 20143140, 20143159, 20143178, 20143197)
      THEN 'Personalized'
      ELSE 'Static'
    END as treatment_type
  FROM `auxia-gcp.company_1950.treatment_history_sent` s
  JOIN eligible_users e ON s.user_id = e.user_id
  WHERE DATE(treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
    AND surface_id = 929
    AND request_source = 'LIVE'
),

-- Interactions
interactions AS (
  SELECT
    user_id,
    treatment_id,
    interaction_type
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE DATE(TIMESTAMP_MICROS(interaction_timestamp_micros)) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
)

SELECT
  s.treatment_type,
  COUNT(DISTINCT s.user_id) as users_sent,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN s.user_id END) as viewers,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.user_id END) as clickers,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN s.user_id END),
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN s.user_id END)
  ) as ctr
FROM sent s
LEFT JOIN interactions i ON s.user_id = i.user_id AND s.treatment_id = i.treatment_id
GROUP BY s.treatment_type
```

### Step 3: Within-User Comparison (Gold Standard)

Find users who received BOTH treatment types:
```sql
WITH user_treatment_types AS (
  SELECT
    user_id,
    CASE
      WHEN treatment_id IN (16150700, 20142778, 20143044, 20143063, 20143082,
                             20143121, 20143140, 20143159, 20143178, 20143197)
      THEN 'Personalized'
      ELSE 'Static'
    END as treatment_type,
    treatment_id
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE DATE(treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
    AND surface_id = 929
    AND request_source = 'LIVE'
),
users_with_both AS (
  SELECT user_id
  FROM user_treatment_types
  GROUP BY user_id
  HAVING COUNT(DISTINCT treatment_type) = 2
)
-- Compare CTR for these users on each treatment type
SELECT COUNT(*) as users_with_both_treatments FROM users_with_both
```

### Step 4: Calculate Uplift

```
Uplift = (CTR_personalized - CTR_static) / CTR_static × 100%
```

## Output Format

Report should include:
1. **Sample sizes** for each group
2. **CTR comparison** (Personalized vs Static)
3. **Uplift percentage** with direction
4. **Statistical significance** note (if sample too small)
5. **Bias check** - are populations comparable?

## Related Files
- `docs/analysis/treatment_ctr_unbiased_analysis_2025_12_17.md` - Methodology reference
- `configs/personalized_treatments.csv` - Treatment IDs
- `configs/static_treatments.csv` - Treatment IDs
