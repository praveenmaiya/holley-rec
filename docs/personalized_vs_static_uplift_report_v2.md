# Personalized vs Static Uplift Report V2

**Date**: February 5, 2026
**Author**: Claude Code analysis
**Status**: COMPLETE - full v5.17 period (no crash exclusion), CTR formula corrected, diagnostic analysis added
**Updated**: February 5, 2026 - Added CTR formula fix + 6 diagnostic queries

---

## Executive Summary

**V2 Change**: This version treats v5.17 (Jan 10 - Feb 4) as ONE period without crash exclusion. Results differ significantly from v1.

**Update (Feb 5)**: CTR formula corrected (excluded clicks without opens from image-blocking clients). Six diagnostic queries added to investigate WHY Static outperforms.

Seven key findings:

1. **No reversal**: Static outperforms Personalized in BOTH periods on corrected CTR (v5.7: 12.26% vs 4.57%; v5.17: 16.87% vs 3.52%).
2. **CTR formula bug fixed**: 19 clicks without opens removed (17 Personalized, 2 Static). Correcting the formula makes Personalized slightly WORSE, widening Static's advantage.
3. **Send frequency is a MAJOR confound**: Personalized sends 6.3 emails/user vs Static 1.9/user (3.3x). Per-user binary click rates in v5.7 are nearly equal (P=3.57% vs S=3.78%, delta only -0.21pp). The per-send CTR gap is largely an artifact of email fatigue.
4. **Email fatigue confirmed**: Personalized CTR drops 70% from 1st send (6.74%) to 7th+ send (2.00%). This heavily dilutes aggregate CTR.
5. **First-send CTR still favors Static**: Even on first email only, Static CTR (14.51%) beats Personalized (6.74%) - the content/category difference is real.
6. **Bandit selection bias ruled out**: Static wins in BOTH Random arm (4103) and Bandit arm (4689). The bandit is not artificially boosting Static.
7. **Revenue signal**: Static outperforms on revenue per user ($84 vs $56 in v5.7 30d; $59 vs $9 in v5.17 30d).

**Critical insight**: The per-send CTR gap (3x Static advantage) overstates the real difference. When normalized for send frequency, the v5.7 gap shrinks to nearly zero (-0.21pp). However, Static's first-send CTR advantage (14.51% vs 6.74%) is genuine and likely driven by the Apparel vs Vehicle Parts content difference.

---

## Analysis Design

### Scope
- **Campaign**: Post Purchase only (surface_id=929)
- **Traffic**: LIVE only (request_source='LIVE')
- **Treatments**: 10 Personalized Fitment vs 22 Static (only Apparel 16490939 has sends)
- **Grain**: treatment_tracking_id (one row per email send)

### Periods

| Period | Dates | Pipeline | Notes |
|--------|-------|----------|-------|
| **v5.7** | Dec 7, 2025 - Jan 9, 2026 | Baseline | Global popularity scoring |
| **v5.17** | Jan 10, 2026 - Feb 4, 2026 | 3-tier segment fallback | Full period (no exclusions) |

### Three Methods

| Method | What it controls for | Strength |
|--------|---------------------|----------|
| **A: MECE** | User population differences (fitment-eligible only) | Good |
| **B: Within-user** | All user-level confounders (same users, both types) | Gold standard |
| **C: Deployment uplift (DiD)** | Temporal trends (Static as control) | Causal estimate |

---

## 1. Data Quality

### Send Volume

| Period | Treatment | Total Sends | Unique Users | Opens | Clicks | Fitment Eligible |
|--------|-----------|-------------|--------------|-------|--------|------------------|
| v5.7 | Personalized | 15,226 | 2,409 | 1,882 | 97 | 15,226 (100%) |
| v5.7 | Static | 58,094 | 30,890 | 4,661 | 319 | 2,900 (5%) |
| v5.17 | Personalized | 3,537 | 586 | 653 | 29 | 3,537 (100%) |
| v5.17 | Static | 13,448 | 7,236 | 1,253 | 76 | 290 (2%) |

**Key observation**: Personalized is 100% fitment-eligible; Static is only 2-5% fitment-eligible. This is by design - Personalized only sends to users with vehicle data.

