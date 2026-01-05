# Algorithm Analysis: Fitment Breadth vs Sales Velocity

**Date**: 2026-01-04
**Issue**: AUX-11136 - Post launch data analysis
**Author**: Claude Code analysis

---

## Executive Summary

The recommendation algorithm was designed to recommend products that **fit** a user's vehicle, ranked by **global popularity**. However, the user expectation was to recommend products that **sell to owners** of that specific vehicle. This fundamental mismatch explains why 0% of users buy what we recommend.

**Key Finding**: Products that fit many vehicles (broad fitment) are LESS relevant to any specific vehicle owner than products that fit few vehicles (narrow fitment).

---

## The Core Question Answered

### What the user expected was built:
```
Vehicle V1 (1969 Camaro) → P1, P2, P3 (highest selling parts FOR Camaro owners)
```

### What was actually built:
```
Vehicle V1 (1969 Camaro) → P1, P2, P3 (parts that FIT Camaro, ranked by GLOBAL sales)
```

**The critical difference**: We recommend products that *fit* the vehicle, not products that vehicle *owners actually buy*.

---

## Case Study: 1969 Chevrolet Camaro

### Population
- Total users with 1969 Camaro: **4,070**
- Largest vehicle segment in recommendations table

### What We Recommend

| SKU | Product Type | Users Recommended To | % of Camaro Users |
|-----|--------------|---------------------|-------------------|
| LFRB155 | Headlight | 4,013 | **98.6%** |
| 0-80457S | Carburetor | 9 | 0.2% |
| Other | Various | 48 | 1.2% |

**98.6% of 1969 Camaro users receive the same recommendation: LFRB155 (Headlight)**

### What 1969 Camaro Owners Actually Buy

| Rank | SKU | Product Type | Qty Bought | In Fitment Data? |
|------|-----|--------------|-----------|------------------|
| 1 | EXT-SHIP-PROTECTION | Shipping Protection | 76 | N/A |
| 2 | C6051-69 | Center Console Latch | 75 | NO |
| 3 | 36-525 | License Plate Bracket | 62 | NO |
| 4 | C0AF-13788-A | Dome Light Housing | 61 | YES (4 vehicles) |
| 5 | C6TZ-8125-3K | Radiator Insulator | 58 | YES (12 vehicles) |
| 6 | C9088-69 | Parking Light Lens | 56 | NO |
| ... | ... | ... | ... | ... |
| **9** | **LFRB155** | **Headlight (OUR REC)** | **13** | YES (3,213 vehicles) |

### The Paradox Illustrated

| Metric | LFRB155 (We Recommend) | C6051-69 (They Buy) |
|--------|------------------------|---------------------|
| Product Type | Headlight | Console Latch |
| Vehicles It Fits | 3,213 | NOT IN FITMENT |
| Global Sales (365d) | 1,179 | 363 |
| Bought by Camaro Owners | 13 | 75 |
| Algorithm Score | HIGH | ZERO |

**LFRB155 fits 3,213 vehicles** - it's a generic aftermarket headlight that works across many classic cars.

**C6051-69 fits only 1969 Camaro** - it's a year-specific console latch that Camaro owners specifically need.

The algorithm recommends the generic part because it has fitment data and global popularity. But Camaro owners want the Camaro-specific part.

---

## Vehicle Fitment Breadth Analysis

### Products in Recommendations vs Actual Purchases

| SKU | Vehicles It Fits | Global Sales | Camaro Owner Purchases |
|-----|-----------------|--------------|------------------------|
| LFRB155 | 3,213 | 1,179 | 13 |
| C6TZ-8125-3K | 12 | 72 | 58 |
| C0AF-13788-A | 4 | 207 | 61 |
| C6051-69 | NOT IN DATA | 363 | 75 |
| 36-525 | NOT IN DATA | 2,447 | 62 |
| C9088-69 | NOT IN DATA | 80 | 56 |

### Key Insight: Inverse Relationship

```
Vehicles Fit (Fitment Breadth) vs Relevance to Specific Vehicle

High fitment (3000+ vehicles) → Generic product → LOW relevance
Low fitment (4-12 vehicles) → Specific product → HIGH relevance
No fitment data → Year-specific part → HIGHEST relevance (often)
```

---

## Three Root Causes Identified

### 1. Fitment Data Coverage Gap

Many popular vehicle-specific products are **not in the fitment database** at all:
- C6051-69 (Console Latch) - NO FITMENT DATA
- 36-525 (License Bracket) - NO FITMENT DATA
- C9088-69 (Parking Light) - NO FITMENT DATA

These products can NEVER be recommended, even though they're top sellers for specific vehicles.

### 2. Wrong Popularity Signal

**Current scoring formula** (from `v5_7_vehicle_fitment_recommendations.sql`):
```sql
final_score = intent_score + LOG(1 + total_orders) * 2
```

Where `total_orders` = **GLOBAL sales across ALL vehicles**

**Problem**: A product selling 1,000 units across 3,000 different vehicles scores the same as a product selling 1,000 units to 100 vehicles. But the second product is 30x more relevant per vehicle!

### 3. Fitment Breadth as Anti-Signal

Products with broad fitment (fits 3,000+ vehicles) are often:
- Universal/generic aftermarket parts
- Less specific to any individual vehicle
- Lower purchase intent per vehicle owner

Products with narrow fitment (fits 4-50 vehicles) are often:
- Year/model specific parts
- Exactly what that vehicle owner needs
- Higher purchase intent per vehicle owner

---

## Quantified Impact

### Match Rate Analysis

| Metric | Value |
|--------|-------|
| Users with recommendations | 458,210 |
| Users who purchased anything | 2,077 (0.45%) |
| Purchases matching recommendation | 1 (0.06%) |

