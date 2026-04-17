# V5.19 SQL-Shaping Pre-Draft

Date: 2026-04-16
Linear: AUX-14029
Status: pre-draft (prose + table shapes only; NO SQL). Intended for one fast Codex pass before the full SQL-shaping spec.
Input: `specs/v5_19_updated_ticket_design.md` (Codex pass 10 sign-off).

Scope of this document:
- Lock the five intermediate tables' grain and columns.
- Lock the pipeline build order.
- Lock the candidate-exclusion order.
- Lock placement of `browse_recovery_lookback_days` DECLARE.
- Confirm how the new candidate pool feeds the unchanged Step 3.3 pivot → `final_vehicle_recommendations`.

**Out of scope for this pre-draft:** actual SQL, variable-level seed-weight formulas, fallback-floor re-design, `v5_19_go_no_go_eval.sql` gate re-shape. Those belong in the full SQL-shaping spec.

---

## 1. Intermediate tables

All `CREATE OR REPLACE TABLE` in `auxia-reporting.temp_holley_v5_19.*`. All user-level tables key on `email_lower` (per disjoint invariant, chosen `user_id` per email is upstream of this layer).

### 1.1 `co_purchase_graph`
- **Grain:** one row per ordered pair `(seed_sku, related_sku)` with `seed_sku != related_sku`.
- **Columns:** `seed_sku`, `related_sku`, `co_order_count INT64`, `co_score FLOAT64` (normalized, e.g., PMI-style or lift over marginal).
- **Derivation:** `import_orders` + event-side purchases rolled up to the buyer-history level (same `email_lower` / chosen user), since `import_orders` does not expose an order id. Eligibility filter applied at build time by joining both sides to the existing `eligible_skus` contract (`tbl_eligible_skus` / current Step 1.3 semantics) rather than re-stating a narrower subset here. Both `seed_sku` and `related_sku` must already satisfy the pipeline's catalog rules before entering the graph.
- **User-agnostic.** Built once per pipeline run.

### 1.2 `active_cart_context`
- **Grain:** one row per `(email_lower, cart_sku_normalized)`.
- **Columns:** `email_lower`, `cart_sku_normalized`, `cart_snapshot_ts` (for debugging; timestamp of the `CART UPDATE` event the SKU was sourced from).
- **Derivation:** per Locked decision 4 — latest `CART UPDATE` per chosen `user_id` per email, `UNNEST items_N.productid`, normalize via `[0-9][BRGP]$` strip rule.
- **User-level.**

### 1.3 `recent_browse_context`
- **Grain:** one row per `(email_lower, browse_sku_normalized)`.
- **Columns:** `email_lower`, `browse_sku_normalized`, `last_view_ts`.
- **Derivation:** view events where `DATE(event_ts) >= DATE_SUB(CURRENT_DATE(), INTERVAL browse_recovery_lookback_days DAY)`. Normalize via the same strip rule.
- **User-level.** This is the only table that consumes the DECLARE.

### 1.4 `seed_sku_per_user`
- **Grain:** one row per `(email_lower, seed_sku, seed_source)`.
- **Columns:** `email_lower`, `seed_sku`, `seed_source ENUM('purchase','cart','view')`, `seed_weight FLOAT64` (recency × source-weight; exact formula deferred to full spec).
- **Derivation:** UNION ALL of lifetime-purchase seeds + active-cart seeds + browse seeds over the full signal window, then aggregate to the grain keeping max seed_weight per (email, seed, source). Browse seeds must cover both:
  - recent browse activity (same underlying view events that also feed `recent_browse_context` for exclusion), and
  - historical browse activity outside the `browse_recovery_lookback_days` window but inside the pipeline signal window.
- **User-level.**
- Users with zero seeds flow to the generic-floor fallback (current exact-SKU V5.19 retained as floor per Locked decision 3; floor-reshape deferred). Users with seeds but zero surviving related candidates after exclusions/dedup/diversity also fall through to that same fallback.

### 1.5 `related_candidate_pool`
- **Grain:** one row per `(email_lower, candidate_sku)`.
- **Columns:** `email_lower`, `candidate_sku`, `candidate_score FLOAT64`, `best_seed_sku` (debug), `best_seed_source` (debug).
- **Derivation:** `seed_sku_per_user` INNER JOIN `co_purchase_graph` ON `seed_sku = co_purchase_graph.seed_sku`, producing (email, candidate=related_sku, score=seed_weight × co_score). Aggregate to (email, candidate) keeping MAX(score) and the `argmax` seed for debug.
- **User-level.** Pre-exclusion; exclusions applied in Section 3.

---

## 2. Build order

Strict dependency chain. Each step is a `CREATE OR REPLACE` in `temp_holley_v5_19`.

