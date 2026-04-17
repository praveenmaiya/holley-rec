# Feature: V5.19 Recommendations — Extend Coverage to Non-Fitment Users

## Status
- [x] Draft (rewritten 2026-04-16 from locked restructure plan `tasks/v5_19_restructure_plan.md` r7)
- [ ] In Review
- [ ] Approved
- [ ] In Progress
- [ ] Completed

Linear: AUX-14029
Branch: `praveen-aux-14029`

## What V5.19 Is

V5.19 is a **release**, not a separate algorithm. It extends the V5.18 fitment pipeline to also cover users who do **not** have vehicle (YMM) data, using a behavior-based algorithm. Both audiences land in the **same** output table with the **same column set**.

| Audience | Algorithm that produces the row | Approx. size | `rec1_type` |
|----------|----------------------------------|--------------|-------------|
| Fitment users (have YMM) | V5.18 fitment + popularity logic — **unchanged** | ~457K | `'fitment'` |
| Non-fitment users (no YMM) | V5.19 behavior-based logic — **new** | ~1.8M addressable | `'non_fitment'` |

The two audiences are **disjoint by email**. Total addressable jumps from ~457K (V5.18) to ~2.25M (V5.19 release).

## Problem Statement

V5.18 served ~457K YMM users with vehicle-fitment recommendations. The remaining ~1.8M active no-YMM users received nothing personalized despite leaving strong behavior signals (cart adds, product views).

V5.19 closes that coverage gap with a unified shared output table. Downstream email systems read one table; row-level audience routing is via existing `rec1..4_type` column values (`'fitment'` vs `'non_fitment'`).

## Scope

**In scope:**
1. New non-fitment algorithm covering ~1.8M no-YMM users
2. Combined output to existing `final_vehicle_recommendations` table (no new columns, no new table)
3. V5.18 fitment algorithm unchanged
4. Per-run-overwritten fitment snapshot + UNION ALL to keep release atomic
5. Lifetime purchase exclusion for non-fitment rows
6. QA migration so existing value-set checks branch on `rec1_type`

**Out of scope (deferred to V5.20+):**
1. Collaborative filtering ("users who browsed X also browsed Y")
2. Search query → SKU mapping
3. Brand / category / PartType campaign targeting
4. GNN approach (V6.x track)
5. Purchase-based related-item personalization (since exact-SKU purchase candidates are always lifetime-excluded)
6. Tuning of cart/view weights and taus — ship current values, tune via post-launch CTR data

## Locked Contract

These are not open choices. Sourced from `tasks/v5_19_restructure_plan.md` r7:

1. **Single shared output table** — `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
2. **No new columns** — V5.18's column set is preserved exactly. V5.19 internal fields (`dominant_signal`, signal types, signal ages, 4-tier engagement) live only in `temp_holley_v5_19` working tables
3. **Row-level audience marker** — `rec1_type ∈ {'fitment', 'non_fitment'}`. Within a row, all populated `recN_type` slots equal each other
4. **Single release tag** — `pipeline_version = 'v5.19'` for **every** row in the post-restructure table
5. **YMM placeholders** — non-fitment rows: `v1_year = v1_make = v1_model = 'UNKNOWN'`
6. **Lifetime purchase exclusion** for non-fitment rows (V5.18 stays at 365d)
7. **V5.19 signal set** — `{cart, view, bestseller}` only. Purchase signals dropped
8. **V5.19 price floor** — `$50` (matches V5.18; do not lower)
9. **Materialization** — V5.19 SQL must snapshot V5.18 staging into a per-run-overwritten table before UNION ALL (V5.18 staging is `CREATE OR REPLACE`'d, so direct read is racy)
10. **`generated_at` semantics** — both row types are stamped with a **fresh shared-table run timestamp** at UNION time. Fitment rows do **not** preserve their original V5.18 build timestamp; they are re-projected with the V5.19 release run timestamp so the whole shared table reflects one logical release moment. This matches the existing post-deploy reporting at `sql/recommendations/v5_18_fitment_recommendations.sql:1086` which expects a single `generated_at` for the table

## Output Schema

`final_vehicle_recommendations` keeps V5.18's exact column set. V5.19 fills the columns as follows:

| Column | V5.18 (fitment) row | V5.19 (non-fitment) row |
|--------|---------------------|-------------------------|
| `email_lower` | user email | user email |
| `v1_year` | YMM year | `'UNKNOWN'` |
| `v1_make` | YMM make | `'UNKNOWN'` |
| `v1_model` | YMM model | `'UNKNOWN'` |
| `rec_part_1..4` | fitment-filtered SKUs | non-fitment SKUs (cart/view + bestseller) |
| `rec1..4_price` | price | price |
| `rec1..4_score` | popularity score | recency-weighted behavior score |
| `rec1..4_image` | HTTPS image URL | HTTPS image URL |
| `rec1..4_type` | `'fitment'` | `'non_fitment'` |
| `rec1..4_pop_source` | `'segment'` / `'make'` / `'global'` | `NULL` |
| `engagement_tier` | `'hot'` / `'cold'` (from V5.18 logic) | `NULL` |
| `fitment_count` | `3` or `4` | `NULL` |
| `generated_at` | shared-table run timestamp (fresh at UNION; **not** the original V5.18 build timestamp) | shared-table run timestamp (fresh at UNION) |
| `pipeline_version` | `'v5.19'` | `'v5.19'` |

**Note on `rec1..4_score`:** scale and meaning differ across audiences (V5.18 popularity vs V5.19 behavior score). Within an audience, ordering across slots is monotonically decreasing. Cross-audience score comparison is not meaningful.

## Algorithm — V5.18 Fitment Users (unchanged)

V5.18's fitment logic is preserved exactly. See `docs/architecture/v5_18_architecture_specification.md` for the authoritative algorithm description. Summary:

1. Universe: users with valid email + complete YMM
2. Candidate pool: SKUs that fit user's vehicle (from `vehicle_product_fitment_data`)
3. Ranking: tiered popularity (segment → make → global)
4. Filters: price ≥ $50, no refurbished, ≤2 per PartType, variant dedup, exclude purchases (last 365d)
5. Output: top 4 SKUs

The only change is metadata when these rows land in the shared table:
- `rec1..4_type = 'fitment'` (was already this value, now semantically the audience marker)
- `pipeline_version = 'v5.19'` (was `'v5.18'` in V5.18 release)

## Algorithm — V5.19 Non-Fitment Users (new)

### Step 1 — Universe

Users with valid email but **missing** YMM. Specifically: any user from `ingestion_unified_attributes_schema_incremental` with valid email, where at least one of `{v1_year, v1_make, v1_model}` is missing or `v1_year` fails `SAFE_CAST(... AS INT64)`.

**Disjointness gate:** anti-join against the V5.18 fitment universe (by email) so that no user appears in both audiences.

### Step 2 — Signal extraction

For each non-fitment user, extract `(user_id, sku, event_ts, signal_type)` tuples from event data:

| Signal | Source | Event/Pattern |
|--------|--------|---------------|
| `cart` | `ingestion_unified_schema_incremental` | `event_name = 'CART UPDATE'`, SKU from `^items_[0-9]+\.productid$` |
| `view` | `ingestion_unified_schema_incremental` | `event_name = 'VIEWED PRODUCT'`, SKU from `^prod(?:uct)?id$` |
| `bestseller` | global top-N from `import_orders` (last 365d of orders) | cross-joined to every non-fitment user as a baseline candidate |

Event window: events table last 365 days.

**Purchase signals are not scored.** Under exact-SKU candidate generation + lifetime purchase exclusion (Step 4), any purchase candidate would be removed before ranking. See "Why purchase signals are dropped" below.

### Step 3 — Scoring

For each `(user, SKU)` pair, sum recency-weighted contributions across that user's signals on that SKU:

```
score(user, sku) = Σ over signals on (user, sku):  weight × exp( -age_days / tau )
```

| Signal | weight | tau (days) | Decay behavior |
|--------|--------|------------|----------------|
| `cart` | 10.0 | 7 | strongest signal; falls below bestseller floor (1.0) at age ≈ 16 days |
| `view` | 5.0 | 3 | weaker, faster decay; falls below bestseller floor at age ≈ 5 days |
| `bestseller` | 1.0 | ∞ | constant floor; cross-joined to every user; never decays |

**Implication:** bestsellers are always in the scored pool. A user's stale cart/view can be outranked by generic bestsellers above the crossover thresholds. This is intentional under the locked Path A scoring model — fresh popularity is preferred over stale intent.

Weights and taus are inherited from the current branch and treated as starting values. Tuning is deferred to post-launch A/B analysis.

### Step 4 — Filters

Same filter shape as V5.18, with one substitution:

1. **Lifetime purchase exclusion** — drop any (user, SKU) where the user has ever purchased that SKU (events + `import_orders`, all-time). This is the only filter difference vs V5.18.
2. Price floor `$50`
3. HTTPS image required
4. Refurbished and commodity items excluded (`import_items_tags` + PartType filters per V5.18)
5. Variant dedup — strip `[0-9][BRGP]$` suffix
6. Diversity cap — max 2 SKUs per `PartType` per user

### Step 5 — Selection

1. Rank surviving (user, SKU) candidates by score DESC, take top 4
2. **Hard fallback:** if a user has 0 surviving candidates after filters, fill all 4 slots from the bestseller pool — ensures every non-fitment user receives recommendations

Fewer than 4 surviving non-bestseller candidates? Backfill from bestsellers (already in the scored pool, so this happens naturally via the rank step).

### Step 6 — Projection into shared schema

Each non-fitment row is projected into the V5.18 column set per the Output Schema table above. Critical literals:
- `rec1..4_type = 'non_fitment'`
- `v1_year = v1_make = v1_model = 'UNKNOWN'`
- `rec1..4_pop_source = NULL`
- `engagement_tier = NULL`
- `fitment_count = NULL`
- `pipeline_version = 'v5.19'`

## Materialization Strategy

**V5.18 must run before V5.19 each release cycle.** The V5.19 SQL performs:

1. Assert V5.18 staging is non-empty (loud error if empty):
   ```sql
   SELECT IF(
     (SELECT COUNT(*) FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`) = 0,
     ERROR('V5.18 fitment staging is empty — run V5.18 before V5.19'),
     'OK'
   );
   ```
2. Snapshot V5.18 staging into a per-run-overwritten V5.19 source table (release-cycle snapshot):
   ```sql
   CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_19.fitment_source_snapshot` AS
   SELECT * FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`;
   ```
   The snapshot is a fixed table name, overwritten on each V5.19 run. It is not per-run uniquely named; the goal is to stop V5.19's UNION from reading V5.18's staging table while a concurrent V5.18 rerun mutates it, not to retain history. This is required because V5.18's staging table is itself `CREATE OR REPLACE`'d every run; reading it directly during V5.19's UNION is racy.
3. Build non-fitment candidate rows in `temp_holley_v5_19.*` working tables
4. Apply lifetime exclusion + filters + selection
5. Project non-fitment rows into V5.18 schema
6. UNION ALL: snapshotted fitment rows (re-projected with `pipeline_version = 'v5.19'` and a fresh `generated_at = CURRENT_TIMESTAMP()`) + non-fitment rows (also tagged with the same fresh `generated_at`) → `temp_holley_v5_19.final_vehicle_recommendations`. All rows in the shared table carry one logical release timestamp.
7. Validate (go/no-go + QA)
8. Deploy combined shared table to `company_1950_jp.final_vehicle_recommendations`

## Why Purchase Signals Are Dropped

V5.19 generates candidates as **exact SKUs** (the same SKU you carted/viewed). Lifetime exclusion then removes any SKU you have ever purchased. So:
- `purchase_recent` candidate = SKU you bought → always excluded → never appears as a recommendation
- `purchase_historical` candidate = SKU you bought → always excluded → never appears as a recommendation

Scoring purchase signals would burn CPU on candidates that always die at the filter step. They are removed from the scoring code entirely under V5.19.

A future V5.20 could revive purchase signals by switching to **related-item** candidates (same PartType, same brand, complementary parts) instead of exact SKU.

## Disjointness Guarantee

By construction:
- V5.18 universe = users with **complete** YMM
- V5.19 universe = users with **incomplete or missing** YMM, anti-joined against V5.18 by email

Validated in go/no-go: no email appears in both `rec1_type = 'fitment'` and `rec1_type = 'non_fitment'` row partitions.

## QA Migration (Mandatory)

The existing `sql/validation/qa_checks.sql` enforces V5.18-only invariants that will fail when V5.19 rows land in the shared table. Required changes:

| Existing check | Change |
|----------------|--------|
| `rec*_type = 'fitment'` (implicit invariant) | enforce only when `rec1_type = 'fitment'`; allow `'non_fitment'` rows |
| `engagement_tier IN ('hot','cold')` (line 233) | enforce only when `rec1_type = 'fitment'`; allow `NULL` when `rec1_type = 'non_fitment'` |
| `fitment_count IN (3,4)` (line 216) | enforce only when `rec1_type = 'fitment'`; allow `NULL` when `rec1_type = 'non_fitment'` |
| (new) cross-slot consistency | within a row, all populated `recN_type` slots equal each other |
| (new) pipeline_version single-valued | `COUNT(DISTINCT pipeline_version) = 1` across the shared table |

Plus existing universal checks (price ≥ $50, HTTPS images, no duplicates within row, etc.) apply to all rows regardless of audience.

## Success Criteria

- [ ] 0 emails appearing in both `rec1_type = 'fitment'` and `rec1_type = 'non_fitment'` partitions
- [ ] V5.18 fitment row count and content unchanged vs current V5.18-only output (modulo `pipeline_version` re-tagging)
- [ ] ≥150K non-fitment users with signal-based (cart or view) recs
- [ ] Up to ~1.8M non-fitment users covered with bestseller fallback
- [ ] 0 duplicate SKUs within any row (any audience)
- [ ] 0 prices < $50 (any audience)
- [ ] 0 refurbished products (any audience)
- [ ] All recs have HTTPS images (any audience)
- [ ] Diversity cap honored (≤2 per PartType per user, any audience)
- [ ] 0 lifetime purchase exclusion violations for `rec1_type = 'non_fitment'` rows
- [ ] 0 365-day purchase exclusion violations for `rec1_type = 'fitment'` rows
- [ ] Within each row: all populated `recN_type` slots equal each other
- [ ] `pipeline_version = 'v5.19'` for every row, no other values present
- [ ] No `purchase_recent` / `purchase_historical` values appear in V5.19 working-table signal enums

## Test Plan

### SQL Validation
- [ ] Dry-run the rewritten V5.19 pipeline SQL via `bq query --dry_run`
- [ ] Dry-run the migrated `qa_checks.sql`
- [ ] Dry-run the rewritten `v5_19_go_no_go_eval.sql`

### Staging Execution
- [ ] Run V5.18 to populate `temp_holley_v5_18.final_vehicle_recommendations`
- [ ] Run V5.19 (which snapshots V5.18 staging, then UNIONs)
- [ ] Confirm `temp_holley_v5_19.final_vehicle_recommendations` exists with both row types

### QA Validation
- [ ] `qa_checks.sql` passes against shared table
- [ ] `v5_19_go_no_go_eval.sql` passes against shared table
- [ ] Disjointness check passes
- [ ] V5.18-row invariants identical to V5.18-only baseline (modulo pipeline_version)

### Targeted Sample
- [ ] 5 cart-heavy non-fitment users — recs reflect their cart history
- [ ] 5 view-heavy non-fitment users — recs reflect their view history
- [ ] 5 bestseller-only non-fitment users — recs are popular SKUs
- [ ] 5 fitment users from V5.18 source — recs match what V5.18 alone would produce

## Dependencies

- [ ] V5.18 fitment pipeline must run successfully **before** V5.19 each release cycle
- [ ] Downstream email pipeline reads existing schema columns only (`email_lower`, `rec_part_1..4`, prices, images, `rec1..4_type` for routing)
- [ ] No downstream consumer should be wired to a `final_non_fitment_recommendations` table (the as-built branch's separate-table design is dropped — confirm no consumers exist before deleting the table reference)

## Files Affected

| File | Change |
|------|--------|
| `sql/recommendations/v5_19_non_fitment_recommendations.sql` | Drop separate-table write target; lifetime exclusion (was 365d); drop purchase scoring; price floor $50 (was $25); add fitment-source snapshot + UNION ALL; emit shared schema with locked literals |
| `sql/recommendations/v5_18_fitment_recommendations.sql` | No algorithmic change. Optional: change `pipeline_version` literal from `'v5.18'` → `'v5.19'` (or do this only at V5.19 UNION step — easier) |
| `sql/validation/qa_checks.sql` | Parameterize value-set checks per `rec1_type`; add cross-slot and single-pipeline_version invariants |
| `sql/validation/v5_19_go_no_go_eval.sql` | Retarget to shared table; validate disjointness, lifetime exclusion for non-fitment rows, V5.18 invariants for fitment rows |
| `docs/architecture/v5_18_architecture_specification.md` | Update value vocabularies for `rec*_type`, `engagement_tier`, `fitment_count`; document the audience discriminator and snapshot+UNION materialization |
| `docs/release_notes.md` | Rewrite V5.19 entry around shared table, lifetime exclusion, V5.18 → V5.19 ordering, mandatory snapshot |

## Implementation Notes

(Fill during/after implementation)

---
Created: 2026-04-15 (original draft)
Rewritten: 2026-04-16 from `tasks/v5_19_restructure_plan.md` r7
Author: Praveen + Claude + Codex
Approved by: [TBD]
