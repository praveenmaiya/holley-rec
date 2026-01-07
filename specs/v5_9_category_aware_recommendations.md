# V5.9: Category-Aware Recommendations

**Status**: Draft
**Author**: Claude + Praveen
**Date**: 2026-01-06
**Linear Ticket**: AUX-11437

---

## Problem Statement

V5.8 showed 0% match rate in backtesting. Even when users buy products that **fit their vehicle** and **exist in our catalog**, we recommend **completely unrelated products 84% of the time**.

**Example**: User interested in headlights (LFRB145) was recommended carburetors (0-80457S).

**Root Cause**: The algorithm doesn't consider product category. A user browsing headlights should get headlight recommendations, not carburetors.

---

## Solution: Category-Aware Scoring

### Key Changes from V5.8

| Component | V5.8 | V5.9 |
|-----------|------|------|
| Category matching | None | 50% of score based on category match |
| Intent recency | Sep 1 fixed boundary | Exponential decay (30-day half-life) |
| Recency window | ~4 months old data | 60-day rolling window |
| Slot allocation | Best 4 by score | 2 primary category + 2 related |
| Related products | None | Based on co-purchase patterns |

---

## Algorithm Design

### Step 1: Determine User's Primary Category

For each user, identify their primary interest category based on **most recent activity**:

```sql
-- Get most recent interaction per user
WITH recent_activity AS (
  SELECT
    user_id,
    sku,
    event_name,
    client_event_timestamp,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY client_event_timestamp DESC
    ) AS recency_rank
  FROM events
  WHERE DATE(client_event_timestamp) >= CURRENT_DATE - 60  -- 60-day window
    AND event_name IN ('Viewed Product', 'Added to Cart', 'Ordered Product')
),

user_primary_category AS (
  SELECT
    ra.user_id,
    i.PartType AS primary_category
  FROM recent_activity ra
  JOIN import_items i ON ra.sku = i.PartNumber
  WHERE ra.recency_rank = 1
    AND i.PartType IS NOT NULL
)
```

**Fallback**: If user has no activity in 60 days → cold start treatment (segment popular).

### Step 2: Intent Score with Exponential Decay

Apply 30-day half-life decay to all intent signals:

```sql
-- Decay formula: weight = 0.5 ^ (days_ago / 30)
intent_score = SUM(
  base_score * POW(0.5, DATE_DIFF(CURRENT_DATE, event_date, DAY) / 30.0)
)

-- Base scores by event type:
-- Viewed Product: 1 point
-- Added to Cart: 5 points
-- Ordered Product: -10 points (already converted, don't recommend again)
```

**Example**:
- View today = 1.0 points
- View 30 days ago = 0.5 points
- View 60 days ago = 0.25 points

### Step 3: Category Match Score (50% of total)

Products matching user's primary category get a significant boost:

```sql
category_score = CASE
  WHEN product.PartType = user.primary_category THEN 50
  WHEN product.PartType IS NULL THEN 25  -- Universal bucket
  ELSE 0  -- Non-matching category
END
```

**Design Decision**: 50% weight, not hard filter. A very popular non-category item could still rank if other signals are strong enough.

### Step 4: Related Category Detection (Co-Purchase)

For slots 3-4, find categories commonly purchased with user's primary category:

```sql
-- All-time co-purchase patterns
WITH co_purchases AS (
  SELECT
    o1.PartType AS category_a,
    o2.PartType AS category_b,
    COUNT(DISTINCT o1.order_id) AS co_purchase_count
  FROM orders o1
  JOIN orders o2 ON o1.order_id = o2.order_id AND o1.sku != o2.sku
  GROUP BY 1, 2
  HAVING co_purchase_count >= 50  -- Minimum threshold
)

-- For a user interested in "Headlights", related might be:
-- "Wiring Harness" (often bought together)
-- "Turn Signal" (lighting project)
```

**Fallback**: If co-purchase data is sparse → use segment popular for slots 3-4.

### Step 5: Segment Popularity (from V5.8)

Keep V5.8's segment-based popularity:

```sql
segment_popularity_score = LOG(1 + orders_by_same_vehicle_segment) * 10
```

### Step 6: Narrow-Fit Bonus (from V5.8)

Keep V5.8's narrow-fit bonus unchanged:

```sql
narrow_fit_bonus = CASE
  WHEN vehicles_fit <= 50 THEN 10
  WHEN vehicles_fit <= 100 THEN 7
  WHEN vehicles_fit <= 500 THEN 3
  WHEN vehicles_fit <= 1000 THEN 1
  ELSE 0
END
```

### Step 7: Final Scoring Formula

```sql
final_score =
    category_score                  -- 50 points if matches primary category
  + intent_score_decayed            -- Recency-weighted intent (0-20 typical)
  + segment_popularity_score        -- What similar owners buy (0-30 typical)
  + narrow_fit_bonus                -- Prefer specific parts (0-10)
  + co_purchase_boost               -- If product co-purchased with user's interests (0-5)
```

### Step 8: Slot Allocation

