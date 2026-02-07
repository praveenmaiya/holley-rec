# Bandit Model Investigation Report v2: Deep Root Cause Analysis

**Date:** 2026-02-07
**Phase:** 2 of 2 (Deep Investigation)
**Model:** 195001001 (arm 4689, NIG Thompson Sampling)
**Baseline:** Model 1 (arm 4103, Random boost-weighted)
**Queries:** `sql/analysis/bandit_investigation_phase2.sql` (Q11-Q16)
**Simulation:** `src/nig_convergence_simulation.py`

---

## Executive Summary

Phase 2 definitively answers "is there a mistake from our side?" with a **nuanced verdict**:

| Hypothesis | Verdict | Details |
|------------|---------|---------|
| H1: Bad training data | **Minor issues only** | 877 phantom clicks, 150K non-LIVE sends exist but are filtered correctly |
| H2: Model misconfigured | **Partially yes** | 55-87 treatments compete (not 30), new treatments caused score > 1.0 anomaly |
| H3: Structural limitation | **PRIMARY CAUSE** | Simulation proves 30+ treatments need 106+ days to converge; 50% never converge |

**Root cause:** The model is mathematically correct but structurally unable to learn at current data volume. With 55-87 treatments sharing ~5,000 sends/day, each treatment gets only ~60-90 sends/day and ~1-2 clicks/day. The NIG posterior needs months to differentiate treatments whose true CTRs differ by only 0.5-1.5pp.

**Fix:** Reduce active treatments from 80+ to 10. Simulation shows this cuts convergence from 106 days (50% never) to 12 days (100% converge).

---

## Phase 1 Recap

Phase 1 (`docs/bandit_investigation_report.md`, 2026-02-06) established:

1. Model IS updating daily (scores shift 0.001-0.005/day)
2. Click feedback loop broken (clicks move scores by ~0.001, often negative)
3. 1,587 invalid scores > 1.0 during Jan 23-30 anomaly
4. Bandit CTR matches Random within noise (~0.15pp)
5. Near-uniform treatment distribution (no exploitation)
6. User stickiness is good (only 2.2% see both arms)

**Phase 1 conclusion:** The model updates but doesn't learn. Phase 2 investigates WHY.

---

## Phase 2 Findings

### Finding 11: Training Data Is Clean (H1 Ruled Out)

**Q11: Training Data Quality Audit** (120-day window, Oct 2025 - Feb 2026)

| Metric | Value | Severity |
|--------|-------|----------|
| Total LIVE sends | 821,740 | -- |
| Phantom clicks (clicked=1, opened=0) | 877 (0.11%) | Low |
| Phantom clicks, bandit only | 209 (0.03%) | Negligible |
| Duplicate treatment_tracking_ids | 0 | Clean |
| Non-LIVE sends (SIMULATION/QA) | 150,650 | Filtered out correctly |
| Time-travel clicks (click before send) | 0 | Clean |
| Time-travel opens (open before send) | 0 | Clean |
| Sends with score <= 0 | 2 | Negligible |
| Sends with score > 1.0 | 1,686 | Investigated in Q14 |

**Verdict:** Training data is clean. The 877 phantom clicks (0.11% of all sends) are from image-blocking email clients -- a known issue that doesn't materially impact model training. Zero duplicates, zero time-travel events. The model is NOT being trained on bad data.

---

### Finding 12: Too Many Treatments Competing (55-87, Not 30)

**Q12: Treatment Count & Effective Competition**

| Period | Treatments/Day | Sends/Day | Sends/Treatment/Day | Top Treatment Share |
|--------|---------------|-----------|--------------------|--------------------|
| Jan 14-22 | **55-57** | 3,900-7,100 | 70-125 | 7-13% |
| **Jan 23** | **87** | 5,230 | **60** | 10% |
| Jan 24-Feb 7 | **81-85** | 3,900-5,700 | 48-70 | 6-15% |

