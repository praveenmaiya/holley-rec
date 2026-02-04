# V5.18: Revenue A/B Test Pipeline

**Status**: ✅ Implemented
**Base Version**: V5.17 (3-Tier Segment Fallback)
**Script**: `sql/recommendations/v5_18_revenue_ab_test.sql`
**Dataset**: `auxia-reporting.temp_holley_v5_18`
**Deadline**: End of February 2026

---

## Problem Statement

Holley's contract renewal depends on proving that personalized recommendations drive measurable revenue. We need a one-time email blast A/B test where:

- **Treatment group** gets personalized vehicle-fitment recs (this pipeline)
- **Control group** gets static/generic content

**Current issue with V5.17**: Recs are good at relevance but lack structural guarantees needed for a revenue test:

| Problem | Evidence | Impact |
|---------|----------|--------|
| Category concentration | 28.5% of recs come from just 3 PartTypes | Users see similar products, low discovery |
| No guaranteed vehicle relevance | Top-4-by-score can be all universal | Defeats "personalized fitment" value prop |
| No audience segmentation | Can't analyze results by engagement level | Harder to prove ROI post-hoc |
| Limited universal pool | Only 500 products → ~322 PartTypes | Narrow discovery for non-fitment slots |

## Solution

Four targeted changes to V5.17 (no algorithm rewrites, no risky experiments):

1. **Reserved slot allocation**: 2 fitment + 2 universal (guarantee both vehicle relevance AND discovery)
2. **Strict diversity**: Max 2 per PartType (was unlimited in practice)
3. **Expanded universal pool**: 1000 products (was 500) → more category coverage
4. **Engagement tier tagging**: Classify users as hot/warm/cold for post-hoc revenue segmentation

### What We Are NOT Changing

These were tested in prior versions and proven critical:

| Feature | Why it stays |
|---------|-------------|
| Intent weights (20/10/2) | Removing was -34% in V5.9 |
| 3-tier popularity fallback (segment → make → global) | V5.17's best feature, -90% global fallback |
| Sep 1 fixed boundary | Historical vs real-time data split |
| Variant dedup (`[0-9][BRGP]$`) | V5.7 fix; wrong regex collapsed 7,711 SKUs |
| Commodity exclusions (gaskets, decals, etc.) | V5.6.2 fix |
| $50 price floor | Revenue comes from traffic, not rec price |
| 365-day purchase exclusion | Don't recommend already-purchased items |

---

## Input Data

| Source | Table | Purpose |
|--------|-------|---------|
| Users | `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` | User profiles, v1 vehicle (Year/Make/Model), email |
| Events | `auxia-gcp.company_1950.ingestion_unified_schema_incremental` | Views, carts, orders (Sep 1, 2025+) |
| Fitment | `auxia-gcp.data_company_1950.vehicle_product_fitment_data` | Vehicle → SKU mapping |
| Catalog | `auxia-gcp.data_company_1950.import_items` | PartType for diversity, refurb/commodity filter |
| Orders | `auxia-gcp.data_company_1950.import_orders` | Historical purchases (Apr 16 - Aug 31, 2025) |

## Output Schema

```
auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations (~450K rows)
```

| Column | Type | Description |
|--------|------|-------------|
| `email_lower` | STRING | User email (lowercase) |
| `v1_year` | STRING | Vehicle year |
| `v1_make` | STRING | Vehicle make (uppercase) |
| `v1_model` | STRING | Vehicle model (uppercase) |
| `rec_part_1..4` | STRING | SKU for each slot |
| `rec1_price..rec4_price` | FLOAT64 | Price per slot |
| `rec1_score..rec4_score` | FLOAT64 | Final score per slot |
| `rec1_image..rec4_image` | STRING | HTTPS image URL per slot |
| `rec1_type..rec4_type` | STRING | 'fitment' or 'universal' per slot |
| `rec1_pop_source..rec4_pop_source` | STRING | 'segment', 'make', or 'global' |
| **`engagement_tier`** | STRING | **NEW**: 'hot', 'warm', or 'cold' |
| **`fitment_count`** | INT64 | **NEW**: Count of fitment recs (0-4) |
| `generated_at` | TIMESTAMP | Pipeline run time |
| `pipeline_version` | STRING | 'v5.18' |

---

## Parameter Changes

