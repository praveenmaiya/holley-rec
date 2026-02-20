# Architecture & Engineering Specification: Vehicle Fitment Recommendation Engine V5.18

**Client / Tenant:** Holley Performance Products (Company ID: 1950)
**Platform:** Google Cloud Platform — BigQuery SQL Scripting
**Execution Pattern:** Idempotent Batch ELT via `EXECUTE IMMEDIATE FORMAT()` with Dynamic Table References
**Pipeline Version:** V5.18 — Strict Fitment-Only / 3-Tier Cascading Popularity
**Base Version:** V5.17 (1,105 lines) — 3-Tier Segment Fallback with Intent Scoring
**Date:** February 19, 2026
**Author:** Praveen Maiya

---

## 1. System Overview & Design Philosophy

The Holley Vehicle Fitment Recommendation Engine is a deterministic, heuristic-scoring data pipeline that generates personalized product recommendations for automotive aftermarket email campaigns. It solves the **sparse-data long-tail problem** inherent to niche vehicle segments — a 1969 Camaro generates thousands of orders, while a 1992 GMC Typhoon generates single digits.

Unlike collaborative filtering models that fail on sparse segments, this engine uses a **Cascading 3-Tier Popularity Fallback** that gracefully degrades from segment-specific to make-level to global purchase data, guaranteeing every recommended product has a non-zero, purchase-backed score.

### 1.1 Why V5.18 Exists

V5.17 ran an A/B revenue test that showed **positive uplift and conversion**. However, two issues prompted V5.18:

1. **The Golf Cart Incident**: Client flagged universal (non-fitment) parts being recommended for a golf cart. Universal products — "one-size-fits-most" parts without explicit vehicle mapping — violated the customer's expectation of vehicle-specific relevance.
2. **Intent Scoring Waste**: 98% of email campaign recipients had no recent browsing activity. The intent scoring layer (views=1pt, carts=5pts, orders=10pts) only affected 2% of users while adding significant complexity and a class of edge cases (stale intent, event attribution errors).

### 1.2 Core Architectural Tenets

| Tenet | Implementation |
|-------|---------------|
| **Strict Fitment-Only** | Universal product path entirely removed. Every recommendation maps to an authoritative `(year, make, model, SKU)` tuple in `vehicle_product_fitment_data`. |
| **Popularity-Only Scoring** | Intent signals (views, carts) removed. `final_score = popularity_score` — no additive components. Fully transparent and auditable. |
| **Per-Product Tier Fallback** | Tier selection is per-product, not per-vehicle. A segment-dominant vehicle can still have individual products fall through to make or global tiers if that specific SKU lacks segment-level data. Eliminates zero-score recommendations. |
| **Logarithmic Dampening** | `ln(1 + orders) × weight` prevents high-volume SKUs from permanently monopolizing slots. Diminishing returns: the gap between rank #1 and #2 matters more than #501 vs #502. |
| **Idempotent Materialization** | All intermediate tables created via `CREATE OR REPLACE TABLE`. The pipeline can be re-executed without producing duplicate state or requiring cleanup. |
| **Late-Stage Denormalization** | All scoring, filtering, and deduplication occur in normalized long-format tables. The wide pivot (`rec_part_1` through `rec_part_4`) happens only in the final step, minimizing BigQuery slot waste. |
| **Dataset Isolation** | All intermediate and final tables write to `auxia-reporting.temp_holley_v5_18`. Production deployment is a separate, gated `COPY` operation. |

---

## 2. Data Lineage & Temporal Architecture

The pipeline combines two temporally disjoint data sources with a fixed boundary at **September 1, 2025**:

```
                    Jan 1, 2024          Aug 31, 2025    Sep 1, 2025          Current Date
                        |                     |              |                     |
  import_orders --------|=====================|              |                     |
  (Historical)          | Popularity Window   |              |                     |
                        | (20 months)         |              |                     |
                                                             |                     |
  unified_events -------------------------------------------|=====================|
  (Real-time)                                               | Recent Events       |
                                                            | (orders for scoring,|
                                                            |  all events for     |
                                                            |  price/image data)  |
```

### 2.1 Source Tables

