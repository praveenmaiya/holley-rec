---
name: analyze-ctr
description: Run Thompson Sampling CTR analysis on email treatments. Use when analyzing treatment performance or optimizing email campaigns.
allowed-tools: Bash, Read, Glob, Grep
---

# CTR Analysis Skill

Analyzes email treatment click-through rates using Bayesian Thompson Sampling.

## When to Use
- Analyzing which treatments perform best
- Checking if bandit model is learning correctly
- Comparing CTR across treatment groups
- Preparing treatment optimization recommendations

## Process

### Step 1: Run the Bandit Analysis
```bash
python src/bandit_click_holley.py
```

This computes:
- CTR per treatment (clicks / views)
- Beta posterior parameters (α = 1 + clicks, β = 1 + views - clicks)
- Thompson Sampling selection probabilities

### Step 2: Interpret Results

Key metrics to report:
| Metric | Meaning |
|--------|---------|
| `posterior_mean` | Bayesian CTR estimate |
| `posterior_std` | Uncertainty (higher = less data) |
| `selection_pct` | % of time bandit would pick this treatment |

### Step 3: Quick SQL Analysis (if needed)

For raw funnel data:
```bash
bq query --use_legacy_sql=false "
SELECT
  treatment_id,
  COUNT(DISTINCT CASE WHEN interaction_type = 'VIEWED' THEN user_id END) as views,
  COUNT(DISTINCT CASE WHEN interaction_type = 'CLICKED' THEN user_id END) as clicks,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN interaction_type = 'CLICKED' THEN user_id END),
    COUNT(DISTINCT CASE WHEN interaction_type = 'VIEWED' THEN user_id END)
  ) as ctr
FROM \`auxia-gcp.company_1950.treatment_interaction\`
WHERE DATE(TIMESTAMP_MICROS(interaction_timestamp_micros)) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
GROUP BY treatment_id
ORDER BY ctr DESC
"
```

## Treatment Categories

Reference files:
- Personalized: `configs/personalized_treatments.csv` (10 treatments)
- Static: `configs/static_treatments.csv` (22 treatments)

## Output Format

Report should include:
1. **Top 5 treatments** by posterior mean CTR
2. **Bottom 5 treatments** (candidates for pausing)
3. **High uncertainty** treatments (need more data)
4. **Recommendation** on treatment optimization

## Related Files
- `src/bandit_click_holley.py` - Core analysis code
- `sql/reporting/campaign_performance.sql` - Funnel queries
- `docs/analysis/model_ctr_comparison_2025_12_17.md` - Analysis methodology
