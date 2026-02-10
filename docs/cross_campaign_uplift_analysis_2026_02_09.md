# Cross-Campaign Uplift Analysis — Full Comparison Report

**Date**: February 9, 2026
**Period**: December 4, 2025 – February 9, 2026 (interactions captured through Feb 16)
**Purpose**: Complete experimental breakdown across all dimensions

---

## Experiment Structure

```
All Email Recipients (~104K of 3M total users)
│
├── Random Arm (4103): ~80% of sends overall
│   ├── Browse Recovery / Abandon Cart / Post Purchase
│   │   ├── Fitment Users (have YMM) → Personalized OR Static
│   │   └── Non-Fitment Users → Static only
│
└── Bandit Arm (4689): ~20% of sends overall
    └── (same structure, biased by Thompson Sampling)
```

**Arm split note**: The experiment started 100% Random. Bandit was introduced Dec 14 at ~6-10%, ramped to ~28% by Jan 11, and reached 50/50 only on Jan 18. Overall period average is **80% Random / 20% Bandit**.

**Key constraint**: No holdout control group. All email recipients get a treatment — we can compare Personalized vs Static, but not email vs no-email. Only ~3.4% of total users (104K of 3M) received email during this period.

### Full User Funnel

| Stage | Users | % of Total |
|-------|------:|----------:|
| **Total users in system** | **3,031,468** | 100% |
| Email consented | **1,132,419** | 37.3% |
| No email consent | 1,899,049 | 62.7% |
| | | |
| **Has fitment data (YMM)** | **504,092** | 16.6% |
| Fitment + email consented | **258,185** | 8.5% |
| Fitment, no email consent | 245,907 | 8.1% |
| | | |
| **No fitment data** | **2,527,376** | 83.4% |
| No fitment + email consented | **874,234** | 28.8% |
| | | |
| **Actually received email** (this period) | **103,852** | 3.4% |
| Fitment users who received email | **19,711** | 0.7% |

**Key gaps**:
- Only **16.6%** of users have fitment data — the rest can only receive Static
- ~49% of fitment users have NOT opted into email (245K untapped)
- Of 258K fitment email subscribers, only **7.6% actually received emails** this period
- **874K non-fitment email subscribers** exist — currently can only get Static content

---

## A. Personalized vs Static — Within-User (Gold Standard)

_Same users received BOTH Personalized and Static emails. Controls for all user-level differences._

### A1-A3: Random Arm Only (Cleanest — Unbiased Assignment)

| Campaign | Type | Overlap Users | Sends | % Users Opened | % Users Clicked | Open Uplift | Click Uplift |
|----------|------|-------------:|------:|--------------:|--------------:|------------:|-------------:|
| **Browse Recovery** | Personalized | 13,310 | 72,594 | **36.03%** | **6.66%** | | |
| | Static | 13,310 | 81,836 | 26.89% | 5.57% | **+34%** | **+20%** |
| **Abandon Cart** | Personalized | 1,314 | 6,305 | **31.20%** | **4.64%** | | |
| | Static | 1,314 | 3,225 | 22.83% | 3.73% | **+37%** | **+24%** |
| **Post Purchase** | Personalized | 656 | 3,726 | **30.95%** | 3.66% | | |
| | Static | 656 | 1,250 | 22.87% | 3.66% | **+35%** | **0% (tied)** |

**Takeaway**: Personalized wins on opens in all 3 campaigns (+34-37%). Wins on clicks in BR (+20%) and AC (+24%). Post Purchase is **dead even** on clicks (3.66% each).

### A4-A6: Both Arms (More Power, Slight Bandit Bias)

| Campaign | Type | Overlap Users | Sends | % Users Opened | % Users Clicked | Open Uplift | Click Uplift |
|----------|------|-------------:|------:|--------------:|--------------:|------------:|-------------:|
| **Browse Recovery** | Personalized | 14,217 | 88,123 | **37.42%** | **7.24%** | | |
| | Static | 14,217 | 98,285 | 28.21% | 6.27% | **+33%** | **+15%** |
| **Abandon Cart** | Personalized | 1,683 | 8,981 | **34.11%** | **5.76%** | | |
| | Static | 1,683 | 4,149 | 24.42% | 3.86% | **+40%** | **+49%** |
| **Post Purchase** | Personalized | 688 | 4,025 | **31.25%** | 3.63% | | |
| | Static | 688 | 1,306 | 22.97% | 3.63% | **+36%** | **0% (tied)** |

