# Pipeline Architecture: Vehicle Fitment Recommendations

## Overview

The v5.7 pipeline generates personalized vehicle part recommendations by combining:
1. **User vehicle data** (Year/Make/Model from registration)
2. **Behavioral intent** (views, carts, orders)
3. **Global popularity** (historical sales)

**Output**: 4 recommendations per user → ~450K users served

---

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           STEP 0: AUDIENCE                                   │
│  ingestion_unified_attributes → users_with_v1_vehicles (~475K)              │
│  Filter: email + v1_year + v1_make + v1_model all present                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        STEP 1: DATA PREPARATION                              │
│                                                                              │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────────┐   │
│  │ staged_events    │    │ sku_prices       │    │ sku_image_urls       │   │
│  │ (Sep 1+ events)  │───▶│ (max observed)   │    │ (most recent https)  │   │
│  └────────┬─────────┘    └────────┬─────────┘    └──────────┬───────────┘   │
│           │                       │                         │               │
│           │                       ▼                         │               │
│           │              ┌──────────────────┐               │               │
│           │              │ eligible_parts   │◀──────────────┘               │
│           │              │ (fitment+filters)│                               │
│           │              └────────┬─────────┘                               │
│           │                       │                                         │
│           │    ┌──────────────────┴──────────────────┐                      │
│           │    │         7 QUALITY FILTERS           │                      │
│           │    │  • Price ≥ $50                      │                      │
│           │    │  • HTTPS image required             │                      │
│           │    │  • No refurbished items             │                      │
│           │    │  • No service SKUs (EXT-*, etc)     │                      │
│           │    │  • No commodity parts (gaskets)     │                      │
│           │    │  • UNKNOWN parts only if ≥$3000     │                      │
│           │    │  • Vehicle must have ≥4 parts       │                      │
│           │    └─────────────────────────────────────┘                      │
│           │                                                                 │
│           │              ┌──────────────────┐                               │
│           └─────────────▶│import_orders_    │ (single scan: popularity +   │
│                          │filtered          │  purchase exclusion windows)  │
│                          └──────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          STEP 2: SCORING                                     │
│                                                                              │
│  ┌─────────────────────────────┐    ┌─────────────────────────────────────┐ │
│  │       INTENT SCORE          │    │        POPULARITY SCORE             │ │
│  │                             │    │                                     │ │
│  │  order → LOG(1+n) × 20     │    │  LOG(1 + total_orders) × 2          │ │
│  │  cart  → LOG(1+n) × 10     │    │                                     │ │
│  │  view  → LOG(1+n) × 2      │    │  Sources:                           │ │
│  │                             │    │  • Jan-Aug 2025: import_orders      │ │
│  │  (strongest signal wins)    │    │  • Sep 1+ 2025: unified_events      │ │
│  └─────────────────────────────┘    └─────────────────────────────────────┘ │
│                    │                              │                          │
│                    └──────────────┬───────────────┘                          │
│                                   ▼                                          │
│                    ┌─────────────────────────────┐                           │
│                    │  final_score = intent +     │                           │
│                    │               popularity    │                           │
│                    └─────────────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       STEP 3: RECOMMENDATION SELECTION                       │
│                                                                              │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────────────┐    │
│  │ 3.1 PURCHASE    │   │ 3.2 SCORED      │   │ 3.3 VARIANT DEDUP +     │    │
│  │ EXCLUSION       │──▶│ RECOMMENDATIONS │──▶│ DIVERSITY FILTER        │    │
│  │ (365d suppress) │   │ (join all data) │   │                         │    │
│  └─────────────────┘   └─────────────────┘   │ • Strip color variants  │    │
│                                               │   (140061B → 140061)    │    │
│                                               │ • Max 2 per PartType    │    │
│                                               └───────────┬─────────────┘    │
│                                                           │                  │
│                                                           ▼                  │
│                        ┌─────────────────┐   ┌─────────────────────────┐    │
│                        │ 3.5 PIVOT TO    │◀──│ 3.4 TOP 4 SELECTION     │    │
│                        │ WIDE FORMAT     │   │ (users with ≥4 options) │    │
│                        │ (1 row/user)    │   └─────────────────────────┘    │
│                        └────────┬────────┘                                   │
└─────────────────────────────────┼───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       STEP 4: DEPLOYMENT (Optional)                          │
│                                                                              │
│  temp_holley_v5_7.final_vehicle_recommendations                              │
│                         │                                                    │
│                         ▼ (if deploy_to_production = TRUE)                   │
│  company_1950_jp.final_vehicle_recommendations + dated backup                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Tables (Intermediate)

