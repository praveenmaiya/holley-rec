# V5.19 Restructure Plan — Shared Output + Lifetime Exclusion

**Branch:** `praveen-aux-14029` (commit `38bbd6e`, pushed, untested)
**Linear:** AUX-14029
**Stage:** PRE-IMPLEMENTATION — no code changes yet
**Audience:** handoff between Claude (Anthropic) + Codex (OpenAI) reviewers + user
**Created:** 2026-04-16

**Revision log:**
- r1 (Claude) — initial plan; 6 decisions, 7 questions
- r2 (Codex) — locked 4 requirements (shared table, discriminator, UNKNOWN placeholders, lifetime exclusion); proposed additive shared-schema contract; defined materialization via UNION ALL with V5.18 untouched; trimmed to 4 decisions + 4 questions
- r3 (Claude) — added §4.2 redundancy note + qa assertion; §4.3 ordering-dependency note (V5.18 must run before V5.19) with sub-question on staging-vs-prod source; D3 strengthened (recommend D3a); new D5 (source-of-truth for projection); Q5 added; recommended answers added inline
- r4 (Codex) — tightened slot-level invariants; replaced live-table dependency with required fitment snapshot; reconciled D2 with allowed signal enum; clarified QA migration scope and validation expectations
- r5 (Claude) — user override: keep V5.18 column **schema** unchanged. Introduced 4 regressions: (a) silently re-described "value-vocabulary expansion" as "no schema changes"; (b) tried to repurpose `pipeline_version` as audience discriminator; (c) dropped the run-scoped fitment snapshot; (d) flipped YMM placeholders from `'UNKNOWN'` to `NULL` without re-approval
- r6 (Claude) — addresses Codex r5 review findings: (a) honest framing — value-vocabulary expansion required, QA must be updated; (b) `rec1_type` is the row-level audience discriminator (user-approved value `'non_fitment'`), `pipeline_version` stays a single release tag `'v5.19'` for the whole table; (c) restore run-scoped fitment snapshot before UNION; (d) restore `'UNKNOWN'` YMM placeholders
- **r7 (Codex — locked)** — user signed off on the simple contract: keep existing table + columns, use existing columns as internal markers, keep `'UNKNOWN'` placeholders, set `pipeline_version = 'v5.19'` across the combined table, use lifetime exclusion for V5.19, drop exact-SKU purchase scoring, and keep the fitment snapshot before `UNION ALL`

---

## 1. Why we are restructuring

Codex review identified **structural drift** between the as-built V5.19 branch and the user's stated requirements. The drift propagates across spec, pipeline, validation, and release notes:

| File | Lines | Drift |
|------|-------|-------|
| `specs/v5_19_non_fitment_recommendations.md` | 35, 62, 135 | separate-table design + 365d exclusion |
| `sql/recommendations/v5_19_non_fitment_recommendations.sql` | 40, 67 | writes to `final_non_fitment_recommendations`; 365d exclusion |
| `sql/validation/v5_19_go_no_go_eval.sql` | 22, 27 | targets separate table; 365d window |
| `docs/release_notes.md` | 32, 79, 94 | documents separate table + 365d exclusion |

Three confirmed user requirements override the as-built branch:

1. **Shared output table** — V5.19 rows must append to V5.18's `final_vehicle_recommendations`, not a separate `final_non_fitment_recommendations`.
2. **No new columns added to the prod table** — V5.18's column set stays as-is. V5.19 internal fields (`dominant_signal`, signal types, signal ages, 4-tier engagement) live only in `temp_holley_v5_19` working tables.
3. **Lifetime purchase exclusion** — V5.19 excludes any past purchase ever, not just the trailing 365 days.

**Lifetime exclusion is the keystone.** Under V5.19's exact-SKU candidate generation, lifetime exclusion makes purchase signals (both `purchase_recent` and `purchase_historical`) unable to surface in recommendations — the SKU you bought is always the SKU that gets excluded. So purchase-signal disposition is **blocked on the exclusion rule**, not a later cleanup item.