| Source | BigQuery Location | Purpose | Temporal Window |
|--------|------------------|---------|-----------------|
| **User Attributes** | `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` | User email, vehicle (year/make/model) | Latest per property (ROW_NUMBER by update_timestamp) |
| **User Events** | `auxia-gcp.company_1950.ingestion_unified_schema_incremental` | Views, carts, orders — for price/image extraction and recent order counting | Sep 1, 2025 → current |
| **Historical Orders** | `auxia-gcp.data_company_1950.import_orders` | Bulk order history for popularity scoring and purchase exclusion | Jan 1, 2024 → Aug 31, 2025 |
| **Fitment Map** | `auxia-gcp.data_company_1950.vehicle_product_fitment_data` | Authoritative vehicle-to-product compatibility | Static (refreshed by client) |
| **Product Catalog** | `auxia-gcp.data_company_1950.import_items` | PartType taxonomy, tags (refurbished detection) | Static |
| **Product Tags** | `auxia-gcp.data_company_1950.import_items` (Tags column) | Refurbished tag detection via `Tags LIKE '%refurbished%'` | Static |

### 2.2 Why September 1 Is Fixed

The September 1 boundary exists because `import_orders` (historical bulk data) and `ingestion_unified_schema_incremental` (real-time events) overlap temporally. The fixed boundary ensures:

- No double-counting orders that appear in both sources
- Deterministic results regardless of when the pipeline runs
- Clear data ownership: pre-Sep-1 = import_orders, post-Sep-1 = events

### 2.3 The 14-Month History Extension

V5.17 used `pop_hist_start = 2025-04-16` (4.5 months of history). V5.18 extends to `2024-01-01` (20 months). This was critical for:

- **Expanding the segment tier**: More historical orders mean more products cross the 5-order segment threshold
- **Compensating for fitment-only**: Removing universal products reduced the candidate pool; extended history recovers coverage by scoring more fitment products
- **Automotive purchase stability**: Auto parts buying patterns are inherently stable — a popular Camaro carburetor in 2024 is still popular in 2026

---

## 3. Pipeline Execution Flow

The pipeline executes as a single BigQuery SQL script (~1,050 lines) using `EXECUTE IMMEDIATE FORMAT()` for dynamic table name injection. All 34 declared variables are bound at the top of the script.

```
Step 0: User Extraction          → users_with_v1_vehicles
  │
Step 1: Data Preparation
  ├── 1.0  Staged Events         → staged_events (all events for price/image)
  ├── 1.1  SKU Prices            → sku_prices (MAX price per SKU)
  ├── 1.2  SKU Images            → sku_image_urls (latest HTTPS image per SKU)
  ├── 1.3  Eligible Parts        → eligible_parts (fitment × catalog × filters)
  ├── 1.4  Vehicle Generations   → vehicle_generation_fitment (reporting)
  └── 1.5  Import Orders         → import_orders_filtered (historical + exclusion)
  │
Step 2: Popularity Scoring
  ├── 2.2   Segment Popularity   → segment_popularity (make+model, weight 10.0)
  ├── 2.2b  Global Popularity    → global_popularity_fallback (all vehicles, weight 2.0)
  └── 2.2c  Make Popularity      → make_popularity (make-only, weight 8.0)
  │
Step 3: Recommendation Assembly
  ├── 3.1  Purchase Exclusion    → user_purchased_parts_365d
  ├── 3.2  Scored Recommendations → scored_recommendations (candidates × scores)
  ├── 3.3  Variant Dedup + Diversity → diversity_filtered (cap 2 per PartType)
  ├── 3.4  Top-N Selection       → ranked_recommendations (3-4 per user)
  └── 3.5  Pivot to Wide Format  → final_vehicle_recommendations
  │
Step 4: Production Deployment    → company_1950_jp.final_vehicle_recommendations (gated)
```

### 3.1 Step 0: User Extraction with Latest-Per-Property Resolution

**Table**: `users_with_v1_vehicles`
**Purpose**: Extract users with complete vehicle attributes (email, year, make, model)

**Key Design Decision — ROW_NUMBER vs MAX(IF):**