**Only 0.06% of purchases match what we recommended.**

### For 1969 Camaro Specifically

| Metric | Value |
|--------|-------|
| Users with recommendations | 4,070 |
| Users receiving LFRB155 rec | 4,013 (98.6%) |
| Users who bought LFRB155 | 13 |
| Match rate | 0.3% |

---

## Current Algorithm Flow

```
Step 1: Get user's vehicle (v1_year, v1_make, v1_model)
        ↓
Step 2: Find all products that FIT this vehicle (via fitment data)
        ↓
Step 3: Calculate intent score (user's views/carts/orders)
        ↓
Step 4: Calculate popularity score = LOG(1 + GLOBAL_orders) * 2
        ↓
Step 5: final_score = intent_score + popularity_score
        ↓
Step 6: Rank by final_score, pick top 4
```

**The Problem is in Step 4**: Global orders doesn't reflect what THIS vehicle's owners buy.

---

## Proposed Fix: Per-Vehicle Sales Velocity

### Change Step 4 to:

```sql
-- Instead of:
LOG(1 + global_total_orders) * 2

-- Use:
LOG(1 + orders_by_this_vehicle_segment) * weight
```

### Implementation Approach

```sql
WITH vehicle_segment_sales AS (
  SELECT
    v1_year,
    v1_make,
    v1_model,
    sku,
    COUNT(*) as segment_orders
  FROM orders o
  JOIN user_vehicles uv ON o.user_id = uv.user_id
  GROUP BY 1,2,3,4
)
-- Then join to recommendations and use segment_orders for scoring
```

### Expected Impact

For 1969 Camaro, instead of recommending LFRB155 (13 Camaro purchases), we would recommend:
- C6051-69 (75 Camaro purchases) - IF we add it to fitment data
- C0AF-13788-A (61 Camaro purchases) - Already in fitment data
- C6TZ-8125-3K (58 Camaro purchases) - Already in fitment data

---

## Additional Recommendations

### 1. Expand Fitment Data Coverage

Many top-selling vehicle-specific products have no fitment data:
- Audit top 100 sellers per vehicle segment
- Add missing fitment mappings
- Flag products as "year-specific" even without full YMM data

### 2. Add Narrow Fitment Bonus

```sql
-- Bonus for products that fit fewer vehicles (more specific)
narrow_fit_bonus = CASE
  WHEN vehicles_fit <= 50 THEN 10
  WHEN vehicles_fit <= 200 THEN 5
  WHEN vehicles_fit <= 1000 THEN 2
  ELSE 0
END
```

### 3. Cold-Start with Segment Sales

For users with no intent data (98% of users):
```sql
-- Instead of global popularity, use segment popularity
cold_start_score = LOG(1 + segment_orders) * 5
```

---

## Data Sources

```sql
-- Recommendations output
`auxia-reporting.company_1950_jp.final_vehicle_recommendations`

-- Orders by user
`auxia-gcp.data_company_1950.import_orders`

-- Product catalog
`auxia-gcp.data_company_1950.import_items`

-- Vehicle fitment mapping
`auxia-gcp.data_company_1950.vehicle_product_fitment_data`

-- Recommendation algorithm
`sql/recommendations/v5_7_vehicle_fitment_recommendations.sql`
```

---

## Key Queries Used

### Top Recommendations for Vehicle Segment
```sql
SELECT
  rec_part_1 as recommended_sku,
  COUNT(*) as users_with_this_rec
FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
WHERE v1_year = '1969'
  AND LOWER(v1_make) = 'chevrolet'
  AND LOWER(v1_model) = 'camaro'
GROUP BY 1
ORDER BY users_with_this_rec DESC
```

### Actual Purchases by Vehicle Segment
```sql
WITH segment_users AS (
  SELECT email_lower
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
  WHERE v1_year = '1969'
    AND LOWER(v1_make) = 'chevrolet'
    AND LOWER(v1_model) = 'camaro'
)
SELECT
  o.ITEM as actually_bought,
  SUM(o.QTY) as total_qty
FROM `auxia-gcp.data_company_1950.import_orders` o
JOIN segment_users su ON LOWER(o.SHIP_TO_EMAIL) = su.email_lower
WHERE o.ORDER_DATE >= FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY))
GROUP BY 1
ORDER BY total_qty DESC
```

### Fitment Breadth Analysis
```sql
SELECT
  p.product_number as sku,
  COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) as vehicles_fit
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`,
     UNNEST(products) as p
WHERE p.product_number IN ('LFRB155', 'C6051-69', 'C0AF-13788-A')
GROUP BY 1
ORDER BY vehicles_fit DESC
```

---

## Related Documents

- `docs/personalized_underperformance_root_cause_2026_01_03.md` - Initial root cause analysis
- `docs/buying_behavior_analysis_2026_01_02.md` - Category and basket analysis
- `docs/post_launch_conversion_analysis_2026_01_02.md` - Conversion metrics
- `specs/v5_6_recommendations.md` - Current algorithm specification
- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` - Algorithm implementation

---

## Conclusion

The algorithm is technically working as designed - it recommends products that fit the user's vehicle, ranked by global popularity. But this design is flawed because:

1. **Fitment ≠ Relevance**: Products fitting many vehicles are generic, not specific
2. **Global popularity ≠ Segment popularity**: What sells globally isn't what a specific vehicle owner wants
3. **Missing fitment data**: Many vehicle-specific parts can never be recommended

**The fix**: Replace global popularity scoring with per-vehicle-segment sales velocity.

---

*Generated by Claude Code for AUX-11136*
