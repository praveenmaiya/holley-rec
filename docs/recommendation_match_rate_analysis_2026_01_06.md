# Recommendation System Analysis Report

**Date**: 2026-01-06
**Data Period**: Dec 4, 2025 - Jan 6, 2026 (~1 month since Personalized treatments went live)
**Linear Ticket**: AUX-11434

---

## Executive Summary

After one month of personalized recommendations being live, the match rate is **0.04%** - only 1 out of 2,295 users purchased any of the 4 products recommended to them.

---

## Section 1: What Was Sent?

| Metric | Value |
|--------|-------|
| Total emails sent | 18,287 |
| Unique users | 2,357 |
| Treatments active | 10 |
| Days active | 32 |
| Avg emails/user | 7.8 |

**Treatment IDs (Personalized Fitment)**:
- 16150700 (Thanks)
- 20142778 (Warm Welcome)
- 20142785 (Relatable Wrencher)
- 20142804 (Completer)
- 20142811 (Momentum)
- 20142818 (Weekend Warrior)
- 20142825 (Visionary)
- 20142832 (Detail Oriented)
- 20142839 (Expert Pick)
- 20142846 (Look Back)

---

## Section 2: What Was Recommended?

**Top Recommended Products (rec_part_1)**:

| SKU | Times Recommended | Part Type | Vehicles It Fits |
|-----|-------------------|-----------|------------------|
| LFRB155 | 687 (29.9%) | Headlight | 3,213 |
| 0-80457S | ~1,000 | Carburetor | 3,891 |
| 550-849K | ~500 | Fuel Injection Kit | 5,991 |
| LFRB135 | ~700 | Headlight | 3,193 |
| 8202 | ~700 | Ignition Coil | 2,216 |

**Key Problem**: 1,101 different vehicle types in the user base, but only 174 unique product recommendations being made.

---

## Section 3: What Did Users Actually Buy?

| Metric | Value |
|--------|-------|
| Users who purchased anything | 571 (24.23%) |
| Unique products purchased | 1,542 |
| Products NOT in fitment data | 1,004 (65.1%) |
| Products fitting <50 vehicles | 163 (10.5%) |
| Products fitting 1000+ vehicles | 76 (4.9%) |

**Key Finding**: 65% of products users buy are NOT in the fitment database at all.

### Fitment Breadth Distribution of Purchased Products

| Fitment Category | Product Count | % |
|------------------|---------------|---|
| Not in fitment data | 1,004 | 65.1% |
| Very specific (1-10 vehicles) | 76 | 4.9% |
| Specific (11-50) | 87 | 5.6% |
| Moderate (51-200) | 145 | 9.4% |
| Broad (201-1000) | 154 | 10.0% |
| Very broad (1000+) | 76 | 4.9% |

---

## Section 4: The Match Rate

| Metric | Value |
|--------|-------|
| Users with recommendations | 2,295 |
| Users who bought ANY recommended product | **1** |
| **Match Rate** | **0.04%** |

**570 users bought something, but NOT what was recommended to them.**

### The One Match

| Field | Value |
|-------|-------|
| Email | rrenwand@msn.com |
| Vehicle | 1964 CHEVROLET MALIBU |
| Recommendations | 0-80457S, 8202, LFRB145, 550-849K |
| Purchased | 8202 (Ignition Coil) |
| Which recommendation | rec_part_2 |

---

## Root Causes Identified

### 1. Fitment Data Gap (65% of purchases)

- Users buy vehicle-specific parts that don't exist in the fitment database
- These products can never be recommended
- Example: C6051-69 (Console Latch) is top seller for 1969 Camaro but has NO fitment data

### 2. Broad Fitment Bias (Algorithm Issue)

- The algorithm recommends products fitting 2,000-6,000 vehicles
- But users actually buy products fitting <200 vehicles
- Generic parts ≠ Relevant parts

| What We Recommend | Vehicles It Fits |
|-------------------|------------------|
| 550-849K | 5,991 |
| 0-80457S | 3,891 |
| LFRB155 | 3,213 |

### 3. Global Popularity (Wrong Signal)

- Algorithm ranks by total sales across ALL vehicles
- Should rank by sales within the SAME vehicle segment
- A product selling 1,000 units across 3,000 vehicles scores the same as one selling 1,000 units to 100 vehicles - but the second is 30x more relevant per vehicle!

---

## Visual Summary

**WHAT THE ALGORITHM DOES (BROKEN):**
```
1969 Camaro ──► LFRB155, 0-80457S, LFRB135, 8202
1970 Camaro ──► LFRB155, 0-80457S, LFRB135, 8202
1967 Malibu ──► LFRB155, 0-80457S, LFRB135, 8202
1964 Malibu ──► 0-80457S, 8202, LFRB145, 550-849K

→ Same generic products for everyone
  (each fits 2000-6000 vehicles)
```

**WHAT USERS ACTUALLY BUY (DIFFERENT):**
```
1969 Camaro ──► 145-160, 16-111, 19-403, 197-400
1970 Camaro ──► 1005-567, 108-7, 121-8, 122-78
1967 Malibu ──► 19-405, 20-185BK, 26-553, 558-321

→ Vehicle-specific parts
  (65% not even in fitment data!)
```

**MATCH RATE: 0.04%** (1 out of 2,295 users)

---

## Side-by-Side Comparison Examples