V5.17 used `MAX(IF(property_name = 'email', property_value, NULL))` to pivot user attributes. This is subtly wrong: if a user updates their email, `MAX()` picks the lexicographically largest value, not the most recent. V5.18 uses:

```sql
ROW_NUMBER() OVER (
  PARTITION BY user_id, LOWER(property_name)
  ORDER BY update_timestamp DESC, auxia_insertion_timestamp DESC
) AS rn
-- Then: WHERE rn = 1
```

This guarantees the **temporally latest** value for each property, not the lexicographically largest.

**Strict Valid-Year Filter**: `SAFE_CAST(v1_year AS INT64) IS NOT NULL` rejects users with garbage year values (e.g., "NONE", "0", non-numeric strings) at extraction time rather than failing silently downstream.

### 3.2 Step 1: Data Preparation

#### 1.0 Staged Events
Extracts all 5 event types from `ingestion_unified_schema_incremental` since Sep 1:
- `VIEWED PRODUCT` — for price/image data only (not scoring)
- `CART UPDATE` — for price/image data only (not scoring)
- `PLACED ORDER`, `ORDERED PRODUCT`, `CONSUMER WEBSITE ORDER` — for scoring AND price/image

The event property schema varies by event type:
- View/Order events: `productid` or `prodid` (regex: `^prod(?:uct)?id$`)
- Cart/Placed Order: `items_N.productid` (indexed array)
- Consumer Website Order: `skus_N` (indexed array)

Price and image are extracted via indexed property matching (`items_N.itemprice`, `items_N.imageurl`) and aggregated per `(user_id, event_ts, event_name, item_idx)`.

#### 1.1-1.2 SKU Prices and Images
- **Prices**: `MAX(price)` per SKU across all observations
- **Images**: Latest image per SKU (`ROW_NUMBER() OVER (PARTITION BY sku ORDER BY event_ts DESC)`), with protocol normalization: `//cdn` → `https://cdn`, `http://` → `https://`

Both require the SKU to have appeared in at least one recent event. If a fitment product has no recent event data, it relies on `allow_price_fallback = TRUE` (defaults to `min_price`).

#### 1.3 Eligible Parts — The Deterministic Catalog Gate

This is the most filter-heavy step. A product must survive ALL of the following to enter the candidate pool:

**The Complete Exclusion Matrix:**

| Filter | Rule | Rationale |
|--------|------|-----------|
| **Financial Floor** | `price >= $50.00` | Focus on meaningful performance parts, not stickers/hardware |
| **Refurbished** | `Tags LIKE '%refurbished%'` in `import_items` | Quality consistency |
| **Service SKUs** | `SKU LIKE 'EXT-%'`, `'GIFT-%'`, `'WARRANTY-%'`, `'SERVICE-%'`, `'PREAUTH-%'` | Non-merchandise items |
| **Commodity PartTypes** | `Gasket`, `Decal`, `Key`, `Washer`, `Clamp` | Low-consideration commodity parts |
| **Bolt Exception** | `LIKE '%Bolt%'` excluded UNLESS exactly `'Engine Cylinder Head Bolt'` or `'Engine Bolt Kit'` | High-value engine bolts are allowed |
| **Cap Exception** | `LIKE '%Cap%'` excluded UNLESS `'Distributor Cap'`, `'Wheel Hub Cap'`, or `'Wheel Cap Set'` | Distributor Caps are performance parts; Wheel Caps are high-value |
| **Unknown Taxonomy** | `PartType = 'UNKNOWN' AND price < $3,000` | Only ultra-high-ticket unknowns (crate engines) are allowed |
| **Image Required** | `image_url IS NOT NULL AND LIKE 'https://%'` | Email template requires valid HTTPS images |
| **Fitment Dedup** | `SELECT DISTINCT year, make, model, sku` before joining | Prevents duplicate rows from fitment table producing inflated candidate sets |

**Minimum Assortment Gate:** After all filters, a vehicle generation must have `>= 4` eligible SKUs. This is intentionally stricter than `min_required_recs` (3) — it ensures enough candidate diversity before any enter the scoring pipeline. Vehicles with only 3 surviving products are dropped at this stage, even though a user could theoretically receive 3 recs.

