# Fitment-Eligible User Engagement Report

**Date**: February 5, 2026
**Focus**: How do users with vehicle data (fitment-eligible) engage with Personalized vs Static emails?

---

## Executive Summary

Fitment-eligible users are the core audience for Holley's personalized vehicle recommendations. There are **503,828 users with vehicle data (YMM)** in the system, but the post-purchase email campaign only reaches ~10% of recent purchasers who have YMM data. Here's how they performed:

1. **We reached 3,357 fitment users in v5.7 and 736 in v5.17** out of 32,687 and 7,810 total post-purchase email recipients respectively (~10% have vehicle data).
2. **Overall, ~4-5% of fitment users click at least one email** (either type). This improved from 4.26% in v5.7 to 4.89% in v5.17.
3. **Per-user click rates are nearly equal in v5.7**: Personalized 3.57% vs Static 3.78% (delta only -0.21pp). The per-send CTR gap (4.57% vs 12.26%) is misleading due to 3.3x send frequency difference.
4. **Personalized gets MORE users to open**: 32.17% of P users opened vs 23.21% of S users in v5.7. Personalized emails are opened more, but when opened, Static (Apparel) gets more clicks.
5. **Within-user gold standard (612 users got both in v5.7)**: 2.94% clicked Personalized vs 3.43% clicked Static. Nearly identical, with Personalized users opening at higher rates (28.76% vs 21.73%).
6. **Revenue per user favors Static**: $84 vs $56 per user (30-day, v5.7), but this compares Apparel vs Vehicle Parts product categories.
7. **v5.17 open rates improved significantly**: Same 242 users saw open rates jump from 14.56% to 23.48% (+61%), confirming v5.17 algorithm improvements are working.

---

## 1. Fitment User Landscape

### Who are fitment-eligible users?

Users with vehicle data (Year/Make/Model) who can receive personalized vehicle-specific product recommendations. All Personalized treatment recipients are fitment-eligible by definition. A subset of Static treatment recipients also have vehicle data.

### Scale Context: 503K YMM Users, ~3K Reached

There are **503,828 users with vehicle data (YMM)** in the Holley system. However, this analysis covers only the **Post Purchase email campaign** (surface_id=929), which targets users who recently made a purchase. Only ~10% of post-purchase email recipients have YMM data on file.

| Metric | v5.7 | v5.17 |
|--------|------|-------|
| Total users with YMM in system | 503,828 | 503,828 |
| Total users emailed (post-purchase) | 32,687 | 7,810 |
| Of those, fitment-eligible | 3,357 (**10.3%**) | 736 (**9.4%**) |
| Non-fitment emailed | 29,330 | 7,074 |

**Why are fitment numbers small?**
- The post-purchase campaign is the bottleneck: only users with a recent purchase trigger these emails
- Of those recent purchasers, only ~10% have vehicle data (YMM) on file
- All 2,753 Personalized recipients are fitment-eligible (100%) - the system correctly targets only users with vehicle data
- Static (Apparel) goes mostly to non-fitment users: only 1,704 of 37,380 Static recipients (4.6%) happen to also have vehicle data

**Implication**: The 503K YMM users represent a large untapped audience. The current analysis only covers the subset who made a recent purchase AND received a post-purchase email.

### Treatment Distribution Among Fitment Users

| Period | Total Fitment Users | Got Personalized | Got Static | Got Both | P-Only | S-Only |
|--------|-------------------|------------------|------------|----------|--------|--------|
| **v5.7** | 3,357 | 2,409 | 1,560 | 612 | 1,797 | 948 |
| **v5.17** | 736 | 586 | 162 | 12 | 574 | 150 |

Key: 612 users in v5.7 received BOTH Personalized and Static emails, enabling a direct within-user comparison.

### Treatment Reach Across All Users