**V2 vs V1**: v5.17 now includes full 3,537 Personalized sends (vs 749 in v1 crash-excluded).

### Static Treatment Distribution

| Treatment ID | Category | Sends | Users | Opens | Clicks |
|--------------|----------|-------|-------|-------|--------|
| 16490939 | Apparel | 71,542 | 37,380 | 5,914 | 395 |
| (others) | Various | 0 | 0 | 0 | 0 |

**Caveat**: "Personalized vs Static" = "Vehicle Parts vs Apparel" in practice.

---

## 2. Method A: MECE Comparison

_Fitment-eligible users only._

### Primary Result (Corrected CTR Formula)

_CTR formula corrected: only counts clicks where opened=1 (excludes image-blocking phantom clicks)._

| Period | Treatment | Sends | Unique Users | Opens | Clicks (corrected) | Open Rate | CTR (opens) | CTR (sends) |
|--------|-----------|-------|--------------|-------|---------------------|-----------|-------------|-------------|
| v5.7 | Personalized | 15,226 | 2,409 | 1,882 | 86 | 12.36% | 4.57% | 0.56% |
| v5.7 | Static | 2,900 | 1,560 | 473 | 58 | 16.31% | **12.26%** | 2.00% |
| v5.17 | Personalized | 3,537 | 586 | 653 | 23 | 18.46% | 3.52% | 0.65% |
| v5.17 | Static | 290 | 162 | 83 | 14 | 28.62% | **16.87%** | 4.83% |

_Note: "Clicks (corrected)" excludes 19 clicks from image-blocking clients (17 P, 2 S). Original total clicks: P v5.7=97, P v5.17=29, S v5.7=60, S v5.17=14._

### With 95% Confidence Intervals (Wilson, Corrected)

| Period | Treatment | Opens | Clicks | CTR (opens) | 95% CI |
|--------|-----------|-------|--------|-------------|--------|
| v5.7 | Personalized | 1,882 | 86 | 4.57% | [3.71%, 5.62%] |
| v5.7 | Static | 473 | 58 | 12.26% | [9.58%, 15.56%] |
| v5.17 | Personalized | 653 | 23 | 3.52% | [2.35%, 5.24%] |
| v5.17 | Static | 83 | 14 | 16.87% | [10.32%, 26.34%] |

**Interpretation**: Static CTR is significantly higher than Personalized in BOTH periods. CIs don't overlap. However, per-send CTR is confounded by 3.3x send frequency difference (see Section 7 Diagnostic).

---

## 3. Method B: Within-User Comparison (Gold Standard)

_Users who received BOTH Personalized and Static._

### Send-Level Comparison

| Period | Overlap Users | P Sends | P Opens | P Clicks | P CTR | S Sends | S Opens | S Clicks | S CTR | Delta (pp) |
|--------|---------------|---------|---------|----------|-------|---------|---------|----------|-------|------------|
| v5.7 | 612 | 3,273 | 354 | 19 | 5.37% | 1,117 | 169 | 21 | **12.43%** | **-7.06** |
| v5.17 | 12 | 71 | 4 | 1 | 25.0% | 19 | 3 | 1 | 33.33% | -8.33 |

**V2 vs V1**: Now have 12 v5.17 overlap users (vs 0 in v1), though sample is tiny.

### User-Level (At-Least-Once)

| Period | Overlap Users | Clicked Personalized | Clicked Static | Clicked Both | Clicked Neither | Pct Clicked P | Pct Clicked S | Delta (pp) |
|--------|---------------|---------------------|----------------|--------------|-----------------|---------------|---------------|------------|
| v5.7 | 612 | 18 | 21 | 2 | 575 | 2.94% | **3.43%** | **-0.49** |
| v5.17 | 12 | 1 | 1 | 1 | 11 | 8.33% | 8.33% | 0.0 |
| Combined | 657 | 21 | 23 | 3 | 616 | 3.20% | **3.50%** | **-0.30** |

**Interpretation**: Among users who received both treatments, Static has consistently higher click rates. The delta favors Static (-0.30pp combined).

---

## 4. Method C: Deployment Uplift (Difference-in-Differences)

_Static serves as the control trend. If Personalized improved MORE than Static after v5.17 deployment, that excess improvement is causally attributable to the algorithm change._