#### 1.5 Import Orders — Consolidated Historical Scan

Single scan of `import_orders` with dual-purpose windowing:
- **Popularity window** (`Jan 1, 2024 → Aug 31, 2025`): Feeds segment/make/global popularity computation
- **Exclusion window** (trailing 365 days): Feeds purchase exclusion

**ORDER_DATE Pre-filter Optimization**: The `ORDER_DATE` column is a string (e.g., `"Thursday, February 13, 2025"`). Rather than parsing every row with `SAFE.PARSE_DATE`, a regex pre-filter extracts the 4-digit year and checks `BETWEEN min_prefilter_year AND max_prefilter_year`. This eliminates rows from years outside the range before the expensive parse.

**Variant Normalization**: SKUs are normalized at extraction: `REGEXP_REPLACE(ITEM, r'([0-9])[BRGP]$', r'\1')`. This means `RA003B` (blue) and `RA003R` (red) both become `RA003` in the historical orders table, ensuring consistent matching downstream.

---

## 4. The 3-Tier Cascading Popularity Algorithm

### 4.1 Scoring Formula

$$\text{Score} = \ln(1 + \text{orders}_{\text{tier}}) \times W_{\text{tier}}$$

| Tier | Scope | Weight ($W$) | Activation Threshold | Data Source |
|------|-------|-------------|---------------------|-------------|
| **1. Segment** | Same `(make, model)` | 10.0 | `segment_total_orders >= 5` for the make/model AND product has segment-level score | Historical + Recent orders by make/model |
| **2. Make** | Same `make` | 8.0 | `make_total_orders >= 20` for the make AND product has make-level score | Aggregated from segment popularity |
| **3. Global** | All vehicles | 2.0 | Always active (ultimate fallback) | Historical + Recent orders, all users |

### 4.2 The Per-Product Fallback (V5.18 Innovation)

This is the critical design difference from V5.17. The tier selection is evaluated **per product**, not per vehicle segment:

```sql
CASE
  WHEN segment_total_orders >= 5 AND seg.segment_popularity_score IS NOT NULL
    THEN seg.segment_popularity_score
  WHEN make_total_orders >= 20 AND mk.make_popularity_score IS NOT NULL
    THEN mk.make_popularity_score
  ELSE COALESCE(glob.global_popularity_score, 0)
END AS final_score
```

The dual condition (`total_orders >= threshold AND score IS NOT NULL`) means:
- A vehicle with 5,000 segment orders can still have individual products fall through to make or global tier if that specific SKU has no segment-level purchase data
- This eliminates the **zero-score problem** from V5.17 where some products had NULL segment scores and received `final_score = 0 + 0 = 0`

**Result**: Score range is now `1.39 – 47.45` with zero instances of `final_score = 0`.

### 4.3 Practical Score Interpretation

| Orders at Tier | Tier 1 (×10) | Tier 2 (×8) | Tier 3 (×2) |
|---------------|-------------|------------|------------|
| 2 | 10.99 | 8.79 | 2.20 |
| 5 | 17.92 | 14.33 | 3.58 |
| 10 | 23.98 | 19.18 | 4.80 |
| 50 | 39.32 | 31.45 | 7.86 |
| 100 | 46.15 | 36.92 | 9.23 |
| 500 | 62.17 | 49.73 | 12.43 |

### 4.4 Tier Distribution (Production Run, Feb 19, 2026)

| Slot | Segment | Make | Global | None |
|------|---------|------|--------|------|
| Rec 1 | 56.8% | 40.2% | 3.0% | 0% |
| Rec 2 | 51.2% | 44.7% | 4.1% | 0% |
| Rec 3 | 44.1% | 49.2% | 6.7% | 0% |
| Rec 4 | 42.8% | 49.7% | 7.5% | 0% |
| **All Slots** | **48.9%** | **45.6%** | **5.4%** | **0%** |

The tier degradation across slots is expected: the top-1 product for a vehicle is most likely to have strong segment data, while the 4th-best product may need to fall back to make-level data.

---

## 5. Post-Scoring Business Rules

### 5.1 Purchase Exclusion with Variant-Normalized Matching

