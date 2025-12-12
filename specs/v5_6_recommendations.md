# V5.6 Vehicle Fitment Recommendations

**Status**: ✅ Production
**Version**: 5.6.2 (Dec 11 commodity filter)
**Last Run**: December 11, 2025
**Production Table**: `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
**Working Table**: `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations`

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

Intent (Sep 1 to current date, LOG-scaled):
  - Orders: LOG(1 + n) × 20
  - Carts:  LOG(1 + n) × 10
  - Views:  LOG(1 + n) × 2
  - None:   0 (cold-start)

Popularity (hybrid, split at Sep 1):
  - Historical: import_orders (Jan 10 - Aug 31)
  - Recent: unified_events (Sep 1 - current)
  - Score: LOG(1 + total_orders) × 2
```

**Note**: Sep 1, 2025 is the fixed boundary between historical order data and real-time event data.

## Filters

1. Price ≥ $50
2. Has HTTPS image
3. Not refurbished (`Tags != 'Refurbished'`)
4. Not service SKU (EXT-, GIFT-, WARRANTY-, SERVICE-, PREAUTH-)
5. Fits user's vehicle
6. Not purchased in last 365 days
7. Max 2 per PartType (diversity)
8. **Variant dedup**: Only one SKU per base product (color variants deduplicated)
9. **Commodity filter**: Exclude low-value parts (gaskets, decals, bolts, caps, etc.)

### Commodity Filter (v5.6.2)

Excludes low-value commodity parts that aren't compelling email recommendations:

| Pattern | Excluded | Whitelisted |
|---------|----------|-------------|
| `%Gasket%` | All | - |
| `%Decal%` | All | - |
| `%Key%` | All | - |
| `%Washer%` | All | - |
| `%Clamp%` | All | - |
| `%Bolt%` | Most | Engine Cylinder Head Bolt, Engine Bolt Kit |
| `%Cap%` | Most | Distributor Cap Kits, Wheel Hub Cap, Wheel Cap Set |
| `UNKNOWN` | Under $3,000 | $3,000+ (premium packages) |

### Variant Deduplication (v5.6.1)

Color/style variants are deduplicated using regex to extract base SKU:

```sql
REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2}|[BRGP])$', '') AS base_sku
```

Examples:
- `RA003B`, `RA003R`, `RA003G` → `RA003` (only highest scoring variant kept)
- `8326-AR`, `8326-BR` → `8326`
- `CI100038-A`, `CI100038-B` → `CI100038`

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
| Price range | $50 - $5,000 |
| HTTPS images | 100% |
| Refurbished | 0 |
| Commodity parts | 0 |
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

## Metrics (Production Run - Dec 11, 2025)

| Metric | Value |
|--------|-------|
| Users | 456,119 |
| Price Range | $50.57 - $5,165.95 |
| Avg Price | $465.87 |
| Duplicates | 0 |
| Variant duplicates | 0 (fixed in v5.6.1) |
| Commodity parts | 0 (filtered in v5.6.2) |

### Run History

| Date | Users | Notes |
|------|-------|-------|
| Dec 11, 2025 v3 | 456,119 | Commodity filter ($50 min, PartType exclusions) |
| Dec 11, 2025 v2 | 458,826 | Variant dedup fix |
| Dec 11, 2025 | 459,540 | Sep 1 intent window |
| Dec 2, 2025 | 458,859 | Initial production |

### Backups

- `final_vehicle_recommendations_2025_12_11_v3` - Current production (commodity filter)
- `final_vehicle_recommendations_2025_12_11_v2` - Variant dedup fix
- `final_vehicle_recommendations_2025_12_11` - Pre-fix run
- `final_vehicle_recommendations_2025_12_02` - Previous production

**Detailed run stats**: See `docs/pipeline_run_stats.md` for comparison analysis.

---

*Spec completed November 2025. SQL developed by ChatGPT, reviewed by Claude. Updated Dec 11, 2025 with commodity filter (v5.6.2).*