**Critical finding:** On Jan 23, the number of active treatments jumped from 56 to 87 (+31 treatments overnight). This coincides exactly with the score > 1.0 anomaly. The new treatments had almost zero historical data, causing the NIG prior to produce extreme scores.

After Jan 23, the system consistently runs **80+ treatments**, far more than our Phase 1 estimate of "30+". With uniform distribution at 83 treatments, each gets only 1.2% of traffic (~60 sends/day, ~0.7 clicks/day). This is vastly insufficient for NIG convergence.

---

### Finding 13: NIG Posteriors Are Correct (Model Is Not Broken)

**Q13: NIG Math Verification**

Initial comparison using sends as denominator showed a 5-12x mismatch between expected NIG posterior (mu = clicks/(1+sends)) and actual scores. However, cross-referencing with Q16 data reveals the model trains on **CTR of opens** (clicks/opens), not CTR of sends:

| Treatment | Clicks | Opens | Sends | Expected mu (opens) | Actual Score | Delta | Verdict |
|-----------|--------|-------|-------|---------------------|-------------|-------|---------|
| 17049625 | 102 | 1,462 | 11,797 | 0.0697 | 0.0753 | +0.6pp | CLOSE |
| 21265478 | 142 | 1,232 | 7,008 | 0.1152 | 0.1114 | -0.4pp | MATCH |
| 21265451 | 123 | 1,347 | 9,735 | 0.0912 | 0.0929 | +0.2pp | MATCH |
| 16490939 | 41 | 701 | 8,065 | 0.0584 | 0.0603 | +0.2pp | MATCH |
| 21265506 | 118 | 1,175 | 8,051 | 0.1004 | 0.1003 | -0.01pp | EXACT |

**Verdict:** The model IS computing correct NIG posteriors. It uses opens (not sends) as the observation count, and clicks as the reward. The scores align closely with the expected NIG posterior mean mu = clicks / (1 + opens). **This is not a model bug -- the math is right.**

The stddev values also make sense: actual stddev (0.003-0.008) is much higher than the NIG posterior stddev (~0.0002), confirming that within-day score variation comes from Thompson Sampling's random perturbation, not posterior uncertainty.

---

### Finding 14: Score Anomaly Caused by New Treatment Cold Start

**Q14A: Daily Invalid Score Volume**

| Date | Invalid Scores | Avg Score | Max Score |
|------|---------------|-----------|-----------|
| Jan 23 | 197 | 1.48 | 4.32 |
| Jan 24 | 233 | 1.41 | 3.82 |
| Jan 25 | 239 | 1.38 | 2.69 |
| Jan 26 | 222 | 1.39 | 3.82 |
| Jan 27 | 186 | 1.48 | 3.14 |
| Jan 28 | 161 | 1.38 | 2.52 |
| Jan 29 | 185 | 1.43 | 2.97 |
| Jan 30 | 132 | 1.42 | 3.10 |
| Jan 31 | 31 | 1.37 | 2.65 |
| Feb 3 | 1 | 1.09 | 1.09 |

The anomaly peaked Jan 23-30 (130-240 invalid scores/day) and self-corrected by Feb 1 as the new treatments accumulated data.

**Q14B: Which Treatments Had Invalid Scores?**

All 15 treatments with scores > 1.0 are from the `2437xxxx` and `2441xxxx` series -- the batch of new treatments added on Jan 23.

**Q14C: Pre-Anomaly Data for Affected Treatments**

| Treatment | Sends Before Jan 23 | Clicks Before | Volume |
|-----------|-------------------|---------------|--------|
| 24370744 | 1 | 0 | LOW |
| 24370723 | 1 | 0 | LOW |
| 24410086 | 1 | 0 | LOW |
| 24370716 | 2 | 0 | LOW |
| 24370702 | 5 | 0 | LOW |
| 24370709 | 24 | 1 | LOW |
| 24370634 | 29 | 1 | LOW |