The engine enforces a **365-day lookback exclusion** by scanning two sources:

| Source | Table | Notes |
|--------|-------|-------|
| **Recent events** | `staged_events` (Sep 1+) | Order events only, variant-normalized at extraction |
| **Historical imports** | `import_orders_filtered` (trailing 365 days) | Already variant-normalized at Step 1.5 |

**Variant Normalization**: Both sources apply `REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1')` to strip color-variant suffixes. Additionally, the exclusion JOIN normalizes the candidate SKU:

```sql
LEFT JOIN purchase_excl purch
  ON fc.user_id = purch.user_id
  AND REGEXP_REPLACE(fc.sku, r'([0-9])[BRGP]$', r'\1') = purch.sku
WHERE purch.sku IS NULL
```

This was a **bug fix in V5.18**: the original implementation normalized `from_import` but not `from_events`, allowing 2 users to be recommended `RA003R` (red) when they had purchased `RA003B` (blue) via events. The fix applies normalization to all three touchpoints: `from_events`, `from_import`, and the exclusion JOIN itself.

### 5.2 Two-Stage Variant Deduplication

Stage 1 strips suffix modifiers: `REGEXP_REPLACE(sku, r'(-KIT|-BLK|-POL|-CHR|-RAW|-[A-Z0-9]{1,2})$', '')`
Stage 2 strips color suffixes: `REGEXP_REPLACE(..., r'([0-9])[BRGP]$', r'\1')`

Within each `(user_id, base_sku)` group, only the highest-scoring variant survives (`ROW_NUMBER() OVER (PARTITION BY user_id, base_sku ORDER BY final_score DESC, sku)`). The deterministic `sku` tie-break ensures reproducible results.

### 5.3 Taxonomic Diversity Cap

`ROW_NUMBER() OVER (PARTITION BY user_id, part_type ORDER BY final_score DESC, sku) <= 2`

A user never sees more than 2 products from the same PartType category. This was raised from a non-enforced cap of 999 in V5.17, making it a real constraint in V5.18.

### 5.4 Top-N Selection

```sql
WHERE rec_count >= 3   -- User must have at least 3 candidates
  AND rn <= 4          -- Take up to 4 per user
```

V5.17 required `rec_count >= 4`. Relaxing to 3 recovers users who have enough fitment products for a meaningful recommendation set but not enough for a full 4-slot layout. The downstream email template must handle NULL `rec4_*` columns.

**Distribution**: 445,468 users (98.5%) receive 4 recs; 6,682 users (1.5%) receive 3 recs.

---

## 6. The Defensive Pivot (State Resolution)

The pivot from long-format to wide-format (`rec_part_1` through `rec_part_4`) handles a subtle data quality issue: **multiple `user_id` values sharing the same `(email, year, make, model)`**.

This happens when:
- A user creates a new account with the same email
- Guest vs. logged-in profile fragmentation
- CRM data merges

Without handling, this produces duplicate rows in the final table (one per `user_id`). The defensive pivot resolves this via a `selected_user` CTE:

```sql
selected_user AS (
  SELECT email_lower, v1_year, v1_make, v1_model, user_id
  FROM (
    SELECT ...,
      ROW_NUMBER() OVER (
        PARTITION BY email_lower, v1_year, v1_make, v1_model
        ORDER BY user_rec_count DESC,      -- Most recommendations wins
               user_total_score DESC,       -- Then highest total score
               user_top_score DESC,         -- Then highest single score
               user_id                      -- Deterministic tie-break
      ) AS pick_rn
    FROM ranked_with_user_stats
    GROUP BY ...
  )
  WHERE pick_rn = 1
)
```

This guarantees exactly **one row per `(email, year, make, model)`** in the final table, selecting the user_id with the richest recommendation set.

---

## 7. Output Schema

**Table**: `final_vehicle_recommendations`
**Clustering**: `email_lower`

