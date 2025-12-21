# Holley Recommendation System Architecture

## Overview

Vehicle fitment recommendations for Holley automotive customers. Generates 4 personalized product recommendations per user based on:
- Registered vehicle (year, make, model)
- 90-day behavioral intent (views, carts, orders)
- 324-day product popularity

## Data Flow

```
Source Tables          Pipeline Steps              Output
─────────────────────────────────────────────────────────────
user_attributes  ──┐
                   ├──► Step 0: Audience     ──┐
unified_events   ──┤    (users + vehicles)    │
                   │                           │
fitment_data     ──┼──► Step 1: Fitment      ──┼──► final_vehicle_
                   │    (eligible SKUs)        │    recommendations
import_items     ──┤                           │    (450K users × 4)
                   ├──► Step 2: Scoring      ──┤
import_orders    ──┤    (intent+popularity)   │
                   │                           │
import_items_tags──┴──► Step 3: Selection   ──┘
                        (top 4, diversity)
```

## Scoring Algorithm

```
final_score = intent_score + popularity_score

Intent Score (90-day window):
  orders: LOG(1 + count) × 20    # max ~75 pts
  carts:  LOG(1 + count) × 10    # max ~45 pts
  views:  LOG(1 + count) × 2     # max ~17 pts
  none:   0                      # cold-start

Popularity Score (324-day hybrid):
  LOG(1 + total_orders) × 2      # max ~15 pts

Score Range: 0-90 (typical: 5-25)
```

## Pipeline Steps

| Step | Purpose | Output |
|------|---------|--------|
| **0** | Extract users with vehicle + email | `users_with_vehicles` |
| **1.1** | Single scan of events (price, image, SKU) | `staged_events` |
| **1.2** | Aggregate prices per SKU (≥$20) | `sku_prices` |
| **1.3** | Extract HTTPS images | `sku_images` |
| **1.4** | Apply 5 filters (price, image, refurbished, service, fitment) | `eligible_parts` |
| **2.1** | Calculate 90-day intent scores | `user_intent_90d` |
| **2.2** | Calculate 324-day popularity | `popularity_324d` |
| **3.1** | Exclude 365-day purchases | `user_purchases_365d` |
| **3.2** | Diversity filter (max 2 per PartType) | filtered candidates |
| **3.3** | Select top 4, pivot to columns | `final_vehicle_recommendations` |

## Filters Applied

1. **Price ≥ $50** - Exclude cheap accessories (raised from $20 in v5.6)
2. **HTTPS image** - Email client compatibility
3. **Not refurbished** - `Tags != 'Refurbished'`
4. **Not service SKU** - Exclude EXT-, GIFT-, WARRANTY-, SERVICE-, PREAUTH-
5. **Vehicle fitment** - Must fit user's registered vehicle
6. **Purchase exclusion** - Don't recommend already-purchased items (365d)
7. **Diversity** - Max 2 SKUs per PartType category

## Source Tables

| Table | Dataset | Purpose |
|-------|---------|---------|
| `ingestion_unified_attributes_schema_incremental` | company_1950 | User profiles, vehicle data |
| `ingestion_unified_schema_incremental` | company_1950 | Behavioral events |
| `vehicle_product_fitment_data` | data_company_1950 | Vehicle-to-SKU mapping |
| `import_items` | data_company_1950 | Product catalog (PartType) |
| `import_items_tags` | data_company_1950 | Refurbished filter |
| `import_orders` | data_company_1950 | Historical orders (pre-Sep 2025) |

## Output Schema

```sql
final_vehicle_recommendations:
  email_lower   STRING   -- User email
  year          STRING   -- Vehicle year
  make          STRING   -- Vehicle make
  model         STRING   -- Vehicle model
  rec_part_1    STRING   -- SKU #1
  rec1_price    FLOAT64  -- Price #1
  rec1_score    FLOAT64  -- Score #1
  rec1_image    STRING   -- Image URL #1
  -- (repeated for rec_part_2, 3, 4)
```

## Key Metrics

| Metric | Expected Value |
|--------|----------------|
| Users | ~450,000 |
| Recs per user | 4 (exactly) |
| Price range | $20 - $2,500 |
| Score range | 0 - 55 |
| Cold-start users | ~98% (popularity-driven) |
| Duplicate SKUs | 0 |
| HTTPS images | 100% |

## Known Bugs & Workarounds

See `agent_docs/bigquery.md` for event extraction gotchas and SQL patterns.
