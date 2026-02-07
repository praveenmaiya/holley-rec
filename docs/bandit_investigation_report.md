# Bandit Model Investigation Report

**Date:** 2026-02-06
**Model:** 195001001 (arm 4689, Thompson Sampling)
**Baseline:** Model 1 (arm 4103, Random boost-weighted)
**Scope:** All campaigns (Browse Recovery, Abandon Cart, Post Purchase)
**Queries:** `sql/analysis/bandit_investigation.sql`

---

## Executive Summary

The bandit model (195001001) **is updating daily** but **is not meaningfully learning**. Scores drift slowly downward across all treatments, clicks do not reliably increase treatment scores, and the model produced **1,587 invalid scores above 1.0** (max 4.32) during a Jan 23-30 anomaly. Despite this, the bandit arm performs **comparably to the Random arm** on CTR -- it is not hurting performance, but it is not improving it either.

**Key verdict:** The model retrains but the learning loop is broken. Clicks have negligible impact on next-day scores.

---

## Phase 1: Is the Model Updating?

### Finding 1: Scores Change Daily, But With an Anomaly

| Period | Bandit Avg Score | Max Score | Interpretation |
|--------|-----------------|-----------|----------------|
| Jan 10-22 | 0.093 - 0.108 | 0.16 - 0.27 | Normal range (raw CTR posteriors) |
| **Jan 23-30** | **0.231 - 0.282** | **2.52 - 4.32** | **ANOMALY: scores > 1.0 are invalid** |
| Jan 31 | 0.138 | 2.65 | Transitioning back |
| Feb 1-7 | 0.088 - 0.093 | 0.32 - 1.09 | Mostly normal, occasional outliers |

The model IS updating -- avg scores shift 0.001-0.005/day in the normal period. However:
- **Jan 23 anomaly**: Bandit avg score jumped 2.6x overnight (0.093 to 0.241). Max scores exceeded 4.0.
- **1,587 sends had scores above 1.0** since Jan 14 (confirmed by score histogram).
- **1 send had a negative score** (-0.026 on Jan 30).
- These are not valid probability values. Something broke in the model on Jan 23 and partially recovered by Feb 1.

The Random arm remained completely stable throughout (~0.70-0.75 avg).

### Finding 2: All Treatment Scores Trend Downward

Top 5 bandit treatments by volume show **monotonic downward drift**:

| Treatment | Jan 10 Avg Score | Feb 6 Avg Score | Change |
|-----------|-----------------|-----------------|--------|
| 21265478 | 0.134 | 0.111 | -17% |
| 21265458 | 0.109 | 0.101 | -7% |
| 21265451 | 0.097 | 0.093 | -4% |
| 17049625 | 0.086 | 0.075 | -13% |
| 16490939 | 0.057 | 0.060 | +5% (nearly flat) |

**Interpretation:** The posteriors are converging (uncertainty shrinking) but ALL toward lower values. The model is not discovering and exploiting winners -- it is uniformly compressing scores toward actual CTR rates. This is expected behavior for a Beta posterior with growing data but no exploitation mechanism.

### Finding 3: Click Feedback Loop Is Broken

Direct test: When a treatment gets clicked on day D, does its score increase on day D+1?

| Treatment | Click Date | Score | Next-Day Score | Delta |
|-----------|-----------|-------|---------------|-------|
| 16150700 | Jan 16 (1 click) | 0.0845 | 0.0792 | **-0.0053** |
| 16150700 | Jan 22 (2 clicks) | 0.0792 | 0.0805 | +0.0013 |
| 16150707 | Jan 16 (1 click) | 0.0695 | 0.0705 | +0.0011 |
| 16150707 | Jan 17 (1 click) | 0.0705 | 0.0697 | **-0.0008** |
| 16150707 | Jan 18 (1 click) | 0.0697 | 0.0694 | **-0.0003** |
| 16150707 | Jan 19 (2 clicks) | 0.0694 | 0.0687 | **-0.0007** |