| Column | Type | Description |
|--------|------|-------------|
| `email_lower` | STRING | User email (lowercase, trimmed) — composite key with YMM |
| `v1_year` | STRING | Vehicle year |
| `v1_make` | STRING | Vehicle make (uppercased) |
| `v1_model` | STRING | Vehicle model (uppercased) |
| `rec_part_1` through `rec_part_4` | STRING | SKU for each recommendation slot |
| `rec1_price` through `rec4_price` | FLOAT64 | Price per recommendation |
| `rec1_score` through `rec4_score` | FLOAT64 | Final popularity score |
| `rec1_image` through `rec4_image` | STRING | HTTPS image URL |
| `rec1_type` through `rec4_type` | STRING | Always `'fitment'` (kept for backward compatibility) |
| `rec1_pop_source` through `rec4_pop_source` | STRING | `'segment'`, `'make'`, or `'global'` |
| `engagement_tier` | STRING | `'hot'` (order since Sep 1) or `'cold'` (no recent orders) |
| `fitment_count` | INT64 | 3 or 4 — number of recommendations for this user |
| `generated_at` | TIMESTAMP | Pipeline execution timestamp |
| `pipeline_version` | STRING | `'v5.18'` |

**Note**: `rec4_*` columns are NULL for users with `fitment_count = 3`. Downstream consumers must handle this gracefully.

---

## 8. Deployment Architecture

### 8.1 Working vs Production

| Environment | Dataset | Purpose |
|-------------|---------|---------|
| **Working** | `auxia-reporting.temp_holley_v5_18` | All intermediate + final tables. Safe for iteration. |
| **Production** | `auxia-reporting.company_1950_jp.final_vehicle_recommendations` | Consumed by Auxia treatment engine. |

### 8.2 Deployment Workflow

```
1. Set deploy_to_production = FALSE  (default)
2. Run pipeline → writes to temp_holley_v5_18
3. Run qa_checks.sql → standard QA checks
4. Run v5_18_go_no_go_eval.sql → 14 severity-ranked checks
5. Review results → all checks must PASS
6. Set deploy_to_production = TRUE
7. Re-run pipeline → copies final table to production
8. Timestamped backup created: final_vehicle_recommendations_2026_02_19_143022
```

**Zero-Downtime Deployment**: Production writes use `CREATE OR REPLACE TABLE ... COPY`, which is atomic. The old table is replaced in a single operation — no `DROP` + `CREATE` gap where the table doesn't exist.

**Timestamped Snapshots**: Every deployment creates `final_vehicle_recommendations_YYYY_MM_DD_HHMMSS` for rollback capability and A/B test backtesting. The timestamp suffix (down to seconds) ensures multiple same-day deploys never overwrite prior snapshots.

---

## 9. Validation & Quality Assurance

### 9.1 Inline Pipeline Checks

Every materialization step emits a check query:

| Step | Check | Threshold |
|------|-------|-----------|
| Step 0 | User count | >= 400,000 |
| Step 1.0 | Event count | >= 100,000 |
| Step 1.3 | Eligible parts count | >= 1,000 |
| Step 3.5 | Final user count | >= 400,000 |
| Post-pivot | Fitment count distribution | 3 or 4 only |
| Post-pivot | Engagement tier distribution | hot + cold = total |
| Post-pivot | Duplicate SKUs within user | 0 |
| Post-pivot | Price floor violations | 0 |
| Post-pivot | Score ordering (monotonic) | ~100% |
| Post-pivot | Universal products | 0 |
| Post-pivot | Generation coverage | Track exclusion rate |
| Post-pivot | Popularity source distribution | 0% none |

### 9.2 Go/No-Go Evaluation (`v5_18_go_no_go_eval.sql`)

A separate 14-check severity-ranked evaluation script run after pipeline completion:

