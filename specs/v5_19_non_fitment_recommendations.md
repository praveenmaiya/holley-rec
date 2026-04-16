# Feature: v5.19 Non-Fitment Product Recommendations (No-YMM Users)

## Status
- [x] Draft
- [ ] In Review
- [ ] Approved
- [ ] In Progress
- [ ] Completed

Linear: AUX-14029
Branch: `praveen-aux-14029`

## Problem Statement
v5.18 serves ~457k YMM users with fitment-based vehicle recommendations. Another ~1.8M active users without complete v1 YMM receive nothing personalized, despite leaving strong signals (views, cart adds, past purchases).

v5.19 extends the recommendation system to this no-YMM audience using a unified recency-weighted scoring model. The design choice of one scoring model (over a tiered fallback) avoids tier-handoff complexity and ships all signal sources through the same pipeline.

## Signal Investigation Summary
Before designing scoring, we validated each signal's predictive value for no-YMM users specifically:

| Signal | Same-SKU purchase within 30d | Same-SKU share of converters |
|--------|------------------------------|-------------------------------|
| Cart Update | 70.3% | 99.5% |
| Viewed Product | 30.6% | 95.4% |

Decay curves (view→purchase window):
- 70% of conversions within 24 hours
- 90% within 14 days
- ~3% after 30 days

This overturns v5.18's "browse doesn't convert" assumption for the no-YMM segment: short-horizon browse signal is extremely predictive. Tau values for time decay are grounded in these curves.