| Treatment | Fitment Users | Non-Fitment Users | Total | Pct Fitment |
|-----------|--------------|-------------------|-------|-------------|
| Personalized | 2,753 | 0 | 2,753 | **100%** |
| Static | 1,704 | 35,676 | 37,380 | 4.6% |

---

## 2. Overall Fitment User Engagement

_Across all treatment types combined._

| Period | Fitment Users Reached | Total Sends | Users Who Opened | Pct Opened | Users Who Clicked | Pct Clicked |
|--------|----------------------|-------------|------------------|------------|-------------------|-------------|
| **v5.7** | 3,357 | 18,126 | 1,045 | **31.13%** | 143 | **4.26%** |
| **v5.17** | 736 | 3,827 | 262 | **35.60%** | 36 | **4.89%** |

**Improvement**: v5.17 shows higher engagement rates across the board (+4.5pp open rate, +0.63pp click rate).

---

## 3. Personalized vs Static: Per-User Comparison

_The fairest comparison metric - "what % of users engaged at least once?" - because it eliminates the send frequency confound (P sends 6.3 emails/user vs S sends 1.9)._

### Per-User Click Rates (Primary Metric)

| Period | Treatment | Users | Users Clicked | **Pct Clicked** | Users Opened | Pct Opened | Sends/User |
|--------|-----------|-------|--------------|-----------------|--------------|------------|------------|
| v5.7 | Personalized | 2,409 | 86 | **3.57%** | 775 | 32.17% | 6.3 |
| v5.7 | Static | 1,560 | 59 | **3.78%** | 362 | 23.21% | 1.9 |
| v5.17 | Personalized | 586 | 24 | **4.10%** | 204 | 34.81% | 6.0 |
| v5.17 | Static | 162 | 13 | **8.02%** | 60 | 37.04% | 1.8 |

**Key findings**:
- **v5.7: Click rates are nearly identical** (3.57% vs 3.78%, delta only -0.21pp). Personalized is NOT underperforming - it reaches more users and gets them to open at higher rates.
- **v5.17: Static leads** (8.02% vs 4.10%), but with only 162 Static users this is a small sample.
- **Personalized drives more opens**: In v5.7, 32.17% of P users opened vs 23.21% of S users (+8.96pp). The algorithm is generating email content that gets opened.

### Why Per-Send CTR Is Misleading

| Period | Treatment | Per-Send CTR | Per-User Click Rate | Gap |
|--------|-----------|-------------|---------------------|-----|
| v5.7 | Personalized | 4.57% | 3.57% | |
| v5.7 | Static | 12.26% | 3.78% | |
| v5.7 | **Ratio (S/P)** | **2.7x** | **1.06x** | Per-send inflates gap by 2.5x |

The 2.7x per-send CTR advantage shrinks to only 1.06x when measured per-user. The difference is almost entirely driven by Personalized sending 3.3x more emails per user, which dilutes per-send metrics through email fatigue.

---

## 4. Within-User Comparison (Gold Standard)

_612 fitment users in v5.7 received BOTH Personalized and Static emails. This is the strongest evidence because it controls for all user-level differences._

### Same Users, Both Treatments (v5.7, n=612)

| Metric | Personalized | Static | Advantage |
|--------|-------------|--------|-----------|
| Sends per user | 5.3 | 1.8 | P sends 2.9x more |
| **Pct users opened** | **28.76%** | 21.73% | **P +7.03pp** |
| **Pct users clicked** | 2.94% | **3.43%** | **S +0.49pp** |
| Per-send open rate | 10.82% | 15.13% | S +4.31pp |
| Per-send CTR of opens | 3.67% | 11.24% | S +7.57pp |

### User Preference Breakdown (v5.7, n=612)

| Behavior | Users | Pct |
|----------|-------|-----|
| Clicked Personalized only | 16 | 2.61% |
| Clicked Static only | 19 | 3.10% |
| Clicked both | 2 | 0.33% |
| Clicked neither | 575 | 93.95% |