| # | Check Name | Severity | Pass Criteria |
|---|------------|----------|---------------|
| 1 | `fitment_mismatch_rows` — YMM × SKU vs authoritative fitment map | CRITICAL | 0 row-level mismatches |
| 2 | `users_with_any_fitment_mismatch` — user-level fitment check | CRITICAL | 0 users with any mismatch |
| 3 | `golf_segment_mismatch_rows` — golf-model guardrail | CRITICAL | 0 golf-model mismatches |
| 4 | `universal_recommendation_rows` — universal products in output | CRITICAL | 0 rows |
| 5 | `price_floor_violations` — price below threshold | CRITICAL | 0 violations |
| 6 | `final_user_count` — output volume gate | CRITICAL | >= 400,000 |
| 7 | `purchase_exclusion_violations` — variant-normalized | HIGH | 0 violations |
| 8 | `duplicate_users` — duplicate SKUs within a user row | HIGH | 0 duplicate SKUs |
| 9 | `diversity_cap_violations` — max 2 per PartType | HIGH | 0 violations |
| 10 | `popularity_source_none_rows` — pop source integrity | HIGH | 0 invalid sources |
| 11 | `popularity_source_join_mismatches` — label vs backing table | HIGH | 0 mismatches |
| 12 | `fitment_count_outside_3_or_4` — invalid rec counts | HIGH | Only 3 or 4 |
| 13 | `final_coverage_of_base_pct` — coverage vs base universe | HIGH | >= threshold % |
| 14 | `score_ordering_violations` — monotonicity across slots | MEDIUM | 0 violations |
| — | `users_with_4_recommendations_pct` — 4-rec percentage | INFO | Monitoring only |

**Investigation Readiness**: Sample rows are emitted only when any check FAILs (conditional output), providing immediate triage data without cluttering successful runs.

### 9.3 Standard QA Checks (`qa_checks.sql`)

| Check | Query |
|-------|-------|
| 7a. Duplicate check | 0 users with duplicate SKUs across slots |
| 7b. Price floor | All prices >= $50 |
| 7c. Score ordering | rec1_score >= rec2_score >= rec3_score >= rec4_score |
| 7d. Diversity | Max 2 per PartType per user |
| 7e. Fitment match | Every rec SKU exists in fitment map for user's YMM |
| 7f. Authoritative fitment (YMM × SKU) | JOIN against `vehicle_product_fitment_data` — end-to-end verification |

### 9.4 Production Run Results (February 19, 2026)

| Metric | Value |
|--------|-------|
| Total users | 452,150 |
| Users with 4 recs | 445,468 (98.5%) |
| Users with 3 recs | 6,682 (1.5%) |
| Score range | 1.39 – 47.45 |
| Zero scores | 0 |
| Price range | $50.57 – $2,609.95 |
| Average price | $602.21 |
| Unique vehicles (YMM) | 9,746 |
| Hot users (recent orders) | 9,573 (2.1%) |
| Cold users | 442,577 (97.9%) |
| Pop source: Segment (all slots) | 48.9% |
| Pop source: Make (all slots) | 45.6% |
| Pop source: Global (all slots) | 5.4% |
| Go/no-go result | 14/14 actionable checks PASS |
| Pipeline execution time | ~155 seconds |

---

## 10. Hardening History & Attribution

V5.18 underwent multiple review passes from different AI models and human review. Each fix is documented with source attribution:

| # | Fix | Source | Severity |
|---|-----|--------|----------|
| 1 | Purchase exclusion variant normalization (RA003R/RA003B gap) | Claude — bug investigation | CRITICAL |
| 2 | Per-product popularity fallback (eliminates zero scores) | Claude — scoring analysis | HIGH |
| 3 | Latest-per-property attributes (ROW_NUMBER vs MAX) | Codex CLI peer review | HIGH |
| 4 | Defensive pivot (duplicate user_id resolution) | ChatGPT + Gemini review | HIGH |
| 5 | Strict valid-year filter (SAFE_CAST guard) | ChatGPT + Gemini review | MEDIUM |
| 6 | Deterministic fitment candidate dedup (DISTINCT before join) | ChatGPT + Gemini review | MEDIUM |
| 7 | Authoritative fitment QA check (YMM × SKU) | ChatGPT + Gemini review | MEDIUM |
| 8 | ORDER_DATE year prefilter (REGEXP_EXTRACT + BETWEEN) | Claude — optimization | LOW |
| 9 | Threshold variables (min_users_with_v1, min_final_users) | Codex CLI peer review | LOW |
| 10 | Go/no-go eval with severity-ranked checks | Codex CLI peer review | LOW |

---

## 11. Configuration Reference