**Root cause of score > 1.0:** All affected treatments had 1-29 sends before the anomaly. With the NIG prior NIG(1, 1, 0, 1), a treatment with very few observations and even one click can produce an extreme posterior. With lambda=1 and n=1, a single click gives mu=0.5, and the Thompson Sampling perturbation (stddev = sqrt(beta/(lambda*(alpha-0.5)))) is very large, easily producing sampled scores above 1.0.

**Fix:** The platform should clamp scores to [0, 1] or use a warmup period that requires a minimum number of observations before including a treatment in the bandit.

---

### Finding 15: Click Latency Is Mixed

**Q15: Click Feedback Loop Verification**

Analyzing days with clicks and the next-day score response:

| Pattern | Count | % | Interpretation |
|---------|-------|---|----------------|
| Clicks on day D, score UP on D+1 | ~45% | Expected if learning | Correct response |
| Clicks on day D, score DOWN on D+1 | ~55% | Unexpected | Counterintuitive |

For high-volume treatments like 17049625 (218 sends/day), clicks barely move the score (delta ~0.0001). Score direction after clicks is essentially random. This is consistent with the NIG math: with 12,000+ observations already in the posterior, 1 additional click changes the mean by 1/(12,000+1) = 0.00008 -- effectively invisible.

For lower-volume treatments like 16593503 (12 sends/day), clicks DO visibly increase scores (+0.002 to +0.005 per day). This confirms the model IS learning from clicks -- it just can't learn fast enough for high-volume treatments because individual clicks are drowned by the denominator.

**Verdict:** Training data IS fresh (D+1 response visible). The issue is signal-to-noise, not data staleness.

---

### Finding 16: Per-Treatment Data Volume Confirms Sparsity

**Q16: Treatment Data Summary** (top 20 by volume)

| Treatment | Campaign | Sends | Opens | Clicks | CTR (opens) | Clicks/Week |
|-----------|----------|-------|-------|--------|-------------|-------------|
| 17049625 | BR/AC | 11,797 | 1,462 | 102 | 6.98% | 13.2 |
| 21265451 | BR/AC | 9,735 | 1,347 | 123 | 9.13% | 15.9 |
| 21265458 | BR/AC | 8,966 | 1,377 | 131 | 9.51% | 17.0 |
| 21265485 | BR/AC | 8,278 | 1,018 | 54 | 5.30% | 7.0 |
| 16490939 | Static | 8,065 | 701 | 41 | 5.85% | 5.3 |
| 21265506 | BR/AC | 8,051 | 1,175 | 118 | 10.04% | 15.3 |
| 21265478 | BR/AC | 7,008 | 1,232 | 142 | 11.53% | 18.4 |

**Long tail problem:** The top 7 treatments get 13-18 clicks/week, but the bottom 40+ treatments get 0.1-3 clicks/week. With 80+ treatments competing:

- **Top 10 treatments:** 7-18 clicks/week each (potentially learnable)
- **Middle 20 treatments:** 2-6 clicks/week each (very slow convergence)
- **Bottom 50+ treatments:** 0-2 clicks/week each (impossible to learn)

---

## Mathematical Analysis: NIG Convergence Simulation

`src/nig_convergence_simulation.py` simulates 200 runs of 180 days each under four scenarios.

### Simulation Results

| Scenario | Median Days | P90 Days | Never Converge | Correct at 90d | Correct at 180d |
|----------|------------|---------|----------------|----------------|-----------------|
| **A: Current (30 trts, flat prior)** | **106** | **169** | **50.0%** | 96.0% | 99.0% |
| B: 10 treatments, flat prior | **12** | 27 | 0.0% | 100.0% | 100.0% |
| C: Informative prior only | 106 | 169 | 50.0% | 96.0% | 99.0% |
| **D: 10 trts + informative prior** | **12** | **27** | **0.0%** | **100.0%** | **100.0%** |

### Key Insights