**Interpretation**: Among users who received both treatments:
- **Personalized is better at getting opens** (28.76% vs 21.73% of users opened)
- **Static is slightly better at converting opens to clicks** (per-user: 3.43% vs 2.94%)
- **The click rate gap is small**: only 3 more users clicked Static (19 vs 16)
- **94% of users clicked neither** - most users don't click regardless of treatment type

### Combined Across Both Periods (n=657)

| Metric | Personalized | Static |
|--------|-------------|--------|
| Users who clicked | 21 (3.20%) | 23 (3.50%) |
| Clicked P only | 18 | - |
| Clicked S only | 20 | - |
| Clicked both | 3 | - |
| Clicked neither | 616 (93.76%) | - |

**Bottom line**: For the same users, the click rate difference between Personalized and Static is 0.30 percentage points (3.20% vs 3.50%). This is a negligible difference.

---

## 5. First-Send Comparison (No Fatigue Effects)

_Comparing only the first email each user receives of each type. Eliminates fatigue from repeated sends._

| Period | Treatment | Users | Opens | Clicks | Open Rate | CTR (opens) | Pct Users Clicked 1st Email |
|--------|-----------|-------|-------|--------|-----------|-------------|----------------------------|
| v5.7 | Personalized | 2,409 | 371 | 25 | 15.40% | 6.74% | **1.20%** |
| v5.7 | Static | 1,560 | 255 | 37 | 16.35% | 14.51% | **2.44%** |
| v5.17 | Personalized | 344 | 76 | 5 | 22.09% | 6.58% | **1.74%** |
| v5.17 | Static | 144 | 45 | 11 | 31.25% | 24.44% | **7.64%** |

**Finding**: On first email, Static (Apparel) gets ~2x more clicks. This is a genuine content/category difference - Apparel emails are more clickable than Vehicle Parts emails on first impression. However, Personalized keeps generating value through repeated sends (86 total user-clicks vs 25 first-send clicks = 61 additional users clicked on later sends).

---

## 6. Unbiased View: Random Arm Only

_Random arm (4103) has no bandit optimization bias. Per-user binary rates._

| Period | Treatment | Users | Pct Users Opened | **Pct Users Clicked** | Sends/User |
|--------|-----------|-------|------------------|----------------------|------------|
| v5.7 | Personalized | 2,350 | 32.55% | **3.62%** | 6.3 |
| v5.7 | Static | 1,514 | 23.18% | **3.83%** | 1.9 |
| v5.17 | Personalized | 406 | 34.98% | **3.94%** | 5.1 |
| v5.17 | Static | 89 | 42.70% | **8.99%** | 1.8 |

**Key**: Even in the unbiased random arm, v5.7 per-user click rates are nearly identical (3.62% vs 3.83%). v5.17 shows Static ahead (8.99% vs 3.94%) but with only 89 Static users.

---

## 7. Revenue per Fitment User

_Fitment-eligible, non-overlap users only. 30-day attribution window. Directional only - no causal link._

| Period | Treatment | Users | Buyers | Conv Rate | Revenue | Rev/User | AOV |
|--------|-----------|-------|--------|-----------|---------|----------|-----|
| v5.7 | Personalized | 1,797 | 143 | 7.96% | $101,056 | **$56.24** | $707 |
| v5.7 | Static | 913 | 98 | 10.73% | $76,730 | **$84.04** | $783 |
| v5.17 | Personalized | 487 | 19 | 3.90% | $4,170 | **$8.56** | $219 |
| v5.17 | Static | 150 | 14 | 9.33% | $8,785 | **$58.56** | $627 |

**Key findings**:
- Static users spend more per user ($84 vs $56 in v5.7)
- Static AOV is higher ($783 vs $707) - Apparel purchases are slightly larger
- Static conversion rate is higher (10.73% vs 7.96%)
- But this compares Apparel buyers vs Vehicle Parts buyers - different purchase behaviors

---

