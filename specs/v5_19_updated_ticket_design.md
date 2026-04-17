# V5.19 Updated Ticket Reassessment

Date: 2026-04-16
Linear: AUX-14029
Purpose: reassess the updated ticket requirements against the current `v5.19` direction and define what is technically feasible in offline BigQuery.

## Revision history

- 2026-04-16 pass 1 — initial design note (Codex).
- 2026-04-16 pass 2 — Claude reaction captured in line at "Claude review reaction" (below).
- 2026-04-16 pass 3 — Codex second review of Claude's reaction. Locks recorded in "Locked decisions" below. The original cart-state derivation proposal (`max(Cart Added ts) > max(Cart Removed ts)`) was removed: raw-event verification shows the event model uses `CART UPDATE` as a full-cart snapshot (no separate Add/Remove events). Corrected derivation recorded in "Layer 1: seed extraction".
- 2026-04-16 pass 4 — Codex third review + user directive. User directive: **`final_vehicle_recommendations` table and its columns must remain unchanged; additional intermediate/temp tables are fine, but no new final delivery tables.** This overrides the three-table lock from pass 3. Locked decision 1 rewritten below. Codex findings addressed in the same pass: (a) removed contradictory "can be collapsed" sentence that reopened what pass 3 tried to close, (b) added provenance for raw-event volume claims, (c) table-keys open-endedness is moot under the new single-table constraint.
- 2026-04-16 pass 5 — Codex fourth review. Three findings closed: (HIGH) added explicit build-cadence assumption as Locked decision 5 — single-table exclusion is only safe within the batch-boundary, not unconditionally; (MEDIUM) rewrote Section 3 of "Recommended design decisions" in place so it no longer calls for separate per-context tables (that guidance was stale after pass 4); (MEDIUM) added Locked decision 6 marking browse-recovery `N`-day lookback as an explicit contract blocker pending campaign-SLA confirmation. Added corresponding entries to "Required follow-up edits" naming the owners who must resolve each blocker.
- 2026-04-16 pass 6 — Codex fifth review. Two wording cleanups: (MEDIUM) Layer 3 abandoned-cart / browse-recovery exclusion bullets rewritten to match the locked "as of build time, no per-send trigger context" semantics — the old "exclude trigger browse SKU(s)" wording implied per-send context that the single-table contract cannot carry; (LOW) "Locked decisions" section header renamed from `(pass 4)` to `(passes 4–5)` since it now contains pass-5 decisions 5 and 6. No semantic changes — wording only.
- 2026-04-16 pass 7 — user resolution of both contract blockers + Codex seventh review. (1) Cadence confirmed: recommender runs once per day; email sends happen in batches throughout the day drawing from that single daily-refreshed rec table. Locked decision 5 re-worded from "assumption" to "confirmed," and the residual-risk paragraph was split into two named residuals after Codex MEDIUM finding: post-build-cutoff under-exclusion leak (Layer 2 lifetime purchase catches only the purchased SKU in the next build), and post-checkout over-exclusion of cart-mates (Layer 2 does **not** cover this). (2) Browse-recovery `N` parameterized as a BigQuery `DECLARE` (`browse_recovery_lookback_days`) with default `7`, changeable without editing pipeline logic. Locked decision 6 re-worded from "contract blocker" to "parameter with working default." Residual "blocker" references at lines 182 and 274 were updated to match. (3) After Codex HIGH finding, Locked decision 4 rewritten from "pending — not locked / do not freeze into SQL yet" to "verified and accepted" with explicit evidence (7 queries in blocker checklist) and an explicit pointer to the post-checkout staleness residual in Locked decision 5. (4) After Codex LOW finding, section header renamed to "Locked decisions (passes 4–7)"; the cross-reference in the "Design options" preamble was updated to point to the new header; the "Contract blockers (resolved, pass 7)" subsection in "Required follow-up edits" was retained (the previous pass-7 entry misreported it as "removed" — it was actually re-labeled from "must be resolved before SQL" to "resolved, pass 7" with one-line resolution summaries). Both blockers removed from `tasks/v5_19_blocker_resolution_checklist.md`'s exit-criteria list. SQL-shaping spec is now unblocked.
- 2026-04-16 pass 8 — Codex eighth review. One MEDIUM finding: the Layer 1 "Cart-state derivation" header was still labeled "(proposal, pending verification)" with bullets phrased as open edge-case checks, conflicting with the now-locked pass-7 state in Locked decision 4 and the resolved checklist. Fixed: header renamed to "(verified, pass 7 — see Locked decision 4)", body rephrased from proposal to adopted derivation, and the four edge-case bullets rewritten from open checks to verified results with the inline numeric evidence carried over from the blocker checklist (57 zero-item `CART UPDATE` events; post-checkout clearing 11,210/93/0; no multi-user-id collisions; variant normalization 117,768→8,581). No semantic changes — this was the last stale wording between the pass-7 locked state and the remaining historical Layer-1 body text.
- 2026-04-16 pass 9 — Codex ninth review. One MEDIUM finding: the "Required follow-up edits" bullet still said *"Event-model verification for cart state … before cart-state SQL is written"*, contradicting Locked decision 4's "verified and accepted" state. Fixed: bullet rewritten to name it as an **optional parallel validation** (post-SQL-draft session spot-check), explicitly non-blocking, with a cross-reference back to Locked decision 4 for the derivation-verified status. No semantic changes to the design itself.