| Vehicle | Recommended | Actually Bought | Match |
|---------|-------------|-----------------|-------|
| 1987 Chevrolet R10 | BWH87BK, QCCB087BLACK, QSBKT87RED, ATC7387 | 10021-LGHOL, 10294-LGHOL, 1137ERL, 11578FLT, 145-112 | NO |
| 1977 Chevrolet El Camino | 0-80457S, LFRB140-1, 550-849K, 0-80350 | 0-80576SA, 108-124, 12-886KIT, 121-31, 12621HKR | NO |
| 1969 Chevrolet Camaro | LFRB155, 0-80457S, LFRB135, 8202 | 145-160, 16-111, 19-403, 197-301, 197-400 | NO |
| 1970 Chevrolet Camaro | LFRB155, 0-80457S, LFRB135, 8202 | 1005-567, 108-7, 121-8, 122-78, 125-65 | NO |
| 1967 Chevrolet Malibu | LFRB155, 0-80457S, LFRB135, 8202 | 19-405, 20-185BK, 26-553, 550-931, 558-321 | NO |

---

## Next Steps

A fix spec has been drafted: `specs/algorithm_fix_per_vehicle_sales_velocity.md`

### The Fix

**Current Formula (Broken)**:
```sql
popularity_score = LOG(1 + global_orders) * 2
final_score = intent_score + popularity_score
```

**Proposed Formula (Fixed)**:
```sql
segment_popularity = LOG(1 + orders_by_this_vehicle_segment) * 10
narrow_fit_bonus = CASE WHEN vehicles_fit <= 100 THEN 5 ELSE 0 END
final_score = intent_score + segment_popularity + narrow_fit_bonus
```

### Implementation Files to Create

| File | Purpose |
|------|---------|
| `sql/recommendations/v5_8_step1_segment_sales.sql` | What do vehicle owners buy? |
| `sql/recommendations/v5_8_step2_fitment_breadth.sql` | Narrow fit bonus calculation |
| `sql/recommendations/v5_8_vehicle_fitment_recommendations.sql` | Main pipeline with new scoring |
| `sql/validation/v5_8_validation.sql` | Verify improvements |

---

## Key Queries Used

### Treatment Send History
```sql
SELECT
  treatment_id,
  MIN(DATE(treatment_sent_timestamp)) as first_sent,
  MAX(DATE(treatment_sent_timestamp)) as last_sent,
  COUNT(*) as total_sent
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE treatment_id IN (16150700, 20142778, 20142785, 20142804, 20142811,
                       20142818, 20142825, 20142832, 20142839, 20142846)
AND treatment_sent_timestamp >= "2025-12-01"
GROUP BY 1
```

### Match Rate Calculation
```sql
-- Join recommendations to purchases, check if any of 4 recs were bought
-- Result: 1 out of 2,295 users (0.04%)
```

### Fitment Breadth of Purchased Products
```sql
-- Categorize products by how many vehicles they fit
-- Result: 65% not in fitment data, users prefer specific products
```

---

## Section 5: Retrospective Backtest (Dec 15 - Jan 5)

To validate the algorithm improvements, we ran a backtest asking: "If we generated recommendations on Dec 15, would they have matched purchases through Jan 5?"

### Backtest Design
- **Test cutoff**: Dec 15, 2025 (generate recs as of this date)
- **Evaluation window**: Dec 15 - Jan 5, 2026 (21 days of purchases)
- **Users analyzed**: Those with vehicle data who purchased during the window

### Key Findings

| Metric | Value |
|--------|-------|
| Fitting purchase pairs | 462 |
| Exact matches | **0 (0%)** |
| Near-miss (same family, 6-char prefix) | 38 (8.2%) |
| Near-miss (same brand, 4-char prefix) | 34 (7.4%) |
| **Completely unrelated products** | **390 (84.4%)** |

### Root Cause Confirmed

**Even when users buy products that FIT their vehicle, we're recommending completely unrelated products 84% of the time.**

Examples from the backtest:

| User | Vehicle | Purchased (fits vehicle) | Recommended |
|------|---------|--------------------------|-------------|
| john173d@hotmail.com | 1966 Cadillac DeVille | 31193, 8363 | LFRB125, 0-80457S, 8202 |
| veritasproject777@gmail.com | 1966 Chevrolet El Camino | LFRB145, LFRB146 | 550-511-3XX, 0-80457S |
| pjc@winstoncashatt.com | 1966 Ford Mustang | B1AZ-3518-A, C3DZ-3517-A | C5AZ-6316-B, C6ZZ-10B960KBK |

### Why V5.7 and V5.8 Both Show 0 Matches

Both algorithms prioritize globally popular products that fit many vehicles. The segment-based scoring in v5.8 helps, but the fundamental issue is:

1. **Fitment data gap**: 78.6% of purchased SKUs are NOT in the recommendation catalog
2. **Broad fitment bias**: We recommend products fitting 2,000+ vehicles
3. **Wrong signal**: Global popularity ≠ segment relevance

### Implication

The v5.8 algorithm changes (segment popularity, narrow fit bonus) are directionally correct but insufficient. The core issue is **catalog coverage** - we can only recommend ~21% of what users actually buy.

---

## Related Documents

- `specs/algorithm_fix_per_vehicle_sales_velocity.md` - Implementation spec
- `docs/algorithm_fitment_vs_sales_velocity_analysis_2026_01_04.md` - Root cause analysis
- `docs/SESSION_2026_01_05_algorithm_analysis.md` - Previous session summary
- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` - Current pipeline

---

*Analysis conducted 2026-01-06*