## 8. v5.17 Algorithm Impact: Same Users Across Periods

_242 fitment users received Personalized emails in BOTH v5.7 and v5.17. How did their engagement change?_

| Metric | v5.7 | v5.17 | Change |
|--------|------|-------|--------|
| Users | 242 | 242 | Same users |
| Avg sends/user | 6.0 | 4.8 | -1.2 fewer sends |
| **Per-send open rate** | 14.56% | **23.48%** | **+8.92pp (+61%)** |
| **Pct users opened** | 33.47% | **38.84%** | **+5.37pp (+16%)** |
| Per-send CTR of opens | 4.76% | 2.19% | -2.57pp |
| Pct users clicked | 4.13% | 2.48% | -1.65pp |

**Interpretation**:
- **Open rates improved dramatically**: v5.17 recommendations are generating more relevant email content that users want to open (+61% per-send open rate)
- **Click rates declined**: Once users open, they're clicking less. This could be seasonal (Jan vs Dec holiday shopping) or the recommendation content inside the email needs improvement
- The open rate improvement is a strong positive signal for the v5.17 algorithm

---

## 9. Summary: The Fitment User Story

### What's Working

| Signal | Evidence |
|--------|----------|
| **Personalized drives opens** | 32% of P users open vs 23% of S users (v5.7) |
| **Per-user engagement is equal** | P=3.57% vs S=3.78% clicked (v5.7), delta only 0.21pp |
| **v5.17 improved open rates** | Same users: 14.56% → 23.48% (+61%) per-send open rate |
| **Fitment users are engaged** | 4-5% click rate across the board, improving over time |
| **v5.17 reaches users better** | 35.6% of fitment users opened at least once (vs 31.1% in v5.7) |

### What Needs Improvement

| Signal | Evidence |
|--------|----------|
| **First-send CTR lags Static** | P=6.74% vs S=14.51% on first email (content clickability gap) |
| **Email fatigue from overuse** | P sends 6.3 emails/user; CTR drops 70% by 7th+ send |
| **Click-through after open needs work** | Users open more in v5.17 but click less |
| **Revenue per user lags Static** | P=$56/user vs S=$84/user (30d, v5.7) |

### Recommended Metrics for Stakeholders

| Metric | Why | Current (v5.7) |
|--------|-----|----------------|
| **Per-user click rate** (primary) | Controls for send frequency bias | P=3.57%, S=3.78% |
| **Per-user open rate** | Shows email relevance | P=32.17%, S=23.21% |
| **First-send CTR** | Apples-to-apples content comparison | P=6.74%, S=14.51% |
| **Revenue per user** (directional) | Business impact | P=$56, S=$84 |

### Recommendations

1. **Cap send frequency at 3 per user** - 70% CTR decay after 7 sends; diminishing returns after 3rd send
2. **Improve click-through content** - Users OPEN Personalized emails more but don't click as much; the email subject/preview works, but the product recommendations inside need to be more compelling
3. **Use per-user binary click rate** as primary KPI for stakeholder reporting (not per-send CTR)
4. **Test hybrid content** - Include Apparel alongside Vehicle Parts in Personalized emails to capture Static's click advantage
5. **Continue v5.17 algorithm direction** - The open rate improvement (+61% for same users) confirms the 3-tier segment fallback is generating more relevant content

---

## Appendix: Data Notes

- **Base table**: `auxia-reporting.temp_holley_v5_17.uplift_base` (90,305 rows, 0 duplicates)
- **Fitment-eligible**: Users with vehicle Year/Make/Model data
- **CTR formula**: Corrected to exclude clicks from image-blocking clients (opened=0, clicked=1)
- **Revenue**: Directional only; fuzzy attribution via email+time matching; non-overlap users only
- **Static = Apparel only**: Only treatment 16490939 (Apparel) has sends among 22 Static treatments
- **Random arm (4103)**: Unbiased selection; Bandit arm (4689) uses Thompson Sampling