**Why downstream doesn't need new columns.** The downstream email pipeline reads `email_lower`, the 4 rec SKUs, prices, and images. That's it. Everything else (engagement vocabulary, signal provenance, dominant signal routing) is V5.19 internal analytics that lives in working tables. We don't change a stable downstream contract for ourselves.

---

## 1a. Honest framing: schema vs. vocabulary

Saying "no schema changes" hides a real impact. The **column set** (names + types) stays unchanged. The **allowed value set** for several existing columns changes:

| Column | V5.18-only allowed values | After V5.19 ships |
|--------|---------------------------|-------------------|
| `rec1..4_type` | `'fitment'` literal | `'fitment'` for V5.18 rows, `'non_fitment'` for V5.19 rows (user-approved) |
| `engagement_tier` | `'hot'` / `'cold'` only, no NULLs | `'hot'` / `'cold'` for V5.18 rows, `NULL` for V5.19 rows |
| `fitment_count` | `3` or `4` only | `3` / `4` for V5.18 rows, `NULL` for V5.19 rows |
| `v1_year`, `v1_make`, `v1_model` | always populated, never NULL | populated for V5.18 rows; placeholder `'UNKNOWN'` for V5.19 rows |
| `rec1..4_pop_source` | `'segment'` / `'make'` / `'global'` | same for V5.18; `NULL` for V5.19 (no new values introduced — user-approved) |
| `pipeline_version` | `'v5.18'` for all rows | `'v5.19'` for **all** rows in the post-restructure table (it is the table's release tag, not a per-row source flag) |

Two consequences:

1. **Existing QA invariants will fail** the moment V5.19 rows land in the shared table. Specifically `qa_checks.sql:216` (`fitment_count IN (3,4)`), `qa_checks.sql:233` (`engagement_tier IN ('hot','cold')`), and the implied `rec*_type = 'fitment'` invariant (`docs/architecture/v5_18_architecture_specification.md:345`). QA migration is **mandatory**, not optional — addressed in §7.
2. **Documentation must be updated** — `docs/architecture/v5_18_architecture_specification.md` lines 345/347/348 currently document the narrower vocabulary. Those lines need to carry the new conditional vocabulary above.

---

## 2. Carryover from prior reviews

### Codex round 1 (already addressed in commit `38bbd6e`)
1. Disjoint leak (user_id vs email) — fixed via Step 0a/0b email anti-join
2. Purchase window overlap (recent_boundary) — fixed via consistent DECLARE
3. `engagement_tier` from filtered output — fixed via Step 1.6 raw signal ages
4. Purchase-exclusion audit only import-side — fixed via event-side union in go/no-go
5. Fallback after filters — fixed via Step 3.2 UNION ALL
6. Signal coverage gate — fixed via ≥150K signal-based user check
7. Year prefilter on `ORDER_DATE` — fixed for bytes scan

These are still relevant where structure overlaps, but findings 1, 2, 4 will be **superseded** by the restructure (lifetime exclusion + shared table change their semantics).

### Codex round 2 (drove the restructure)
- HIGH: requirement drift across 4 files (above)
- HIGH: lifetime exclusion blocks purchase signal design — must decide before SQL edits
- MEDIUM: Claude's earlier "purchase_historical is dead" was overstated under current 365d exclusion; will become accurate under lifetime exclusion
- MEDIUM: `engagement_tier` mismatch — moot in r6 because `engagement_tier` is `NULL` for V5.19 rows in prod; rich tier classification stays in working tables
- LOW: spec investigation table uses different metric than later 90d investigation — needs provenance

### Codex round 3 (review of r5 — addressed in r6)
- HIGH: r5's "no schema changes" framing was misleading — value vocabulary changes for several columns. **Fixed in §1a.**
- HIGH: r5 used `pipeline_version` as the audience discriminator. `pipeline_version` is a release tag — `v5_18_fitment_recommendations.sql:1084` reports a single `MAX(pipeline_version)` after deploy, expecting one value across the table. **Fixed in §4: discriminator is `rec1_type`; `pipeline_version` stays single-valued = `'v5.19'`.**
- HIGH: r5 dropped the run-scoped fitment snapshot. V5.18 staging is `CREATE OR REPLACE TABLE` (`v5_18_fitment_recommendations.sql:817`), so direct read during V5.19 union is racy if V5.18 reruns mid-cycle. **Fixed in §4.3: snapshot restored.**
- HIGH: r5 silently flipped YMM placeholders from `'UNKNOWN'` (r2 lock) to `NULL`. **Fixed in §4: defaults restored to `'UNKNOWN'`.**

---

## 3. Locked requirements (already decided)

These are not open choices anymore:

1. **Single shared output table** — V5.19 lands in `final_vehicle_recommendations`, not a separate table.
2. **No new columns on the shared table** — column set is V5.18's; V5.19 fills existing columns per §4.
3. **Row-level audience discriminator** — `rec1_type IN ('fitment', 'non_fitment')` (user-approved value vocabulary). `pipeline_version` is **not** the discriminator.
4. **No-YMM placeholders** — non-fitment rows use `'UNKNOWN'` for `v1_year`, `v1_make`, `v1_model`.
5. **Lifetime exclusion for V5.19** — non-fitment recommendations exclude any SKU the user has ever purchased.
6. **Rich V5.19 internal data stays in working tables** — `temp_holley_v5_19.*` keeps `dominant_signal`, signal types, signal ages, 4-tier engagement for our analysis. None of it is projected into the prod table.
7. **Combined-table release tag** — `pipeline_version = 'v5.19'` across the combined shared table.
8. **Simple non-fitment signal set** — V5.19 drops exact-SKU purchase scoring and uses `cart`, `view`, and bestseller fallback only.
9. **Deterministic fitment source** — V5.19 snapshots the chosen V5.18 source before `UNION ALL`.

---

## 4. How V5.19 fills V5.18's existing columns

The shared table keeps V5.18's column set unchanged:

```
email_lower, v1_year, v1_make, v1_model,
rec_part_1..4, rec1..4_price, rec1..4_score, rec1..4_image,
rec1..4_type, rec1..4_pop_source,
engagement_tier, fitment_count,
generated_at, pipeline_version
```

V5.18 rows behave exactly as they do today. V5.19 rows fill the same columns as follows:

| Column | V5.18 row (unchanged) | V5.19 row |
|--------|------------------------|-----------|
| `email_lower` | user email | user email |
| `v1_year` | YMM year | **`'UNKNOWN'`** (string per `v1_year` STRING type — confirmed) |
| `v1_make` | YMM make | **`'UNKNOWN'`** |
| `v1_model` | YMM model | **`'UNKNOWN'`** |
| `rec_part_1..4` | fitment-filtered SKUs | non-fitment SKUs (from cart/view/bestseller) |
| `rec1..4_price` | prices | prices |
| `rec1..4_score` | scores | scores |
| `rec1..4_image` | image URLs | image URLs |
| `rec1..4_type` | `'fitment'` literal | **`'non_fitment'`** literal — this is the row-level audience discriminator |
| `rec1..4_pop_source` | `segment` / `make` / `global` | **NULL** (no new values introduced) |
| `engagement_tier` | `hot` / `cold` | **NULL** (V5.19's 4-tier classification stays in `temp_holley_v5_19`) |
| `fitment_count` | `3` or `4` | **NULL** (no fitment context for no-YMM users) |
| `generated_at` | run timestamp | run timestamp |
| `pipeline_version` | `'v5.19'` for all rows in the post-restructure table | `'v5.19'` for all rows |

### 4.1 Audience discriminator

`rec1_type` is the row-level audience flag. It is **always populated** (every row has at least 1 rec, hence rec1) and takes exactly two values:

- `rec1_type = 'fitment'` → row produced by V5.18 logic
- `rec1_type = 'non_fitment'` → row produced by V5.19 logic

QA must assert that within a row, `rec1_type = rec2_type = rec3_type = rec4_type` for all populated slots — i.e., no row can mix audiences across slots.

`pipeline_version` is **single-valued across the whole shared table** (`'v5.19'`) and represents the release version of the pipeline architecture, not the per-row source. This preserves the existing post-deploy reporting at `v5_18_fitment_recommendations.sql:1084` which expects a single value.

### 4.2 Disjointness

Every email is in exactly one of {V5.18 fitment universe, V5.19 non-fitment universe}. No email gets both row types. Validated in go/no-go.

### 4.3 Materialization with run-scoped fitment snapshot

V5.19's pipeline must read V5.18's fitment output to UNION it into the shared table. Because `v5_18_fitment_recommendations.sql:817` recreates `temp_holley_v5_18.final_vehicle_recommendations` with `CREATE OR REPLACE TABLE` on every run, reading it directly during V5.19's union is racy: if V5.18 reruns mid-cycle, V5.19's union pulls inconsistent data and the shared output mutates silently.

**Required step (do not skip):**

1. V5.18 finishes staging → `temp_holley_v5_18.final_vehicle_recommendations` is materialized
2. **V5.19 first creates a run-scoped snapshot:**
   ```sql
   CREATE OR REPLACE TABLE auxia-reporting.temp_holley_v5_19.fitment_source_snapshot AS
   SELECT * FROM auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations;
   ```
   Optionally suffix with `_<run_id>` if we want versioned snapshots; the simpler `fitment_source_snapshot` (overwritten per V5.19 run) is sufficient because V5.19 itself is the only consumer.
3. V5.19 builds non-fitment candidate rows in temp tables
4. Apply lifetime exclusion
5. UNION ALL: snapshotted fitment rows + new non-fitment rows → `temp_holley_v5_19.final_vehicle_recommendations`
6. Validate (go/no-go + QA)
7. Deploy combined shared table to `company_1950_jp.final_vehicle_recommendations`

**Ordering invariant:** V5.18 must run before V5.19 each cycle. V5.19 SQL must fail loudly if the V5.18 staging table is missing or empty:

```sql
SELECT IF(
  (SELECT COUNT(*) FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`) = 0,
  ERROR('V5.18 fitment staging is empty — run V5.18 before V5.19'),
  'OK'
);
```

The snapshot step is what makes the cycle atomic. Without it, V5.19's output is non-deterministic with respect to concurrent V5.18 reruns.

---

## 5. Locked execution defaults

These defaults are now fixed by user sign-off and should be treated as implementation input, not as open design questions:

1. **Lifetime exclusion scope** — applies to **V5.19 only**. V5.18 remains unchanged.
2. **Purchase signal strategy** — drop exact-SKU `purchase_recent` / `purchase_historical` scoring in V5.19. Ship `cart`, `view`, and bestseller fallback only.
3. **Fitment source for the union** — snapshot from V5.18 **staging** (`temp_holley_v5_18.final_vehicle_recommendations`) before building the combined table.
4. **YMM placeholders** — use `'UNKNOWN'`, not `NULL`, for V5.19 rows.
5. **Existing-table assumption** — keep `final_vehicle_recommendations` and the existing column set only; use existing columns as internal markers.

Implementation consequence:
- narrow the V5.19 internal signal enum to `{cart, view, bestseller}` everywhere it appears
- remove any remaining references to `final_non_fitment_recommendations` from the pipeline, validation, and docs unless a concrete downstream dependency is found during implementation

---

## 6. User-approved defaults

The plan is approved with these defaults:

- keep `final_vehicle_recommendations`
- keep the existing column set only
- use existing columns as internal markers
- `rec*_type = 'fitment'` or `'non_fitment'`
- `pipeline_version = 'v5.19'` across the combined table
- V5.19 `v1_year`, `v1_make`, `v1_model = 'UNKNOWN'`
- V5.19 `rec*_pop_source`, `engagement_tier`, `fitment_count = NULL`
- lifetime exclusion applies to V5.19 only
- V5.19 uses cart/view + bestseller fallback; no exact-SKU purchase scoring
- keep the run-scoped fitment snapshot before `UNION ALL`

---

## 7. Files affected

| File | Type of change |
|------|----------------|
| `specs/v5_19_non_fitment_recommendations.md` | Rewrite Output, Architecture, Filters, Success Criteria sections to reflect: shared table, value-vocabulary expansion per §1a, V5.19 column fills per §4, lifetime exclusion, dropped purchase signals |
| `sql/recommendations/v5_19_non_fitment_recommendations.sql` | (a) Drop separate `final_non_fitment_recommendations` write target (line 40); (b) replace 365d exclusion with lifetime (line 67); (c) drop `purchase_*` scoring + narrow internal signal enum to `{cart, view, bestseller}`; (d) add run-scoped fitment snapshot per §4.3; (e) UNION ALL with snapshot from V5.18 staging; (f) emit V5.19 rows in V5.18 schema per §4 (`'UNKNOWN'` for v1_*, `'non_fitment'` literal for `rec*_type`, NULL for `rec*_pop_source`/`engagement_tier`/`fitment_count`, `'v5.19'` for `pipeline_version`) |
| `sql/validation/qa_checks.sql` | **MANDATORY:** parameterize value-set checks for the shared table. `fitment_count IN (3,4)` → only enforce when `rec1_type = 'fitment'`. `engagement_tier IN ('hot','cold')` → only enforce when `rec1_type = 'fitment'`; allow NULL when `rec1_type = 'non_fitment'`. Add cross-slot invariant: `rec1_type = rec2_type` etc. when slots populated. Add `pipeline_version` single-value invariant. |
| `sql/validation/v5_19_go_no_go_eval.sql` | Retarget to shared table; validate lifetime exclusion for `rec1_type = 'non_fitment'` rows; validate fitment/non-fitment disjointness by email; validate V5.18 invariants still hold for `rec1_type = 'fitment'` rows |
| `docs/architecture/v5_18_architecture_specification.md` | Update lines 345/347/348 (`rec*_type`, `engagement_tier`, `fitment_count`) value vocabularies per §1a; document the row-level audience discriminator and the snapshot/UNION materialization |
| `docs/release_notes.md` | Rewrite V5.19 entry around shared-table deployment, lifetime exclusion, value-vocabulary expansion, V5.18 → V5.19 ordering, mandatory snapshot |

Conditional: `sql/recommendations/v5_18_fitment_recommendations.sql` — **no algorithmic change needed**. V5.18 logic untouched. Only `pipeline_version` may move from `'v5.18'` → `'v5.19'` if we want the staging table tagged with the release version even when V5.19 has not yet been unioned. Deferred — easier to set `pipeline_version = 'v5.19'` only at the V5.19 UNION step.

---

## 8. Implementation order

1. Rewrite spec → **get written approval from user** before any SQL touch
2. Rewrite V5.19 pipeline SQL:
   - drop separate `final_non_fitment_recommendations` write target (line 40)
   - replace 365d purchase exclusion with lifetime (line 67)
   - drop `purchase_recent` / `purchase_historical` from candidate scoring
   - emit V5.19 rows in V5.18 schema (`'UNKNOWN'` for v1_*, `'non_fitment'` literal for `rec*_type`, NULL for `rec*_pop_source`/`engagement_tier`/`fitment_count`)
   - add run-scoped fitment snapshot step per §4.3 with the V5.18-empty assertion
   - UNION ALL snapshot + non-fitment rows → `temp_holley_v5_19.final_vehicle_recommendations`, all rows tagged `pipeline_version = 'v5.19'`
3. Migrate `qa_checks.sql` per §7 (value-set checks become conditional on `rec1_type`)
4. Rewrite V5.19 go/no-go SQL against the shared table
5. Update `v5_18_architecture_specification.md` value vocabularies
6. Update release notes
7. `bq query --dry_run` on every SQL touched
8. Staging execution to `temp_holley_v5_19.final_vehicle_recommendations`
9. Validate:
   - email-level disjointness between `rec1_type = 'fitment'` and `rec1_type = 'non_fitment'` rows
   - lifetime exclusion holds for V5.19 rows
   - within every row, all populated `recN_type` slots are equal
   - `pipeline_version` is single-valued across the table
   - V5.18 invariants (price ≥ $50, ≤2 SKUs per PartType, 0 universals, 0 fitment mismatches) still pass for V5.18 rows
   - no `purchase_recent` / `purchase_historical` survive in V5.19 working tables under the locked cart/view/bestseller default
10. Sample-user sanity check:
    - 5 cart-heavy non-fitment users
    - 5 view-heavy non-fitment users
    - 5 bestseller-only non-fitment users
    - 5 fitment users from the snapshotted V5.18 source
11. **User confirmation → PR**
12. **User confirmation → prod deploy** of combined shared table

Per `feedback_pr_and_testing.md`: PR + prod are terminal gates and require explicit user confirmation. Never auto-pushed.

---

## 9. Out-of-scope for V5.19 (deferred)

- Collaborative filtering ("users who browsed X also browsed Y") — V5.20+
- GNN approach — V6.x track
- Search query → SKU mapping
- Brand / category / PartType-level campaign targeting
- Retroactive V5.18 behavior change unless explicitly requested
- Purchase-based related-item personalization
- New shared-table columns (`user_segment`, `dominant_signal`, signal types, signal ages, etc.) — kept in V5.19 working tables only

---

## 10. Estimated effort (after contract locked)

| Phase | Estimate |
|-------|----------|
| Spec rewrite + user approval | 1 hour |
| SQL rewrite (V5.19 pipeline + snapshot) | 4 hours |
| QA migration (parameterize value-set checks) | 1 hour |
| Go/no-go + arch doc + release notes | 1 hour |
| Dry-run + staging + QA execution | 2 hours |
| Sample sanity check | 30 min |
| **Total** | **~9–10 hours** focused |

---

## 11. Plan status

- [x] User approved the plan defaults
- [x] Execution contract is locked
- [ ] Spec rewrite begins next

---

## Appendix A — Why purchase_recent is dead under current branch

`sql/recommendations/v5_19_non_fitment_recommendations.sql`:
- Line 283 — extracts `purchase_recent` signal from events
- Line 661 — purchase exclusion table built from events + import orders, 365d window
- Line 703 — `purchase_recent` scored in `event_signals`
- Line 794 — purchase exclusion LEFT JOIN drops the (user, sku) pair

So a user's `purchase_recent` (user, sku) pair is scored, then immediately removed by exclusion. `purchase_historical` survives only because its candidates may be older than 365d.

Under **lifetime** exclusion, both die. Hence the locked cart/view/bestseller default.

## Appendix B — engagement_tier semantics gap (resolved)

Earlier rounds raised that V5.19's `engagement_tier` was derived from raw pre-filter signal ages, so a user could be tagged `warm` while their actual recs were pure bestsellers (purchased SKU excluded).

**Resolution in r6:** the prod table's `engagement_tier` for V5.19 rows is **NULL**. The 4-tier internal classification (hot/warm/cold/fallback with provenance) lives in `temp_holley_v5_19` working tables for our analysis. Downstream email copy doesn't read the column for V5.19 rows, so the gap is no longer exposed externally. QA migration (§7) parameterizes the existing `engagement_tier IN ('hot','cold')` check to apply only when `rec1_type = 'fitment'`.

## Appendix C — Why `rec1_type` works as the audience discriminator

- Always populated (every row has at least rec_part_1, hence rec1_type)
- Takes exactly two semantic values across the universe of rows: `'fitment'` (V5.18 logic) or `'non_fitment'` (V5.19 logic) — user-approved
- Already a per-slot column in V5.18; no schema addition required
- Cross-slot invariant (`rec1_type = rec2_type = ...`) is trivially asserted in QA

The alternative — using `pipeline_version` — fails because:
- `pipeline_version` is documented and used as a single-value release tag (`docs/architecture/v5_18_architecture_specification.md:350`, `sql/recommendations/v5_18_fitment_recommendations.sql:1084` reports `MAX(pipeline_version)` after deploy expecting one value)
- Mixed `'v5.18'` and `'v5.19'` rows in one table breaks that report
- Adding a separate column (`user_segment`) violates the user's "no new columns" requirement and is redundant with `rec1_type` anyway