**Score deltas after clicks are negligible (0.001) and frequently negative.** The expected behavior for a learning model is: click on treatment X -> X's posterior mean increases -> X gets selected more. This is NOT happening. Individual clicks are drowned out by the volume of non-click data.

---

## Phase 2: Performance Assessment

### Finding 4: Bandit CTR Matches Random (Neither Winning Nor Losing)

Weekly CTR of opens across all campaigns:

| Week | Bandit CTR | Random CTR | Bandit Open Rate | Random Open Rate |
|------|-----------|-----------|------------------|------------------|
| Dec 15 | 10.83% | 9.18% | 6.50% | 6.31% |
| Dec 22 | 7.81% | 9.46% | 4.71% | 4.31% |
| Dec 29 | 8.84% | 7.95% | 10.63% | 10.58% |
| Jan 5 | 8.59% | 9.50% | 16.54% | 16.67% |
| **Jan 12** | **8.51%** | **8.63%** | **18.07%** | **15.05%** |
| **Jan 19** | **6.89%** | **7.03%** | **22.04%** | **23.30%** |
| **Jan 26** | **7.18%** | **7.18%** | **17.64%** | **17.68%** |
| **Feb 2** | **7.45%** | **6.67%** | **7.84%** | **7.46%** |

Post-50/50 (bold rows): CTR of opens is virtually identical between arms (within 0.14-0.78pp). The bandit is not outperforming OR underperforming Random. It has effectively become another random distribution.

### Finding 5: All-Campaign Breakdown Confirms Parity

| Campaign | Period | Bandit CTR | Random CTR | Difference |
|----------|--------|-----------|-----------|------------|
| BR/AC | Pre-50/50 | 9.24% | 9.11% | +0.13pp |
| BR/AC | Post-50/50 | 7.50% | 7.65% | -0.15pp |
| PP-Personalized | Post-50/50 | 3.73% | 3.23% | +0.50pp |
| PP-Static | Post-50/50 | 5.50% | 5.67% | -0.17pp |

Browse Recovery / Abandon Cart (86% of all traffic): Bandit and Random are statistically indistinguishable.

### Finding 6: Last 7 Days Show Bandit Slightly Ahead

| Date | Bandit CTR | Random CTR | Bandit Opens | Random Opens |
|------|-----------|-----------|--------------|--------------|
| Jan 31 | 6.30% | 6.51% | 920 | 891 |
| Feb 1 | 8.30% | 7.13% | 916 | 855 |
| Feb 2 | 8.20% | 7.11% | 256 | 239 |
| Feb 3 | 6.60% | 5.38% | 500 | 465 |
| Feb 4 | 7.16% | 7.47% | 433 | 348 |
| Feb 5 | 8.02% | 6.99% | 636 | 672 |
| Feb 6-7 | 0 opens | 0 opens | (data lag) | (data lag) |

In the last 7 days, Bandit CTR exceeded Random on 4 out of 5 measurable days. However, the differences are small and within noise. There is no upward trend -- the model is not converging toward better performance over time.

---

## Phase 3: Architecture & Configuration

### Finding 7: 50/50 Split Still Active

| Week | Bandit % | Random % |
|------|----------|----------|
| Dec 15 | 9.6% | 90.4% |
| Dec 22 | 9.9% | 90.1% |
| Dec 29 | 10.1% | 89.9% |
| Jan 5 | 10.2% | 89.8% |
| **Jan 12** | **35.2%** | **64.8%** |
| Jan 19 | 49.7% | 50.3% |
| Jan 26 | 49.6% | 50.4% |
| Feb 2 | 50.2% | 49.8% |

The 50/50 split has been in effect since Jan 14 (transition week of Jan 12). It has NOT been reverted.

### Finding 8: Score Calibration -- Fundamentally Different Scales

Post-50/50 score distribution:

