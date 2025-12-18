# CTR Comparison: Random Model vs Bandit Click Model

**Date**: December 17, 2025
**Analysis Period**: December 16, 2025 (first day of Bandit deployment)

## Summary

Comparing CTR between two models:
- **Random Model (model_id=1)**: ~90% traffic, random treatment selection
- **Bandit Click Model (model_id=195001001)**: ~10% traffic, Thompson Sampling based on clicks

## Results (Dec 16, 2025)

| Model | Sends | Opens | Clicks | Open Rate | CTR/Send | CTR/Open |
|-------|-------|-------|--------|-----------|----------|----------|
| **Random Model** | 24,550 | 546 | 46 | **2.22%** | 0.19% | 8.42% |
| **Bandit Click Model** | 2,289 | 25 | 3 | 1.09% | 0.13% | **12.0%** |

### Traffic Split

| Model | Sends | % Traffic |
|-------|-------|-----------|
| Random | 24,550 | 91.5% |
| Bandit | 2,289 | 8.5% |

## Key Observations

### 1. Open Rate
- **Random wins**: 2.22% vs 1.09%
- Bandit has ~50% lower open rate
- Possible cause: Bandit may be selecting treatments with less appealing subject lines

### 2. CTR per Open
- **Bandit wins**: 12.0% vs 8.42%
- When users open, Bandit emails get +43% more clicks
- Suggests Bandit is selecting treatments with better content/recommendations

### 3. CTR per Send
- **Random wins**: 0.19% vs 0.13%
- Lower open rate drags down Bandit's overall performance
- This is the metric that matters for business impact

### 4. Sample Size
- Bandit: Only **3 clicks** - too small for statistical significance
- Random: 46 clicks - still small but more reliable
- Need more data before drawing conclusions

## Data Lag Note

| Date | Random Opens | Bandit Opens |
|------|--------------|--------------|
| Dec 16 | 546 | 25 |
| Dec 17 | 0 | 0 |
| Dec 18 | 0 | 0 |

Dec 17-18 show 0 interactions due to data pipeline lag (~1 day delay).

## Verdict

**Too early to conclude.** Only 1 day of data with 3 Bandit clicks.

The higher CTR/Open (12% vs 8.4%) is promising but not statistically significant with n=3.

## Recommendations

1. **Wait for more data** - at least 50+ clicks per model before drawing conclusions
2. **Investigate open rate gap** - why is Bandit getting 50% fewer opens?
3. **Check treatment selection** - what treatments is Bandit favoring vs Random?

## Data Sources

- `auxia-gcp.company_1950.treatment_history_sent` - model_id, treatment assignments
- `auxia-gcp.company_1950.treatment_interaction` - opens (VIEWED), clicks (CLICKED)

## Model IDs

| model_id | Name | Traffic |
|----------|------|---------|
| 1 | Random Model (C1_RANDOM_MODEL_NO_PARAMS_OPTIMIZER_nan_SCORE_4_RANK_INCREASING_SCORE) | 90% |
| 195001001 | Bandit Click Model (Thompson Sampling) | 10% |

---

*Analysis performed using BigQuery. Data from auxia-gcp project.*
