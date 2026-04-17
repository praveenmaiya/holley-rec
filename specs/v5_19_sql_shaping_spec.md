# V5.19 SQL-Shaping Spec

Date: 2026-04-16
Linear: AUX-14029
Status: implementation-ready shaping spec
Inputs:
- `specs/v5_19_updated_ticket_design.md`
- `specs/v5_19_sql_shaping_pre_draft.md`
- `sql/recommendations/v5_19_non_fitment_recommendations.sql`

## Goal

Reshape the non-fitment portion of `v5.19` from exact-SKU scoring into a
`seed -> co-purchase expansion -> flow-safe exclusion -> rank -> unchanged Step 3.3 pivot`
pipeline, while preserving:

- the shared final table `final_vehicle_recommendations`
- the current 32-column delivery contract
- the fitment snapshot + union release shape
- the existing exact-SKU non-fitment path only as a generic floor/backfill layer

## Locked contracts carried in

1. Final delivery table remains `auxia-reporting.temp_holley_v5_19.final_vehicle_recommendations`, with optional guarded deploy to `auxia-reporting.company_1950_jp.final_vehicle_recommendations`.
2. No new delivery columns. `rec*_type='non_fitment'` remains the row-level audience marker for non-fitment rows.
3. `v1_year`, `v1_make`, `v1_model` are `'UNKNOWN'` for non-fitment rows.
4. Lifetime purchase exclusion applies to final recommended SKUs.
5. A single stored row must be safe to show in any flow within the accepted daily-build / batched-send cadence boundary.
6. `browse_recovery_lookback_days` is a top-level BigQuery `DECLARE`, default `7`.
7. `co_purchase_graph` is the only v1 related-item engine. No same-brand / same-PartType heuristics in this version.
8. The current exact-SKU non-fitment logic is retained only as a fallback floor, not the primary personalization path.

## High-level shape

The implementation splits non-fitment ranking into two parallel sources:

1. **Primary related-item path**
   - derive user seeds from lifetime purchases, latest cart snapshot, and browse history
   - expand seeds through a co-purchase graph
   - exclude purchased/carted/recently viewed candidates
   - rank remaining related candidates

2. **Backup floor path**
   - retain the current exact-SKU `cart/view + bestseller` engine as a generic backup source
   - apply the same lifetime/cart/recent-browse exclusions to make it flow-safe
   - use it only to backfill users or slots not covered by the primary related-item path

The two paths merge into one ranked non-fitment candidate table, which feeds the existing Step 3.3 pivot unchanged.

## DECLAREs

Retain existing DECLAREs already present in `v5_19_non_fitment_recommendations.sql`.

Add:

```sql
DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;
DECLARE min_co_purchase_support INT64 DEFAULT 3;
DECLARE min_seed_buyer_count INT64 DEFAULT 5;

DECLARE w_purchase_seed FLOAT64 DEFAULT 3.0;
DECLARE w_cart_seed FLOAT64 DEFAULT 2.0;
DECLARE w_view_seed FLOAT64 DEFAULT 1.0;

DECLARE tau_purchase_seed FLOAT64 DEFAULT 90.0;
DECLARE tau_cart_seed FLOAT64 DEFAULT 14.0;
DECLARE tau_view_seed FLOAT64 DEFAULT 30.0;
```

These are implementation defaults, not a frozen product contract. They are chosen to:

- keep purchase seeds strongest
- keep cart seeds materially stronger than browse
- keep historical browse non-zero instead of decaying to irrelevance immediately

## Working tables

Retain current base working tables:

- `tbl_noymm_users`
- `tbl_ymm_users`
- `tbl_staged_signals`
- `tbl_sku_prices`
- `tbl_sku_images`
- `tbl_eligible_skus`
- `tbl_bestsellers`
- `tbl_purchase_history`
- `tbl_purchase_excl`
- `tbl_fitment_snapshot`
- `tbl_final`

Add:

- `tbl_co_purchase_graph`
- `tbl_active_cart_context`
- `tbl_recent_browse_context`
- `tbl_seed_sku_per_user`
- `tbl_related_candidate_pool`
- `tbl_related_filtered`
- `tbl_related_ranked`
- `tbl_floor_filtered`
- `tbl_floor_ranked`
- `tbl_ranked_merged`

Implementation note: keep `tbl_final_nf`, `tbl_ranked`, and the Step 3.3 pivot shape intact where possible. `tbl_ranked_merged` should become the input that replaces the current `tbl_ranked` semantics.

## Step-by-step pipeline shape

### 0. User universes

Keep current Step 0 unchanged:

- `ymm_users_for_exclusion`
- `no_ymm_users`

