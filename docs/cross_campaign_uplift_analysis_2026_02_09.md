# Cross-Campaign Uplift Analysis — Full Comparison Report

**Date**: February 9, 2026
**Period**: December 4, 2025 – February 9, 2026 (interactions captured through Feb 16)
**Purpose**: Complete experimental breakdown across all dimensions

---

## Experiment Structure

```
All Holley Email Users (100% treated, 0% control)
│
├── Random Arm (4103): 50% — unbiased treatment assignment
│   ├── Browse Recovery / Abandon Cart / Post Purchase
│   │   ├── Fitment Users (have YMM) → Personalized OR Static
│   │   └── Non-Fitment Users → Static only
│
└── Bandit Arm (4689): 50% — Thompson Sampling selection
    └── (same structure, biased assignment)
```

**Key constraint**: No holdout control (0% untreated). We can only compare Personalized vs Static, not email vs no-email.

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
| **Browse Recovery** | Personalized | 14,384 | 80,263 | **36.08%** | **6.75%** | | |
| | Static | 13,377 | 82,017 | 26.89% | 5.56% | **+34%** | **+21%** |
| **Abandon Cart** | Personalized | 1,717 | 7,464 | **28.19%** | **4.60%** | | |
| | Static | 3,264 | 8,768 | 21.29% | 3.62% | **+32%** | **+27%** |
| **Post Purchase** | Personalized | 1,022 | 5,686 | **33.76%** | 4.21% | | |
| | Static | 1,867 | 3,700 | 27.05% | **4.82%** | **+25%** | **-13% (S wins)** |

**Takeaway**: Personalized wins on opens in all 3 campaigns (+25-34%). Wins on clicks in BR and AC, but **Static wins on clicks in Post Purchase** by 13%.

### A4-A6: Both Arms (More Power, Slight Bandit Bias)

| Campaign | Type | Overlap Users | Sends | % Users Opened | % Users Clicked | Open Uplift | Click Uplift |
|----------|------|-------------:|------:|--------------:|--------------:|------------:|-------------:|
| **Browse Recovery** | Personalized | 15,388 | 98,320 | **37.55%** | **7.43%** | | |
| | Static | 14,290 | 98,489 | 28.19% | 6.26% | **+33%** | **+19%** |
| **Abandon Cart** | Personalized | 2,141 | 10,384 | **31.20%** | **5.56%** | | |
| | Static | 3,761 | 11,101 | 23.56% | 4.15% | **+32%** | **+34%** |
| **Post Purchase** | Personalized | 1,118 | 6,273 | **34.08%** | 4.11% | | |
| | Static | 1,944 | 3,859 | 27.16% | **4.84%** | **+25%** | **-15% (S wins)** |

**Takeaway**: Similar to Random-only. Adding Bandit arm doesn't change the story materially. Post Purchase: Static still wins on clicks.

### Summary: Within-User P vs S

| Campaign | Open Winner | Click Winner | Open Lift (Random) | Click Lift (Random) |
|----------|:----------:|:----------:|------------------:|-------------------:|
| Browse Recovery | **Personalized** | **Personalized** | +34% | +21% |
| Abandon Cart | **Personalized** | **Personalized** | +32% | +27% |
| Post Purchase | **Personalized** | **Static** | +25% | -13% |

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
| **Browse Recovery** | **809** | 582 | 162 | 12,898 | 14,451 | **1.39:1 (P wins)** |
| **Abandon Cart** | 66 | **105** | 13 | 3,483 | 3,667 | **0.63:1 (S wins)** |
| **Post Purchase** | 39 | **86** | 4 | 2,104 | 2,233 | **0.45:1 (S wins)** |

**Takeaway**:
- Browse Recovery: 39% more users prefer Personalized (809 vs 582)
- Abandon Cart: 59% more users prefer Static (105 vs 66)
- Post Purchase: 120% more users prefer Static (86 vs 39)
- **Only Browse Recovery shows clear user preference for Personalized**

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

### 1. Personalized Wins on Opens Everywhere (+25-34%)
Consistent across all campaigns, both arms. The personalized email is more likely to be opened.

### 2. Personalized Click Lift is Campaign-Dependent
- **Browse Recovery: P wins** (+21% clicks, 39% more users prefer P)
- **Abandon Cart: P wins on rate** (+27%) but **users prefer S** (105 vs 66)
- **Post Purchase: S wins** (-13% clicks, 120% more users prefer S)

### 3. The Bandit IS Learning
Bandit arm shows higher open rates and % users clicked than Random in BR and AC. This means the model is selecting better user-treatment pairs.

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
- **Within-user**: Users who received BOTH P and S on the same arm
- **CTR formula**: `SUM(CASE WHEN opened=1 AND clicked=1 THEN 1 ELSE 0 END) / SUM(opened)` (excludes phantom clicks from image-blocking clients)
- **% users clicked**: Binary per-user rate — "did this user click at least once?" (controls for send frequency)
- **Treatment classification**: From PostgreSQL treatment.name (Browse Recovery / Abandon Cart / Post Purchase × Personalized / Static)
- **Fitment-eligible**: Users with all 3 vehicle attributes (v1_year, v1_make, v1_model)
- **Arms**: Random (4103) = unbiased assignment; Bandit (4689) = Thompson Sampling