1. **Treatment count is THE bottleneck.** Reducing from 30 to 10 treatments cuts convergence from 106 to 12 days and eliminates non-convergence entirely. This is a 9x improvement.

2. **Informative priors don't help.** Scenario C (informative prior with 30 treatments) shows identical results to Scenario A (flat prior). With ~167 sends/treatment/day, the prior is overwhelmed by data within 1-2 days. The prior doesn't matter when the fundamental issue is signal-to-noise ratio.

3. **50% of simulations never converge with 30 treatments.** The best-vs-second-best gap is only ~0.7pp CTR. With 167 sends/treatment/day and ~2% CTR, the 95% CI width is ~1pp -- larger than the treatment gap. Convergence is a coin flip.

4. **Real situation is WORSE than simulated.** The simulation uses 30 treatments; Q12 shows 80+ active treatments in reality. At 80+ treatments with 60 sends/treatment/day, convergence would take significantly longer than 106 days.

### Posterior Evolution (Best vs Worst Treatment)

**Scenario A (Current): 30 treatments**
```
   Day   Best mu  Best std  Worst mu Worst std       Gap  Separable?
     1  0.024242  0.014726  0.000000  0.008571  0.024242          no
     8  0.030897  0.004868  0.002268  0.001689  0.028629         YES
    30  0.025820  0.002227  0.001165  0.000549  0.024656         YES
    90  0.025755  0.001292  0.001126  0.000288  0.024629         YES
   180  0.024835  0.000902  0.001138  0.000201  0.023697         YES
```

Best vs worst (2.5% vs 0.1%) separates within 8 days. But the **adjacent treatments** (2.5% vs 2.2%, or 1.0% vs 0.9%) never separate within 180 days -- that's what the "50% never converge" means.

**Scenario D (Recommended): 10 treatments**
```
   Day   Best mu  Best std  Worst mu Worst std       Gap  Separable?
     1  0.024749  0.006802  0.001333  0.001394  0.023416         YES
    12  0.024309  0.001775  0.002078  0.000522  0.022231         YES
    90  0.024473  0.000724  0.001947  0.000206  0.022526         YES
```

With 3x more data per treatment, even adjacent treatments separate quickly.

---

## Root Cause Verdict

### Is it a bug?

**No.** Q13 confirms the model computes correct NIG posteriors using opens-based CTR. The math checks out -- actual scores match expected posterior means within 0.2-0.6pp. The model is doing exactly what it's designed to do.

### Is it bad data?

**No.** Q11 shows clean data: zero duplicates, zero time-travel events, only 877 phantom clicks out of 821,740 sends (0.11%). Non-LIVE sends are correctly filtered.

### Is it a configuration issue?

**Partially.** Two configuration problems:
1. **Too many treatments (80+ vs recommended 10):** The Jan 23 addition of 31 new treatments was particularly harmful, causing the score anomaly and diluting data further.
2. **No cold-start protection:** New treatments with 1-2 observations can produce scores > 1.0 via Thompson Sampling perturbation. A warmup period or score clamping is needed.

### Is it a structural limitation?

**YES -- this is the primary cause.** The NIG Thompson Sampling model is fundamentally unable to learn at the current data volume:

- **80+ treatments** share ~5,000 sends/day = 60 sends/treatment/day
- At ~10% open rate and ~8% CTR of opens: ~0.5 clicks/treatment/day
- NIG posterior mean changes by 1/(1+opens) per click = ~0.001 per click
- Treatment CTR differences are ~0.5-2pp
- Posterior needs to shrink stddev below 0.5pp to differentiate = requires thousands of opens per treatment
- At 6 opens/treatment/day, this takes **months**

The model is correct but operating in a regime where convergence is mathematically impossible within a reasonable timeframe.

---

## Prioritized Recommendations

### Immediate (This Week)

1. **Reduce active treatments to 10-15** (HIGHEST IMPACT)
   - Simulation proves this cuts convergence from 106 to 12 days
   - Group the 80+ treatments into 10 categories by campaign type
   - Concentrate traffic on the best representative treatment per group
   - Expected impact: Model starts exploiting winners within 2 weeks