## What changed in the ticket

The updated Linear ticket now asks for two things that the current `v5.19` simplification does not provide:

1. Use `purchase history` as a recommendation signal for non-fitment users.
2. For triggered flows, avoid recommending the exact items already present in the flow context:
   - abandoned cart: do not recommend cart items
   - browse recovery: do not recommend the browsed trigger item(s)

This changes the problem from "rank exact user-touched SKUs" to "use user behavior as a seed for complementary recommendations."

## Core conclusion

The updated ticket is technically feasible, but not in the current exact-SKU recommendation shape.

It becomes feasible if we change the architecture to:

- use purchase/cart/view as `seed signals`
- expand those seeds into `related or complementary candidates`
- apply exclusions to the final recommended SKUs
- precompute flow-aware outputs in BigQuery before send

It is not feasible to satisfy the updated ticket with only the current generic shared table and exact-SKU recommendations.

## Why purchase history was dropped in the current V5.19 design

Purchase history was not dropped because it is a weak signal. It was dropped because it is incompatible with exact-SKU output under `lifetime purchase exclusion`.

Current simplified logic:

1. seed on a past purchase
2. candidate SKU = the purchased SKU
3. apply lifetime purchase exclusion
4. candidate is removed

So exact-SKU purchase recommendations are structurally dead.

The only way to bring purchase history back is to use purchase as a `seed` for other products, not as the final product itself.

## Feasibility assessment

### Feasible now

1. `Purchase-seeded related-item recommendations`
   - We already have the source purchase data in `import_orders` and purchase events.
   - The repo already contains a co-purchase prototype in [sql/recommendations/v5_17_collaborative_filtering_prototype.sql](/Users/praveenm/dev/auxia/holley-rec/sql/recommendations/v5_17_collaborative_filtering_prototype.sql:1).
   - A first-pass related-item layer can be built offline in BigQuery.

2. `Cart/view-seeded complementary recommendations`
   - We already parse cart and view SKU events in the existing recommendation SQL.
   - Those events can be used as seeds for related-item lookup instead of recommending the exact same SKU.

3. `Offline flow-aware exclusion`
   - If the trigger-item sets can be materialized in BigQuery before send, we can exclude them during recommendation generation.
   - That means abandoned-cart and browse-recovery recommendation outputs can be precomputed offline.

4. `Bestseller fallback`
   - Already feasible and already implemented.

### Not feasible in the current shape

1. `Exact-SKU purchase recommendations` under lifetime exclusion
   - Not possible for the reasons above.

2. `Guaranteed flow-specific non-overlap` from a single generic user-level row
   - A generic row in `final_vehicle_recommendations` does not know which flow is sending.
   - It also does not know which cart items or browsed items triggered that specific email.
   - Therefore one generic row per user cannot satisfy flow-aware exclusion rules.

3. `Search-pattern recommendations`
   - Search queries are mentioned in the ticket, but this repo does not currently show a search-to-SKU mapping layer.
   - Search should remain out of scope unless we can map search terms to candidate products reliably.

## Design options

> **Note (pass 4, decisions extended through pass 7):** The three options below reflect pass-1 thinking when the table contract was still open. Under the pass-4 user directive ("final table and columns remain the same"), none of A/B/C apply as stated. The adopted design is **Option D (pass 4)**: a single unchanged `final_vehicle_recommendations` delivery table, with flow-aware exclusions applied during row generation rather than expressed as new tables or new columns. See "Locked decisions (passes 4–7)" below for the authoritative design. A/B/C are retained only as historical context for why that evolution happened.