| Score Bucket | Bandit Sends | Bandit % | Random Sends | Random % |
|--------------|-------------|----------|--------------|----------|
| [0.00, 0.01) | 1 | ~0% | 160 | 0.1% |
| [0.01, 0.05) | 1,386 | 1.2% | 803 | 0.7% |
| [0.05, 0.10) | **54,901** | **45.6%** | 1,187 | 1.0% |
| [0.10, 0.20) | **46,703** | **38.8%** | 3,561 | 2.9% |
| [0.20, 0.30) | 4,808 | 4.0% | 4,262 | 3.5% |
| [0.30, 0.50) | 7,066 | 5.9% | 11,884 | 9.6% |
| [0.50, 0.70) | 2,107 | 1.8% | 21,025 | 17.1% |
| [0.70, 0.90) | 1,126 | 0.9% | **42,471** | **34.6% ** |
| [0.90, 1.00] | 478 | 0.4% | **37,815** | **30.8%** |
| **ABOVE 1.0** | **1,587** | **1.3%** | 0 | 0% |

**Key observations:**
- **84.4% of Bandit scores** fall in [0.05, 0.20) -- these are raw CTR posterior means
- **65.4% of Random scores** fall in [0.70, 1.00] -- these are normalized/boost-weighted
- **1,587 Bandit scores exceed 1.0** (max 4.32) -- confirmed scoring bug
- The models operate on **completely different scales**, making cross-arm score comparison meaningless

### Finding 9: User Stickiness Is Good

| User Segment | Users | Total Sends | Avg Sends/User |
|-------------|-------|-------------|----------------|
| Random Only | 19,781 | 122,289 | 6.2 |
| Bandit Only | 18,645 | 114,756 | 6.2 |
| **Both Arms** | **879** | **6,286** | **7.2** |

Only **2.2% of users** (879 of 39,305) received emails from both arms post-50/50. This means the learning signal is NOT fragmented by arm switching. User stickiness is good.

### Finding 10: Bandit Distribution Is Near-Uniform (No Exploitation)

Top 5 treatments by share of Bandit arm (Post-50/50):

| Treatment | Bandit Share | Type |
|-----------|-------------|------|
| 17049625 | 6.28% | Browse Recovery |
| 21265458 | 5.52% | Browse Recovery |
| 21265451 | 5.44% | Browse Recovery |
| 24370709 | 4.92% | Browse Recovery |
| 21265478 | 4.87% | Browse Recovery |

With 30+ active treatments, a uniform distribution would give ~3.3% each. The top treatment has only 6.28% -- the bandit is barely differentiating between treatments. This is consistent with the model NOT having learned which treatments are best. It is still primarily exploring, not exploiting.

---

## Root Cause Analysis

| # | Finding | Root Cause | Severity |
|---|---------|-----------|----------|
| 1 | Scores > 1.0 | NIG posterior bug or model update error (Jan 23) | **HIGH** |
| 2 | Clicks don't increase scores | Click signal drowned by volume; update mechanism too sluggish | **HIGH** |
| 3 | All scores drift downward | Posterior converging without exploitation weighting | Medium |
| 4 | Near-uniform treatment distribution | Insufficient exploration-exploitation trade-off | Medium |
| 5 | Score scale mismatch (0.09 vs 0.71) | Different model architectures; scores not comparable | Low (cosmetic) |
| 6 | 50/50 split still active | Configuration not reverted after Jan investigation | Medium |

### Primary Root Cause: Model Architecture Issue

The bandit model (195001001) appears to use a NIG (Normal-Inverse-Gamma) or similar posterior that:

1. **Produces raw CTR posterior means as scores** (~0.05-0.15 range = actual CTR values)
2. **Updates very slowly** -- individual clicks move scores by 0.001 or less
3. **Occasionally produces invalid outputs** (scores > 1.0, negative scores)
4. **Lacks an exploitation mechanism** -- it converges toward true CTR but doesn't amplify winners