## Scope
In scope for v5.19:
1. New output table for no-YMM users (disjoint from v5.18's fitment output)
2. Unified recency-weighted scoring across {cart, view, recent purchase, historical purchase, bestseller}
3. Exponential time decay per signal type
4. Up to 4 recommendations per eligible user; fall back to bestsellers when user has no signal
5. `dominant_signal` column to route downstream email treatments by intent type

Out of scope for v5.19:
1. Collaborative filtering (e.g., "users who browsed X also browsed Y") — v5.20+
2. Search query → SKU mapping
3. Brand / category / PartType level campaign targeting
4. GNN approach (v6.x track)
5. Changes to email treatment routing or bandit system

## Data Requirements

### Input Data
| Table/Source | Columns Used | Purpose |
|--------------|--------------|---------|
| `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` | `user_id`, `user_properties` | Identify no-YMM users (disjoint from v5.18) |
| `auxia-gcp.company_1950.ingestion_unified_schema_incremental` | `user_id`, `event_name`, `client_event_timestamp`, `event_properties` | View / cart / order events for signal extraction |
| `auxia-gcp.data_company_1950.import_orders` | `ITEM`, `SHIP_TO_EMAIL`, `ORDER_DATE` | Historical purchase signal + purchase exclusion |
| `auxia-gcp.data_company_1950.vehicle_product_fitment_data` | `products.product_number` | Candidate SKU universe (any SKU with catalog fitment record) |
| `auxia-gcp.data_company_1950.import_items` | `PartNumber`, `PartType`, `Tags` | PartType for diversity cap, refurbished/commodity exclusion |

### Output Data
| Table/Destination | Columns | Purpose |
|-------------------|---------|---------|
| `auxia-reporting.temp_holley_v5_19.final_non_fitment_recommendations` | See schema below | Staging output for validation |
| `auxia-reporting.company_1950_jp.final_non_fitment_recommendations` | Same | Production output (deployed after QA) |

Schema:
```
email_lower              STRING
rec_part_1..4            STRING
rec1..4_price            FLOAT64
rec1..4_score            FLOAT64
rec1..4_image            STRING
rec1..4_type             STRING    -- 'view','cart','purchase_recent','purchase_historical','bestseller'
rec1..4_signal_age_days  INT64     -- days since freshest supporting signal (NULL for bestseller)
rec_count                INT64     -- 1..4
dominant_signal          STRING    -- the top signal type across all user recs
engagement_tier          STRING    -- 'hot' | 'warm' | 'cold' | 'fallback'
generated_at             TIMESTAMP
pipeline_version         STRING    -- 'v5.19'
```

`dominant_signal` is the contract the email treatment system uses to pick language (e.g., "Still thinking about this?" for cart, "You might also like…" for bestseller).

Engagement tier definition:
- `hot`: any cart or view signal within last 7 days
- `warm`: any view or purchase signal within last 30 days (and not hot)
- `cold`: purchase-only signal (recent or historical)
- `fallback`: bestseller-only (no user signal)

### Data Volume
- Target audience: ~1.8M no-YMM active users
- Upper bound output (from investigation): ~168K users with signal in 180 days + bestseller fallback
- Expected output: ≥150K with signal, up to ~1.8M if bestseller fallback is enabled for no-signal users
- Processing: on-demand pipeline runs

## Architecture & Approach

### 1) User Universe
No-YMM users with valid email. Disjoint from v5.18's YMM universe. Defined as: any user from `ingestion_unified_attributes_schema_incremental` with valid email but missing ≥1 of `{v1_year, v1_make, v1_model}` (or where year fails `SAFE_CAST INT64`).

### 2) Signal Extraction
Reuse `staged_events` pattern from `sql/recommendations/v5_18_fitment_recommendations.sql:185-260`. For each event, extract a (user_id, sku, event_ts, signal_type) tuple:

| Event | SKU property pattern | Signal type |
|-------|----------------------|-------------|
| `VIEWED PRODUCT` | `^prod(?:uct)?id$` | `view` |
| `CART UPDATE` | `^items_[0-9]+\.productid$` | `cart` |
| `ORDERED PRODUCT` / `PLACED ORDER` / `CONSUMER WEBSITE ORDER` | (existing v5.18 patterns) | `purchase_recent` |
| `import_orders.ITEM` | — | `purchase_historical` |

Event window: events table last 365 days; `import_orders` all-time. Consistent with v5.18's Sep 1, 2025 boundary between recent and historical.

### 3) Scoring Formula
For each (user, sku) pair:

```
score(u, s) = Σ_{signal ∈ signals(u, s)} weight[signal] × exp(-age_days[signal] / tau[signal])
```

Initial parameters (tunable as `DECLARE` constants):

| Signal | weight | tau (days) | Rationale |
|--------|--------|------------|-----------|
| cart | 10.0 | 7 | 70% same-SKU conversion — strongest signal |
| view | 5.0 | 3 | 30% same-SKU conversion, very fast decay (90% within 14d) |
| purchase_recent | 3.0 | 30 | Proven intent but not repeat-purchase target |
| purchase_historical | 2.0 | 180 | Long-proven taste, low recency |
| bestseller | 1.0 | ∞ | No decay; lowest confidence catch-all |

### 4) Candidate Generation
Union of:
- User-signaled SKUs (viewed / carted / purchased, as scored above)
- Top-N global bestsellers (last 365 days of orders) as fallback with `bestseller` signal

### 5) Filters (reuse v5.18 logic)
1. Purchase exclusion: drop SKUs the user bought in last 365 days (variant-normalized)
2. Price floor: `$25` (tunable)
3. HTTPS image required
4. Refurbished and commodity items excluded (reuse v5.18 `import_items_tags` + PartType filters)
5. Variant dedup: strip `[0-9][BRGP]$` suffix
6. Diversity cap: max 2 SKUs per `PartType` per user

### 6) Selection
Rank by score DESC, take top 4. Require ≥1 rec per user (NULL fill beyond rec count). If user has zero candidates after filters, populate from bestsellers so fallback engagement_tier users still receive recs.

## Open Questions
- [ ] Tau values are initial guesses grounded in decay data. Grid-search during QA or ship defaults and tune via A/B?
- [ ] Bestseller granularity: overall top sellers, or per-PartType top sellers (more diverse fallback)?
- [ ] Should `signal_age_days` be kept in production output (analytics-only column)?
- [ ] Should we cap bestseller-only output users (e.g., only emit fallback for opted-in users)?

## Success Criteria
- [ ] 0 overlap with v5.18's YMM users (email_lower disjoint from `final_vehicle_recommendations`)
- [ ] ≥150K users with signal-based recs
- [ ] 0 duplicate SKUs within a user row
- [ ] 0 prices < $25
- [ ] 0 refurbished products
- [ ] All recs have HTTPS images
- [ ] Diversity cap honored (≤2 per PartType per user)
- [ ] `dominant_signal` ∈ {cart, view, purchase_recent, purchase_historical, bestseller}
- [ ] `engagement_tier` ∈ {hot, warm, cold, fallback}
- [ ] Score ordering monotonic across rec slots within a user

## Evaluation Metrics
| Metric | Target |
|--------|--------|
| Users served | ≥150K with signal |
| Purchase exclusion violations | 0 |
| Fitment mismatch (N/A — this pipeline is non-fitment) | — |
| Duplicate SKU rows | 0 |
| Price floor violations | 0 |
| Rec coverage (rec_count=4 share) | Monitor |

Downstream A/B metric (deferred — separate deploy step):
- Email CTR on v5.19 recs vs. non-personalized baseline for no-YMM segment

## Test Plan

### SQL Validation
- [ ] Dry-run pipeline SQL via `bq query --dry_run`
- [ ] Execute pipeline in `temp_holley_v5_19` dataset

### QA Validation (new go/no-go eval)
- [ ] `sql/validation/v5_19_go_no_go_eval.sql` mirrors v5.18's severity-ranked checks
- [ ] Extend `qa_checks.sql` to branch on `pipeline_version` ∈ {v5.18, v5.19}

### Targeted Validation
- [ ] Pick 20 users across signal types (5 cart-heavy / 5 view-heavy / 5 purchase-heavy / 5 bestseller-only). Manually verify recs correlate with signals.
- [ ] Confirm coverage ≥100K users with signal (investigation estimated 168K with 180d signal)

## Dependencies
- [ ] Downstream email routing system ingests `dominant_signal` column
- [ ] Treatment system can accommodate non-YMM user segment
- [ ] Sign-off on tau values and weights before production deploy

## Implementation Notes
(Fill during/after implementation)

---
Created: 2026-04-15
Author: Praveen + Claude
Approved by: [TBD]
