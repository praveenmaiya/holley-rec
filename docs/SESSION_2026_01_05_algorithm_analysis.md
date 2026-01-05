# Session Summary: Algorithm Analysis & Fix Plan

**Date**: 2026-01-05
**Duration**: Extended deep-dive session
**Linear Ticket**: AUX-11136 (deleted by user)

---

## Session Objectives

1. Understand why Personalized recommendations underperform
2. Prove the recommendation system is fundamentally broken
3. Document the fix plan

---

## Key Findings

### The Core Problem

**What was built:**
```
Vehicle V1 → Products that FIT V1 → Rank by GLOBAL popularity → Recommend
```

**What was needed:**
```
Vehicle V1 → Products that V1 OWNERS BUY → Rank by SEGMENT popularity → Recommend
```

### Proof Points

| Evidence | Data |
|----------|------|
| Top 10 sellers in recommendations | 1 out of 10 (90% missing) |
| LFRB155 recommended | 122,945 users |
| LFRB155 purchased | 1,179 (0.96% conversion) |
| 84130-3 recommended | 65,703 users |
| 84130-3 purchased | 24 (0.04% conversion) |
| 1969 Camaro top rec | LFRB155 (fits 3,213 vehicles) |
| 1969 Camaro top purchase | C6051-69 (Camaro-specific) |
| LFRB155 rank in Camaro purchases | 9th (only 13 purchases) |

### Root Causes

1. **Fitment breadth optimization** - Products fitting more vehicles rank higher
2. **Global popularity signal** - Uses sales across ALL vehicles, not per-segment
3. **Missing fitment data** - 90% of top sellers not in fitment database
4. **Inverse relevance** - Broad fitment = generic = irrelevant

---

## Documents Created

### 1. Root Cause Analysis
**File**: `docs/algorithm_fitment_vs_sales_velocity_analysis_2026_01_04.md`

Contents:
- Executive summary
- 1969 Camaro case study with data
- Three root causes identified
- Quantified impact (0.06% match rate)
- Current vs needed algorithm flow

### 2. Implementation Spec
**File**: `specs/algorithm_fix_per_vehicle_sales_velocity.md`

Contents:
- Problem statement
- Solution overview (new formula)
- Step-by-step SQL implementation
- Validation queries
- Execution order
- Expected improvements
- Definition of done

---

## The Fix

### Current Formula (v5.7 - Broken)
```sql
popularity_score = LOG(1 + global_total_orders) * 2
final_score = intent_score + popularity_score
```

### New Formula (v5.8 - Fixed)
```sql
segment_popularity_score = LOG(1 + orders_by_this_vehicle_segment) * 10
narrow_fit_bonus = CASE WHEN vehicles_fit <= 100 THEN 5 ELSE 0 END
final_score = intent_score + segment_popularity_score + narrow_fit_bonus
```

### Implementation Steps

| Step | File to Create | Purpose |
|------|----------------|---------|
| 1 | `sql/recommendations/v5_8_step1_segment_sales.sql` | What do owners of each vehicle buy? |
| 2 | `sql/recommendations/v5_8_step2_fitment_breadth.sql` | Narrow fit bonus calculation |
| 3 | `sql/recommendations/v5_8_vehicle_fitment_recommendations.sql` | Main pipeline with new scoring |
| 4 | `sql/validation/v5_8_validation.sql` | Validate improvements |

---

## Key Queries Used

### Top Recommended Products
```sql
SELECT rec_part_1 as sku, COUNT(*) as times_recommended
FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
GROUP BY 1 ORDER BY 2 DESC LIMIT 10
```

### Top Selling Products
```sql
SELECT ITEM as sku, SUM(QTY) as purchases
FROM `auxia-gcp.data_company_1950.import_orders`
WHERE ORDER_DATE >= FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY))
GROUP BY 1 ORDER BY 2 DESC LIMIT 10
```

### What 1969 Camaro Owners Buy
```sql
WITH camaro_users AS (
  SELECT email_lower
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
  WHERE v1_year = '1969' AND LOWER(v1_make) = 'chevrolet' AND LOWER(v1_model) = 'camaro'
)
SELECT o.ITEM as sku, SUM(o.QTY) as qty
FROM `auxia-gcp.data_company_1950.import_orders` o
JOIN camaro_users cu ON LOWER(o.SHIP_TO_EMAIL) = cu.email_lower
WHERE o.ORDER_DATE >= FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY))
GROUP BY 1 ORDER BY 2 DESC LIMIT 15
```

### Fitment Breadth
```sql
SELECT p.product_number as sku, COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) as vehicles_fit
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`, UNNEST(products) as p
WHERE p.product_number IN ('LFRB155', 'C6051-69')
GROUP BY 1
```

---

## Next Steps

1. **Implement v5.8** - Run `/implement-spec specs/algorithm_fix_per_vehicle_sales_velocity.md`
2. **Validate** - Check 1969 Camaro recommendations change
3. **Compare** - Use `/compare-versions` to see diff
4. **Deploy** - After validation passes

---

## Notes

- **Linear ticket AUX-11136 was deleted** - Do not update without checking with user first
- All analysis saved locally in docs/ and specs/
- Session can be resumed with this document as context

---

## Related Documents

- `docs/personalized_underperformance_root_cause_2026_01_03.md`
- `docs/buying_behavior_analysis_2026_01_02.md`
- `docs/post_launch_conversion_analysis_2026_01_02.md`
- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql`

---

*Session saved by Claude Code*