### Option A: Keep current exact-SKU V5.19 and reinterpret the ticket

Description:
- keep `cart/view + bestseller`
- keep shared generic table
- do not add purchase-related logic
- do not solve flow-specific item exclusion in BigQuery

Pros:
- smallest change
- fastest path

Cons:
- does not actually satisfy the updated ticket
- leaves purchase history and trigger-flow dedup unresolved

Verdict:
- not recommended

### Option B: One unified context-aware non-fitment table

Description:
- build one new non-fitment recommendations table in BigQuery
- include multiple contexts per user, e.g. `generic`, `abandon_cart`, `browse_recovery`
- each context uses the same related-item engine but different exclusion sets

Pros:
- one recommendation system
- one output surface for non-fitment
- fully offline

Cons:
- requires downstream selection by context
- requires either a new context column or a new table contract

Verdict:
- feasible

### Option C: Separate offline outputs by use case

Description:
- keep the existing generic recommendation path for fitment and possibly generic non-fitment
- add dedicated BigQuery outputs for flow-aware non-fitment recommendations:
  - generic non-fitment
  - browse recovery non-fitment
  - abandon cart non-fitment

Pros:
- simplest mental model
- easiest to QA per use case
- matches the fact that the exclusion logic is flow-specific

Cons:
- more tables or pipelines
- more deployment/config surface

Verdict:
- recommended

## Recommended design decisions

### 1. Reframe non-fitment recommendation generation around seeds and expansion

We should no longer treat purchase/cart/view SKUs as final recommendation candidates.

Instead:
- purchase/cart/view define what the user is interested in
- a related-item layer turns those seeds into recommendable complementary SKUs
- the final recommendation set is drawn from those complementary SKUs, not the seed item itself

### 2. Reintroduce purchase history, but only as a seed

Purchase history should come back into scope as:
- purchased SKU -> related products

Not as:
- purchased SKU -> purchased SKU again

This satisfies the updated ticket while respecting lifetime exclusion.

### 3. Fold flow-aware exclusions into the single-table generation path

*(Rewritten pass 4. Earlier version proposed separate per-context output tables; that was overridden by the user directive locking a single `final_vehicle_recommendations` delivery shape. See Locked decision 1.)*

The updated rule: flow-aware behavior is expressed as **candidate filters applied during row generation**, not as separate rows or separate tables. A single stored row per email must be safe to show in any flow the send platform picks, within the pre-compute cadence boundary (see Locked decision 5 and "Implications of Locked decision 1").

Concretely:
- Abandoned-cart safety: exclude every SKU in the user's latest cart snapshot from the non-fitment candidate pool.
- Browse-recovery safety: exclude every SKU the user has viewed within the lookback window `browse_recovery_lookback_days` (BigQuery `DECLARE`, default `7` — see Locked decision 6).
- Both exclusions run in the same filter layer as lifetime-purchase exclusion — upstream of the final Step 3.3 pivot.

### 4. Build offline trigger-context snapshots in BigQuery

To support flow-aware exclusions, BigQuery needs pre-send context tables such as:

- `active_cart_context`
  - user/email
  - cart SKU set
  - snapshot timestamp

- `browse_recovery_context`
  - user/email
  - trigger browse SKU or recent browsed SKU set
  - snapshot timestamp

Without these context tables, the flow-specific exclusion requirement cannot be met offline.

### 5. Keep lifetime purchase exclusion on final recommended SKUs

The user requirement still stands:
- recommended SKU must not be something the user has ever purchased

This remains valid even after we switch to related-item generation.

### 6. Keep search patterns out of the first pass

Search is not the blocking requirement.
The ticket can be substantially satisfied with:
- purchase history
- recent browsing
- historical browsing
- bestseller fallback

Search should stay out unless we discover a reliable SKU-mapping source.

## Proposed offline architecture

### Layer 1: seed extraction

Per user, extract seed SKUs from:
- lifetime purchases (authoritative; `auxia-gcp.data_company_1950.import_orders` + purchase events)
- recent cart activity
- recent browse activity
- historical browse activity