**Takeaway**: Consistent with Random-only. Post Purchase is tied on clicks. AC shows the strongest uplift (+49% clicks, +40% opens) in the both-arms view.

### Summary: Within-User P vs S

| Campaign | Open Winner | Click Winner | Open Lift (Random) | Click Lift (Random) |
|----------|:----------:|:----------:|------------------:|-------------------:|
| Browse Recovery | **Personalized** | **Personalized** | +34% | +20% |
| Abandon Cart | **Personalized** | **Personalized** | +37% | +24% |
| Post Purchase | **Personalized** | **Tied** | +35% | 0% |

---

## B. Random vs Bandit — Is the Model Learning?

| Campaign | Type | Arm | Users | Sends | Open Rate | CTR of Opens | % Users Clicked |
|----------|------|-----|------:|------:|----------:|-------------:|--------------:|
| **Browse Recovery** | Personalized | Random | 22,258 | 148,451 | 16.97% | 8.68% | 7.56% |
| | Personalized | **Bandit** | 4,294 | 35,544 | **21.78%** | 7.74% | **10.34%** |
| | Static | Random | 49,520 | 328,716 | 10.46% | 8.39% | 4.64% |
| | Static | **Bandit** | 13,113 | 81,837 | **14.47%** | 8.24% | **5.73%** |
| **Abandon Cart** | Personalized | Random | 2,897 | 11,497 | 14.15% | 8.05% | 4.31% |
| | Personalized | **Bandit** | 854 | 3,691 | **20.46%** | 8.08% | **6.21%** |
| | Static | Random | 27,938 | 102,042 | 10.19% | 8.00% | 2.65% |
| | Static | **Bandit** | 6,936 | 42,045 | **11.66%** | 8.43% | **4.77%** |
| **Post Purchase** | Personalized | Random | 2,571 | 17,591 | 13.39% | 4.71% | 4.20% |
| | Personalized | **Bandit** | 378 | 2,207 | **15.09%** | 3.60% | 2.91% |
| | Static | Random | 34,172 | 69,116 | 8.91% | 6.06% | 1.15% |
| | Static | **Bandit** | 4,520 | 8,478 | 8.67% | 5.44% | 0.93% |

**Takeaway**:
- Bandit consistently shows **higher open rates** than Random across all campaign × treatment combos (except PP Static)
- Bandit shows **higher % users clicked** in BR and AC (both P and S), suggesting the model IS selecting better user-treatment matches
- Post Purchase is the exception — Bandit has fewer users (378 P) and underperforms Random on clicks
- CTR-of-opens is similar between arms (~8%), confirming the lift comes from better targeting, not content

---

## C. Across Campaigns — Random Arm, Fitment Users Only

| Campaign | Type | Users | Sends | % Users Opened | % Users Clicked | Sends/User |
|----------|------|------:|------:|--------------:|--------------:|-----------:|
| **Browse Recovery** | Personalized | 12,783 | 125,923 | **46.00%** | **10.15%** | 9.9 |
| | Static | 7,342 | 24,620 | 20.99% | 3.05% | 3.4 |
| **Abandon Cart** | Personalized | 2,896 | 11,496 | 27.00% | 4.32% | 4.0 |
| | Static | 2,475 | 7,267 | 23.43% | 4.48% | 2.9 |
| **Post Purchase** | Personalized | 2,571 | 17,591 | 34.15% | 4.20% | 6.8 |
| | Static | 1,642 | 3,230 | 25.46% | 4.32% | 2.0 |

**Takeaway**:
- Browse Recovery has the **highest engagement** by far (10.15% users clicked, 46% opened for P)
- Browse Recovery also has the **highest send frequency** (9.9 sends/user for P)
- Abandon Cart and Post Purchase show **near-identical click rates** between P and S for fitment users
- Personalized sends 2-3x more emails per user than Static across all campaigns

---

## D. Fitment vs Non-Fitment — Static Treatment, Random Arm

_Same treatment (Static), different user populations. Does having vehicle data correlate with engagement?_