| Table | Purpose | Clustered By |
|-------|---------|--------------|
| `users_with_v1_vehicles` | Audience with email + YMM | user_id |
| `staged_events` | Behavioral events (Sep 1+) | user_id, sku |
| `sku_prices` | Max observed price per SKU | sku |
| `sku_image_urls` | Most recent HTTPS image | sku |
| `eligible_parts` | Fitment catalog post-filters | make, model, year, sku |
| `import_orders_filtered` | Orders for popularity + exclusion | sku, email_lower |
| `dedup_intent` | User×SKU intent scores | user_id, sku |
| `sku_popularity_324d` | Global SKU popularity | sku |
| `scored_recommendations` | All scores joined | user_id |
| `diversity_filtered` | After variant dedup + parttype cap | user_id |
| `ranked_recommendations` | Top 4 per user | user_id |
| `final_vehicle_recommendations` | Wide format output | email_lower |

---

## Scoring Algorithm

### Intent Score (User×SKU)
Hierarchical - strongest signal wins:
```
order: LOG(1 + order_count) × 20  ← ~13.8 for 1 order
cart:  LOG(1 + cart_count)  × 10  ← ~6.9 for 1 cart
view:  LOG(1 + view_count)  × 2   ← ~1.4 for 1 view
```

### Popularity Score (Global)
```
LOG(1 + total_orders) × 2
```
Range: 0 to ~12 for most popular items

### Final Score
```
final_score = intent_score + popularity_score
```
- Pure popularity: 0-12
- Has intent: 12-90+
- Most users get popularity-only recommendations

---

## Time Windows

| Window | Start | End | Purpose |
|--------|-------|-----|---------|
| Intent | Sep 1, 2025 (fixed) | CURRENT_DATE | Recent behavior |
| Historical Popularity | Jan 10, 2025 | Aug 31, 2025 | Pre-Sep orders |
| Purchase Exclusion | CURRENT_DATE - 365d | CURRENT_DATE | Don't re-recommend |

**Why Sep 1 is fixed**: Ensures consistent boundary between historical (import_orders) and recent (unified_events) data sources.

---

## Variant Deduplication

Two-step regex to handle color variants:
```sql
-- Step 1: Strip explicit suffixes
REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', '')

-- Step 2: Strip color code only when preceded by digit
REGEXP_REPLACE(result, r'([0-9])[BRGP]$', r'\1')
```

**Examples**:
- `140061B` → `140061` (color variant)
- `SNIPER` → `SNIPER` (not a variant - no digit before suffix)
- `ABC-KIT` → `ABC` (kit suffix)

---

## Quality Filters

### 1. Price Filter
- Minimum: $50
- Fallback: Use $50 if price unknown (configurable)

### 2. Image Filter
- Must have HTTPS image URL
- Protocol-relative URLs converted: `//cdn.` → `https://cdn.`

### 3. Product Exclusions
- Refurbished items (via Tags)
- Service SKUs: `EXT-*`, `GIFT-*`, `WARRANTY-*`, `SERVICE-*`, `PREAUTH-*`
- Commodity parts: Gaskets, Decals, Keys, Washers, Clamps, most Bolts/Caps
- UNKNOWN parts under $3000

### 4. Diversity Filter
- Max 2 SKUs per PartType per user
- Prevents recommending 4 carburetors

### 5. Vehicle Eligibility
- Minimum 4 eligible parts per YMM combination
- Ensures users can receive full 4 recommendations

---

## Tuning Knobs

All configurable via DECLARE statements at top of SQL:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `min_price` | 50.0 | Minimum product price |
| `max_parttype_per_user` | 2 | Diversity cap |
| `required_recs` | 4 | Recommendations per user |
| `purchase_window_days` | 365 | Suppression window |
| `allow_price_fallback` | TRUE | Use min_price when unknown |
| `deploy_to_production` | TRUE | Auto-deploy to prod |

---

## Performance Optimizations (v5.7)

1. **Single import_orders scan**: Consolidated popularity + exclusion into one table
2. **String pre-filter before PARSE_DATE**: `ORDER_DATE LIKE '%2025%'` for partition pruning
3. **Pre-cast v1_year to INT64**: Done once in Step 0, reused in joins
4. **Clustering**: All tables clustered on join keys
5. **EXISTS vs JOIN**: `EXISTS (SELECT 1...)` for existence checks (no row multiplication)

---

## Validation Checkpoints

Built-in validation after each step:

| Step | Check | Expected |
|------|-------|----------|
| 0 | User count | ≥400K |
| 1 | Event count | ≥100K |
| 1.3 | Eligible parts | ≥1K |
| Final | Unique users | ≥400K |
| Final | Duplicates | 0 |
| Final | Min price | ≥$50 |

Run full QA: `bq query < sql/validation/qa_checks.sql`

---

## Related Documentation

- [BigQuery Schema](bigquery_schema.md) - Table schemas and gotchas
- [Release Notes](release_notes.md) - Version history
- [Pipeline Run Stats](pipeline_run_stats.md) - Historical runs
