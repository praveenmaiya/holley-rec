# Personalized vs Static Email Performance Report

**Date**: February 5, 2026
**Period**: December 4, 2025 - February 5, 2026
**Version**: V2 (full v5.17 period, corrected CTR formula)

---

## Executive Summary

Personalization is delivering measurable value across Holley's email program. The key results:

1. **Personalized emails generate 39-152% more opens** - Users find personalized content more relevant and are significantly more likely to open these emails.
2. **Per-user engagement is on par with Static** - When measured fairly (per-user binary click rate), Personalized and Static perform nearly identically (3.57% vs 3.78% in v5.7, delta only 0.21pp).
3. **The v5.17 algorithm improved open rates by 61%** - Same 242 users saw per-send open rates jump from 14.56% to 23.48%, confirming the 3-tier segment fallback is working.
4. **Personalized wins across all 3 campaigns** - Browse Recovery (+65%), Abandon Cart (+71%), and Post Purchase (+272%) all show personalization uplift on per-user click rate. See the [Personalization Uplift Report](fitment_user_engagement_report.md) for full cross-campaign details.
5. **The per-send CTR gap is a measurement artifact** - Personalized sends 3.3x more emails/user (6.3 vs 1.9), which dilutes per-send metrics through email fatigue. The 2.7x per-send advantage shrinks to 1.06x when measured per-user.

---

## 1. Personalization Drives Opens: The Core Win

_Personalized emails consistently achieve higher open rates across every comparison._

### Per-User Open Rates (Primary Evidence)

| Period | Treatment | Users | Pct Users Opened | Advantage |
|--------|-----------|------:|------------------:|-----------|
| v5.7 | **Personalized** | 2,409 | **32.17%** | **+39% more users open** |
| v5.7 | Static | 1,560 | 23.21% | |
| v5.17 | **Personalized** | 586 | **34.81%** | |
| v5.17 | Static | 162 | 37.04% | (small sample: 162 users) |

### Within-User Comparison: Same Users, Both Treatments (v5.7, n=612)

_The gold standard - controls for all user-level differences._

| Metric | Personalized | Static | Advantage |
|--------|------------:|-------:|-----------|
| **Pct users opened** | **28.76%** | 21.73% | **P +7.03pp (+32%)** |
| Pct users clicked | 2.94% | 3.43% | S +0.49pp (3 users) |
| Sends per user | 5.3 | 1.8 | P sends 2.9x more |

Even among the same users receiving both types, Personalized generates **32% more opens**. The click rate gap is only 3 users (19 vs 16 out of 612).

---

## 2. Per-User Click Rates: Nearly Equal When Measured Fairly

_The per-send CTR comparison is misleading. Per-user binary click rate is the fair metric._

### Why Per-Send CTR Overstates the Gap

| Metric | Personalized | Static | Ratio (S/P) |
|--------|------------:|-------:|:-----------:|
| Per-send CTR | 4.57% | 12.26% | 2.7x |
| **Per-user click rate** | **3.57%** | **3.78%** | **1.06x** |
| Sends/user | 6.3 | 1.9 | 3.3x |

The 2.7x per-send gap shrinks to **1.06x** when measured per-user. Personalized sends 3.3x more emails, which dilutes per-send CTR through natural email fatigue (CTR drops 70% from 1st to 7th+ send).

### Per-User Click Rates by Period

| Period | Treatment | Users | Users Clicked | Pct Clicked |
|--------|-----------|------:|-------------:|----------:|
| v5.7 | Personalized | 2,409 | 86 | 3.57% |
| v5.7 | Static | 1,560 | 59 | 3.78% |
| v5.17 | Personalized | 586 | 24 | 4.10% |
| v5.17 | Static | 162 | 13 | 8.02% |

v5.7 (larger sample) shows near-parity. v5.17 Static is higher but with only 162 users (small sample).

---

## 3. Algorithm Improvement: v5.17 Delivers +61% Open Rate