**Cart-state derivation (verified, pass 7 — see Locked decision 4):**
The `ingestion_unified_schema_incremental` event stream uses `CART UPDATE` as a full-cart snapshot event. Each `CART UPDATE` carries the entire cart state as indexed properties (`items_1.productid`, `items_2.productid`, …). There is no separate `Cart Removed` event. Adopted derivation: for each user, take the latest `CART UPDATE` event (max `client_event_timestamp`), unnest `items_N.productid`, and that is the active cart SKU set. Edge cases verified (full evidence in `tasks/v5_19_blocker_resolution_checklist.md`):
- Empty-cart / cart-clear events — **representable**: 57 zero-item `CART UPDATE` events across 51 users in the last 30 days.
- Checkout transition — **cart-clear is NOT timely or reliable** after order: of 11,210 users with a non-empty cart before an order, only 93 had any `CART UPDATE` within 1h after the order and 0 had a zero-item `CART UPDATE` in that window. Consequence (over-exclusion of cart-mates until the next cart event) is the post-checkout over-exclusion residual in Locked decision 5.
- Multi-user-id-per-email — **no collisions observed** in the 30-day cart sample. The disjoint-invariant per-email user_id selection rule can be reused for cart-snapshot derivation.
- Variant normalization — **catalog-parity confirmed**: 117,768 cart rows → 8,635 distinct raw SKUs → 8,581 distinct normalized SKUs under the `[0-9][BRGP]$` strip rule from `v5.18`.

`ADDED TO CART` is present in the data but at negligible volume (~700 events/30d vs ~49k `CART UPDATE`/30d). Ignore unless a later review shows it carries information `CART UPDATE` does not.

Provenance for the event counts (run 2026-04-16):
```sql
SELECT UPPER(event_name) AS event_name, COUNT(*) AS n
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
WHERE DATE(client_event_timestamp) >= CURRENT_DATE() - 30
  AND UPPER(event_name) LIKE "%CART%"
GROUP BY 1 ORDER BY n DESC;
-- Result: CART UPDATE=49374, AUTOMATIC ABANDONED CART PROMO=2006, ADDED TO CART=700.
```
`AUTOMATIC ABANDONED CART PROMO` is an outbound marketing event, not a user action, and is excluded from cart-state derivation. The `items_N.productid` snapshot shape was confirmed on a 2026-04-16 sample event from user `01KPAEZN91NXPVA3Y07WE4F5BV`.

### Layer 2: related-item generation

Generate candidate complementary SKUs from seed SKUs using one or more offline relations:
- co-purchase
- co-view
- co-cart
- same part type / same brand / adjacent catalog logic

The simplest first pass is co-purchase because the repo already has a prototype.

### Layer 3: context-specific exclusions

Apply exclusions by context:

- all contexts:
  - lifetime purchased SKUs
  - low price
  - no image
  - refurb / commodity filters
  - diversity cap

- abandoned cart (safety filter applied at row build time — no per-send trigger context; see Locked decision 1):
  - exclude every SKU present in the user's latest `CART UPDATE` snapshot as of build time

- browse recovery (safety filter applied at row build time — no per-send trigger context):
  - exclude every SKU the user viewed in the last `browse_recovery_lookback_days` days as of build time (BigQuery `DECLARE`, default `7` — see Locked decision 6; changeable in one place if campaign-ops later returns a different SLA)

### Layer 4: output tables

Recommended offline outputs:

`final_vehicle_recommendations` is the single delivery table. Its columns are fixed at the current V5.19 shared-table contract (32-column list, see `sql/recommendations/v5_19_non_fitment_recommendations.sql`). Every user — fitment or non-fitment — is represented by exactly one row in this table.

Flow-aware behavior (abandoned-cart exclusion, browse-recovery exclusion) is applied **during** non-fitment row generation, before the rows are written to `final_vehicle_recommendations`. It is not expressed as a separate delivery table.

Intermediate/temp tables used to derive flow-aware behavior (e.g. `active_cart_context`, `browse_recovery_context`, `co_purchase_graph`, `seed_sku_per_user`) live inside the working dataset and do not participate in the delivery contract. They can be redesigned freely.

## What this means for the current V5.19 rewrite

If we accept the updated ticket as the source of truth, the current exact-SKU `cart/view + bestseller` version of `v5.19` should no longer be treated as the final target architecture.

It can still be useful as:
- a baseline
- a fallback generic non-fitment table
- a stepping stone while related-item logic is added

But it does not fully satisfy the new ticket.

## Locked decisions (passes 4–7)

These are resolved and should not be re-opened without explicit review. Decisions from pass 3 that were superseded by the pass-4 user directive are noted inline. Decisions 5–6 were added in pass 5. Decisions 4, 5, and 6 were updated in pass 7 (cart derivation verified; cadence confirmed; `N` parameterized).