### DiD Summary (Fitment-Eligible Only, Corrected CTR)

| Treatment | v5.7 Sends | v5.7 Open Rate | v5.7 CTR (opens) | v5.17 Sends | v5.17 Open Rate | v5.17 CTR (opens) | Open Rate Delta | CTR Delta |
|-----------|-----------|----------------|------------------|-------------|-----------------|-------------------|-----------------|-----------|
| Personalized | 15,226 | 12.36% | 4.57% | 3,537 | 18.46% | 3.52% | +6.10pp | **-1.05pp** |
| Static | 2,900 | 16.31% | 12.26% | 290 | 28.62% | 16.87% | +12.31pp | **+4.60pp** |

### DiD Estimate (Corrected)

| Metric | DiD (pp) | Interpretation |
|--------|----------|----------------|
| Open Rate | **-6.21pp** | Static open rate improved MORE than Personalized |
| **CTR (opens)** | **-5.66pp** | **Static CTR improved 5.66pp MORE than Personalized** |
| CTR (sends) | -2.72pp | Static improved more on sends-based CTR |

**V2 vs V1 Critical Difference**:
- v1 (crash-excluded): DiD = +13.13pp favoring Personalized
- v2 (full period, corrected): DiD = **-5.66pp favoring Static**

The crash exclusion in v1 removed data points where Static was performing well, creating an artificial "reversal" narrative.

**Caveat on DiD**: This comparison is heavily confounded by send frequency (6.3 vs 1.9 per user). See Section 7 for diagnostics showing per-user binary rates are nearly equal in v5.7.

---

## 5. The Reversal Story (Updated)

_There is no reversal when including full data. Per-send CTR gap is partly an artifact of send frequency._

| Period | P Open Rate | P CTR (opens) | S Open Rate | S CTR (opens) | Winner (per-send) |
|--------|-------------|---------------|-------------|---------------|-------------------|
| v5.7 | 12.36% | 4.57% | 16.31% | 12.26% | **Static** |
| v5.17 | 18.46% | 3.52% | 28.62% | 16.87% | **Static** |

**Narrative**:
- In v5.7: Static (Apparel) outperformed Personalized on per-send CTR by 7.69pp.
- In v5.17: Static STILL outperforms Personalized on per-send CTR, gap widened to 13.35pp.
- However, the per-send metric is misleading due to 3.3x send frequency difference.
- **Per-user binary click rate in v5.7 is nearly equal** (P=3.57% vs S=3.78%, delta only -0.21pp).
- First-send CTR still favors Static (14.51% vs 6.74%), suggesting the Apparel vs Vehicle Parts content difference is real.

**Why v1 showed a reversal**: The Jan 14+ crash window disproportionately affected Static (which had more volume in that period). Excluding crash data removed Static's good performance, creating an artificial 0% CTR for Static in v5.17.

---

## 6. Revenue Attribution (Directional)

_Revenue uses fuzzy email+time matching against order events. Treat as directional signal, not causal proof._

**IMPORTANT**: Results below filter to **fitment-eligible users only** for fair population comparison. Excludes overlap users (who received both treatment types) to prevent double-counting. Orders must occur AFTER email send (not same-day).

### Data Quality Fixes Applied

| Fix | Impact |
|-----|--------|
| Overlap exclusion | Users receiving both P and S excluded |
| Order dedupe | Duplicate order events removed |
| Per-send attribution | Orders attributed to most recent preceding send |
| Timestamp fix | Orders must occur strictly AFTER email send |

### 7-Day Attribution (Fitment-Eligible Only, All Fixes Applied)

| Period | Treatment | Users | Buyers | Conv Rate | Revenue | Rev/User |
|--------|-----------|-------|--------|-----------|---------|----------|
| v5.7 | Personalized | 1,797 | 80 | 4.45% | $50,086 | $27.87 |
| v5.7 | Static | 913 | 56 | 6.13% | $35,393 | **$38.77** |
| v5.17 | Personalized | 487 | 15 | 3.08% | $2,474 | $5.08 |
| v5.17 | Static | 150 | 7 | 4.67% | $5,061 | **$33.74** |

### 30-Day Attribution (Fitment-Eligible Only, All Fixes Applied)

