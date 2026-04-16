# Feature: v5.18 Fitment-Only, Purchase-Only Recommendations

## Status
- [x] Draft
- [ ] In Review
- [ ] Approved
- [ ] In Progress
- [ ] Completed

## Problem Statement
v5.17 is the current production pipeline and was used for the A/B revenue test. A key issue remains: universal parts can appear in recommendation slots and produce obvious fitment mismatches (for example, Golf users receiving non-fitting universal parts).

For v5.18, the goal is to improve recommendation relevance by enforcing a stricter fitment-first architecture and simplifying ranking signals:
- No universal candidates in final recommendations
- Purchase-only scoring (orders only), no view/cart intent scoring

## Scope
In scope for v5.18:
1. Fitment-only candidate pool (no universal candidate generation in ranking path)
2. Price floor change: `$50 -> $25`
3. Diversity cap: max `2` recommendations per PartType per user
4. Recommendation count rule: keep users with `3` or `4` fitment recs; drop `<3`
5. Scoring simplification: remove intent score and use purchase-order popularity only with existing 3-tier fallback

Out of scope:
1. GNN architecture changes
2. Multi-vehicle modeling (`v2/v3` vehicles)
3. Bandit/treatment-system changes
4. Email delivery pacing/infrastructure changes

## Data Requirements

### Input Data
| Table/Source | Columns Used | Purpose |
|--------------|--------------|---------|
| `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` | `user_id`, `email`, `v1_year`, `v1_make`, `v1_model` | Build eligible user set with YMM |
| `auxia-gcp.company_1950.ingestion_unified_schema_incremental` | `user_id`, `event_name`, `event_timestamp`, SKU fields, price/image fields | Recent order events for popularity + purchase exclusion; metadata extraction support |
| `auxia-gcp.data_company_1950.import_orders` | `ITEM`, `SHIP_TO_EMAIL`, `ORDER_DATE` | Historical order history for popularity + purchase exclusion |
| `auxia-gcp.data_company_1950.vehicle_product_fitment_data` | `v1_year`, `v1_make`, `v1_model`, `products.product_number` | Vehicle-to-SKU fitment mapping |
| `auxia-gcp.data_company_1950.import_items` | `PartNumber`, `PartType`, `Tags` | PartType, refurbished exclusion, commodity filtering |

### Output Data
| Table/Destination | Columns | Purpose |
|-------------------|---------|---------|
| `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations` | User columns + `rec_part_1..4`, prices/scores/images/types/pop_source, `fitment_count`, `pipeline_version` | Staging output for validation and comparison before deployment |

### Data Volume
- Estimated input rows: multi-million events/orders (existing v5.17 scale)
- Estimated output rows: target >= 250K users (3 or 4 recommendations)
- Processing frequency: on-demand pipeline runs

## Architecture & Approach

### 1) User Universe
Build users with complete v1 YMM and valid email (same as v5.17).

### 2) Fitment-Eligible Product Pool
Generate YMM-matched fitment SKUs only, applying:
- price >= `$25`
- HTTPS image only
- refurbished/service SKU exclusions
- commodity exclusions
- generation-level minimum support

### 3) Purchase-History Construction
Use purchase orders only for ranking signals:
- Historical purchases from `import_orders`
- Recent purchases from unified events, restricted to order events

No view/cart signals are used in ranking.

### 4) Popularity Scoring (3-Tier Fallback, Purchase-Only)
Keep existing fallback structure:
1. Segment popularity (`make + model`) if segment support is sufficient
2. Make-level popularity if segment is sparse
3. Global popularity fallback

`final_score = popularity_score`

Intent score is removed from final scoring.

### 5) Recommendation Selection
1. Build fitment candidates per user from fitment-eligible table
2. Apply purchase exclusion (365-day lookback)
3. Apply variant dedup
4. Apply diversity cap (`max 2 per PartType`)
5. Rank by `final_score DESC`
6. Keep top 4
7. Retain user if recommendation count is 3 or 4

### 6) Output Contract
Output remains wide-table compatible with 4 slots.
- For 3-rec users, slot 4 fields are `NULL`
- `fitment_count` expected in `{3, 4}`
- `rec*_type` expected as `fitment` (or `NULL` where slot missing)

## Open Questions
- [ ] Popularity history window: keep current historical start boundary or extend farther back in `import_orders`?
- [ ] Should engagement tiers remain in v5.18 output if ranking is purchase-only?
- [ ] Downstream compatibility check: any consumer that requires non-NULL slot 4?

## Success Criteria
- [ ] 0 universal recommendations in final output
- [ ] `fitment_count` only 3 or 4
- [ ] 0 duplicate SKUs within a user row
- [ ] All prices >= $25
- [ ] Max 2 recs per PartType per user
- [ ] User coverage meets target threshold (>= 250K)
- [ ] Spot-check known mismatch segments (e.g., Golf) shows fitment-consistent outputs

## Evaluation Metrics
| Metric | Current (v5.17) | Target (v5.18) |
|--------|------------------|----------------|
| Users with universal recs | >0 | 0 |
| Users with fitment_count < 3 | N/A | 0 in output |
| Price floor violations | 0 at $50 floor | 0 at $25 floor |
| Duplicate SKU users | 0 | 0 |

## Test Plan

### SQL Validation
- [ ] Dry run pipeline SQL
- [ ] Execute pipeline in temp dataset

### QA Validation
- [ ] Update QA checks for fitment-only + min 3 rec rule
- [ ] Validate no universal product types
- [ ] Validate coverage, duplicates, price floor, diversity cap
- [ ] Compare v5.17 vs v5.18 user coverage and rec distribution

### Targeted Validation
- [ ] Re-check previously affected vehicle examples (Golf and top affected segments)

## Dependencies
- [ ] Updated QA query logic (`sql/validation/qa_checks.sql`) for 3-or-4 rec expectation
- [ ] Spec/release-note updates aligned with final design
- [ ] Sign-off on historical window policy for popularity

## Implementation Notes
(To be filled during/after implementation)

---
Created: 2026-02-19
Author: Codex
Approved by: [TBD]
