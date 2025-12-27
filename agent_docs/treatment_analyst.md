# Treatment Analyst Agent Guide

Instructions for subagents analyzing email treatment performance.

## Standard Metrics

| Metric | Formula | Notes |
|--------|---------|-------|
| **Open Rate** | opens / sent | Delivery-adjusted if using delivered |
| **CTR (of opens)** | clicks / opens | Standard email metric |
| **CTR (of sent)** | clicks / sent | Overall effectiveness |
| **Conversion Rate** | orders / clicks | Purchase intent |
| **Revenue per Send** | total_revenue / sent | ROI metric |

**Important**: Always use `COUNT(DISTINCT user_id)` to prevent multi-click inflation.

---

## Key Tables

```sql
-- Who received what treatment
`auxia-gcp.company_1950.treatment_history_sent`
  - user_id, treatment_id, treatment_sent_timestamp
  - surface_id (929 = email)
  - request_source ('LIVE' for production)
  - model_id (1 = random, 195001001 = bandit)

-- Opens and clicks
`auxia-gcp.company_1950.treatment_interaction`
  - user_id, treatment_id, interaction_type ('VIEWED', 'CLICKED')
  - interaction_timestamp_micros (use TIMESTAMP_MICROS to convert)

-- Orders (for conversion tracking)
`auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  - Filter: event_type = 'Order'
  - Extract: Items_n.Subtotal for revenue
```

---

## Comparison Methodology

### 1. MECE Framework (Required for Fair Comparison)

**Problem**: Personalized treatments require vehicle data. Comparing all users is biased.

**Solution**: Split users into mutually exclusive, collectively exhaustive groups:

```
All Users
├── No vehicle data → Static only (exclude from comparison)
└── Has vehicle data (eligible for both)
    ├── Received Personalized → Include
    └── Received Static → Include ← COMPARE THESE
```

### 2. Within-User Comparison (Gold Standard)

Find users who received BOTH treatment types:

```sql
WITH user_types AS (
  SELECT user_id,
    COUNTIF(treatment_id IN (...personalized...)) as got_personalized,
    COUNTIF(treatment_id IN (...static...)) as got_static
  FROM treatment_history_sent
  GROUP BY user_id
)
SELECT * FROM user_types
WHERE got_personalized > 0 AND got_static > 0
```

This controls for all user-level confounders.

### 3. Statistical Significance

Before drawing conclusions:
- **Sample size**: Need 100+ clicks per group minimum
- **Confidence**: Report 95% CI when possible
- **Duration**: At least 7 days to control for day-of-week effects

---

## Treatment Categories

### Personalized Fitment (10 treatments)
Post-purchase emails with vehicle-specific recommendations.
IDs: 16150700, 20142778, 20143044, 20143063, 20143082, 20143121, 20143140, 20143159, 20143178, 20143197

### Static Recommendations (22 treatments)
Category-based recommendations (Air Cleaners, Exhaust, etc.)
See: `configs/static_treatments.csv`

---

## Common Analysis Queries

### Basic CTR by Treatment
```sql
SELECT
  s.treatment_id,
  COUNT(DISTINCT s.user_id) as sent,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN i.user_id END) as opens,
  COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN i.user_id END) as clicks,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'CLICKED' THEN i.user_id END),
    COUNT(DISTINCT CASE WHEN i.interaction_type = 'VIEWED' THEN i.user_id END)
  ) as ctr
FROM `auxia-gcp.company_1950.treatment_history_sent` s
LEFT JOIN `auxia-gcp.company_1950.treatment_interaction` i
  ON s.user_id = i.user_id AND s.treatment_id = i.treatment_id
WHERE DATE(s.treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
  AND s.surface_id = 929
  AND s.request_source = 'LIVE'
GROUP BY s.treatment_id
ORDER BY ctr DESC
```

### Personalized vs Static (Eligible Users Only)
See: `/uplift` skill for full query

---

## Common Pitfalls

1. **Selection bias**: Don't compare different populations
2. **Exploration traffic**: Bandit model intentionally sends to low-score users
3. **Small samples**: <100 clicks = high variance, don't over-interpret
4. **Data lag**: treatment_interaction has ~1 day delay
5. **Paused treatments**: Check `is_paused` in PostgreSQL treatment table

---

## Reference Files
- `src/bandit_click_holley.py` - Thompson Sampling implementation
- `docs/treatment_ctr_unbiased_analysis_2025_12_17.md` - MECE analysis example
- `docs/model_ctr_comparison_2025_12_17.md` - Random vs Bandit comparison
- `configs/personalized_treatments.csv` - Personalized treatment IDs
- `configs/static_treatments.csv` - Static treatment IDs
