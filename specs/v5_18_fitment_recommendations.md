# V5.18 Spec: Fitment-Only + Popularity-Only Scoring

**Date**: February 18, 2026
**Base**: `sql/recommendations/v5_17_vehicle_fitment_recommendations.sql` (1,105 lines)
**Target**: `sql/recommendations/v5_18_fitment_recommendations.sql`
**Dataset**: `auxia-reporting.temp_holley_v5_18`

## Problem

The v5.17 A/B revenue test showed positive uplift and conversion. However:
1. Client flagged universal (non-fitment) parts being recommended for a golf cart
2. Supervisor directed simplifying scoring to orders-only (remove view/cart intent)

## Solution

All 4 recommendation slots are vehicle-specific fitment products only, scored by orders-based popularity with the 3-tier fallback from v5.17.

## Changes Summary

| # | Change | Type |
|---|--------|------|
| 1 | All 4 slots fitment-only (remove universals) | Slot logic |
| 2 | Remove intent scoring (popularity-only) | Scoring |
| 3 | Extend historical window to Jan 1, 2024 | Data prep |
| 4 | Price floor $50 → $25 | Parameter |
| 5 | Min 3 recs per user (was 4) | Selection |
| 6 | Diversity cap 999 → 2 | Parameter |
| 7 | final_score = popularity_score only | Scoring |

## Parameters

```sql
pipeline_version = 'v5.18'
target_dataset = 'temp_holley_v5_18'
pop_hist_start = '2024-01-01'       -- was 2025-04-16 (14 more months of history)
min_price = 25.0                    -- was 50.0
max_parttype_per_user = 2           -- was 999
required_recs = 4                   -- max recs per user
min_required_recs = 3               -- was 4 (min recs to include user)
```

## Scoring

```sql
-- No intent. Popularity only with 3-tier fallback.
final_score = CASE
  WHEN segment_orders >= 5 THEN segment_popularity_score  -- weight 10.0
  WHEN make_orders >= 20   THEN make_popularity_score      -- weight 8.0
  ELSE global_popularity_score                             -- weight 2.0
END
```

## What Was Removed

- `universal_eligible_parts` table and all universal candidate logic
- `dedup_intent` table and all intent scoring
- `max_universal_products` parameter
- `intent_score`, `intent_type` columns from scored_recommendations

Note: `staged_events` still extracts all 5 event types (views, carts, orders) for price/image data. Only the intent *scoring* was removed.

## What Was Changed (Technical)

- ORDER_DATE year prefilter: replaced individual LIKE patterns with `REGEXP_EXTRACT(ORDER_DATE, r'\\b(20[0-9]{2})\\b') BETWEEN min_prefilter_year AND max_prefilter_year` in dynamic SQL — contiguous year range from pop_hist_start to current year, no gaps possible
- Per-generation quality gate (>= 4 eligible parts) documented as intentional, stricter than min_required_recs (3)
- Generation coverage QA monitor added (tracks total exclusions from all filters)

## What Was Kept (Unchanged)

- 3-tier popularity fallback (segment → make → global)
- Historical + recent data combination (Sep 1 boundary)
- staged_events extracts all event types (views/carts/orders for price/image)
- Variant dedup regex `([0-9])[BRGP]$`
- Commodity PartType exclusions
- Per-generation minimum of 4 eligible parts
- 365-day purchase exclusion window
- Production deployment workflow

## New Output Columns

| Column | Values | Purpose |
|--------|--------|---------|
| `engagement_tier` | 'hot' or 'cold' | Binary: has order event since Sep 1 vs no recent orders |
| `fitment_count` | 3 or 4 | Number of recommendations per user |

## Schema Notes

- `rec4_*` columns may be NULL for users with only 3 fitment recs
- `rec1_type` through `rec4_type` always 'fitment' (kept for backward compatibility)
- Downstream email templates must handle NULL rec4 gracefully

## Validation Criteria

- >= 250K users
- 0 duplicates
- Prices >= $25
- Max 2 per PartType per user
- fitment_count is 3 or 4
- 0 universal products
- Score floor >= 0 (popularity only; segment/make tiers can exceed 25)

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Audience shrinks (fewer users with 3+ fitment) | Price floor drop $50→$25 expands fitment pool |
| Same-vehicle users get identical recs | Acceptable; purchase exclusion provides differentiation |
| Stale products in popularity | Jan 1, 2024 start + recent orders; auto parts buying patterns are stable |
| 3-rec users have NULL rec4 | Downstream must handle NULL rec4 gracefully |

## Verification Plan

1. Dry run: `bq query --dry_run`
2. Execute pipeline to `temp_holley_v5_18`
3. Run updated `qa_checks.sql`
4. Coverage comparison: v5.17 vs v5.18 user counts
5. Fitment count distribution: expect 3 and 4
6. Score distribution: verify 0–25 range (no intent boost)
7. No universals: verify 0 rows with product_type = 'universal'