2. **Clamp scores to [0, 1]**
   - Prevents the score > 1.0 anomaly from recurring
   - Apply `MIN(score, 1.0)` in the serving layer
   - Zero-risk change, purely defensive

### Short-Term (Next 2 Weeks)

3. **Add cold-start warmup**
   - New treatments should not enter the bandit until they have >= 100 sends and >= 10 opens
   - During warmup, use the global average CTR as the treatment score
   - Prevents extreme scores from low-data treatments

4. **Revert to 10/90 split** (10% Random / 90% Bandit)
   - With reduced treatment count, the bandit should actually start learning
   - 90% traffic to Bandit gives it 4,500 sends/day = 450 per treatment (with 10 treatments)
   - This combined with treatment reduction should show measurable CTR lift within 30 days

### Medium-Term (Next Month)

5. **Implement hierarchical/group-level learning**
   - Instead of per-treatment NIG, learn at the campaign-type level
   - e.g., "Browse Recovery" as one arm with 5 sub-treatments
   - Share click signal across similar treatments to speed convergence

6. **Consider contextual bandits**
   - Current model ignores user features entirely (confirmed in code analysis)
   - Contextual TS with user features (vehicle type, engagement history) would allow personalization within treatment selection
   - Reference: `docs/bandit-models-deep-analysis.md` Section 4-6

---

## Summary of Key Numbers

| Metric | Value | Source |
|--------|-------|--------|
| Active treatments per day | 55-87 | Q12 |
| Sends per treatment per day | 60-90 | Q12 |
| Clicks per treatment per week | 0.1-18 | Q16 |
| Phantom clicks | 877 / 821,740 (0.11%) | Q11 |
| Invalid scores (> 1.0) | 1,686 total | Q11 |
| Score anomaly cause | 31 new treatments added Jan 23 | Q14 |
| NIG posterior accuracy | MATCH (within 0.2-0.6pp of expected) | Q13 |
| Median convergence (30 treatments) | 106 days, 50% never | Simulation |
| Median convergence (10 treatments) | 12 days, 0% never | Simulation |
| Convergence improvement factor | **9x faster** | Simulation |

---

## Appendix: Query Reference

| Query | File | Purpose | Key Finding |
|-------|------|---------|-------------|
| Q11 | `sql/analysis/bandit_investigation_phase2.sql` | Training data quality | Clean data (0 dupes, 0 time-travel) |
| Q12 | Same | Treatment count per day | 55-87 treatments (not 30) |
| Q13 | Same | NIG math verification | Model is correct (opens-based CTR) |
| Q14A-C | Same | Score > 1.0 forensics | New treatments with 1-29 sends |
| Q15 | Same | Click latency | D+1 response exists but signal ~0.001 |
| Q16 | Same | Per-treatment data volume | 0.1-18 clicks/week per treatment |
| Sim | `src/nig_convergence_simulation.py` | NIG convergence proof | 10 treatments → 12 days vs 106 |
| Phase 1 | `sql/analysis/bandit_investigation.sql` | Initial 10 queries | Model updates but doesn't learn |

---

## Conclusion

The bandit model is **not broken** -- it's **starving for data**. The NIG Thompson Sampling math is correct (Q13), the training data is clean (Q11), and the model updates daily (Phase 1). But with 80+ treatments competing for ~5,000 sends/day, each treatment gets so little data that the model cannot differentiate winners from losers.

The single most impactful fix is **reducing active treatments from 80+ to 10**. Our simulation proves this would cut convergence time from 106 days (with 50% never converging) to 12 days (with 100% convergence). Combined with a 90/10 traffic split favoring the bandit, the model should start showing measurable CTR improvement within 2-4 weeks.

**Bottom line: This isn't a software bug to fix -- it's a statistical reality to address through treatment consolidation.**