The Random arm uses boost-weighted scores (0.5-1.0 range) that directly determine selection probability. The Bandit arm's raw CTR posteriors are so similar across treatments that selection is effectively random.

### Why the Model Can't Learn

Back-of-envelope calculation for treatment 16150707:
- ~100 sends/day in Bandit arm
- ~15 opens/day (15% open rate)
- ~1 click every 2 days
- Beta posterior update from 1 click: `alpha/(alpha+beta)` shifts by ~0.001

With 30+ treatments sharing traffic, each treatment gets ~3 clicks/week. At this rate, the Beta posterior needs **months** to meaningfully differentiate treatments. The model is structurally unable to learn at the current data volume.

---

## Recommendations

### Immediate (This Week)

1. **Revert to 10/90 split** (10% Random / 90% Bandit)
   - Rationale: The 50/50 split wastes 50% of traffic on a model that performs identically to Random
   - Concentrating 90% on Bandit gives it more data to potentially learn
   - Impact: No CTR change expected (arms perform identically)

2. **Investigate the Jan 23 scoring anomaly**
   - 1,587 scores > 1.0 (max 4.32) and 1 negative score (-0.026)
   - Check model deployment logs for Jan 22-23
   - Root cause may be a model training failure or data pipeline issue

### Short-Term (Next 2 Weeks)

3. **Verify model retraining pipeline**
   - Confirm the Metaflow cron job for model 195001001 is running daily
   - Check if training data includes recent clicks (not stale)
   - Validate that updated posteriors are deployed to the serving layer

4. **Use informative priors instead of uniform Beta(1,1)**
   - Current uniform prior means the model starts with zero knowledge
   - Set informative priors based on historical CTR (e.g., Beta(3, 97) for ~3% CTR)
   - This would accelerate convergence significantly

### Medium-Term (Next Month)

5. **Consider treatment-group-level learning instead of per-treatment**
   - 30+ treatments with ~3 clicks/week each = impossible to learn
   - Group treatments by category (e.g., "Browse Recovery" vs "Post Purchase")
   - Learn at group level, then differentiate within group

6. **Add exploitation amplification**
   - Current model: selection proportional to raw posterior mean
   - Improvement: Use Thompson Sampling with temperature scaling
   - Higher temperature = more exploitation of winners

7. **Normalize bandit scores to [0,1] range**
   - Scores > 1.0 are invalid for probability-based selection
   - Apply sigmoid or min-max normalization post-training
   - This also makes cross-arm comparison meaningful

---

## Conclusion

The bandit model is **updating but not learning**. It retrains daily and produces slightly different scores, but individual clicks have negligible impact on treatment scores. The model effectively acts as another random distribution, producing comparable CTR to the Random arm. The most concerning issue is the **1,587 invalid scores > 1.0** from the Jan 23 anomaly, suggesting a model training bug.

The fundamental problem is **data sparsity**: with 30+ treatments sharing traffic and only ~3 clicks/week per treatment, the Beta posterior cannot converge fast enough to differentiate winners. The model needs either more data (traffic concentration), stronger priors, or group-level learning to become useful.

**Bottom line: The 50/50 split is not hurting performance, but neither arm is learning. Reverting to 10/90 while fixing the model architecture is recommended.**

---

## Appendix: Query Reference

| Query | File Location | Purpose |
|-------|---------------|---------|
| Q1 | `sql/analysis/bandit_investigation.sql` | Daily score drift |
| Q2 | Same file | Per-treatment score evolution |
| Q3 | Same file | Arm split over time |
| Q4 | Same file | Weekly CTR by arm |
| Q5 | Same file | Treatment distribution by arm |
| Q6 | Same file | Click feedback loop |
| Q7 | Same file | All-campaign pre vs post |
| Q8 | Same file | Score calibration histogram |
| Q9 | Same file | User-arm stickiness |
| Q10 | Same file | Last 7 days health check |