This remains the email-level disjointness guard between fitment and non-fitment audiences.

### 1. Shared staging / catalog / exclusion inputs

Keep the following sections conceptually unchanged from the current file:

- staged event extraction into `tbl_staged_signals`
- price extraction into `tbl_sku_prices`
- image extraction into `tbl_sku_images`
- eligible catalog construction into `tbl_eligible_skus`
- bestseller construction into `tbl_bestsellers`
- lifetime purchase exclusion into `tbl_purchase_excl`

Important rule: `tbl_eligible_skus` remains the single source of truth for catalog eligibility. The new co-purchase graph must join to this table rather than re-implementing a partial subset of the rules.

### 2. Co-purchase graph

Build `tbl_co_purchase_graph` from lifetime purchase history, using normalized SKUs on both sides.
Implementation constraint: `import_orders` does not expose an order id, so v1 co-purchase must be built at the buyer-history level (`email_lower` / chosen user), not strict same-order co-occurrence.

Grain:
- one row per `(seed_sku, related_sku)`

Columns:
- `seed_sku`
- `related_sku`
- `co_order_count`
- `seed_buyer_count`
- `related_buyer_count`
- `co_score`

Filters:
- `seed_sku != related_sku`
- both sides must exist in `tbl_eligible_skus`
- minimum support gate:
  - `co_order_count >= min_co_purchase_support`
  - `seed_buyer_count >= min_seed_buyer_count`

Initial scoring:

```text
co_score = SAFE_DIVIDE(co_order_count, seed_buyer_count) * LOG(1 + co_order_count)
```

Reason:
- `P(related | seed)` is the right directional score for seeded recommendations
- `LOG(1 + co_order_count)` downranks brittle one-off pairs without requiring a more complex lift/PMI model in v1

### 3. Active-cart context

Build `tbl_active_cart_context` from the latest `CART UPDATE` per chosen `user_id` / `email_lower`.

Grain:
- one row per `(email_lower, cart_sku_normalized)`

Columns:
- `email_lower`
- `cart_sku_normalized`
- `cart_snapshot_ts`

Rules:
- normalize SKU with the same `[0-9][BRGP]$` strip rule used elsewhere
- empty-cart updates produce zero rows after `UNNEST`, which is correct
- accept the known stale-cart residual after checkout; do not attempt to infer delta-state from missing events

### 4. Recent-browse context

Build `tbl_recent_browse_context` from view events in `tbl_staged_signals`.

Grain:
- one row per `(email_lower, browse_sku_normalized)`

Columns:
- `email_lower`
- `browse_sku_normalized`
- `last_view_ts`

Rules:
- consume `browse_recovery_lookback_days` in exactly this table's source filter
- this table is for exclusion only
- dedupe to most recent timestamp per `(email_lower, browse_sku_normalized)`

### 5. Seed extraction

Build `tbl_seed_sku_per_user` by unioning three seed families:

1. **purchase seeds**
   - source: lifetime purchase history, same logical source used by `tbl_purchase_excl`
   - score:
     - `seed_weight = w_purchase_seed * EXP(-age_days / tau_purchase_seed)`

2. **cart seeds**
   - source: `tbl_active_cart_context`
   - score:
     - `seed_weight = w_cart_seed * EXP(-age_days / tau_cart_seed)`
   - `age_days` is derived from `cart_snapshot_ts`

3. **browse seeds**
   - source: view rows in `tbl_staged_signals` across the full signal window
   - includes both recent and historical browse
   - score:
     - `seed_weight = w_view_seed * EXP(-age_days / tau_view_seed)`

Grain:
- one row per `(email_lower, seed_sku, seed_source)`

Columns:
- `email_lower`
- `seed_sku`
- `seed_source` in `('purchase','cart','view')`
- `seed_weight`
- `seed_event_ts` for debugging / argmax tie-breaks

Aggregation rule:
- if the same `(email, seed_sku, seed_source)` appears multiple times, keep the maximum `seed_weight`

### 6. Related candidate expansion

Build `tbl_related_candidate_pool` by joining `tbl_seed_sku_per_user` to `tbl_co_purchase_graph`.

Initial candidate score:

```text
candidate_score = seed_weight * co_score
```

Grain before aggregation:
- `(email_lower, seed_sku, seed_source, candidate_sku)`

Aggregate to:
- `(email_lower, candidate_sku)`

Keep:
- `MAX(candidate_score)` as `candidate_score`
- `argmax(seed_sku)` as `best_seed_sku`
- `argmax(seed_source)` as `best_seed_source`

### 7. Related candidate filtering

Build `tbl_related_filtered` by applying exclusions in this order:

1. lifetime purchase exclusion via `tbl_purchase_excl`
2. active-cart exclusion via `tbl_active_cart_context`
3. recent-browse exclusion via `tbl_recent_browse_context`
4. join back to `tbl_eligible_skus` as a defensive re-check

Then apply:

5. base-SKU variant dedup
6. score ordering within base SKU

Do **not** apply PartType diversity yet. Diversity must see the merged primary+floor pool, not only the related path.

### 8. Related primary ranking

Build `tbl_related_ranked` with:

- `email_lower`
- `candidate_sku`
- `final_score`
- `source_tier = 1`
- `source_family = 'related'`
- `best_seed_sku`
- `best_seed_source`
- provisional per-user rank by `final_score DESC, candidate_sku`

This table is not yet the final ranked input to Step 3.3. It is the primary candidate source.

### 9. Backup floor path

Retain the current exact-SKU non-fitment engine conceptually, but demote it to a backup layer:

- cart/view exact-SKU scoring
- bestseller floor
- no purchase signals

Implementation rule:
- reuse as much of the current Step 3 scoring logic as possible
- but apply the same three flow-safety exclusions before the floor is allowed to backfill:
  - lifetime purchase exclusion
  - active-cart exclusion
  - recent-browse exclusion

Build:

- `tbl_floor_filtered`
- `tbl_floor_ranked`

with:
- `source_tier = 2`
- `source_family = 'floor'`

This path exists only to fill empty or partially filled related-item rows.

### 10. Merge primary and floor candidates

Build `tbl_ranked_merged` by unioning:

- `tbl_related_ranked`
- `tbl_floor_ranked`

Then, on the unioned pool:

1. re-apply base-SKU dedup across both sources
2. apply max-2-per-PartType diversity across both sources
3. rank by:
   - `source_tier ASC`
   - `final_score DESC`
   - `candidate_sku`

This gives the required behavior:

- related candidates always beat floor candidates
- floor candidates can still backfill slots 2-4
- users with zero related candidates still receive a row from the backup path

### 11. Step 3.3 pivot

Keep the existing non-fitment pivot contract unchanged.

Input requirement:
- one ranked table with up to 4 candidates per `email_lower`

Use `tbl_ranked_merged` as the effective replacement for the current `tbl_ranked`.

Populate the same final non-fitment row shape:

- `v1_* = 'UNKNOWN'`
- `rec*_type = 'non_fitment'`
- `rec*_pop_source = NULL`
- `engagement_tier = NULL`
- `fitment_count = NULL`
- `pipeline_version = 'v5.19'`
- `generated_at = pipeline_start`

### 12. Fitment snapshot + shared final table

Keep the current shared-table release shape:

1. snapshot `temp_holley_v5_18.final_vehicle_recommendations`
2. re-project fitment rows with:
   - fresh `generated_at = pipeline_start`
   - `pipeline_version = 'v5.19'`
3. union with the non-fitment Step 3.3 output
4. materialize `temp_holley_v5_19.final_vehicle_recommendations`
5. guarded optional deploy to production

## Validation changes required

### `sql/validation/qa_checks.sql`

Must continue checking shared-table invariants, but non-fitment rows need the new expectations:

- `rec*_type` must null out with null slots
- non-fitment rows may be related-backed or floor-backed
- `engagement_tier` and `fitment_count` remain NULL for non-fitment rows
- browse/cart flow-safety should be checked as exclusion assertions against the new context tables where practical

### `sql/validation/v5_19_go_no_go_eval.sql`

Current signal-coverage framing must be relaxed.

Changes:
- demote `signal_based_non_fitment_user_count >= 150k` from hard gate to informational
- add related-item coverage metrics:
  - users with at least 1 related-backed rec
  - users fully served by related path
  - users requiring floor backfill
  - users ending as bestseller-dominant

## Implementation order

1. Add new DECLAREs and working-table names.
2. Keep current Step 0 and Step 1 base-table logic stable.
3. Implement `co_purchase_graph`.
4. Implement `active_cart_context` and `recent_browse_context`.
5. Implement `seed_sku_per_user`.
6. Implement `related_candidate_pool` and `related_filtered`.
7. Refactor the current exact-SKU scoring path into an explicit backup floor path.
8. Merge related + floor into one ranked table.
9. Reuse Step 3.3 pivot.
10. Keep fitment snapshot / union / deploy sections aligned with the current shared-table logic.
11. Update QA and go/no-go validators.

## Non-goals

- no new delivery tables
- no same-brand / same-PartType heuristic expansion
- no runtime/send-time filtering
- no sub-day browse window precision
- no redesign of the fitment slice