```sql
-- Slot 1-2: Primary category (highest scores within category)
-- Slot 3-4: Related categories OR segment popular fallback

SELECT
  user_id,
  -- Primary category slots
  MAX(CASE WHEN primary_rank = 1 THEN sku END) AS rec_part_1,
  MAX(CASE WHEN primary_rank = 2 THEN sku END) AS rec_part_2,
  -- Related category slots
  MAX(CASE WHEN related_rank = 1 THEN sku END) AS rec_part_3,
  MAX(CASE WHEN related_rank = 2 THEN sku END) AS rec_part_4
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY user_id, is_primary_category
      ORDER BY final_score DESC
    ) AS rank_within_type,
    CASE WHEN is_primary_category THEN rank_within_type END AS primary_rank,
    CASE WHEN NOT is_primary_category THEN rank_within_type END AS related_rank
  FROM scored_products
)
GROUP BY user_id
```

---

## Edge Cases & Fallbacks

### 1. Cold Start (No Recent Activity)

**Condition**: User has no events in last 60 days.

**Fallback**: Use segment popular - what do other owners of the same vehicle buy?

```sql
-- Cold start users get segment-popular products
WHERE user_id IN (SELECT user_id FROM cold_start_users)
ORDER BY segment_popularity_score DESC
```

### 2. No Products Fit Primary Category

**Condition**: User interested in "LED Headlights" but no LED headlights fit their 1969 Camaro.

**Fallback**: Move to their 2nd most interested category.

```sql
-- Get user's category preferences ranked
user_category_preferences AS (
  SELECT
    user_id,
    PartType,
    COUNT(*) AS interaction_count,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY COUNT(*) DESC) AS pref_rank
  FROM recent_activity ra
  JOIN import_items i ON ra.sku = i.PartNumber
  GROUP BY user_id, PartType
)
-- If primary (pref_rank=1) has no fitting products, try pref_rank=2
```

### 3. Sparse Co-Purchase Data

**Condition**: User's primary category has <50 co-purchase instances.

**Fallback**: Fill slots 3-4 with segment popular instead of co-purchased categories.

### 4. Missing PartType (Universal Bucket)

**Condition**: Product has NULL or empty PartType.

**Treatment**: Treat as "Universal" category. Gets 25 points (half of category match).

---

## Purchase Exclusion

**Rule**: Don't recommend products the user bought in the last 365 days.

```sql
-- Exclude recent purchases
WHERE sku NOT IN (
  SELECT sku
  FROM orders
  WHERE user_id = u.user_id
    AND order_date >= CURRENT_DATE - 365
)
```

**Rationale**: Automotive parts are durable. Users rarely need the same part twice in a year.

---

## Data Sources

| Data | Source Table | Purpose |
|------|--------------|---------|
| User events | `ingestion_unified_schema_incremental` | Intent signals, recency |
| Product categories | `import_items.PartType` | Category matching |
| Vehicle fitment | `vehicle_product_fitment_data` | Filter to fitting products |
| Orders | `import_orders` or events | Co-purchase, exclusion |
| Segment popularity | Derived from orders | Fallback scoring |

---

## Implementation Files

| File | Purpose |
|------|---------|
| `sql/recommendations/v5_9_vehicle_fitment_recommendations.sql` | Main pipeline (monolithic) |
| `sql/validation/v5_9_backtest.sql` | Backtest validation |
| `sql/validation/v5_9_validation.sql` | QA checks |

---

## Execution Plan

1. **Daily refresh**: Pipeline runs once per day
2. **Output table**: `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
3. **Estimated runtime**: ~10 minutes (similar to v5.8)

---

## Success Criteria

| Metric | Current (V5.8) | Target (V5.9) | Go/No-Go Threshold |
|--------|----------------|---------------|---------------------|
| Match rate | 0.04% | ≥5% | ≥1% (25x improvement) |
| Unique SKUs | 4,429 | Maintain or increase | ≥4,000 |
| Category alignment | 16% near-miss | ≥50% exact or near | ≥30% |

---

## Validation Plan

1. **Backtest**: Run Dec 15 → Jan 5 backtest using `v5_9_backtest.sql`
2. **Pass criteria**: Match rate ≥1%
3. **If pass**: Deploy to production
4. **If fail**: Iterate on scoring weights

---

## Rollback Plan

If v5.9 underperforms in production:

1. Re-run v5.8 pipeline to restore previous recommendations
2. Output table remains the same, just overwritten
3. No downstream changes needed

---

## Open Questions

All resolved during interview session.

---

## Appendix: Interview Summary

| Decision | Choice |
|----------|--------|
| Category priority | Same category first, 50% weight |
| Intent recency | 60-day window, 30-day half-life decay |
| Slot allocation | 2 primary + 2 related |
| Related detection | Co-purchase patterns (all-time data) |
| Cold start | Vehicle segment popular |
| No fit fallback | Fall to next category |
| Sparse co-purchase | Use segment popular |
| Missing PartType | Universal bucket (25 points) |
| Purchase exclusion | 365 days |
| Narrow-fit bonus | Keep v5.8 settings |
| Architecture | Monolithic single SQL |
| Refresh cadence | Daily |
| Validation | Backtest only |
| Go/no-go threshold | ≥1% match rate |
| Version | New v5.9 |

---

*Spec created 2026-01-06*
