# Holley Recommendations - Release Notes

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
