# CTR Comparison: Random Model vs Bandit Click Model

**Date**: December 17, 2025
**Analysis Period**: December 16, 2025 (first day of Bandit deployment)

## Summary

Comparing CTR between two models:
- **Random Model (model_id=1)**: ~90% traffic, random treatment selection
- **Bandit Click Model (model_id=195001001)**: ~10% traffic, Thompson Sampling based on clicks

## Results (Dec 16, 2025) - Updated Dec 17

| Model | Sends | Opens | Clicks | Open Rate | CTR/Send | CTR/Open |
|-------|-------|-------|--------|-----------|----------|----------|
| **Random Model** | 24,722 | 661 | 62 | **2.67%** | 0.25% | 9.38% |
| **Bandit Click Model** | 2,301 | 29 | 9 | 1.26% | **0.39%** | **31.03%** |

### Traffic Split

| Model | Sends | % Traffic |
|-------|-------|-----------|
| Random | 24,722 | 91.5% |
| Bandit | 2,301 | 8.5% |

## Key Observations

### 1. Open Rate
- **Random wins**: 2.67% vs 1.26%
- Bandit has ~53% lower open rate
- **Root cause**: Thompson Sampling exploration - Bandit deliberately tests low-score user-treatment pairs (see Deep Dive below)

### 2. CTR per Open
- **Bandit wins**: 31.03% vs 9.38% (3.3x higher!)
- When users open, Bandit emails get dramatically more clicks
- **Explanation**: Users who open despite low predicted scores are self-selected high-intent users (see Deep Dive below)

### 3. CTR per Send
- **Bandit wins**: 0.39% vs 0.25% (+56%)
- Despite lower open rate, Bandit's superior CTR/Open more than compensates
- This is the metric that matters for business impact

### 4. Sample Size
- Bandit: **9 clicks** - still small but improving
- Random: 62 clicks - more reliable
- Need more data before drawing firm conclusions

## Data Lag Note

| Date | Random Opens | Bandit Opens |
|------|--------------|--------------|
| Dec 16 | 661 | 29 |
| Dec 17 | 0 | 0 |

Dec 17 shows 0 interactions due to data pipeline lag (~1 day delay).

## Verdict

**Promising early results.** With updated data (9 Bandit clicks vs 62 Random clicks):

- Bandit now **wins on CTR/Send** (0.39% vs 0.25%) - the business metric that matters
- CTR/Open is 3.3x higher (31% vs 9.4%)
- Still early (9 clicks), but trend is positive

## Recommendations

1. **Wait for more data** - at least 50+ clicks per model before drawing conclusions
2. **Investigate open rate gap** - why is Bandit getting 50% fewer opens? ✅ Answered below
3. **Check treatment selection** - what treatments is Bandit favoring vs Random? ✅ Answered below

---

## Deep Dive: Why Bandit Has Lower Open Rate But Higher CTR/Open

### User Selection: Not the Cause

Bandit users actually have **higher historical engagement**:

| Model | Unique Users | Avg Hist Opens | Agg Hist Open Rate | % New Users |
|-------|--------------|----------------|--------------------| ------------|
| Bandit | 2,289 | 0.9 | 18.04% | 2.3% |
| Random | 24,525 | 0.7 | 16.85% | 4.5% |

Bandit selects more engaged users with better history, so user selection isn't causing lower opens.

### Root Cause: Thompson Sampling Exploration

The Bandit is **deliberately exploring low-score treatment-user combinations**.

For the **same treatments**, score comparison:

| Treatment ID | Bandit Avg Score | Random Avg Score | Ratio |
|--------------|------------------|------------------|-------|
| 21265506 | 0.156 | 0.906 | **6x lower** |
| 17049625 | 0.086 | 0.628 | **7x lower** |
| 21265451 | 0.099 | 0.794 | **8x lower** |
| 16444546 | 0.043 | 0.480 | **11x lower** |
| 21265458 | 0.112 | 0.873 | **8x lower** |

The Bandit is sending treatments to users where the scoring model predicts **poor engagement** (low scores). This is exploration - trying low-probability options to gather data.

### Same Treatment, Different Open Rates

When comparing identical treatments across models:

| Treatment | Random Open Rate | Bandit Open Rate | Delta |
|-----------|------------------|------------------|-------|
| Browse Recovery - 1 Item (17049625) | 2.24% | 0.83% | -1.41% |
| Browse Recovery - 2 Items (21265492) | 1.67% | 0.0% | -1.67% |
| Browse Recovery - 4 Items (21265506) | 2.12% | 1.44% | -0.67% |
| Abandon Cart - 2 Items (17049596) | 4.92% | 2.27% | -2.65% |

For 13 of 15 treatments with sufficient volume, Bandit has **lower open rates** than Random.

### Explanation

1. **Low scores = poor predicted match**: Bandit selects user-treatment pairs the model thinks won't work
2. **Users don't open**: When sent a treatment that's a poor match, users are less likely to open
3. **But when they DO open, they click**: Those who open despite the poor match are genuinely interested
4. **Higher CTR/open**: 31% vs 9.4% because openers are self-selected high-intent users

### Thompson Sampling Trade-off

| Aspect | Short-term Impact | Long-term Benefit |
|--------|-------------------|-------------------|
| Exploration | Lower open rate | Better model learning |
| Low-score tests | Hurts CTR/send | Discovers hidden good matches |
| Concentrated exploration | Sub-optimal performance | Faster convergence |

The Bandit is working as designed - it's exploring to learn, which hurts short-term performance but enables long-term optimization.

---

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
