# Algorithm Fix: Per-Vehicle Sales Velocity Scoring

**Date**: 2026-01-05
**Issue**: AUX-11136
**Status**: SPEC READY FOR IMPLEMENTATION
**Author**: Claude Code

---

## Problem Statement

The current algorithm recommends products based on:
1. **Fitment** - Does the product fit the user's vehicle?
2. **Global Popularity** - How many total orders does this product have across ALL vehicles?

This is fundamentally broken because:
- Products fitting MANY vehicles (broad fitment) rank higher
- But broad-fit products are GENERIC and irrelevant to specific vehicle owners
- 90% of top-selling products are NOT in our recommendations
- 0.04% - 0.96% of recommended products are actually purchased

---

## Solution Overview

**Change the scoring from GLOBAL popularity to PER-VEHICLE-SEGMENT popularity.**

### Current Formula (Broken)
```sql
popularity_score = LOG(1 + global_total_orders) * 2
final_score = intent_score + popularity_score
```

### New Formula (Fixed)
```sql
segment_popularity_score = LOG(1 + orders_by_this_vehicle_segment) * 10
narrow_fit_bonus = CASE WHEN vehicles_fit <= 100 THEN 5 ELSE 0 END
final_score = intent_score + segment_popularity_score + narrow_fit_bonus
```

---

## Implementation Steps

### Step 1: Create Vehicle Segment Sales Table

**Purpose**: Calculate how many times each product is purchased by owners of each vehicle segment.

**File**: `sql/recommendations/v5_8_step1_segment_sales.sql`

```sql
-- Step 1: Calculate per-vehicle-segment sales
-- This answers: "What do owners of [year] [make] [model] actually buy?"

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_8.segment_product_sales` AS

WITH user_vehicles AS (
  -- Get user -> vehicle mapping from recommendations table
  -- (already has the denormalized v1_year, v1_make, v1_model)
  SELECT DISTINCT
    email_lower,
    v1_year,
    v1_make,
    v1_model
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
  WHERE v1_year IS NOT NULL
),

user_orders AS (
  -- Get all orders with user email
  SELECT
    LOWER(SHIP_TO_EMAIL) as email_lower,
    ITEM as sku,
    SUM(QTY) as qty
  FROM `auxia-gcp.data_company_1950.import_orders`
  WHERE ORDER_DATE >= FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY))
  GROUP BY 1, 2
),

segment_sales AS (
  -- Join: what do users with vehicle X buy?
  SELECT
    uv.v1_year,
    uv.v1_make,
    uv.v1_model,
    uo.sku,
    SUM(uo.qty) as segment_orders,
    COUNT(DISTINCT uo.email_lower) as segment_buyers
  FROM user_vehicles uv
  JOIN user_orders uo ON uv.email_lower = uo.email_lower
  GROUP BY 1, 2, 3, 4
)

SELECT
  v1_year,
  v1_make,
  v1_model,
  sku,
  segment_orders,
  segment_buyers,
  -- Pre-calculate the score component
  LOG(1 + segment_orders) * 10 as segment_popularity_score
FROM segment_sales
WHERE segment_orders >= 2  -- Minimum 2 orders to be considered
;
```

**Expected Output**:
| v1_year | v1_make | v1_model | sku | segment_orders | segment_popularity_score |
|---------|---------|----------|-----|----------------|--------------------------|
| 1969 | CHEVROLET | CAMARO | C6051-69 | 75 | 43.2 |
| 1969 | CHEVROLET | CAMARO | 36-525 | 62 | 41.4 |
| 1969 | CHEVROLET | CAMARO | LFRB155 | 13 | 26.4 |

### Step 2: Calculate Fitment Breadth

**Purpose**: Count how many vehicles each product fits (for narrow-fit bonus).

**File**: `sql/recommendations/v5_8_step2_fitment_breadth.sql`

```sql
-- Step 2: Calculate fitment breadth for narrow-fit bonus
-- Products fitting fewer vehicles get a bonus (more specific = more relevant)

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_8.product_fitment_breadth` AS

SELECT
  p.product_number as sku,
  COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) as vehicles_fit,
  CASE
    WHEN COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) <= 50 THEN 10   -- Very specific
    WHEN COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) <= 100 THEN 7
    WHEN COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) <= 500 THEN 3
    WHEN COUNT(DISTINCT CONCAT(v1_year, v1_make, v1_model)) <= 1000 THEN 1
    ELSE 0  -- Broad fitment = no bonus
  END as narrow_fit_bonus
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`,
     UNNEST(products) as p