| Campaign | Has Fitment | Users | Sends | Open Rate | CTR of Opens | % Users Clicked |
|----------|:----------:|------:|------:|----------:|-------------:|--------------:|
| **Browse Recovery** | No | 42,178 | 304,096 | 10.42% | 8.33% | **4.91%** |
| | **Yes** | 7,342 | 24,620 | **10.92%** | **9.04%** | 3.05% |
| **Abandon Cart** | No | 25,463 | 94,775 | 9.75% | 7.76% | 2.47% |
| | **Yes** | 2,475 | 7,267 | **16.06%** | **9.85%** | **4.48%** |
| **Post Purchase** | No | 32,530 | 65,886 | 8.49% | 5.38% | 0.99% |
| | **Yes** | 1,642 | 3,230 | **17.46%** | **12.77%** | **4.32%** |

**Takeaway**:
- Fitment users have **dramatically higher open rates** in AC (+65%) and PP (+106%) even on Static emails
- Fitment users have **higher CTR-of-opens** in all campaigns
- Fitment users click at higher rates in AC and PP, but **non-fitment win in BR** (4.91% vs 3.05%)
- This confirms fitment users are a **higher-intent population** — the vehicle data is a proxy for engagement level

---

## F. User Preference — Who Do They Click? (Random Arm, Within-User)

_Among users who received both P and S, which did they click?_

| Campaign | Clicked P Only | Clicked S Only | Clicked Both | Clicked Neither | Total | **P:S Ratio** |
|----------|-------------:|-------------:|------------:|--------------:|------:|:------------:|
| **Browse Recovery** | **725** | 579 | 162 | 11,844 | 13,310 | **1.25:1 (P wins)** |
| **Abandon Cart** | **48** | 36 | 13 | 1,217 | 1,314 | **1.33:1 (P wins)** |
| **Post Purchase** | 20 | 20 | 4 | 612 | 656 | **1:1 (tied)** |

**Takeaway**:
- Browse Recovery: 25% more users prefer Personalized (725 vs 579)
- Abandon Cart: 33% more users prefer Personalized (48 vs 36)
- Post Purchase: Dead even (20 vs 20)
- **Personalized wins or ties on user preference in all 3 campaigns**

---

## G. Send Frequency & Fatigue — Personalized Only

### Browse Recovery

| Send # | Sends | Open Rate | CTR of Opens | CTR of Sends | vs 1st |
|--------|------:|----------:|-------------:|-------------:|-------:|
| 1st | 23,845 | 20.40% | 8.63% | 1.76% | baseline |
| 2nd | 19,709 | 18.12% | 9.32% | 1.69% | -4% |
| 3rd | 18,641 | 16.87% | 7.98% | 1.35% | -23% |
| 4th-6th | 39,146 | 11.80% | 7.14% | 0.84% | -52% |
| 7th+ | 82,654 | 20.24% | 8.68% | 1.76% | 0% |

**Note**: BR 7th+ shows NO fatigue — open rate rebounds to 20.24%. This suggests Browse Recovery triggers are driven by fresh browsing intent, not repeated blasts.

### Abandon Cart

| Send # | Sends | Open Rate | CTR of Opens | CTR of Sends | vs 1st |
|--------|------:|----------:|-------------:|-------------:|-------:|
| 1st | 3,476 | 16.43% | 11.38% | 1.87% | baseline |
| 2nd | 2,710 | 16.46% | 9.19% | 1.51% | -19% |
| 3rd | 2,285 | 16.32% | 9.92% | 1.62% | -13% |
| 4th-6th | 4,241 | 14.41% | 4.75% | 0.68% | -64% |
| 7th+ | 2,476 | 15.39% | 5.25% | 0.81% | -57% |

**Note**: AC shows moderate fatigue — CTR drops 64% by 4th-6th send. Open rate stays relatively flat.

### Post Purchase

| Send # | Sends | Open Rate | CTR of Opens | CTR of Sends | vs 1st |
|--------|------:|----------:|-------------:|-------------:|-------:|
| 1st | 2,804 | 15.94% | 7.83% | 1.25% | baseline |
| 2nd | 2,641 | 15.22% | 4.73% | 0.72% | -42% |
| 3rd | 2,477 | 15.66% | 5.41% | 0.85% | -32% |
| 4th-6th | 5,990 | 13.54% | 4.44% | 0.60% | -52% |
| 7th+ | 5,886 | 10.89% | 1.87% | 0.20% | -84% |

