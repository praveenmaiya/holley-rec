# V5.17 Improvements Backlog

**Date**: 2026-02-16
**Pipeline**: v5.17 (`sql/recommendations/v5_17_vehicle_fitment_recommendations.sql`)
**Issues discovered**: 20 total, across bandit analysis, fitment mismatch investigation, burst A/B test, and CTR formula audit

---

## Overview

**Target population**: 258K users with vehicle fitment (YMM) + email consent (out of 504K fitment users total, 3M in system). QA threshold: >= 250K users in output.

Two improvement paths exist:
1. **SQL path (v5.18+)** — incremental fixes to scoring, quality, and infrastructure
2. **GNN path** — replace hand-tuned scoring with learned embeddings (immediate focus)

This document catalogs all known issues, proposed fixes, and which ones GNN makes obsolete.

---

## Track 1: Scoring (SQL Simplification as Stepping Stone to GNN)

Current scoring uses 8 hand-tuned weights:
```sql
final_score = LOG(1+n) * weight(20/10/2)
  + CASE tier
      WHEN segment THEN LOG(1+n)*10
      WHEN make    THEN LOG(1+n)*8
      ELSE              LOG(1+n)*2
    END
```

Simplified target (~3 weights):
```sql
final_score = alpha * norm_intent + (1-alpha) * blended_popularity
```