| Period | Treatment | Users | Buyers | Conv Rate | Revenue | Rev/User |
|--------|-----------|-------|--------|-----------|---------|----------|
| v5.7 | Personalized | 1,797 | 143 | 7.96% | $101,056 | $56.24 |
| v5.7 | Static | 913 | 98 | 10.73% | $76,730 | **$84.04** |
| v5.17 | Personalized | 487 | 19 | 3.90% | $4,170 | $8.56 |
| v5.17 | Static | 150 | 14 | 9.33% | $8,785 | **$58.56** |

**Key finding**: Static outperforms on revenue per user in BOTH periods and BOTH windows:
- v5.7: Static $84/user vs Personalized $56/user (1.5x higher)
- v5.17: Static $59/user vs Personalized $9/user (6.8x higher)

**Caveats**:
- No causal link between email send and purchase (no true control)
- Long consideration cycles for automotive parts
- Revenue attribution is based on any order within window, not click-to-purchase tracking
- v5.17 samples are smaller than v5.7

---

## 7. Diagnostic Investigation: Why Static Outperforms (Added Feb 5)

_SQL queries: Section 6 (6a-6f) in `uplift_analysis_queries_v2.sql`._

Six diagnostic queries were run to investigate WHY Static (Apparel) outperforms Personalized (Vehicle Parts). The investigation tested three hypotheses: CTR formula bug, bandit selection bias, and send frequency confound.

### 7a. CTR Formula Bug (CONFIRMED - Minor Impact)

The original CTR formula `SUM(clicked)/SUM(opened)` included clicks from image-blocking email clients where `clicked=1` but `opened=0`. This inflates CTR.

| Treatment | Period | Total Clicks | Clicked-No-Open | Clicked-With-Open | Old CTR | Corrected CTR | Impact |
|-----------|--------|-------------|-----------------|-------------------|---------|---------------|--------|
| Personalized | v5.7 | 97 | 11 | 86 | 5.15% | 4.57% | -0.58pp |
| Static | v5.7 | 60 | 2 | 58 | 12.68% | 12.26% | -0.42pp |
| Personalized | v5.17 | 29 | 6 | 23 | 4.44% | 3.52% | -0.92pp |
| Static | v5.17 | 14 | 0 | 14 | 16.87% | 16.87% | 0 |

**Verdict**: Bug confirmed but minor. Correction makes Personalized slightly WORSE (more phantom clicks from vehicle parts email formatting). All CTR formulas in SQL files have been fixed.

### 7b. Bandit Selection Bias (RULED OUT)

Testing whether Thompson Sampling bandit (arm 4689) artificially boosts Static by sending it to predicted high-clickers.

| Period | Treatment | Arm 4103 (Random) CTR | Arm 4689 (Bandit) CTR |
|--------|-----------|----------------------|----------------------|
| v5.17 | Personalized | 3.68% | 3.30% |
| v5.17 | Static | **16.36%** | **17.86%** |
| v5.7 | Personalized | 4.64% | 0.00% |
| v5.7 | Static | **12.39%** | 7.69% |

**Verdict**: Static wins in BOTH Random and Bandit arms. The Random arm (4103) is unbiased, and Static still has 4-5x higher CTR. Bandit selection bias is NOT the explanation.

### 7c. Send Frequency Confound (MAJOR FINDING)

Per-user binary click rate eliminates send frequency as a confound by asking: "What % of users clicked at least once?"

| Period | Treatment | Users | Users Clicked | Pct Clicked | Avg Sends/User |
|--------|-----------|-------|--------------|-------------|----------------|
| v5.7 | Personalized | 2,409 | 86 | **3.57%** | 6.3 |
| v5.7 | Static | 1,560 | 59 | **3.78%** | 1.9 |
| v5.17 | Personalized | 586 | 24 | 4.10% | 6.0 |
| v5.17 | Static | 162 | 13 | **8.02%** | 1.8 |

**Verdict for v5.7**: Per-user click rates are nearly identical (3.57% vs 3.78%, delta -0.21pp). The massive per-send CTR gap (4.57% vs 12.26%) is largely an artifact of Personalized sending 3.3x more emails per user. Each additional email dilutes the per-send CTR.

