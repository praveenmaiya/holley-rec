# V5.6 Vehicle Fitment Recommendations

**Status**: ✅ Completed
**Version**: 5.6
**Last Run**: December 2025
**Output**: `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations`

---

## Problem Statement

Generate personalized product recommendations for Holley automotive customers to drive email campaign engagement. Each user should receive 4 product recommendations that:
- Fit their registered vehicle
- Reflect their behavioral intent (views, carts, orders)
- Are quality products (not refurbished, proper price/image)
- Have category diversity

## Solution

SQL-based recommendation pipeline using hybrid scoring:
- **Intent Score**: 90-day user behavior (LOG-scaled)
- **Popularity Score**: 324-day order volume (hybrid historical + recent)
- **Final Score**: Intent + Popularity (0-90 range)

## Input Data

| Source | Table | Purpose |
|--------|-------|---------|
| Users | `ingestion_unified_attributes_schema_incremental` | User profiles, vehicle data |
| Events | `ingestion_unified_schema_incremental` | Views, carts, orders |
| Fitment | `vehicle_product_fitment_data` | Vehicle → SKU mapping |
| Catalog | `import_items` | PartType for diversity |
| Tags | `import_items_tags` | Refurbished filter |
| History | `import_orders` | Historical orders (pre-Sep 2025) |

## Output

```sql
final_vehicle_recommendations (450K rows):
  email_lower, year, make, model,
  rec_part_1, rec1_price, rec1_score, rec1_image,
  rec_part_2, rec2_price, rec2_score, rec2_image,
  rec_part_3, rec3_price, rec3_score, rec3_image,
  rec_part_4, rec4_price, rec4_score, rec4_image
```

## Scoring Formula

```
final_score = intent_score + popularity_score

Intent (90-day, LOG-scaled):
  - Orders: LOG(1 + n) × 20
  - Carts:  LOG(1 + n) × 10
  - Views:  LOG(1 + n) × 2
  - None:   0 (cold-start)

Popularity (324-day hybrid):
  - LOG(1 + orders) × 2
```

## Filters

1. Price ≥ $20
2. Has HTTPS image
3. Not refurbished (`Tags != 'Refurbished'`)
4. Not service SKU (EXT-, GIFT-, WARRANTY-, SERVICE-, PREAUTH-)
5. Fits user's vehicle
6. Not purchased in last 365 days
7. Max 2 per PartType (diversity)

## Pipeline Steps

| Step | Output Table | Rows |
|------|--------------|------|
| 0 | users_with_vehicles | ~500K |
| 1.1 | staged_events | ~5M |
| 1.2 | sku_prices | ~25K |
| 1.3 | sku_images | ~29K |
| 1.4 | eligible_parts | ~10K |
| 2.1 | user_intent_90d | ~200K |
| 2.2 | popularity_324d | ~10K |
| 3 | final_vehicle_recommendations | ~450K |

## Validation Criteria

| Check | Expected |
|-------|----------|
| Users | ~450,000 |
| Recs per user | 4 (exactly) |
| Duplicate SKUs | 0 |
| Price range | $20 - $2,500 |
| HTTPS images | 100% |
| Refurbished | 0 |
| Score ordering | rec1 ≥ rec2 ≥ rec3 ≥ rec4 |

## Known Issues

1. **98% cold-start**: Most users have no 90-day intent → popularity-driven
2. **Diversity edge case**: ~500 users violate max-2-per-PartType for `Vehicle Tuning Flash Tool`
3. **Cart timing bug**: Cart events fire after purchase (workaround: presence-based matching)

## Files

- **SQL**: `sql/recommendations/v5_6_vehicle_fitment_recommendations.sql`
- **Validation**: `sql/validation/qa_checks.sql`
- **Architecture**: `agent_docs/architecture.md`
- **BQ Patterns**: `agent_docs/bigquery.md`

## Run Commands

```bash
# Execute pipeline
bq query --use_legacy_sql=false \
  < sql/recommendations/v5_6_vehicle_fitment_recommendations.sql

# Validate output
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql

# Quick check
bq query --use_legacy_sql=false '
SELECT COUNT(*) as users,
       ROUND(AVG(rec1_price), 2) as avg_price,
       ROUND(AVG(rec1_score), 2) as avg_score
FROM `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations`'
```

## Metrics (Production Run)

| Metric | Value |
|--------|-------|
| Users | 446,574 |
| Price Range | $20.21 - $2,549.95 |
| Avg Price | $210.74 |
| Score Range | 1.39 - 18.32 |
| Cold-Start % | 98.24% |
| Unique SKU Combos | 1,651 |

---

*Spec completed November 2025. SQL developed by ChatGPT, reviewed by Claude.*