1. `co_purchase_graph` (user-agnostic — can run first, parallel to step 2)
2. `active_cart_context` **|** `recent_browse_context` **|** lifetime-purchase seed set **|** browse seed extraction over the full signal window (all user-level, independent enough to build in parallel within one BQ script)
3. `seed_sku_per_user` (consumes step 2)
4. `related_candidate_pool` (JOIN `seed_sku_per_user` × `co_purchase_graph`)
5. Apply exclusions (Section 3) → filtered candidate table
6. Rank within user → top-N candidate table
7. Step 3.3 pivot (unchanged) → `final_vehicle_recommendations`

---

## 3. Exclusion order

Earliest possible pruning to cut the candidate-pool blow-up. Applied in this order on `related_candidate_pool`:

1. **Catalog eligibility** — already enforced at `co_purchase_graph` build time (step 1) by joining both sides to the existing `eligible_skus` contract. Candidates that enter `related_candidate_pool` are catalog-eligible by construction.
2. **Lifetime purchase exclusion** — anti-join against the user's full historical purchased-SKU set (not trailing-365d). Reuse the current V5.19 lifetime purchase exclusion semantics.
3. **Active-cart exclusion** — anti-join against `active_cart_context` (email, candidate_sku).
4. **Recent-browse exclusion** — anti-join against `recent_browse_context` (email, candidate_sku). Window = `browse_recovery_lookback_days` DECLARE, default `7`.
5. **Variant dedup** — same base SKU (`[0-9][BRGP]$` strip rule) collapses duplicates; keep the highest-score variant per base.
6. **Max-2-per-PartType diversity cap** — existing rule preserved.
7. **Final score rank → top-N for pivot.**

Note: ordering #3 before #4 is intentional — abandoned-cart signal is stronger than browse, and cart SKUs are a superset of trigger-browse SKUs in most sessions. Applying cart first also reduces the pool that browse needs to anti-join against.

---

## 4. `browse_recovery_lookback_days` DECLARE placement

- Declared at the top of the pipeline script, alongside existing `pipeline_start`, `recent_boundary`, `deploy_to_production`:
  ```
  DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;
  ```
- Consumed in exactly one place: the `WHERE` clause of the view-event subquery that feeds `recent_browse_context` (Section 1.3).
- **Not** used as a pipeline-wide recency knob. Purchase recency, cart recency (implicit via "latest `CART UPDATE`"), and the broader signal window for historical browse / co-purchase graph construction are independent parameters and must not be folded into this DECLARE.

---

## 5. Step 3.3 pivot — contract preservation

The Step 3.3 pivot is **unchanged**. Input contract to the pivot:

- One row per `(email_lower, candidate_sku)` with a `final_score` column and a rank column.
- Top-4 by rank becomes `rec1_sku`…`rec4_sku` with matching `rec1_score`…`rec4_score`, image URLs, prices, PartType.

Output contract (`final_vehicle_recommendations`) unchanged — 32 columns, one row per email, `rec1_type='non_fitment'` for V5.19 audience rows, `v1_*='UNKNOWN'`, `pipeline_version='v5.19'`, `generated_at` from `pipeline_start`.

What changes upstream of the pivot: the candidate table is now sourced from `related_candidate_pool` (post-exclusion, post-dedup, post-diversity-cap) rather than from exact-SKU user-signal scoring. Users with zero seeds, or with seeds but zero surviving related candidates after filtering, fall through to the current V5.19 exact-SKU / bestseller floor (retained per Locked decision 3; floor reshape is a separate follow-up).

---

## Open decisions for the full spec (intentionally not locked here)

- `seed_weight` formula: exact recency-decay function + per-source multipliers (`purchase` vs `cart` vs `view`).
- `co_score` normalization: raw count, PMI, lift, or something else. Empirical choice — needs a small offline comparison before the full spec.
- Generic-floor reshape: how users with zero related-candidates are served. Current V5.19 exact-SKU pipeline is retained for now; whether to keep it wholesale or merge it with the new related-item layer is a product decision, not an SQL-spec decision.
- `v5_19_go_no_go_eval.sql` gate reshape (`signal_based_non_fitment_user_count ≥150k` → informational under floor framing).

---

## Review questions for Codex

1. Are the five table grains + columns correct, or does any table need a different primary key (e.g., should `related_candidate_pool` carry `seed_source` to support per-source ranking, or is `candidate_score` rollup sufficient)?
2. Is the exclusion order (catalog → lifetime → cart → browse → variant → diversity → rank) right, or should cart/browse exclusions apply **before** the `related_candidate_pool` JOIN (i.e., prune seeds before expansion) rather than after (prune candidates after expansion)?
3. Is `co_purchase_graph` eligibility-filtering at build time the right call, or should eligibility be re-checked at consumption time (safer against catalog drift, more expensive)?
4. Is there a reason to split `seed_sku_per_user` by source into three tables, or is the single unified table with a `seed_source` column the right shape?
5. Any part of the design note that this pre-draft silently contradicts?