| Parameter | V5.17 | V5.18 | Why |
|-----------|-------|-------|-----|
| `max_parttype_per_user` | 999 (no limit) | **2** | Force category diversity across 4 slots |
| `max_universal_products` | 500 | **1000** | Broader discovery pool, more PartTypes |
| `target_dataset` | `temp_holley_v5_17` | `temp_holley_v5_18` | Separate working dataset |

---

## Pipeline Steps

### Step 0: Users with V1 Vehicles
Unchanged from V5.17. Extract users with email + complete vehicle data (year, make, model).

**Expected**: ~475K users

### Step 0.5: Audience Qualification (NEW)

Classify each user by engagement tier based on their event history:

```
hot  = Has order or cart event (PLACED ORDER, ORDERED PRODUCT,
       CONSUMER WEBSITE ORDER, CART UPDATE)
warm = Has VIEWED PRODUCT event only
cold = No events in intent window (Sep 1+)
```

**Why**: Post-hoc analysis needs to answer "did personalized recs drive more revenue from cold users vs hot users?" This column enables that segmentation without re-querying.

**Implementation note**: Created in two phases because `staged_events` (needed for classification) doesn't exist until Step 1. Step 0.5 creates placeholder, Step 0.5b updates after events are loaded.

### Step 1: Data Preparation
Unchanged from V5.17:
- **1.0**: Staged events (single scan of unified events, Sep 1+)
- **1.1**: SKU prices (max observed price per SKU)
- **1.2**: SKU images (most recent HTTPS image per SKU)
- **1.3a**: Eligible fitment parts (YMM-matched, 7 quality filters)
- **1.3b**: Universal eligible parts (no YMM, top 1000 by popularity ← was 500)
- **1.4**: Vehicle generation fitment (reporting)
- **1.5**: Import orders (consolidated scan with window flags)

### Step 2: Scoring
Unchanged from V5.17:
- **2.1**: Intent scores (LOG-scaled: orders×20, carts×10, views×2)
- **2.2**: Segment popularity (make/model, weight 10.0)
- **2.2b**: Global popularity fallback (weight 2.0)
- **2.2c**: Make-level popularity (V5.17, weight 8.0)

```
final_score = intent_score + popularity_score

Popularity tier fallback:
  IF segment_orders >= 5 → segment_popularity_score (weight 10.0)
  ELIF make_orders >= 20 → make_popularity_score (weight 8.0)
  ELSE → global_popularity_score (weight 2.0)
```

### Step 3: Recommendation Selection

#### 3.1: Purchase Exclusion
Unchanged. Exclude SKUs purchased in last 365 days.

#### 3.2: Scored Recommendations
Unchanged. Combine fitment + universal candidates with scores. `product_type` column ('fitment'/'universal') carried through from candidate generation.

#### 3.3: Variant Dedup + Diversity (CHANGED)
- Variant dedup: unchanged (base SKU normalization, keep highest-scoring variant)
- **Diversity**: `max_parttype_per_user` = **2** (was 999). Each user gets at most 2 recs from the same PartType. This forces spread across categories.

#### 3.4: Reserved Slot Selection (NEW — replaces simple top-4)

**Old (V5.17)**: Take top 4 by `final_score` regardless of product type.

**New (V5.18)**: Reserved 2+2 allocation with backfill:

```
1. Rank fitment candidates per user by final_score → take top 2
2. Rank universal candidates per user by final_score → take top 2
3. Backfill:
   - If fitment pool has <2 → take extra from universal
   - If universal pool has <2 → take extra from fitment
   - Example: 1 fitment + 3 universal, or 0 fitment + 4 universal
4. Final ordering: fitment slots first, then universal
5. Require exactly 4 per user (drop users with <4 total)
```

**Why backfill**: Some vehicles have sparse fitment data. Rather than dropping these users, we fill with universal products. The `fitment_count` output column tracks the actual split for analysis.

#### 3.5: Pivot to Wide Format (CHANGED)
- Joins `audience_qualified` to attach `engagement_tier`
- Computes `fitment_count` = count of fitment-type recs per user
- All other columns unchanged

---

## Quality Filters (All 9 Enforced)

