# Holley Recommendations - Release Notes

## V5.18 (February 18, 2026)

**Dataset**: `auxia-reporting.temp_holley_v5_18`
**Script**: `sql/recommendations/v5_18_fitment_recommendations.sql`

### Summary

Fitment-only + popularity-only pipeline. All 4 slots are vehicle-specific fitment products. Scoring simplified to orders-based popularity with per-product 3-tier fallback (segment → make → global). No intent scoring, no universal candidates.

### Why

- Client flagged universal (non-fitment) parts appearing for a golf cart
- Supervisor directed simplifying scoring to orders-only popularity
- A/B test on v5.17 showed positive uplift and conversion

### Changes from V5.17

| Parameter | V5.17 | V5.18 | Why |
|-----------|-------|-------|-----|
| Candidates | Fitment + Universal | **Fitment only** | Client feedback: no non-fitment parts |
| Scoring | Intent + Popularity | **Popularity only** | Simplify to orders-based signal |
| `pop_hist_start` | Apr 16, 2025 | **Jan 1, 2024** | 14 more months of history for better popularity signals |
| `min_price` | $50 | **$50** | Unchanged |
| `min_required_recs` | 4 | **3** | Include users with 3+ fitment parts |
| `max_parttype_per_user` | 999 | **2** | Force category diversity |
| User filter | All fitment users | **All fitment users** | Email consent deferred to QA layer |
| Output columns | Standard | **+ engagement_tier, fitment_count** | Post-hoc analysis |

### NOT Changed

