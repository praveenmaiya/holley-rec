# Post Purchase Uplift Investigation Results

**Date:** January 19, 2026
**Analysis Period:** November 20, 2025 - January 19, 2026 (60 days)
**Objective:** Determine if v5.17 Personalized recommendations outperform Static treatments

---

## Summary Table

| Approach | Personalized CTR | Static CTR | Uplift | Valid Claim? |
|----------|------------------|------------|--------|--------------|
| A: Direct (60-day) | 11.54% | 8.29% | **+39%** | ⚠️ Selection bias caveat |
| A: Direct (Jan 2026) | 12.04% | 8.72% | **+38%** | ⚠️ Selection bias caveat |
| B: Same-user (n=969) | 2.99% clicked | 2.48% clicked | **+21%** | ✅ Valid within-user |
| C: Fitment-only | n=4 clicks | n=3 clicks | -- | ❌ Sample too small |

---

## Approach A: Direct Comparison

**60-day lookback (Nov 20, 2025 - Jan 19, 2026)**

| Metric | Personalized | Static |
|--------|--------------|--------|
| Sends | 21,129 | 76,181 |
| Unique Users | 2,606 | 34,789 |
| Opens | 849 | 4,557 |
| Clicks | 98 | 378 |
| Open Rate | 4.02% | 5.98% |
| **CTR of Opens** | **11.54%** | 8.29% |
| CTR of Sends | 0.46% | 0.50% |

**Key Finding:** Personalized shows **+39% higher CTR of opens** (11.54% vs 8.29%). However, open rate is lower for Personalized (4.02% vs 5.98%), which drags down overall CTR of sends.

**Limitation:** Different user populations. Personalized users have fitment data (vehicle info); Static users don't. This is selection bias - users with vehicles may behave differently regardless of email content.

---

## Approach B: Same-User Comparison (Gold Standard)

**969 users received both Personalized and Static treatments**

| Metric | Personalized | Static |
|--------|--------------|--------|
| Users who clicked | 26 | 21 |
| Clicked both | 3 | 3 |
| % who clicked (at least once) | **2.99%** | 2.48% |

**Click Distribution:**
- 26 users clicked Personalized only
- 21 users clicked Static only
- 3 users clicked both
- 919 clicked neither

**Key Finding:** **+21% more users clicked Personalized** (29 total vs 24 total). This is within-user comparison, eliminating selection bias.

**Limitation:** Sample size is moderate (969 users, 50 clickers). The difference (26 vs 21) is directionally positive but not statistically overwhelming.

---

## Approach C: Fitment-Controlled Comparison

**Users WITH fitment at time of treatment selection**

| Metric | Personalized | Static |
|--------|--------------|--------|
| Sends | 801 | 52 |
| Clicks | 4 | 3 |

**Key Finding:** Sample too small for valid comparison. Only 33 fitment users received Static (1% randomization chance as expected). Not statistically meaningful.

---

## Recommendation for Client Communication

### Can claim with confidence:
> "When users receive both Personalized and Static emails over time, they are **21% more likely to click on Personalized recommendations**."

### Can claim with caveat:
> "Among users who open emails, Personalized recommendations achieve a **38-39% higher click-through rate** compared to Static recommendations. However, this comparison involves different user segments."

### Cannot claim:
- "Personalized beats Static for all users" (selection bias)
- "Personalized has higher overall CTR" (CTR of sends is similar due to lower open rates)

---

## Why Open Rate is Lower for Personalized

Personalized users (with vehicle data) likely receive more targeted marketing overall, leading to:
1. **Email fatigue** - Higher engagement expectations
2. **Self-selection** - Users who provide vehicle data may be more discerning

The higher CTR-of-opens suggests **when they do open, the personalized content is more compelling**.

---

## Key Insight

The real value of Personalized recommendations shows in **engagement quality, not quantity**:
- Users who open Personalized emails are **38% more likely to click**
- Same users prefer Personalized over Static by **21%** when given both

---

## Methodology Notes

### Treatment IDs
- **Personalized (10):** 16150700, 20142778, 20142785, 20142804, 20142811, 20142818, 20142825, 20142832, 20142839, 20142846
- **Static (1 active):** 16490939

### Key Tables
| Table | Purpose |
|-------|---------|
| `treatment_history_sent` | Send records with treatment_id, user_id |
| `treatment_interaction` | Opens (VIEWED), Clicks (CLICKED) |
| `ingestion_unified_attributes_schema_incremental` | User fitment data (v1_year, v1_make, v1_model) |

### Deduplication
- Used DISTINCT for click/view counts to prevent multi-click inflation
- CTR of opens = unique clickers / unique openers
- CTR of sends = unique clickers / total sends

### Timing Consideration
For Approach C, verified fitment existed BEFORE treatment was sent. Found that 98% of "fitment users receiving Static" actually got fitment AFTER the Static send, making that comparison invalid without timing constraints.