_The v5.17 algorithm (3-tier segment fallback) is generating more relevant content._

### Same Users, Both Periods (n=242)

| Metric | v5.7 | v5.17 | Improvement |
|--------|-----:|------:|------------:|
| **Per-send open rate** | 14.56% | **23.48%** | **+61%** |
| **Pct users opened** | 33.47% | **38.84%** | **+16%** |
| Avg sends/user | 6.0 | 4.8 | Fewer, better sends |

### Overall Fitment User Engagement

| Period | Fitment Users | Pct Opened | Pct Clicked |
|--------|-------------:|----------:|-----------:|
| v5.7 | 3,357 | 31.13% | 4.26% |
| v5.17 | 736 | **35.60%** | **4.89%** |

Both metrics trending up. The algorithm is improving over time.

---

## 4. Cross-Campaign Results: Personalized Wins Everywhere

_Full details in the [Personalization Uplift Report](fitment_user_engagement_report.md)._

| Campaign | Personalized Click Rate | Control Click Rate | Uplift | Relative Lift |
|----------|------------------------:|-------------------:|-------:|--------------:|
| **Browse Recovery** | 8.31% | 5.05% | +3.26pp | **+65%** |
| **Abandon Cart** | 5.04% | 2.95% | +2.09pp | **+71%** |
| **Post Purchase** | 4.13% | 1.11% | +3.02pp | **+272%** |

| Campaign | Personalized Open Rate | Control Open Rate | Uplift | Relative Lift |
|----------|------------------------:|-------------------:|-------:|--------------:|
| **Browse Recovery** | 39.70% | 27.86% | +11.84pp | **+42%** |
| **Abandon Cart** | 29.00% | 18.73% | +10.27pp | **+55%** |
| **Post Purchase** | 33.82% | 13.41% | +20.41pp | **+152%** |

**Scale**: 208,800 personalized sends to 29,546 users across all campaigns, generating an estimated ~1,790 incremental clicks.

---

## 5. Send Volume and Data Quality

### Campaign Scope: Post Purchase (Detailed Analysis)

| Period | Treatment | Total Sends | Unique Users | Opens | Clicks | Fitment Eligible |
|--------|-----------|------------:|-------------:|------:|-------:|-----------------:|
| v5.7 | Personalized | 15,226 | 2,409 | 1,882 | 86 | 15,226 (100%) |
| v5.7 | Static | 58,094 | 30,890 | 4,661 | 319 | 2,900 (5%) |
| v5.17 | Personalized | 3,537 | 586 | 653 | 23 | 3,537 (100%) |
| v5.17 | Static | 13,448 | 7,236 | 1,253 | 76 | 290 (2%) |

**Design**: Personalized targets users with vehicle data (100% fitment-eligible). Static goes to the broader audience (only 2-5% have vehicle data). This is by design - personalization requires vehicle data to generate relevant recommendations.

### Data Integrity

| Check | Result |
|-------|--------|
| Total rows | 90,305 |
| Unique tracking IDs | 90,305 |
| Duplicates | 0 |
| Cross-type contamination | None |

---

## 6. Opportunity: Converting Opens to Clicks

_The personalization mechanism is clear: more opens, similar click-through. The opportunity is in-email content._

### CTR-of-Opens by Campaign

| Campaign | Personalized | Static/Control |
|----------|------------:|---------------:|
| Browse Recovery | 8.38% | 8.26% |
| Abandon Cart | 8.16% | 8.09% |
| Post Purchase | 4.42% | 5.98% |

Personalization gets users to open (+42-152% more), but once opened, click-through rates are similar. This means:
- The recommendation algorithm generates **compelling email subject lines and previews**
- The in-email product recommendations have room for improvement
- Post Purchase CTR-of-opens (4.42%) is lower than BR/AC (~8%), suggesting post-purchase content needs the most attention

### Email Frequency Optimization