GROUP BY 1
;
```

**Expected Output**:
| sku | vehicles_fit | narrow_fit_bonus |
|-----|--------------|------------------|
| C0AF-13788-A | 4 | 10 |
| C6TZ-8125-3K | 12 | 10 |
| RA007 | 34 | 10 |
| LFRB155 | 3213 | 0 |

### Step 3: Modify Scoring in Main Pipeline

**Purpose**: Replace global popularity with segment popularity in the main recommendation query.

**File**: `sql/recommendations/v5_8_vehicle_fitment_recommendations.sql`

**Changes to existing v5_7 pipeline**:

```sql
-- REPLACE Step 2.2 (Popularity Scores) with:

-- Step 2.2: Segment Popularity Scores (NEW)
segment_popularity AS (
  SELECT
    sku,
    v1_year,
    v1_make,
    v1_model,
    segment_orders,
    segment_popularity_score
  FROM `auxia-reporting.temp_holley_v5_8.segment_product_sales`
),

-- Step 2.3: Fitment Breadth Bonus (NEW)
fitment_bonus AS (
  SELECT
    sku,
    vehicles_fit,
    narrow_fit_bonus
  FROM `auxia-reporting.temp_holley_v5_8.product_fitment_breadth`
),

-- MODIFY final scoring calculation:
scored_products AS (
  SELECT
    up.email_lower,
    up.v1_year,
    up.v1_make,
    up.v1_model,
    fp.sku,
    fp.price,
    fp.image_url,
    -- Intent score (unchanged)
    COALESCE(ui.intent_score, 0) as intent_score,
    -- NEW: Segment popularity instead of global
    COALESCE(sp.segment_popularity_score, 0) as segment_popularity_score,
    -- NEW: Narrow fit bonus
    COALESCE(fb.narrow_fit_bonus, 0) as narrow_fit_bonus,
    -- NEW: Final score formula
    (
      COALESCE(ui.intent_score, 0) +
      COALESCE(sp.segment_popularity_score, 0) +
      COALESCE(fb.narrow_fit_bonus, 0)
    ) as final_score
  FROM user_products up
  JOIN filtered_products fp ON up.sku = fp.sku
  LEFT JOIN user_intent ui ON up.email_lower = ui.email_lower AND up.sku = ui.sku
  LEFT JOIN segment_popularity sp
    ON up.v1_year = sp.v1_year
    AND up.v1_make = sp.v1_make
    AND up.v1_model = sp.v1_model
    AND up.sku = sp.sku
  LEFT JOIN fitment_bonus fb ON up.sku = fb.sku
)
```

### Step 4: Add Fallback for Missing Segment Data

**Purpose**: For vehicle segments with no sales data, fall back to make/model level or global.

```sql
-- Fallback hierarchy:
-- 1. Year + Make + Model sales (most specific)
-- 2. Make + Model sales (if no year-specific data)
-- 3. Global popularity (last resort)

fallback_popularity AS (
  SELECT
    up.email_lower,
    up.sku,
    COALESCE(
      -- Level 1: Exact year/make/model
      sp_exact.segment_popularity_score,
      -- Level 2: Make/model only (any year)
      sp_makemodel.segment_popularity_score,
      -- Level 3: Global fallback
      LOG(1 + gp.global_orders) * 2
    ) as popularity_score
  FROM user_products up
  LEFT JOIN segment_popularity sp_exact
    ON up.v1_year = sp_exact.v1_year
    AND up.v1_make = sp_exact.v1_make
    AND up.v1_model = sp_exact.v1_model
    AND up.sku = sp_exact.sku
  LEFT JOIN segment_popularity_makemodel sp_makemodel
    ON up.v1_make = sp_makemodel.v1_make
    AND up.v1_model = sp_makemodel.v1_model
    AND up.sku = sp_makemodel.sku
  LEFT JOIN global_popularity gp ON up.sku = gp.sku
)
```

### Step 5: Validation Queries

**File**: `sql/validation/v5_8_validation.sql`

```sql
-- Validation 1: Top recommendations should now include high-segment-sellers
SELECT
  v1_year, v1_make, v1_model,
  rec_part_1,
  rec1_score
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
WHERE v1_year = '1969' AND v1_make = 'CHEVROLET' AND v1_model = 'CAMARO'
LIMIT 10;

-- Expected: Should see C0AF-13788-A, C6TZ-8125-3K instead of LFRB155