| ID | Issue | Severity | What's Wrong | Proposed Fix | GNN Replaces? |
|----|-------|----------|--------------|--------------|---------------|
| S1 | Normalize intent + popularity | High | Intent (0-90) and popularity (0-12) on different scales; intent dominates when present | Normalize both to [0,1], combine with single alpha weight | Partially (GNN replaces popularity) |
| S2 | Smooth 3-tier fallback | Medium | Hard thresholds create scoring cliffs (4 orders = tier 1, 3 = tier 2) | Replace discrete tiers with Bayesian shrinkage: `orders/(orders+k)` weighting | Yes (message passing handles sparsity) |
| S3 | Universal scoring bias | Critical | Universals accumulate orders cross-segment, outscoring fitment products | Apply product-type discount (0.5x for universals) | Partially (GNN may learn similar bias from training data; slot reservation is the real fix) |
| S4 | Price affinity scoring | Low | No spending-based personalization; $50 items rec'd to $500 spenders | Gaussian decay on log-price distance, 4-tier median fallback | Partially (price as node feature) |
| S5 | Cold-start exploration | Low | 98% of users get identical popularity-ranked top-4 per segment | Stochastic sampling from top-20 with exploration weight | Yes (GNN's core hypothesis) |

---

## Track 2: Quality (Recommendation Relevance)

| ID | Issue | Severity | What's Wrong | Proposed Fix | GNN Replaces? |
|----|-------|----------|--------------|--------------|---------------|
| Q1 | Fitment slot reservation | Critical | 51.2% of fitment users (~258K of ~504K fitment population) receive zero vehicle-specific products despite avg 353 eligible parts | Adopt v5.18 logic: 2 fitment + 2 universal + backfill when insufficient candidates | No (business constraint) |
| Q2 | PartType diversity cap | High | `max_parttype_per_user` set to 999, effectively disabled; users get 4 products from same category | Change to 2 (1-param change in DECLARE) | No (post-ranking constraint) |
| Q3 | Price floor too high | Medium | $50 minimum excludes valid accessories and maintenance parts | Lower `min_price` $50 to $25 (keep commodity exclusions: chemicals, stickers, etc.) | No (business rule) |
| Q4 | Universal pool too small | Medium | `max_universal_products` capped at 500, limiting candidate diversity | Expand to 1000 | Partially (GNN scores all products) |
| Q5 | Variant dedup docs | Low | Regex `[0-9][BRGP]$` strips color suffixes but lacks inline documentation and regression detection | Add inline comments + regression test in QA checks | No |
| Q6 | Multi-vehicle handling | Low | Only v1 vehicle used; users with multiple vehicles get partial recommendations | Defer to GNN (multi-edge user-vehicle) | No (not in Option A scope — requires v2/v3 vehicle data) |

### Evidence: Fitment Mismatch (Q1)

- Employee complaint: 2019 VW Golf got carburetor recommendation (SKU 190004)
- 3/4 recs don't fit: 554-102 (UniversalPart=1), 145-160 (zero fitment data), 190004 (UniversalPart=1)
- Only MS100192 (APR Ignition Coil) is correct
- Root cause: v5.17 Step 3.4 is purely `ORDER BY final_score DESC` with no slot reservation
- Universal products get tier 1 segment scoring across multiple segments, outscoring fitment
- Top affected: Ford Mustang (52K users, 2,835 eligible parts), Camaro (16K), Chevelle (12K)

---

## Track 3: Infrastructure (Delivery & Feedback Loop)

| ID | Issue | Severity | What's Wrong | Proposed Fix | GNN Replaces? |
|----|-------|----------|--------------|--------------|---------------|
| I1 | ESP rate limiting | Medium | 67% of burst emails silently dropped; ESP limit ~1,100/min vs 3,400/min attempted | Send pacing at 1,000/min with queue monitoring | No |
| I2 | Bandit pool too large | High | 92 treatments in bandit pool; 34 get 1-7 sends/day (near-zero data); convergence requires 115+ days for 20 treatments | Reduce from 92 to ~10 treatments (4x faster convergence per simulation) | No (different layer) |
| I3 | Interaction tracking gap | High | `treatment_interaction` table broken for burst sends; real data only in Klaviyo events | Investigate pipeline lag, add reconciliation monitoring, codify Klaviyo attribution chain | No |
| I4 | No production monitoring | Medium | No automated checks for fitment ratio drift, score distribution shifts, or category concentration | Automated QA: fitment ratio, score drift, category concentration alerts | No |

### Evidence: Bandit Convergence (I2)

- Model 195001001 (arm 4689) IS updating daily but NOT learning
- NIG posteriors ARE mathematically correct (trains on clicks/opens)
- PRIMARY ROOT CAUSE: structural data sparsity, not a bug
- Simulation v2: 20 trts = 115 days (37.5% never converge), 10 trts = 28 days (0% never), 7 per-user = 44 days
- Informative priors DON'T help (overwhelmed by data in 1-2 days)

---

## Track 4: Analysis (Measurement Methodology)

| ID | Issue | Severity | What's Wrong | Proposed Fix | GNN Replaces? |
|----|-------|----------|--------------|--------------|---------------|
| A1 | CTR formula bug | Medium | `SUM(clicked)/SUM(opened)` counts phantom clicks (clicked=1 but opened=0 from image-blocking clients); 19 phantom clicks inflate Personalized CTR by ~0.5-0.9pp | Correct formula: `SUM(CASE WHEN opened=1 AND clicked=1 THEN 1 ELSE 0 END)/SUM(opened)` (fixed in analysis SQL) | No |
| A2 | Send frequency confound | High | Personalized 6.3 sends/user vs Static 1.9 (3.3x); per-send CTR gap (P=4.57% vs S=12.26%) mostly from frequency dilution, not content quality | Standardize on per-user binary click rate as primary KPI (P=3.57% vs S=3.78% = near parity) | No |
| A3 | Static = Apparel only | Medium | Only 1 of 22 Static treatments (16490939, Apparel) has sends; "Personalized vs Static" = "Vehicle Parts vs Apparel" in practice | Design true "Static Vehicle Parts" control treatment for fair comparison | No |
| A4 | Burst attribution broken | Medium | Treatment_interaction table not populated for burst sends; must use Klaviyo event chain | Codify Klaviyo attribution chain (AuxiaEmailTriggered sendId -> Received Email Transmission ID -> Opened/Clicked) as reusable SQL | No |
| A5 | No engagement tier in output | Low | Output table lacks hot/warm/cold classification for stratified analysis | Adopt v5.18 engagement tier classification in output | No |

### Evidence: Send Frequency (A2)

- Email fatigue pattern: P CTR drops 70% from 1st send (6.74%) to 7th+ send (2.00%)
- Open rate decays: 15.40% to 7.89%
- 3,802 7th+ sends at 2% CTR heavily drag down aggregate
- Within-user comparison (612 users who received both): Personalized +32% opens, CTR parity

---

## Priority Phases (SQL Path)

| Phase | Items | Focus | Effort | Timing |
|-------|-------|-------|--------|--------|
| **1 (Critical — IMMEDIATE)** | Q1, Q2, S3 | Fix 51% zero-fitment via slot reservation + universal discount | 2-3 days | **Deploy now, independent of GNN** |
| **2 (Scoring)** | S1, S2, A2, A5 | Simplify formula from 8 to ~3 weights | 3-4 days | After Phase 1 |
| **3 (Quality)** | Q3, Q4, I2, I4 | Expand candidates, optimize bandit, add monitoring | 3-4 days | After Phase 2 |
| **4 (Long-tail)** | S4, S5, I1, I3, A1, A3, A4, Q5, Q6 | Price affinity, ESP pacing, methodology fixes | Ongoing | Continuous |

**Phase 1 affects 51% of users TODAY.** These are business-rule fixes (slot reservation, diversity cap, universal discount) that are independent of the GNN experiment and should not wait for GNN results.

---

## GNN Overlap Summary (Conservative)

| Category | Total | GNN Replaces | GNN Partially | SQL Only |
|----------|-------|-------------|---------------|----------|
| Scoring | 5 | 2 (S2, S5) | 3 (S1, S3, S4) | 0 |
| Quality | 6 | 0 | 1 (Q4) | 5 (Q1, Q2, Q3, Q5, Q6) |
| Infrastructure | 4 | 0 | 0 | 4 |
| Analysis | 5 | 0 | 0 | 5 |
| **Total** | **20** | **2** | **4** | **14** |

Even with GNN, 14 issues remain SQL-only. Phase 1 critical fixes (Q1, Q2, S3) must be deployed immediately regardless of GNN timeline.

**Reclassification notes** (vs prior version):
- S3 (universal bias): Moved from "Replaces" to "Partially" — GNN can learn the same bias from training data; slot reservation (Q1) is the primary fix
- Q6 (multi-vehicle): Moved from "Replaces" to "SQL Only" — not in GNN Option A scope, requires v2/v3 vehicle data

---

## References

| Document | Content |
|----------|---------|
| `docs/analysis/fitment_mismatch_investigation_2026_02_12.md` | Fitment mismatch root cause |
| `docs/bandit_investigation_report_v2.md` | Bandit convergence analysis |
| `docs/analysis/burst_ab_test_analysis_2026_02_12.md` | Burst A/B test findings |
| `docs/analysis/personalized_vs_static_uplift_report_v2.md` | CTR formula and send frequency |
| `specs/v5_18_revenue_ab_test.md` | V5.18 slot reservation design |