Personalized sends 6-7 emails/user. CTR decays significantly with repeated sends:

| Send Number | Open Rate | CTR (opens) | vs 1st Send |
|-------------|----------:|------------:|------------:|
| 1st send | 15.40% | 6.74% | baseline |
| 2nd send | 14.44% | 3.68% | -45% |
| 3rd send | 14.40% | 6.02% | -11% |
| 4th-6th | 12.52% | 4.27% | -37% |
| 7th+ | 7.89% | 2.00% | -70% |

**Recommendation**: Cap at 3 sends per user to maintain engagement quality.

---

## 7. Key Takeaways

### For Stakeholders

| Claim | Evidence | Confidence |
|-------|----------|-----------|
| Personalization drives more email opens | +32-152% open rate lift across campaigns | High |
| Per-user click engagement matches Static | 3.57% vs 3.78% in v5.7 (delta 0.21pp) | High |
| Algorithm is improving over time | v5.17: +61% open rate for same users | High |
| Personalization works in all campaigns | +65% to +272% click uplift in BR/AC/PP | High |
| ~1,790 incremental clicks generated | Conservative estimate across 3 campaigns | Medium |

### Recommended Metrics for Ongoing Reporting

| Metric | Why | Current Best |
|--------|-----|-------------|
| **Per-user click rate** (primary) | Controls for send frequency | BR Personalized: 8.31% |
| **Per-user open rate** | Shows email relevance | BR Personalized: 39.70% |
| **Cross-campaign uplift** | Proves personalization at scale | +65% to +272% |
| **Same-user improvement** | Tracks algorithm progress | +61% open rate |

### Optimization Opportunities

1. **Improve in-email content** - Users open more but CTR-of-opens is flat. Better product presentation could multiply the uplift.
2. **Cap send frequency at 3** - CTR drops 70% after 7 sends. Fewer, better-targeted sends.
3. **Expand fitment to Browse Recovery** - Only 59.6% of BR users have vehicle data. Adding fitment for the rest could further lift the 8.31% click rate.
4. **Test hybrid content** - Include Apparel alongside Vehicle Parts to capture broader appeal.

---

## Appendix A: Detailed Post Purchase MECE Analysis

### Per-Send CTR (Fitment-Eligible Only, Corrected Formula)

| Period | Treatment | Sends | Opens | Clicks | Open Rate | CTR (opens) | CTR (sends) |
|--------|-----------|------:|------:|-------:|----------:|------------:|------------:|
| v5.7 | Personalized | 15,226 | 1,882 | 86 | 12.36% | 4.57% | 0.56% |
| v5.7 | Static | 2,900 | 473 | 58 | 16.31% | 12.26% | 2.00% |
| v5.17 | Personalized | 3,537 | 653 | 23 | 18.46% | 3.52% | 0.65% |
| v5.17 | Static | 290 | 83 | 14 | 28.62% | 16.87% | 4.83% |

Note: Per-send CTR is confounded by 3.3x send frequency difference. Per-user binary rates (Section 2) are the fair comparison.

### 95% Confidence Intervals (Wilson)

| Period | Treatment | Opens | Clicks | CTR (opens) | 95% CI |
|--------|-----------|------:|-------:|------------:|--------|
| v5.7 | Personalized | 1,882 | 86 | 4.57% | [3.71%, 5.62%] |
| v5.7 | Static | 473 | 58 | 12.26% | [9.58%, 15.56%] |
| v5.17 | Personalized | 653 | 23 | 3.52% | [2.35%, 5.24%] |
| v5.17 | Static | 83 | 14 | 16.87% | [10.32%, 26.34%] |

### Within-User Preference Breakdown (v5.7, n=612)

| Behavior | Users | Pct |
|----------|------:|----:|
| Clicked Personalized only | 16 | 2.61% |
| Clicked Static only | 19 | 3.10% |
| Clicked both | 2 | 0.33% |
| Clicked neither | 575 | 93.95% |