**Verdict for v5.17**: Static still wins per-user (8.02% vs 4.10%), but with only 162 Static users, the sample is small.

### 7d. First-Send-Only Comparison (Eliminates Fatigue + Novelty)

Compares CTR only on each user's first email of each type. Controls for both fatigue and novelty effects.

| Period | Treatment | First Sends | Opens | Clicks | Open Rate | CTR (opens) | CTR (sends) |
|--------|-----------|------------|-------|--------|-----------|-------------|-------------|
| v5.7 | Personalized | 2,409 | 371 | 25 | 15.40% | 6.74% | 1.04% |
| v5.7 | Static | 1,560 | 255 | 37 | 16.35% | **14.51%** | 2.37% |
| v5.17 | Personalized | 344 | 76 | 5 | 22.09% | 6.58% | 1.45% |
| v5.17 | Static | 144 | 45 | 11 | 31.25% | **24.44%** | 7.64% |

**Verdict**: Even on first-send-only, Static has ~2x higher CTR. The Apparel vs Vehicle Parts content difference is genuinely driving higher engagement. Users click Apparel emails more than Vehicle Parts emails regardless of send frequency.

### 7e. Email Fatigue Decay (CONFIRMED)

CTR by send rank for v5.7 (largest sample):

**Personalized:**
| Send Rank | Sends | Opens | Clicks | Open Rate | CTR (opens) |
|-----------|-------|-------|--------|-----------|-------------|
| 1st send | 2,409 | 371 | 25 | 15.40% | **6.74%** |
| 2nd send | 2,258 | 326 | 12 | 14.44% | 3.68% |
| 3rd send | 2,076 | 299 | 18 | 14.40% | 6.02% |
| 4th-6th | 4,681 | 586 | 25 | 12.52% | 4.27% |
| 7th+ | 3,802 | 300 | 6 | 7.89% | **2.00%** |

**Static:**
| Send Rank | Sends | Opens | Clicks | Open Rate | CTR (opens) |
|-----------|-------|-------|--------|-----------|-------------|
| 1st send | 1,560 | 255 | 37 | 16.35% | **14.51%** |
| 2nd send | 1,273 | 206 | 21 | 16.18% | 10.19% |
| 3rd send | 48 | 11 | 0 | 22.92% | 0.00% |

**Verdict**: Clear fatigue pattern for Personalized - CTR drops 70% from 1st send (6.74%) to 7th+ send (2.00%). Open rate drops from 15.40% to 7.89%. Static barely gets past 2nd send, so fatigue is less of a factor. The 3,802 7th+ Personalized sends at 2.00% CTR heavily drag down the aggregate.

### 7f. Data Integrity (CLEAN)

| Check | Result |
|-------|--------|
| Total rows | 90,305 |
| Unique tracking IDs | 90,305 |
| Duplicates | **0** |
| Cross-type contamination | **None** |

**Verdict**: Base table is clean. No duplicates or cross-contamination.

### Diagnostic Summary

| Hypothesis | Verdict | Impact |
|------------|---------|--------|
| CTR formula bug | Confirmed, minor | -0.5 to -0.9pp on Personalized; Static gap WIDENS |
| Bandit selection bias | **Ruled out** | Static wins in both Random and Bandit arms |
| Send frequency confound | **Major factor** | Per-user binary nearly equal in v5.7 (delta -0.21pp) |
| Email fatigue | **Confirmed** | P CTR drops 70% from 1st to 7th+ send |
| Category/content difference | **Real** | First-send CTR: S=14.51% vs P=6.74% (2x) |
| Data integrity | Clean | No issues found |

**Bottom line**: The 3x per-send CTR advantage of Static is driven by THREE factors:
1. **Send frequency dilution** (biggest factor): 6.3 sends/user for P vs 1.9 for S inflates S's per-send CTR
2. **Email fatigue**: P CTR drops 70% over repeated sends
3. **Content/category difference** (real but smaller): Apparel genuinely gets ~2x more clicks on first send than Vehicle Parts

---

## 8. Caveats and Limitations