All tunable parameters are declared as BigQuery variables at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `pipeline_version` | `'v5.18'` | Version tag written to output |
| `target_dataset` | `'temp_holley_v5_18'` | Working dataset for intermediate tables |
| `deploy_to_production` | `FALSE` | Gate for production deployment |
| `pop_hist_start` | `2024-01-01` | Start of historical popularity window |
| `pop_hist_end` | `2025-08-31` | End of historical popularity window |
| `intent_window_start` | `2025-09-01` | Start of recent events window |
| `purchase_window_days` | `365` | Lookback for purchase exclusion |
| `min_price` | `50.0` | Price floor for eligible parts |
| `max_parttype_per_user` | `2` | Diversity cap (was 999 in V5.17) |
| `required_recs` | `4` | Maximum recommendations per user |
| `min_required_recs` | `3` | Minimum recs to include user (was 4) |
| `min_segment_orders` | `2` | Minimum orders to appear in segment table |
| `min_segment_for_use` | `5` | Segment total orders threshold for tier activation |
| `min_make_for_use` | `20` | Make total orders threshold for tier activation |
| `segment_popularity_weight` | `10.0` | Tier 1 weight multiplier |
| `make_popularity_weight` | `8.0` | Tier 2 weight multiplier |
| `min_users_with_v1` | `400,000` | User count monitoring threshold |
| `min_final_users` | `400,000` | Final output user count threshold |
| `allow_price_fallback` | `TRUE` | Allow min_price as fallback when no price data |
| `require_purchase_signal` | `TRUE` | Require at least one popularity tier to have data |

---

## 12. V5.17 → V5.18 Delta Summary

| Dimension | V5.17 | V5.18 | Impact |
|-----------|-------|-------|--------|
| Product types | Fitment + Universal | Fitment only | Eliminates wrong-vehicle recommendations |
| Scoring | Intent (views/carts) + Popularity | Popularity only | Simpler, 98% of users unaffected |
| Tier fallback | Per-vehicle | Per-product | Eliminates zero-score recommendations |
| Price floor | $50 | $50 | No change |
| Diversity cap | 999 (uncapped) | 2 | Forces category variety |
| Min recs | 4 | 3 | Recovers 1.5% more users |
| History window | Apr 16, 2025 (4.5 months) | Jan 1, 2024 (20 months) | Richer popularity signal |
| User count | 501,631 | 452,150 (-9.9%) | Expected: fitment-only is stricter |
| Score range | 0 – 86.14 | 1.39 – 47.45 | No more zeros; narrower, healthier range |
| Zero scores | 9,860 | 0 | Per-product fallback fixed this |
| Intent-affected users | ~2% | 0% | Intent layer removed |
| SQL lines | ~1,105 | ~1,050 | Simpler despite added hardening |

---

## 13. Known Limitations & Future Work

| Limitation | Impact | Planned Mitigation |
|-----------|--------|-------------------|
| **Single vehicle per user** | Multi-vehicle owners only get recs for primary vehicle | GNN model (V6.0) supports multi-vehicle user nodes |
| **No time decay** | Jan 2024 order weighs same as Feb 2026 order | Exponential decay multiplier (planned for V5.19) |
| **Same-vehicle similarity** | Users with same YMM get similar recs, differentiated only by purchase exclusion | Collaborative filtering via GNN embeds user-level preferences |
| **Popularity-only** | No individual browsing behavior considered | GNN two-tower architecture learns user-product affinity beyond popularity |
| **Static fitment map** | Stale if client doesn't refresh | Monitoring: generation coverage QA tracks exclusion rate |
| **September 1 boundary** | Fixed temporal split may need adjustment as time passes | Review boundary quarterly |
| **Popularity count inflation** | Recent popularity uses `COUNT(*)` across order event types without order-level dedup; historical popularity joins by email which can multiply counts if one email maps to multiple user_ids | Add order-level dedup key to recent counts; deduplicate email→user_id mapping in historical join |
| **Image-dependent coverage** | Products require a recent event with an image URL to be eligible; valid fitment SKUs with no recent image events are silently dropped from the candidate pool | Consider supplementing with catalog-sourced images from `import_items` |

---

*End of Architecture Specification*