-- Validation 2: Score breakdown for a sample user
SELECT
  email_lower,
  sku,
  intent_score,
  segment_popularity_score,
  narrow_fit_bonus,
  final_score
FROM `auxia-reporting.temp_holley_v5_8.scored_products_debug`
WHERE v1_year = '1969' AND v1_make = 'CHEVROLET' AND v1_model = 'CAMARO'
ORDER BY final_score DESC
LIMIT 20;

-- Validation 3: Compare old vs new top recommendations
WITH old_recs AS (
  SELECT rec_part_1 as sku, COUNT(*) as old_count
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
  GROUP BY 1
),
new_recs AS (
  SELECT rec_part_1 as sku, COUNT(*) as new_count
  FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
  GROUP BY 1
)
SELECT
  COALESCE(o.sku, n.sku) as sku,
  o.old_count,
  n.new_count,
  CASE
    WHEN o.old_count IS NULL THEN 'NEW'
    WHEN n.new_count IS NULL THEN 'REMOVED'
    ELSE 'CHANGED'
  END as status
FROM old_recs o
FULL OUTER JOIN new_recs n ON o.sku = n.sku
WHERE o.old_count != n.new_count OR o.old_count IS NULL OR n.new_count IS NULL
ORDER BY COALESCE(n.new_count, 0) DESC
LIMIT 20;
```

---

## Execution Order

```bash
# Step 1: Create segment sales table
bq query --use_legacy_sql=false < sql/recommendations/v5_8_step1_segment_sales.sql

# Step 2: Create fitment breadth table
bq query --use_legacy_sql=false < sql/recommendations/v5_8_step2_fitment_breadth.sql

# Step 3: Run main pipeline with new scoring
bq query --use_legacy_sql=false < sql/recommendations/v5_8_vehicle_fitment_recommendations.sql

# Step 4: Run validation
bq query --use_legacy_sql=false < sql/validation/v5_8_validation.sql

# Step 5: Compare with production (use /compare-versions skill)
# Step 6: Deploy if validation passes (use /deploy skill)
```

---

## Expected Improvements

### Before (v5.7)
| Vehicle | Top Rec | Segment Sales | Vehicles Fit |
|---------|---------|---------------|--------------|
| 1969 Camaro | LFRB155 | 13 | 3,213 |
| 2024 Silverado | 84130-3 | ? | 641 |

### After (v5.8)
| Vehicle | Top Rec | Segment Sales | Vehicles Fit |
|---------|---------|---------------|--------------|
| 1969 Camaro | C0AF-13788-A | 61 | 4 |
| 2024 Silverado | RA007 | High | 34 |

### Metrics to Track
| Metric | Before | Expected After |
|--------|--------|----------------|
| Recommendation match rate | 0.06% | 5-10% |
| Top rec conversion | 0.04-0.96% | 3-5% |
| Top 10 sellers in recs | 1/10 | 5+/10 |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Cold start for new vehicles | Fallback to make/model or global popularity |
| Sparse segment data | Require minimum 2 orders per segment-product |
| Score inflation | Normalize scores across methods |
| Performance impact | Pre-compute segment sales daily |

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `sql/recommendations/v5_8_step1_segment_sales.sql` | CREATE | Segment sales calculation |
| `sql/recommendations/v5_8_step2_fitment_breadth.sql` | CREATE | Fitment breadth bonus |
| `sql/recommendations/v5_8_vehicle_fitment_recommendations.sql` | CREATE | Main pipeline with new scoring |
| `sql/validation/v5_8_validation.sql` | CREATE | Validation queries |
| `specs/v5_8_recommendations.md` | CREATE | Full spec for v5.8 |

---

## Definition of Done

- [ ] Segment sales table created and populated
- [ ] Fitment breadth table created and populated
- [ ] Main pipeline modified with new scoring
- [ ] Validation shows improved segment relevance
- [ ] 1969 Camaro test: C0AF-13788-A or C6TZ-8125-3K in top 3 (not LFRB155)
- [ ] Compare-versions shows expected changes
- [ ] Deployed to production
- [ ] 7-day monitoring shows improved match rate

---

## Related Documents

- `docs/algorithm_fitment_vs_sales_velocity_analysis_2026_01_04.md` - Root cause analysis
- `docs/personalized_underperformance_root_cause_2026_01_03.md` - Initial findings
- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` - Current pipeline
- Linear ticket: AUX-11136

---

*Spec created by Claude Code for AUX-11136*