**Note**: PP shows the **most severe fatigue** — CTR drops 84% by 7th+ send. Open rate also decays significantly (15.94% → 10.89%).

---

## Volume Summary — All Dimensions

| Campaign | Type | Arm | Fitment | Users | Sends |
|----------|------|-----|:-------:|------:|------:|
| Browse Recovery | Personalized | Random | Yes | 12,783 | 125,923 |
| Browse Recovery | Personalized | Random | No | 9,475 | 22,528 |
| Browse Recovery | Personalized | Bandit | Yes | 4,294 | 35,544 |
| Browse Recovery | Static | Random | Yes | 7,342 | 24,620 |
| Browse Recovery | Static | Random | No | 42,178 | 304,096 |
| Browse Recovery | Static | Bandit | Yes | 1,308 | 4,972 |
| Browse Recovery | Static | Bandit | No | 11,805 | 76,865 |
| Abandon Cart | Personalized | Random | Yes | 2,896 | 11,496 |
| Abandon Cart | Personalized | Bandit | Yes | 854 | 3,691 |
| Abandon Cart | Static | Random | Yes | 2,475 | 7,267 |
| Abandon Cart | Static | Random | No | 25,463 | 94,775 |
| Abandon Cart | Static | Bandit | Yes | 651 | 2,275 |
| Abandon Cart | Static | Bandit | No | 6,285 | 39,770 |
| Post Purchase | Personalized | Random | Yes | 2,571 | 17,591 |
| Post Purchase | Personalized | Bandit | Yes | 378 | 2,207 |
| Post Purchase | Static | Random | Yes | 1,642 | 3,230 |
| Post Purchase | Static | Random | No | 32,530 | 65,886 |
| Post Purchase | Static | Bandit | Yes | 133 | 237 |
| Post Purchase | Static | Bandit | No | 4,387 | 8,241 |

**Total sends in analysis**: ~851K

---

## Key Findings

### 1. Personalized Wins on Opens Everywhere (+34-37%)
Consistent across all campaigns, both arms. The personalized email is more likely to be opened.

### 2. Personalized Wins or Ties on Clicks in All Campaigns
- **Browse Recovery: P wins** (+20% clicks, 25% more users prefer P)
- **Abandon Cart: P wins** (+24% clicks, 33% more users prefer P)
- **Post Purchase: Tied** (3.66% each, user preference 20 vs 20)

### 3. The Bandit IS Learning (Caveat: Unequal Exposure)
Bandit arm shows higher open rates and % users clicked than Random in BR and AC. However, the arm split was ~80/20 overall (50/50 only from Jan 18), so Bandit results have less statistical power.

### 4. Fitment Users Are Higher-Intent
Even on identical Static emails, fitment users open 65-106% more in AC and PP (BR is near-identical at +5%). Fitment users click at higher rates in AC and PP, but non-fitment win in BR. Vehicle data is a proxy for engagement.

### 5. Fatigue Varies by Campaign
- Browse Recovery: **No fatigue** (7th+ send = same CTR as 1st)
- Abandon Cart: **Moderate fatigue** (-57% by 7th+)
- Post Purchase: **Severe fatigue** (-84% by 7th+)

### 6. Send Frequency Imbalance
Personalized sends 1.4-3.4x more per user than Static (AC 1.4x, BR 2.9x, PP 3.4x). This dilutes per-send metrics and drives fatigue in AC and PP. Capping PP sends at 3 would reduce waste.

---

## Methodology

- **Analysis period**: December 4, 2025 – February 9, 2026
- **Interaction window**: +7 days past send window (through Feb 16)
- **Within-user**: Users who received BOTH P and S **in the same campaign** (per-campaign overlap, not cross-campaign)
- **CTR formula**: `SUM(CASE WHEN opened=1 AND clicked=1 THEN 1 ELSE 0 END) / SUM(opened)` (excludes phantom clicks from image-blocking clients)
- **% users clicked**: Binary per-user rate — "did this user click at least once?" (controls for send frequency)
- **Treatment classification**: From PostgreSQL treatment.name (Browse Recovery / Abandon Cart / Post Purchase × Personalized / Static)
- **Fitment-eligible**: Users with all 3 vehicle attributes (v1_year, v1_make, v1_model)
- **Arms**: Random (4103) = unbiased assignment; Bandit (4689) = Thompson Sampling. Overall split ~80/20 (50/50 only from Jan 18)
