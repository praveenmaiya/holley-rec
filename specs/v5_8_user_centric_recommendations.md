# V5.8 User-Centric Recommendations

**Date**: 2026-01-06
**Status**: SPEC READY FOR IMPLEMENTATION
**Author**: Claude Code (with user interview)
**Linear Ticket**: AUX-11434

---

## Executive Summary

The current recommendation system has a **0.04% match rate** (10 out of 185,882 purchases matched recommendations). This spec defines v5.8, a fundamental redesign moving from vehicle-fitment-only to a user-centric approach with segment popularity, vehicle generations, multi-vehicle support, and co-purchase signals.

---

## Analysis Findings (Pre-Interview)

### The Core Problem

| Category | Purchase Count | % |
|----------|----------------|---|
| No vehicle data (can't recommend) | 145,700 | **78.4%** |
| Doesn't fit vehicle (cross-vehicle) | 32,002 | **17.2%** |
| Fits vehicle, not recommended | 8,170 | **4.4%** |
| Matched recommendation | 10 | **0.01%** |

### Key Statistics

- **Only 16.4%** of purchasers are in recommendation table (14,491 of 88,163)
- **Only 3.16%** of rec users have ever purchased anything
- **60.8%** of purchased SKUs have NO fitment data
- **Top 50 purchased products**: only 6 are in our recommendations
- **112,796 users (22.5%)** have a second vehicle (v2) registered

### Current Algorithm Failure

```
WHAT WE RECOMMEND (BROKEN):
1969 Camaro ──► LFRB155 (fits 3,213 vehicles, 13 Camaro purchases)
1970 Camaro ──► LFRB155 (same generic product)
1967 Malibu ──► LFRB155 (same generic product)

WHAT USERS ACTUALLY BUY:
1969 Camaro ──► C6051-69 (Console Latch, 75 purchases, NOT IN FITMENT)
1970 Camaro ──► Vehicle-specific parts
1967 Malibu ──► Vehicle-specific parts
```

---

## Design Decisions (From Interview)

### Scope & Focus

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Target users | Vehicle users only (22%) | Focus before expanding |
| Non-vehicle fallback | No fallback in v5.8 | Keep scope manageable |
| Phasing | All features at once | Fast iteration mindset |

### Algorithm Design

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Slot structure | Keep 4 slots | No template changes needed |
| Tiered approach | Slots 1-2 fitment, 3-4 segment-popular | Balance safety + discovery |
| Diversity | Max 2 per PartType | Ensure variety |

### Scoring Formula

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Segment popularity | Replace global with per-segment | Core fix |
| Narrow-fit bonus | +10/+7/+3/+1/0 tiers | As originally proposed |
| Co-purchase boost | `LOG(1 + count) * 3` (proportional) | Leverage strong signal |

### Multi-Vehicle Handling

| Decision | Choice | Rationale |
|----------|--------|-----------|
| v2 vehicle support | Yes, use existing v2 data | 112K users have v2 |
| Vehicle priority | User preference (recency) | Most relevant vehicle |
| Recency window | 90 days | Balanced signal |

### Sparsity Handling

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Vehicle generations | Hardcode for 100+ user models | Pool similar years |
| Sparse fitment | Generation fallback → segment-popular | Sequential approach |

### Validation

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary metric | Segment relevance score | Compare recs vs actual purchases |
| Threshold | Any improvement | Fast iteration |
| Architecture | Modular CTEs | Maintainable |

---

## Solution Architecture

### Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER CONTEXT                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ v1 Vehicle   │  │ v2 Vehicle   │  │ Purchase History     │  │
│  │ (primary)    │  │ (secondary)  │  │ (co-purchase signal) │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     VEHICLE PRIORITIZATION                       │
│  Use 90-day recency signal to determine primary vehicle          │
│  If recent v2 activity > v1 activity, prioritize v2              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     CANDIDATE GENERATION                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Tier 1: Fitment Products (slots 1-2)                     │   │
│  │ - Products that fit user's vehicle(s)                    │   │
│  │ - Expand to vehicle GENERATION if sparse                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Tier 2: Segment-Popular Products (slots 3-4)             │   │
│  │ - Products bought by users with same vehicle             │   │
│  │ - Includes products WITHOUT fitment data                 │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         SCORING                                  │
│                                                                  │
│  final_score = intent_score                                      │
│              + segment_popularity_score                          │
│              + narrow_fit_bonus                                  │
│              + co_purchase_boost                                 │
│                                                                  │
│  WHERE:                                                          │
│  - segment_popularity = LOG(1 + orders_by_vehicle_segment) * 10  │
│  - narrow_fit_bonus = {≤50: +10, ≤100: +7, ≤500: +3, ≤1000: +1} │
│  - co_purchase_boost = LOG(1 + co_purchase_count) * 3            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DIVERSITY & RANKING                           │
│  - Max 2 products per PartType                                   │
│  - Rank by final_score                                           │
│  - Output: 4 recommendations per user                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Detailed Scoring Formula

### Current (v5.7 - Broken)

```sql
popularity_score = LOG(1 + global_total_orders) * 2
final_score = intent_score + popularity_score
```

### New (v5.8 - Fixed)

```sql
-- Segment popularity: What do owners of THIS vehicle buy?
segment_popularity_score = LOG(1 + orders_by_this_vehicle_segment) * 10

-- Narrow fit bonus: Specific products get boost
narrow_fit_bonus = CASE
  WHEN vehicles_fit <= 50 THEN 10    -- Very specific
  WHEN vehicles_fit <= 100 THEN 7
  WHEN vehicles_fit <= 500 THEN 3
  WHEN vehicles_fit <= 1000 THEN 1
  ELSE 0                              -- Broad fitment
END

-- Co-purchase boost: Products bought with user's past purchases
co_purchase_boost = LOG(1 + max_co_purchase_count_with_user_products) * 3

-- Final score
final_score = COALESCE(intent_score, 0)
            + COALESCE(segment_popularity_score, 0)
            + COALESCE(narrow_fit_bonus, 0)
            + COALESCE(co_purchase_boost, 0)
```

---

## Vehicle Generation Mappings

### Definition

Vehicle generations group model years where parts are interchangeable. Example:
- **Mustang 1st Gen (1964-1973)**: Parts designed for 1967 Mustang fit 1968 Mustang
- **Camaro 1st Gen (1967-1969)**: Classic F-body years

### Implementation

Create generation mapping table for all models with 100+ users:

```sql
CREATE TABLE `auxia-reporting.temp_holley_v5_8.vehicle_generations` AS
SELECT * FROM UNNEST([
  -- Ford Mustang generations
  STRUCT('FORD' as make, 'MUSTANG' as model, 1964 as year_start, 1973 as year_end, '1st Gen' as generation),
  STRUCT('FORD', 'MUSTANG', 1974, 1978, '2nd Gen (Mustang II)'),
  STRUCT('FORD', 'MUSTANG', 1979, 1993, '3rd Gen (Fox Body)'),
  STRUCT('FORD', 'MUSTANG', 1994, 2004, '4th Gen (SN-95)'),
  STRUCT('FORD', 'MUSTANG', 2005, 2014, '5th Gen (S-197)'),
  STRUCT('FORD', 'MUSTANG', 2015, 2023, '6th Gen (S-550)'),

  -- Chevrolet Camaro generations
  STRUCT('CHEVROLET', 'CAMARO', 1967, 1969, '1st Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1970, 1981, '2nd Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1982, 1992, '3rd Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1993, 2002, '4th Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 2010, 2015, '5th Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 2016, 2024, '6th Gen'),

  -- Chevrolet Corvette generations
  STRUCT('CHEVROLET', 'CORVETTE', 1953, 1962, 'C1'),
  STRUCT('CHEVROLET', 'CORVETTE', 1963, 1967, 'C2'),
  STRUCT('CHEVROLET', 'CORVETTE', 1968, 1982, 'C3'),
  STRUCT('CHEVROLET', 'CORVETTE', 1984, 1996, 'C4'),
  STRUCT('CHEVROLET', 'CORVETTE', 1997, 2004, 'C5'),
  STRUCT('CHEVROLET', 'CORVETTE', 2005, 2013, 'C6'),
  STRUCT('CHEVROLET', 'CORVETTE', 2014, 2019, 'C7'),
  STRUCT('CHEVROLET', 'CORVETTE', 2020, 2024, 'C8'),

  -- Chevrolet C/K Trucks (C10, K10, etc.)
  STRUCT('CHEVROLET', 'C10', 1960, 1966, '1st Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10', 1967, 1972, '2nd Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10', 1973, 1987, '3rd Gen (C/K Square Body)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1960, 1966, '1st Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1967, 1972, '2nd Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1973, 1987, '3rd Gen (C/K Square Body)'),

  -- Chevrolet Chevelle generations
  STRUCT('CHEVROLET', 'CHEVELLE', 1964, 1967, '1st Gen (A-body)'),
  STRUCT('CHEVROLET', 'CHEVELLE', 1968, 1972, '2nd Gen (A-body)'),
  STRUCT('CHEVROLET', 'CHEVELLE', 1973, 1977, '3rd Gen (A-body/Laguna)')

  -- TODO: Add remaining models with 100+ users
]) AS gen
```

### Usage in Query

```sql
-- Expand segment to include generation peers
WITH generation_segment AS (
  SELECT
    u.email_lower,
    u.v1_year,
    u.v1_make,
    u.v1_model,
    g.year_start,
    g.year_end,
    g.generation
  FROM users u
  LEFT JOIN vehicle_generations g
    ON UPPER(u.v1_make) = g.make
    AND UPPER(u.v1_model) = g.model
    AND SAFE_CAST(u.v1_year AS INT64) BETWEEN g.year_start AND g.year_end
)
-- Use generation range for segment popularity when exact year has sparse data
```

---

## Implementation: Modular CTEs

### CTE Structure

```sql
WITH
-- ============================================
-- STEP 0: USER CONTEXT
-- ============================================
users_with_vehicles AS (
  -- Users with v1 vehicle data
  -- Include v2 if exists
  -- Add 90-day recency signal for vehicle priority
),

-- ============================================
-- STEP 1: VEHICLE GENERATIONS
-- ============================================
vehicle_generations AS (
  -- Hardcoded generation mappings
),

user_vehicles_with_generation AS (
  -- Join users to generations
  -- Expand to generation peers if needed
),

-- ============================================
-- STEP 2: SEGMENT POPULARITY
-- ============================================
segment_product_sales AS (
  -- What do owners of each vehicle segment buy?
  -- Include generation pooling for sparse segments
),

-- ============================================
-- STEP 3: CO-PURCHASE SIGNALS
-- ============================================
user_purchase_history AS (
  -- User's past purchases (last 365 days)
),

product_co_purchases AS (
  -- Products frequently bought together
  -- Minimum threshold: 20 co-purchases
),

user_co_purchase_boost AS (
  -- For each user, compute boost for products
  -- co-purchased with their past purchases
),

-- ============================================
-- STEP 4: FITMENT PRODUCTS
-- ============================================
fitment_products AS (
  -- Products that fit user's vehicle(s)
  -- Expand to generation if exact year has <2 products
),

fitment_breadth AS (
  -- How many vehicles does each product fit?
  -- For narrow-fit bonus calculation
),

-- ============================================
-- STEP 5: SEGMENT-POPULAR PRODUCTS
-- ============================================
segment_popular_products AS (
  -- Products bought by segment, regardless of fitment
  -- For slots 3-4
),

-- ============================================
-- STEP 6: SCORING
-- ============================================
scored_products AS (
  SELECT
    email_lower,
    sku,
    tier,  -- 'fitment' or 'segment_popular'
    intent_score,
    segment_popularity_score,
    narrow_fit_bonus,
    co_purchase_boost,
    (intent_score + segment_popularity_score + narrow_fit_bonus + co_purchase_boost) as final_score
  FROM ...
),

-- ============================================
-- STEP 7: DIVERSITY & RANKING
-- ============================================
ranked_with_diversity AS (
  -- Apply max 2 per PartType constraint
  -- Rank by final_score within tier
),

final_recommendations AS (
  -- Take top 2 from fitment tier
  -- Take top 2 from segment_popular tier
  -- Combine into 4 slots
)

SELECT * FROM final_recommendations
```

---

## Validation Queries

### Primary Metric: Segment Relevance Score

```sql
-- For each vehicle segment, compute overlap between
-- recommended products and actually purchased products
WITH segment_recs AS (
  SELECT
    v1_year, v1_make, v1_model,
    ARRAY_AGG(DISTINCT rec_part_1) as recs
  FROM recommendations
  GROUP BY 1, 2, 3
),
segment_purchases AS (
  SELECT
    r.v1_year, r.v1_make, r.v1_model,
    ARRAY_AGG(DISTINCT o.ITEM) as purchases
  FROM recommendations r
  JOIN orders o ON r.email_lower = LOWER(o.SHIP_TO_EMAIL)
  WHERE o.ORDER_DATE >= '2025-12-04'
  GROUP BY 1, 2, 3
)
SELECT
  sr.v1_year, sr.v1_make, sr.v1_model,
  ARRAY_LENGTH(sr.recs) as rec_count,
  ARRAY_LENGTH(sp.purchases) as purchase_count,
  (SELECT COUNT(*) FROM UNNEST(sr.recs) r WHERE r IN UNNEST(sp.purchases)) as overlap,
  ROUND(
    (SELECT COUNT(*) FROM UNNEST(sr.recs) r WHERE r IN UNNEST(sp.purchases))
    / ARRAY_LENGTH(sr.recs) * 100, 2
  ) as relevance_score_pct
FROM segment_recs sr
JOIN segment_purchases sp USING (v1_year, v1_make, v1_model)
ORDER BY relevance_score_pct DESC
```

### Sanity Check: 1969 Camaro

```sql
-- Before: LFRB155 should NOT be top rec
-- After: C0AF-13788-A or C6TZ-8125-3K should be in top 3
SELECT rec_part_1, rec_part_2, rec_part_3, rec_part_4, COUNT(*)
FROM `auxia-reporting.temp_holley_v5_8.final_vehicle_recommendations`
WHERE v1_year = '1969' AND UPPER(v1_model) = 'CAMARO'
GROUP BY 1, 2, 3, 4
ORDER BY 5 DESC
LIMIT 5
```

### Comparison: Old vs New

```sql
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
  n.new_count - COALESCE(o.old_count, 0) as change
FROM old_recs o
FULL OUTER JOIN new_recs n ON o.sku = n.sku
ORDER BY ABS(COALESCE(n.new_count, 0) - COALESCE(o.old_count, 0)) DESC
LIMIT 20
```

---

## Files to Create

| File | Purpose | Status |
|------|---------|--------|
| `sql/recommendations/v5_8_vehicle_fitment_recommendations.sql` | Main pipeline with modular CTEs | TODO |
| `sql/recommendations/v5_8_vehicle_generations.sql` | Generation mapping data | ✅ CREATED |
| `sql/validation/v5_8_validation.sql` | Validation queries | TODO |

---

## Expected Improvements

### Before (v5.7)

| Metric | Value |
|--------|-------|
| Match rate | 0.04% (10/185,882) |
| Top 50 products in recs | 6 (12%) |
| Same rec for all Camaros | LFRB155 |

### After (v5.8) - Projected

| Metric | Target |
|--------|--------|
| Match rate | >0.04% (any improvement) |
| Top 50 products in recs | >10 (20%+) |
| Camaro top rec | Vehicle-specific part |
| Segment relevance score | Higher than v5.7 |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Sparse segment data | Generation pooling expands data |
| Co-purchase noise | Minimum 20 co-purchases threshold |
| Cold start for new users | Segment popularity as fallback |
| Performance | Pre-compute segment sales and co-purchases |
| Generation mapping incomplete | Start with top models, expand iteratively |

---

## Definition of Done

- [ ] Modular CTE pipeline created
- [ ] Vehicle generation mappings defined for 100+ user models
- [ ] Segment popularity scoring implemented
- [ ] Co-purchase boost implemented
- [ ] Tiered slot approach (2 fitment + 2 segment-popular)
- [ ] v2 vehicle support with recency prioritization
- [ ] Diversity constraint (max 2 per PartType)
- [ ] Validation shows segment relevance improvement
- [ ] 1969 Camaro test: No LFRB155 in top rec
- [ ] Deployed to production

---

## Related Documents

- `docs/recommendation_match_rate_analysis_2026_01_06.md` - Analysis findings
- `docs/SESSION_2026_01_06_match_rate_analysis.md` - Previous session
- `docs/algorithm_fitment_vs_sales_velocity_analysis_2026_01_04.md` - Root cause
- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` - Current pipeline

---

*Spec created 2026-01-06 via Claude Code interview process*