- 3-tier popularity fallback (v5.17's best feature)
- Sep 1 boundary, variant dedup, commodity exclusions
- staged_events extracts all event types (views/carts/orders for price/image data)
- Popularity built from VFU user orders only (not all 3M users)
- Production deployment workflow

### Scoring

```sql
-- Popularity-only, per-product fallback (falls through if product has no data at tier)
final_score = CASE
  WHEN segment_orders >= 5 AND segment_popularity_score IS NOT NULL
    THEN segment_popularity_score                            -- weight 10.0
  WHEN make_orders >= 20 AND make_popularity_score IS NOT NULL
    THEN make_popularity_score                               -- weight 8.0
  ELSE COALESCE(global_popularity_score, 0)                  -- weight 2.0
END
```

### New Columns in Output

| Column | Values |
|--------|--------|
| `engagement_tier` | 'hot' (has order event since Sep 1) or 'cold' (no recent orders) |
| `fitment_count` | 3 or 4 (number of recs per user) |

### Schema Notes

- `rec4_*` columns may be NULL for users with only 3 fitment recs
- `rec1_type` through `rec4_type` always 'fitment' (kept for backward compatibility)

### Validation Criteria

- >= 400K users
- 0 duplicates
- Prices >= $50
- No user has >2 of same PartType
- fitment_count is 3 or 4
- 0 universal products
- Score floor > 0 (per-product fallback ensures all recs scored; max ~40)

---

## V5.17 (January 7, 2026)

**Dataset**: `auxia-reporting.temp_holley_v5_17`
**Script**: `sql/recommendations/v5_17_vehicle_fitment_recommendations.sql`

### Summary

3-tier popularity fallback to reduce global fallback from 24% to 2%.

| Tier | Threshold | Weight | V5.16 | V5.17 |
|------|-----------|--------|-------|-------|
| Segment (make/model) | ≥5 orders | 10.0 | 76% | 87% |
| Make (new) | ≥20 orders | 8.0 | - | 11% |
| Global | fallback | 2.0 | 24% | 2% |

### Problem Solved

In V5.16, **24% of users (120K)** had sparse make/model data and fell back to generic global popularity. These users got less relevant recommendations.

### V5.17 Solution

Added intermediate **make-level** fallback:
- Users with sparse FORD/MUSTANG data now get FORD-wide popularity
- More relevant than random global products
- 54K users now use make-level instead of global

### Backtest Results

| Metric | V5.16 | V5.17 | Change |
|--------|-------|-------|--------|
| Match rate | 0.35% | 0.38% | +7% |
| Segment users | 381K (76%) | 436K (87%) | +14% |
| Global users | 120K (24%) | 12K (2%) | **-90%** |

### Fallback Logic

```sql
CASE
  WHEN segment_orders >= 5 THEN segment_popularity_score
  WHEN make_orders >= 20 THEN make_popularity_score  -- NEW
  ELSE global_popularity_score
END
```

### New Tables

| Table | Purpose |
|-------|---------|
| `make_popularity` | Products ranked by make (aggregated across models) |

### New Columns in Output

| Column | Values |
|--------|--------|
| `rec1_pop_source` | 'segment', 'make', or 'global' |

---

## V5.16 (January 7, 2026)

**Dataset**: `auxia-reporting.temp_holley_v5_16`
**Script**: `sql/recommendations/v5_16_vehicle_fitment_recommendations.sql`

### Summary

Segment-based popularity ranking. Products ranked by what users with the **same vehicle (make/model)** buy, instead of global popularity.

### Key Changes

| Aspect | V5.15 | V5.16 |
|--------|-------|-------|
| Popularity | Global (all users) | Segment (same make/model) |
| Scoring | `LOG(1 + global_orders) * 2` | `LOG(1 + segment_orders) * 10` |
| Fallback | N/A | Global popularity if segment is sparse |

### Backtest Results

| Metric | V5.15 | V5.16 | Change |
|--------|-------|-------|--------|
| Match rate | 7.0% | 9.3% | **+32%** |
| Fitment matches | 50 | 84 | **+68%** |

### Pipeline Structure

1. **Fitment products** - Match user's YMM, scored by segment popularity
2. **Universal products** - Top 500, scored by global popularity
3. **Both compete** - Top 4 by `final_score = intent_score + popularity_score`

### New Tables

| Table | Purpose |
|-------|---------|
| `segment_popularity` | Products ranked by make/model segment |
| `global_popularity_fallback` | Fallback for sparse segments |

### New Columns in Output

| Column | Purpose |
|--------|---------|
| `rec1_pop_source` | 'segment' or 'global' - tracks scoring source |
| `rec2_pop_source`, etc. | Same for slots 2-4 |

---

## V5.15 (January 2026)

**Dataset**: `auxia-reporting.temp_holley_v5_15`
**Script**: `sql/recommendations/v5_15_vehicle_fitment_recommendations.sql`

### Summary

Added Universal products (top 500) alongside Fitment products. Both pools compete for 4 recommendation slots.

### Investigation Finding

Initial backtest claimed +162% improvement, but re-investigation showed only **+16%** improvement over V5.12. Root cause: Universal products have ~20% higher popularity scores, displacing fitment products.

See: `docs/v5_15_investigation_summary.md`

---

## CF Analysis - SKIPPED (January 7, 2026)

**Decision**: Do not implement collaborative filtering.

### Analysis Summary

Investigated "users who bought X also bought Y" as improvement strategy.

| Approach | Match Rate | Notes |
|----------|------------|-------|
| V5.16 Baseline | 9.01% | Current |
| V5.16 + CF (Reserved Slot) | 9.07% | **+0.06%** - not worth it |
| V5.16 + CF (Hybrid Score) | 7.45% | **Worse** - CF displaces segment items |

### Why CF Doesn't Help

1. Only 18% are repeat buyers (CF only applies to them)
2. Data sparsity - need 3+ co-purchases for valid signal
3. Long-tail distribution - purchases spread across 4,500+ SKUs

**Conclusion**: +0.06% gain doesn't justify complexity. Focus on other improvements.

See: `docs/cf_analysis_2026_01_07.md`

---

## V5.7 (December 21, 2025)

**Dataset**: `auxia-reporting.temp_holley_v5_7`
**Script**: `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql`

### Summary

Performance optimizations and bug fixes based on code review. No changes to scoring algorithm or business logic.

### Bug Fixes

#### 1. Variant Dedup Regex Fix (Critical)

**Problem**: The v5.6 regex `[BRGP]$` stripped trailing B/R/G/P from ALL SKUs, incorrectly collapsing 7,711 SKUs where these letters are part of the product name (e.g., `0-76650HB` → `0-76650H`).

**Investigation**: Analyzed 11,364 SKUs ending with B/R/G/P:
| Pattern | Count | Example | Action |
|---------|-------|---------|--------|
| Letter+Letter (HB, GR, LG) | 7,711 | `0-76650HB` | DO NOT strip |
| Number+Letter | 2,790 | `RA003B`, `2021G` | Strip (color variant) |
| Dash+Letter | 857 | `171097-B` | Strip (color variant) |

**Fix**: Two-step regex that only strips B/R/G/P when preceded by a digit:
```sql
REGEXP_REPLACE(
  REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', ''),
  r'([0-9])[BRGP]$', r'\1'
)
```

#### 2. QA Validation Threshold Mismatch

**Problem**: Pipeline uses `min_price = $50` but QA validation checked for `>= $20`.

**Fix**: Validation now uses the declared `@min_price` variable for consistency.

### Performance Improvements

#### 1. Consolidated import_orders Scan

**Problem**: `import_orders` table was scanned twice:
- Step 2.2: Historical popularity calculation
- Step 3.1: Purchase exclusion lookup

**Fix**: New Step 1.5 scans `import_orders` once and creates `import_orders_filtered` with flags:
- `is_popularity_window` (Jan 10 - Aug 31, 2025)
- `is_exclusion_window` (365 days from today)

**Impact**: ~50% reduction in import_orders scan cost.

#### 2. Pre-filter Before PARSE_DATE

**Problem**: `SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)` on every row prevented partition pruning.

**Fix**: Added string pre-filter before parsing:
```sql
WHERE ORDER_DATE LIKE '%2024%' OR ORDER_DATE LIKE '%2025%'
```

**Impact**: Enables partition pruning if table is partitioned, reduces rows processed.

#### 3. Pre-cast v1_year in Step 0

**Problem**: `SAFE_CAST(v1_year AS INT64)` repeated in every join with `eligible_parts`.

**Fix**: Added `v1_year_int` column in Step 0, used directly in joins.

**Impact**: Minor CPU reduction, cleaner join conditions.

### New Features

#### 1. Production Deployment Flag

Added `deploy_to_production` flag (default `FALSE`) to control production deployment.

```sql
DECLARE deploy_to_production BOOL DEFAULT FALSE;
```

**Usage**: Set to `TRUE` when ready to deploy to production.

#### 2. Pipeline Version Tracking

Added `pipeline_version` column to final output table.

```sql
SELECT ..., 'v5.7' AS pipeline_version FROM ...
```

**Usage**: Enables tracking which pipeline version generated recommendations.

### Schema Changes

**New column in `final_vehicle_recommendations`:**
| Column | Type | Description |
|--------|------|-------------|
| `pipeline_version` | STRING | Pipeline version (e.g., "v5.7") |

**New column in `users_with_v1_vehicles`:**
| Column | Type | Description |
|--------|------|-------------|
| `v1_year_int` | INT64 | Pre-cast year for joins |

**New intermediate table:**
| Table | Purpose |
|-------|---------|
| `import_orders_filtered` | Consolidated import_orders with window flags |

### Migration Notes

- No breaking changes to final output schema (new column is additive)
- v5.6 and v5.7 can run in parallel for comparison
- Production deployment is opt-in via flag

### Comparison Queries

```sql
-- Compare user counts
SELECT 'v5.6' AS version, COUNT(*) AS users
FROM `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations`
UNION ALL
SELECT 'v5.7', COUNT(*)
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations`;

-- Compare recommendation stability
WITH comparison AS (
  SELECT
    v6.email_lower,
    v6.rec_part_1 AS v6_rec1, v7.rec_part_1 AS v7_rec1,
    v6.rec_part_2 AS v6_rec2, v7.rec_part_2 AS v7_rec2,
    v6.rec_part_3 AS v6_rec3, v7.rec_part_3 AS v7_rec3,
    v6.rec_part_4 AS v6_rec4, v7.rec_part_4 AS v7_rec4
  FROM `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations` v6
  JOIN `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations` v7
    USING (email_lower)
)
SELECT
  COUNT(*) AS total_users,
  COUNTIF(v6_rec1 = v7_rec1 AND v6_rec2 = v7_rec2 AND v6_rec3 = v7_rec3 AND v6_rec4 = v7_rec4) AS identical,
  COUNTIF(v6_rec1 != v7_rec1) AS diff_rec1,
  COUNTIF(v6_rec2 != v7_rec2) AS diff_rec2,
  COUNTIF(v6_rec3 != v7_rec3) AS diff_rec3,
  COUNTIF(v6_rec4 != v7_rec4) AS diff_rec4
FROM comparison;

-- Check variant dedup impact (SKUs that would have been incorrectly collapsed in v5.6)
SELECT v7.rec_part_1, v6.rec_part_1
FROM `auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations` v7
JOIN `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations` v6
  USING (email_lower)
WHERE v7.rec_part_1 != v6.rec_part_1
  AND REGEXP_CONTAINS(v7.rec_part_1, r'[A-Z][BRGP]$')  -- Letter+Letter ending
LIMIT 20;
```

---

## V5.6 (December 2025)

**Dataset**: `auxia-reporting.temp_holley_v5_4`
**Script**: `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql`

### Summary

Production pipeline implementing V5.3 hybrid LOG spec with:
- LOG-scaled intent scoring (orders > carts > views)
- Hybrid popularity (import_orders + unified_events)
- Diversity filter (max 2 per PartType)
- Variant deduplication
- $50 minimum price floor
- Commodity PartType exclusions

### Key Metrics

| Metric | Value |
|--------|-------|
| Users | ~456K |
| Avg price | $337 |
| Min price | $50 |
| Cold-start | ~98% |

---

## V5.3 - V5.5 (November 2025)

Development iterations leading to V5.6. See `specs/v5_6_recommendations.md` for full specification.
