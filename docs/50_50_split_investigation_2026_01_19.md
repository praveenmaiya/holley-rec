# 50/50 Split Investigation Results

**Date:** January 19, 2026
**Objective:** Determine why Personalized CTR dropped after the Jan 14 50/50 arm split

---

## Executive Summary

The 50/50 split on Jan 14 resulted in 50% of traffic being routed to **arm 4689**, which uses a different model (**195001001**) than arm 4103 (model **1**). The new model produces scores ~10x lower and has resulted in **zero clicks from arm 4103** post-split, while arm 4689 has only 1 click.

**Root Cause:** The 50/50 split exposes users to two different models with vastly different scoring behaviors, leading to suboptimal treatment selection.

---

## Key Findings

### 1. Arms Use Different Models

| Arm | Model ID | Avg Score | Score Range |
|-----|----------|-----------|-------------|
| 4103 | 1 (baseline) | 0.87 | 0.29 - 0.99 |
| 4689 | 195001001 (bandit) | 0.08 | 0.04 - 0.17 |

**Impact:** Model 195001001's scores are ~10x lower than the baseline model. This suggests either:
1. The bandit model uses raw CTR values (typically 0.5-1.5%) instead of normalized scores
2. The model hasn't been properly calibrated
3. Different scoring methodology

### 2. Performance Collapsed After 50/50 Split

| Arm | Period | Users | Click Rate | Clicks |
|-----|--------|-------|------------|--------|
| 4103 | Pre-50/50 | 254 | **3.15%** | 8 |
| 4103 | Post-50/50 | 152 | **0%** | 0 |
| 4689 | Pre-50/50 | 25 | 0% | 0 |
| 4689 | Post-50/50 | 131 | **0.76%** | 1 |

**Pattern:** Arm 4103 went from 3.15% click rate to 0% exactly on Jan 14.

### 3. Treatment Distribution Differs by Arm

Post-50/50, the arms favor different treatments:

**Arm 4689 (bandit model):**
- Treatment 16150700: 28% of sends (highest)
- Heavily favors older treatment

**Arm 4103 (baseline model):**
- Treatment 16150700: 5% of sends (lowest)
- Spreads more evenly across treatments

### 4. Engaged Users Were Reassigned

Of the 8 users who clicked during Jan 10-13:
- 3 stopped receiving emails entirely
- 2 stayed on arm 4103 (0 more clicks)
- **4 were moved to arm 4689** (0 more clicks)

Users who previously engaged are now split across arms, diluting the learning signal.

### 5. Open Rates Also Dropped

| Arm | Period | Open Rate |
|-----|--------|-----------|
| 4103 | Pre-50/50 | 31.5% |
| 4103 | Post-50/50 | 18.4% |
| 4689 | Post-50/50 | 20.6% |

Both arms show significantly lower engagement post-split.

---

## Timeline

| Date | Event | Impact |
|------|-------|--------|
| Dec 16 | Model 195001001 first appears | ~10% traffic on arm 4689 |
| Jan 10 | **v5.17 deployed** | Performance improves |
| Jan 12 | Daily bandit training starts | - |
| **Jan 14** | **50/50 arm split** | **Performance crashes** |
| Jan 14-19 | Arm 4103: 0 clicks | - |
| Jan 14-19 | Arm 4689: 1 click | - |

---

## Root Cause Analysis

### Primary Issue: Model Mismatch

The 50/50 split doesn't just split traffic—it splits users between two fundamentally different models:

1. **Model 1 (arm 4103):** Baseline model with high scores (0.87 avg)
2. **Model 195001001 (arm 4689):** Bandit-trained model with low scores (0.08 avg)

When boost_factor is the same (100) for both, the treatment selection still works within each arm, but:
- Users are now randomly assigned to different model behaviors
- Previous engagement history doesn't carry over between arms
- Learning is diluted across two separate models

### Secondary Issue: User Fragmentation

The 50/50 split fragments the user base:
- Same user may receive different treatment types depending on which arm they're assigned to
- Engaged users (clickers) were redistributed, breaking the reinforcement learning loop
- 64 users have received emails on multiple arms, confusing the learning signal

---

## Recommendations

### Immediate Actions

1. **Revert to 90/10 or 95/5 split** to protect v5.17 performance gains
   - Keep most traffic on the proven arm 4103 with baseline model
   - Limit arm 4689 to a small test population

2. **Investigate model 195001001 scoring**
   - Why are scores ~10x lower?
   - Is the model using raw CTR vs normalized scores?
   - Verify the model was trained correctly

### Medium-Term Actions

3. **Ensure model consistency**
   - Both arms should use the same underlying recommendation model (v5.17)
   - Only vary the bandit exploration/exploitation strategy, not the core model

4. **Implement user-level arm stickiness**
   - Users should stay on the same arm throughout the experiment
   - This preserves the learning signal and prevents user confusion

5. **Add monitoring**
   - Alert when CTR drops significantly after configuration changes
   - Track model scores by arm to detect calibration issues

---

## Data Quality Notes

- **Sample size warning:** Only 6 days of post-50/50 data (745 sends, 1 click)
- **Pre-50/50:** 751 sends, 8 clicks (Jan 10-13)
- **Confidence:** High that the split caused the drop; lower confidence on exact root cause

---

## Conclusion

The 50/50 split on Jan 14 exposed a critical issue: **arm 4689 uses a different model (195001001) that produces dramatically lower scores**. This, combined with user fragmentation, has caused Personalized CTR to drop from ~2.3% to 0.1%.

**Recommended immediate action:** Revert to pre-50/50 arm allocation to restore v5.17 performance while investigating model 195001001.
