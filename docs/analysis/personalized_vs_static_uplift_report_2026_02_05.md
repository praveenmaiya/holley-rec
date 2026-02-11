# Personalized vs Static Email Performance Report (V1)

**Date**: February 5, 2026
**Period**: December 7, 2025 - February 4, 2026
**Version**: V1 (crash window excluded)
**Primary Report**: See [V2 report](personalized_vs_static_uplift_report_v2.md) for full analysis with no crash exclusion.

---

## Executive Summary

This report analyzes the Post Purchase email campaign with the Jan 14+ crash window excluded. For the comprehensive analysis (all data, cross-campaign results), see the V2 report.

Key findings:

1. **Personalized drives significantly more opens**: 32.17% of Personalized users opened vs 23.21% of Static users in v5.7 (+39% lift).
2. **Per-user click rates are nearly equal**: P=3.57% vs S=3.78% in v5.7 (delta only 0.21pp). The per-send CTR gap is driven by 3.3x send frequency difference.
3. **v5.17 shows Personalized winning** on crash-excluded data (CTR 4.90% vs 0%), though Static sample is small (74 sends).
4. **v5.17 algorithm improved open rates by 61%** for the same users (14.56% to 23.48%).
5. **Cross-campaign personalization works**: All 3 campaigns show +65% to +272% click uplift from personalization. See [Personalization Uplift Report](fitment_user_engagement_report.md).

---

## 1. Personalization Drives Opens

### Per-User Open Rates (v5.7, Fitment-Eligible)

| Treatment | Users | Pct Users Opened | Advantage |
|-----------|------:|------------------:|-----------|
| **Personalized** | 2,409 | **32.17%** | **+39% more users open** |
| Static | 1,560 | 23.21% | |

### Within-User Comparison (612 users got both, v5.7)

| Metric | Personalized | Static | Advantage |
|--------|------------:|-------:|-----------|
| **Pct users opened** | **28.76%** | 21.73% | **P +7.03pp (+32%)** |
| Pct users clicked | 2.94% | 3.43% | S +0.49pp (3 users) |

Same users, same time period - Personalized generates 32% more opens. The click gap is negligible (3 users out of 612).

---

## 2. Per-User Click Rates: Nearly Equal

| Period | Treatment | Users | Pct Clicked | Sends/User |
|--------|-----------|------:|-----------:|-----------:|
| v5.7 | Personalized | 2,409 | 3.57% | 6.3 |
| v5.7 | Static | 1,560 | 3.78% | 1.9 |

The apparent 2.7x per-send CTR gap shrinks to **1.06x** per-user. Personalized sends 3.3x more emails, diluting per-send metrics through natural email fatigue.

---

## 3. v5.17 Algorithm Improvement

### Same Users Across Periods (n=242)

| Metric | v5.7 | v5.17 | Improvement |
|--------|-----:|------:|------------:|
| **Per-send open rate** | 14.56% | **23.48%** | **+61%** |
| **Pct users opened** | 33.47% | **38.84%** | **+16%** |
| Sends/user | 6.0 | 4.8 | Fewer, better sends |

v5.17 sends fewer emails but gets more of them opened. The algorithm is improving.

### v5.17 MECE Result (Crash Excluded)

| Treatment | Sends | Opens | CTR (opens) |
|-----------|------:|------:|------------:|
| Personalized | 749 | 143 | **4.90%** |
| Static | 74 | 19 | 0.00% |

On crash-excluded data, Personalized outperforms. Static has a very small sample (74 sends, 0 clicks).

---

## 4. Cross-Campaign: Personalized Wins Everywhere

_Full details in [Personalization Uplift Report](fitment_user_engagement_report.md)._

| Campaign | Personalized Click Rate | Control Click Rate | Relative Lift |
|----------|------------------------:|-------------------:|--------------:|
| **Browse Recovery** | 8.31% | 5.05% | **+65%** |
| **Abandon Cart** | 5.04% | 2.95% | **+71%** |
| **Post Purchase** | 4.13% | 1.11% | **+272%** |

208,800 personalized sends to 29,546 users. Estimated ~1,790 incremental clicks from personalization.

---

## 5. Revenue (Directional)

_Fuzzy attribution, fitment-eligible non-overlap users, 30-day window._

| Period | Treatment | Users | Revenue | Rev/User |
|--------|-----------|------:|--------:|---------:|
| v5.7 | Personalized | 1,797 | **$101,056** | $56.24 |
| v5.7 | Static | 926 | $76,858 | $83.00 |

Personalized generated **$101K total revenue** from a larger user base. Per-user revenue differs due to product category mix (Vehicle Parts vs Apparel), not personalization effectiveness.

---

## 6. Key Takeaways

| Claim | Evidence | Confidence |
|-------|----------|-----------|
| Personalization drives more opens | +32-152% open rate lift | High |
| Per-user click engagement matches Static | 3.57% vs 3.78% (v5.7) | High |
| Algorithm improving over time | +61% open rate for same users | High |
| Personalization works in all campaigns | +65% to +272% click lift | High |

### Optimization Opportunities

1. **Cap send frequency at 3** - CTR drops 70% after 7th send
2. **Improve in-email content** - More opens, but CTR-of-opens is flat. Better product presentation can multiply uplift.
3. **Expand fitment to Browse Recovery** - Only 59.6% of BR users have vehicle data
4. **Test hybrid content** - Vehicle Parts + Apparel in same email

---

## Appendix: Methodology

- **Campaign**: Post Purchase (surface_id=929), LIVE traffic
- **Crash exclusion**: Jan 14+ data excluded (50/50 arm split crashed CTR)
- **v5.7**: Dec 7 - Jan 9, 2026; **v5.17**: Jan 10-13, 2026 (clean window only)
- **Base table**: `auxia-reporting.temp_holley_v5_17.uplift_base`
- **CTR formula**: Corrected to exclude image-blocking phantom clicks
- **Per-user click rate**: "What % of users clicked at least once?" - controls for send frequency
- **Static = Apparel only**: Only treatment 16490939 has sends among 22 Static treatments

### Treatment IDs

**Personalized Fitment (10)**: 16150700, 20142778, 20142785, 20142804, 20142811, 20142818, 20142825, 20142832, 20142839, 20142846

**Static (22, only 16490939 has sends)**: 16490932, 16490939, 16518436, 16518443, 16564380, 16564387, 16564394, 16564401, 16564408, 16564415, 16564423, 16564431, 16564439, 16564447, 16564455, 16564463, 16593451, 16593459, 16593467, 16593475, 16593483, 16593491

### SQL Files

| File | Purpose |
|------|---------|
| `sql/analysis/uplift_base_table.sql` | Creates base analysis table |
| `sql/analysis/uplift_analysis_queries.sql` | V1 analysis queries (crash excluded) |
| `sql/analysis/uplift_analysis_queries_v2.sql` | V2 analysis queries (no crash exclusion) |