1. **No true control group**: Cannot measure absolute lift vs "no email"
2. **Static = Apparel only**: 1 of 22 Static treatments has sends; comparison is Parts vs Apparel, not pure personalization test
3. **Send frequency confound**: Personalized sends 3.3x more emails per user (6.3 vs 1.9), inflating Static's per-send CTR advantage. Per-user binary rates are nearly equal in v5.7.
4. **Email fatigue**: Personalized CTR drops 70% from 1st to 7th+ send, heavily diluting aggregate per-send metrics
5. **Revenue is directional**: Fuzzy attribution, no click-to-purchase tracking
6. **Revenue overlap exclusion**: Users receiving both treatment types excluded from revenue analysis to prevent double-counting
7. **Order event dedupe**: Uses both 'Placed Order' and 'Consumer Website Order' events; if same transaction emits both, revenue may be inflated (no OrderId for deduplication)
8. **Boost factor bias**: 100x boost for Personalized means selection isn't random
9. **Category confounding**: Personalized=Vehicle Parts, Static=Apparel - not a pure personalization test
10. **CTR formula corrected**: Prior reports used inflated CTR (including clicks without opens). All numbers in this report use corrected formula.

---

## 9. Recommendations

### For Contract Renewal Communication

**Can claim with confidence:**
> "When comparing per-user engagement (did the user click at least once?), Personalized Vehicle Parts and Static Apparel perform nearly identically in v5.7 (3.57% vs 3.78%). The apparent 3x per-send CTR advantage of Static is largely driven by email frequency differences (Static sends 1.9 emails/user vs Personalized 6.3)."

**Can claim with caveat:**
> "On first-email-only CTR, Static Apparel outperforms Personalized Vehicle Parts by ~2x (14.51% vs 6.74%). This likely reflects the inherent clickability difference between Apparel and Vehicle Parts content, not a failure of personalization."

**Cannot claim:**
> "Static is 3x better than Personalized" (inflated by send frequency confound)
> "v5.17 reversed the CTR trend" (only true when excluding crash window data)

### For Product Improvement
1. **Reduce Personalized send frequency**: 6.3 sends/user causes 70% CTR decay. Cap at 2-3 sends to maintain engagement.
2. **Consider hybrid approach**: Vehicle Parts + Apparel recommendations in the same email
3. **Equalize send frequency** for fair comparison: ensure both treatments send similar emails/user
4. **Deploy v5.18** with proper A/B test design (not boost factor bias)
5. **Enable more Static treatments** to test categories beyond Apparel
6. **Use per-user binary metrics** as primary KPI instead of per-send CTR to avoid send frequency confounds

---

## Appendix: V1 vs V2 Comparison

| Metric | V1 (crash excluded) | V2 (full period) | Difference |
|--------|---------------------|------------------|------------|
| v5.17 P sends (fitment) | 749 | 3,537 | +4.7x |
| v5.17 S sends (fitment) | 74 | 290 | +3.9x |
| v5.17 S CTR (fitment) | 0.00% | 16.87% | Dramatic change |
| DiD (CTR opens) | +12.59pp | -5.66pp | **Sign reversal** |
| CTR winner v5.17 | Personalized | Static | Changed |
| Overlap users v5.17 | 0 | 12 | Now have data |

---

## Appendix: SQL Files

| File | Purpose |
|------|---------|
| `sql/analysis/uplift_base_table.sql` | Creates base analysis table |
| `sql/analysis/uplift_analysis_queries_v2.sql` | V2 analysis queries (no crash exclusion) |
| `sql/analysis/uplift_analysis_queries.sql` | V1 analysis queries (crash excluded) |

### Run Commands

```bash
# Step 1: Create base table (if not already created)
bq query --use_legacy_sql=false < sql/analysis/uplift_base_table.sql

# Step 2: Run v2 analysis queries
# Copy individual sections to BQ console or run via bq CLI
```

---

## Appendix: Treatment IDs

### Personalized Fitment (10)
```
16150700, 20142778, 20142785, 20142804, 20142811,
20142818, 20142825, 20142832, 20142839, 20142846
```

### Static (22, only 16490939 has sends)
```
16490932, 16490939, 16518436, 16518443, 16564380,
16564387, 16564394, 16564401, 16564408, 16564415,
16564423, 16564431, 16564439, 16564447, 16564455,
16564463, 16593451, 16593459, 16593467, 16593475,
16593483, 16593491
```