1. **Delivery contract is a single table: `final_vehicle_recommendations`.** Columns are frozen at the current 32-column V5.19 shared-table shape. One row per email, carrying either fitment or non-fitment audience. Flow-aware behavior (abandoned-cart exclusion, browse-recovery exclusion) is applied **during** row generation — inside the non-fitment candidate pipeline, not as a separate final table. Additional intermediate/temp tables in the working dataset are fine and encouraged where they simplify the generation logic, but they are not part of the delivery contract. *(Supersedes pass-3 three-table design.)*
2. **v1 related-item engine is co-purchase only.** No same-part-type / same-brand / adjacent-catalog blending in v1. The repo has an existing co-purchase prototype to build from. Heuristics may be added in v2 once co-purchase uplift is measured in isolation.
3. **Current exact-SKU V5.19 is retained as a generic floor only.** It is not a personalization system. It should no longer be judged by the "substantial signal-driven coverage" bar currently encoded in `sql/validation/v5_19_go_no_go_eval.sql` (`signal_based_non_fitment_user_count` gate, currently ≥150k). Empirical run shows 99.71% of non-fitment users are fallback-dominated — that is the correct shape for a floor. The go/no-go threshold must be relaxed or reframed when V5.19 is demoted; this is a required follow-up edit.
4. **`active_cart_context` derivation is verified and accepted (pass 7).** The event model uses a single `CART UPDATE` event carrying the full cart as indexed `items_N.productid` properties. There is no `Cart Removed` event. The derivation is therefore "latest `CART UPDATE` per user → unnest `items_N.productid`" — not a delta model. Edge cases checked across 7 queries in `tasks/v5_19_blocker_resolution_checklist.md` and all closed: zero-item `CART UPDATE` events exist (57 events across 51 users in 30d) so cart-clear is representable; multi-user-id-per-email collisions were not observed in the 30-day cart sample; SKU normalization on cart items aligns with the recommendation SKU space (117,768 cart rows, 8,635 raw → 8,581 normalized). Known residual risk: **post-checkout cart clearing is not timely/reliable** — of 11,210 users with a non-empty cart before an order, only 93 had any `CART UPDATE` within 1h after the order and 0 had a zero-item `CART UPDATE` in that window. Consequences of this residual are spelled out in Locked decision 5. Derivation is cleared for SQL-shaping spec.
5. **Confirmed build cadence: daily recommender build + batched daily sends (pass 7, user).** The recommender runs once per day; email sends happen in batches throughout that day, all drawing from the single daily-refreshed recommendation table. Max residual staleness between build cutoff and any send that consumes a row is ≤ 24h. Accepted for both the abandoned-cart and browse-recovery flows. Two residual risks are explicitly accepted under this cadence:
   - **Post-build-cutoff under-exclusion** (safety leak): a SKU the user adds to cart or views *after* the build cutoff will not be excluded until the next day's build. For the specific SKU the user ends up purchasing, Layer 2 lifetime-purchase exclusion catches it in the next build even if the cart never clears. Layer 2 does **not** cover the short window between the new cart event and the next build — that remains a leak.
   - **Post-checkout over-exclusion** (stale cart): when a user buys one item from a multi-item cart, `CART UPDATE` does not reliably fire a cart-clear (see Locked decision 4 evidence). The stale cart snapshot can therefore suppress other cart-mates from being recommended until the next cart event. Layer 2 lifetime-purchase exclusion covers only the *purchased* SKU; it does not prevent over-exclusion of the user's other still-in-cart SKUs, which will keep being filtered out by the stale `active_cart_context` until the user's cart is next mutated. This is an over-exclusion cost (missed candidate opportunity), not a leak.
   Same-day / sub-hour trigger accuracy remains out of scope for this BigQuery pipeline; if the business ever requires it, the architecture must be revisited.
6. **Browse-recovery lookback window is parameterized (pass 7, user): `browse_recovery_lookback_days` DECLARE, default `7`.** The exclusion "do not recommend SKUs the user viewed in the last N days" is implemented as a BigQuery scripting `DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;` at the top of the pipeline. Default `7` is the working value. The parameter can be changed without editing pipeline logic once campaign-ops confirms the actual browse-recovery email SLA. Not a contract blocker — SQL work proceeds with the default; only the DECLARE value is touched if/when ops returns a different SLA.

## Implications of Locked decision 1 (single delivery table)