| # | Filter | Where Applied | Rule |
|---|--------|---------------|------|
| 1 | Price floor | Step 1.3a/b | `price >= $50` |
| 2 | HTTPS image | Step 1.3a/b | `image_url LIKE 'https://%'` |
| 3 | No refurbished | Step 1.3a/b | `Tags != 'Refurbished'` |
| 4 | No service SKUs | Step 1.3a/b | Not `EXT-`, `GIFT-`, `WARRANTY-`, `SERVICE-`, `PREAUTH-` |
| 5 | No commodities | Step 1.3a/b | Exclude gaskets, decals, keys, washers, clamps, most bolts/caps |
| 6 | Vehicle fit | Step 3.2 | Fitment candidates match user's YMM |
| 7 | Purchase exclusion | Step 3.1 | Not purchased in last 365 days |
| 8 | Variant dedup | Step 3.3 | One SKU per base product (color variants) |
| 9 | Category diversity | Step 3.3 | Max 2 per PartType per user |

---

## Validation Criteria

| Check | Expected | Severity |
|-------|----------|----------|
| User count | >= 400,000 | FAIL if below |
| Duplicate SKUs per user | 0 | FAIL if any |
| All prices >= $50 | 0 violations | FAIL if any |
| HTTPS images | 100% | FAIL if below |
| Max same PartType per user | <= 2 | FAIL if exceeded |
| Fitment count distribution | Most users = 2 | WARN if majority != 2 |
| Unique PartTypes in output | >= 400 (up from 322) | WARN if below |
| Engagement tier populated | No NULLs | FAIL if any |
| Score ordering | rec1 >= rec2 >= rec3 >= rec4 | WARN if violated (expected due to reserved slots) |

**Note on score ordering**: V5.18 intentionally breaks strict score monotonicity. A user's top-2 fitment recs may score lower than their top universal recs, but fitment is placed first by design. This is the correct behavior.

---

## Post-Hoc Analysis Plan

After the email blast, analyze revenue by:

```sql
-- Revenue by engagement tier
SELECT engagement_tier,
  COUNT(*) AS users_sent,
  SUM(revenue) AS total_revenue,
  AVG(revenue) AS avg_revenue
FROM results
GROUP BY engagement_tier;

-- Revenue by fitment mix
SELECT fitment_count,
  COUNT(*) AS users,
  AVG(revenue) AS avg_revenue
FROM results
GROUP BY fitment_count;

-- Treatment vs Control
SELECT treatment_group,
  SUM(revenue) AS total_revenue,
  COUNT(DISTINCT buyer_email) AS buyers,
  SUM(revenue) / COUNT(*) AS revenue_per_user
FROM results
GROUP BY treatment_group;
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `sql/recommendations/v5_18_revenue_ab_test.sql` | Created | Pipeline SQL |
| `sql/validation/qa_checks.sql` | Updated | Added checks 7b/7c/7d for v5.18 |
| `docs/release_notes.md` | Updated | V5.18 entry |
| `specs/v5_18_revenue_ab_test.md` | Created | This spec |

## Run Commands

```bash
# Dry run (validate SQL)
bq query --dry_run --use_legacy_sql=false \
  < sql/recommendations/v5_18_revenue_ab_test.sql

# Execute pipeline
bq query --use_legacy_sql=false \
  < sql/recommendations/v5_18_revenue_ab_test.sql

# Validate output
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql

# Quick sanity check
bq query --use_legacy_sql=false '
SELECT COUNT(*) AS users,
  ROUND(AVG(fitment_count), 2) AS avg_fitment,
  COUNTIF(engagement_tier = "hot") AS hot,
  COUNTIF(engagement_tier = "warm") AS warm,
  COUNTIF(engagement_tier = "cold") AS cold
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`'

# Compare v5.17 vs v5.18
bq query --use_legacy_sql=false '
SELECT "v5.17" AS version, COUNT(*) AS users FROM `auxia-reporting.temp_holley_v5_17.final_vehicle_recommendations`
UNION ALL
SELECT "v5.18", COUNT(*) FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`'
```

---

## Version Lineage

```
V5.6  → Production baseline (hybrid scoring, filters)
V5.7  → Perf optimization + variant dedup fix
V5.15 → Added universal products (top 500)
V5.16 → Segment-based popularity (+32% match rate)
V5.17 → 3-tier fallback: segment → make → global (-90% global)
V5.18 → Reserved slots (2+2) + diversity + engagement tiers [YOU ARE HERE]
```

---

Created: January 30, 2026