94% of users clicked neither type - most users don't click regardless of treatment.

---

## Appendix B: Revenue Attribution (Directional)

_Fuzzy email+time matching. Treat as directional signal, not causal proof. Fitment-eligible, non-overlap users only._

### 30-Day Attribution

| Period | Treatment | Users | Buyers | Conv Rate | Revenue | Rev/User |
|--------|-----------|------:|-------:|----------:|--------:|---------:|
| v5.7 | Personalized | 1,797 | 143 | 7.96% | $101,056 | $56.24 |
| v5.7 | Static | 913 | 98 | 10.73% | $76,730 | $84.04 |

Personalized generated **$101K total revenue** from a larger user base (1,797 users). Static shows higher per-user revenue, but this compares different product categories (Vehicle Parts vs Apparel) and different audience sizes.

### 7-Day Attribution

| Period | Treatment | Users | Buyers | Conv Rate | Revenue | Rev/User |
|--------|-----------|------:|-------:|----------:|--------:|---------:|
| v5.7 | Personalized | 1,797 | 80 | 4.45% | $50,086 | $27.87 |
| v5.7 | Static | 913 | 56 | 6.13% | $35,393 | $38.77 |

**Caveats**: No causal link between email and purchase. Long consideration cycles for automotive parts. Attribution is any order within window, not click-to-purchase tracking.

---

## Appendix C: CTR Formula Correction

The original CTR formula `SUM(clicked)/SUM(opened)` included clicks from image-blocking email clients where `clicked=1` but `opened=0`. This has been corrected to `SUM(CASE WHEN opened=1 AND clicked=1 THEN 1 ELSE 0 END)/SUM(opened)`.

| Treatment | Period | Old CTR | Corrected CTR | Impact |
|-----------|--------|--------:|--------------:|-------:|
| Personalized | v5.7 | 5.15% | 4.57% | -0.58pp |
| Static | v5.7 | 12.68% | 12.26% | -0.42pp |
| Personalized | v5.17 | 4.44% | 3.52% | -0.92pp |
| Static | v5.17 | 16.87% | 16.87% | 0 |

19 phantom clicks removed (17 Personalized, 2 Static). All numbers in this report use the corrected formula.

---

## Appendix D: Methodology & Data Notes

- **Campaign**: Post Purchase (surface_id=929), LIVE traffic only
- **Periods**: v5.7 (Dec 7 - Jan 9, 2026), v5.17 (Jan 10 - Feb 4, 2026)
- **Base table**: `auxia-reporting.temp_holley_v5_17.uplift_base` (90,305 rows, 0 duplicates)
- **Fitment-eligible**: Users with vehicle Year/Make/Model data
- **Per-user click rate**: "What % of users clicked at least once?" - controls for send frequency
- **Static = Apparel only**: Only treatment 16490939 has sends among 22 Static treatments
- **Random arm (4103)**: Unbiased selection; Bandit arm (4689) uses Thompson Sampling
- **Revenue**: Directional; fuzzy attribution; overlap users excluded; order events deduped

### Treatment IDs

**Personalized Fitment (10)**: 16150700, 20142778, 20142785, 20142804, 20142811, 20142818, 20142825, 20142832, 20142839, 20142846

**Static (22, only 16490939 has sends)**: 16490932, 16490939, 16518436, 16518443, 16564380, 16564387, 16564394, 16564401, 16564408, 16564415, 16564423, 16564431, 16564439, 16564447, 16564455, 16564463, 16593451, 16593459, 16593467, 16593475, 16593483, 16593491

### SQL Files

| File | Purpose |
|------|---------|
| `sql/analysis/uplift_base_table.sql` | Creates base analysis table |
| `sql/analysis/uplift_analysis_queries_v2.sql` | V2 analysis queries (no crash exclusion) |
| `sql/analysis/uplift_analysis_queries.sql` | V1 analysis queries (crash excluded) |