Because every user produces exactly one row in `final_vehicle_recommendations`, flow-aware behavior cannot be a per-flow row. The pre-compute must produce a recommendation set that is **safe to show in any flow the send platform picks, within the build-cadence boundary defined in Locked decision 5** (daily recommender build + batched daily sends from that one table). Practically this means:
- Abandoned-cart exclusion becomes: "never recommend SKUs in the user's latest `CART UPDATE` snapshot as of build time." Applied at candidate-filter time, same layer as lifetime-purchase exclusion.
- Browse-recovery exclusion becomes: "never recommend SKUs the user viewed in the last `browse_recovery_lookback_days` days as of build time" (BigQuery `DECLARE`, default `7` — see Locked decision 6). Applied at the same filter layer.
- Neither exclusion needs flow context at send time — both filters are already baked into the stored row **for events observed up to the build cutoff**.
- The send-side trigger item (the specific SKU that kicked off the abandoned-cart or browse-recovery flow) is implicitly excluded as a member of the broader cart/view snapshot, **as long as the trigger item was in the snapshot at build time.** A trigger item that first appears in the user's cart or browse stream *after* the build cutoff will not be excluded until the next day's build; this is the post-build-cutoff under-exclusion residual called out in Locked decision 5.
- No `trigger_sku` column on the table: the send platform does not disambiguate which browse or cart event fired the trigger, and the table does not try to.

Trade-offs acknowledged:
- A single stored row is by definition less tailored than a per-flow row. Accepted in exchange for contract simplicity and downstream non-change.
- Up-to-24h staleness on cart/view exclusion is accepted as the residual risk of the batch cadence. If same-day-trigger accuracy becomes required, the design must be revisited (see Locked decision 5).

## Required follow-up edits (not yet done)

- `sql/validation/v5_19_go_no_go_eval.sql`: relax or reframe `signal_based_non_fitment_user_count` gate once V5.19 is formally demoted to generic floor. Current threshold (≥150k) assumes V5.19 is a personalization system; under the floor framing, the gate should become informational or move to the related-item-engine validator instead.
- Optional parallel validation (not blocking SQL): once `active_cart_context` SQL is drafted, spot-check a handful of users across a full cart session (add → modify → clear → checkout) in the working dataset to confirm `CART UPDATE` snapshot semantics hold in practice. The derivation itself is already verified (Locked decision 4); this is a post-draft sanity check, not a pre-draft blocker.
- New pipeline SQL structure (to be proposed separately): intermediate tables `active_cart_context`, `recent_browse_context`, `co_purchase_graph`, `seed_sku_per_user`, `related_candidate_pool`, all as CREATE OR REPLACE in the `temp_holley_v5_19` working dataset, feeding the existing Step 3.3 non-fitment pivot. The pivot's output contract (`final_vehicle_recommendations`) remains unchanged.
- Add `DECLARE browse_recovery_lookback_days INT64 DEFAULT 7;` near the top of the pipeline alongside the other scripting DECLAREs; use this variable inside the `recent_browse_context` construction rather than hard-coding a literal. Changeable in one place if the browse-recovery SLA is later set to a different value.
- **Contract blockers (resolved, pass 7):**
  - Build cadence (Locked decision 5): confirmed daily recommender + batched daily sends; up-to-24h staleness accepted.
  - Browse-recovery lookback (Locked decision 6): parameterized via `browse_recovery_lookback_days` DECLARE, default `7`. Campaign-ops SLA confirmation is a tuning follow-up, not a blocker.

## Superseded question list

The original "Questions for Claude review" section (below) has been answered and resolved by the three-pass review cycle. It is retained for history; the `Locked decisions` section above is authoritative.

## Questions for Claude review (superseded — see "Locked decisions" above)

These questions framed the pass-2 reaction and have been resolved. Kept for history only.

1. Is `separate offline outputs by context` the right recommendation, or should we force a single-table contract?
   - **Resolved (pass 4):** single final table. User directive overrode the pass-3 three-table design. See Locked decision 1 and "Implications of Locked decision 1".
2. For the first related-item layer, should we start with `co-purchase only`, or combine it with same-part-type / same-brand heuristics?
   - **Resolved:** co-purchase only. See Locked decision 2.
3. What is the cleanest way to build `browse_recovery_context` and `active_cart_context` in BigQuery from the existing event stream?
   - **Partially resolved:** event model verified; full derivation pending edge-case review. See Locked decision 4 and "Layer 1: seed extraction".
4. Should the current exact-SKU non-fitment pipeline be kept as a fallback baseline while the related-item layer is built?
   - **Resolved:** yes, as generic floor only. See Locked decision 3 and "Required follow-up edits".
