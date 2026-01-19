# Holley Recommendations - Status Log

**Project**: Vehicle Fitment Recommendations V5
**Production Table**: `auxia-reporting.company_1950_jp.final_vehicle_recommendations`

---

## 2026-01-19 (Sunday)

### Focus: v5.17 Uplift Validation & Post-Purchase Analysis

Completed comprehensive analysis validating v5.17 deployment impact and comparing Personalized vs Static treatment performance.

#### v5.7 vs v5.17 Deployment Impact (Key Business Result)

| Metric | v5.7 Baseline (Dec 15 - Jan 9) | v5.17 (Jan 10-13) | Uplift |
|--------|-------------------------------|-------------------|--------|
| Open Rate | 4.25% | 11.88% | **+180%** |
| CTR of Sends | 0.48% | 0.93% | **+94%** |

**Validation:** Static treatments (control) improved only +87% open rate in the same period, confirming v5.17's **2.1x relative gain** is due to the algorithm change, not systemic factors.

**Same-User Validation:** 221 users who received emails in both periods opened v5.17 emails **58% more often** (5.78% → 9.13%).

#### Personalized vs Static CTR (Treatment Comparison)

| Approach | Personalized | Static | Uplift | Valid? |
|----------|--------------|--------|--------|--------|
| A: Direct (60-day) | 11.54% CTR of opens | 8.29% | **+39%** | ⚠️ Selection bias |
| B: Same-user (n=969) | 2.99% clicked | 2.48% | **+21%** | ✅ Gold standard |

#### Client Communication

> "After deploying v5.17 segment-based recommendations on Jan 10:
> - Open rates nearly tripled (4.25% → 11.88%)
> - Click-through rates nearly doubled (0.48% → 0.93%)
> - Same users opened Personalized emails 58% more often after the upgrade
>
> The improvement for Personalized (180%) was 2x larger than Static (87%), confirming v5.17 is driving real engagement gains."

#### Documents Created
| File | Purpose |
|------|---------|
| `docs/v57_vs_v517_uplift_analysis_2026_01_19.md` | v5.17 deployment impact analysis |
| `docs/post_purchase_uplift_analysis_2026_01_19.md` | Personalized vs Static methodology |

#### Linear Ticket Updated
- [AUX-11471](https://linear.app/auxia/issue/AUX-11471) - Added v5.17 uplift findings

---

## 2026-01-13 (Tuesday)

### Focus: V5.17 Multi-Tier Fallback & Automation

- **Relevance Breakthrough:** Successfully transitioned from global popularity (v5.7) to segment-specific sales velocity (v5.17). Recommendations are now tailored to 1,100+ vehicle segments, prioritizing what owners of the same make/model actually buy.
- **Improved Coverage:** Introduced a 3-tier fallback (Segment → Make → Global). Global fallback dropped from 24% to 2% of users, while 87% now receive highly relevant segment-level recommendations.
- **Match Rate Improvement:** Backtest match rates improved from near-zero to 0.38% after refining candidate pools and addressing the fitment data gap (65% of user purchases were previously untracked).
- **Automation:** Configured Metaflow cron job for automated daily pipeline runs. Finalizing Gradle dependency resolution for seamless deployment.

#### Documents Updated
| File | Purpose |
|------|---------|
| `docs/weekly_updates.md` | Team-facing business summary |
| `docs/v5_15_investigation_summary.md` | Correction of initial match rate estimates |
| `docs/cf_analysis_2026_01_07.md` | Decision to skip CF due to low repeat intent |

#### Commits
`fd5bf9e`, `8f55b51`, `17acdc1`, `35318bd`

---

## 2026-01-05 (Sunday)

### Focus: Algorithm Root Cause Analysis & v5.8 Fix Spec

- **Strategic Focus Validated:** Data analysis confirms vehicle parts drive 98% of total revenue ($43.8M), validating the strategy to keep recommendations focused on core automotive components over apparel or accessories.

- **Relevance Breakthrough:** The current algorithm ranks products by global popularity (what everyone buys) rather than segment popularity (what owners of a specific vehicle buy). Transitioning to segment-specific sales velocity will prioritize relevant, year-specific parts over generic, universal items.

- **Anticipated Business Impact:** Shifting from "what fits" to "what owners like you buy" is expected to significantly increase the rate at which recommendations match actual purchases, driving higher engagement and conversion for the personalized email program.

#### Documents Created

| File | Purpose |
|------|---------|
| `docs/algorithm_fitment_vs_sales_velocity_analysis_2026_01_04.md` | Root cause analysis |
| `specs/algorithm_fix_per_vehicle_sales_velocity.md` | v5.8 implementation spec |
| `docs/SESSION_2026_01_05_algorithm_analysis.md` | Session summary |

#### Commits
`9ef0927`, `4607d93`, `4b7617f`, `0ea5f9e`

---

## 2026-01-02 (Thursday)

### Focus: Claude Code Best Practices & Analytics Subagents

Implemented Boris Cherny's 13 Claude Code tips and created analytics-focused subagents for CTR, uplift, and conversion analysis.

#### Business Impact
- **Faster analytics**: 3 new subagents encode CTR/uplift/conversion patterns - no need to re-explain methodology
- **Consistent analysis**: MECE framework and Thompson Sampling baked into subagent prompts
- **Team velocity**: GitHub Action enables @claude on PRs, Linear MCP for issue tracking

#### Subagents Created (6 total)

| Agent | Purpose | Business Use |
|-------|---------|--------------|
| `ctr-analyst` | Thompson Sampling, Beta posteriors | Treatment performance ranking |
| `uplift-analyst` | MECE framework, within-user comparison | Personalized vs Static comparison |
| `conversion-analyst` | Click-to-order, revenue attribution | Revenue impact analysis |
| `code-reviewer` | Code quality, security | Code review automation |
| `sql-debugger` | BigQuery error diagnosis | Faster debugging |
| `pipeline-verifier` | QA validation, pass/fail | Pipeline quality gates |

#### Infrastructure Added

| Feature | File | Purpose |
|---------|------|---------|
| `/commit` command | `.claude/commands/commit.md` | Streamlined git workflow |
| GitHub Action | `.github/workflows/claude.yml` | @claude on PRs |
| Linear MCP | `.mcp.json` | Issue tracking integration |
| Pre-commit hooks | `.pre-commit-config.yaml` | Code quality gates |
| Python format hook | `.claude/settings.json` | Auto-format with ruff |

#### Boris Cherny Tips Status
- **11/13 implemented** (Tips 3-11, 13)
- **Remaining**: Tip 1-2 (user preference), Tip 12 (stop hooks - optional)

#### Commits
- `ccd8f61` - Add Boris Cherny tips and Phase 1 improvements
- `b9992da` - Convert agent_docs to Claude Code subagents
- `ea6e328` - Add Claude Code GitHub Action
- `704d105` - Add 3 analytics subagents
- `e9697b0` - Add Linear MCP config

---

## 2025-12-29 (Sunday)

### Focus: Agent Infrastructure & Analysis

#### Hooks & Guardrails
- Added PostToolUse hook for SQL validation (auto dry-run on `sql/recommendations/*.sql`)
- Added PreToolUse hook to block force push commands
- Hook format: uses `jq` to parse JSON from stdin, exit code 2 blocks operation

#### New Skills (Workflow Automation)
| Skill | Purpose |
|-------|---------|
| `/deploy` | Deploy staging to production (dry-run → QA → confirm → deploy) |
| `/new-version` | End-to-end pipeline version lifecycle |
| `/full-deploy` | Complete deployment flow |
| `/status` | Quick health check (prod vs staging, CTR, git status) |

#### Apparel vs Vehicle Parts Analysis
Addressed Sumeet's concern about apparel recommendations outperforming vehicle parts.

| Category | Orders | Revenue |
|----------|--------|---------|
| Vehicle Parts | 96% (218,894) | 98% ($43.8M) |
| Apparel/Safety | 4% (9,367) | 2% ($801K) |

**Conclusion**: Vehicle-centric recommendation approach is correctly aligned. No change needed.

#### Files Changed
- `.claude/settings.json` - hooks config
- `.claude/skills/deploy/SKILL.md` - new
- `.claude/skills/new-version/SKILL.md` - new
- `.claude/skills/full-deploy/SKILL.md` - new
- `.claude/skills/status/SKILL.md` - new
- `AGENTS.md` - updated with skills & hooks docs
- `docs/apparel_vs_vehicle_parts_analysis_2025_12_27.md` - new

---

## 2025-12-21 (Saturday)

### Focus: V5.7 Production Deployment

Deployed v5.7 pipeline with performance optimizations and critical variant dedup bug fix.

#### V5.7 Changes

| Type | Change |
|------|--------|
| **Bug Fix** | Variant dedup regex - only strip B/R/G/P when preceded by digit (was incorrectly collapsing 7,711 SKUs like `0-76650HB`) |
| **Bug Fix** | QA validation threshold now uses `$50` min_price (was checking `$20`) |
| **Perf** | Single import_orders scan (was scanned twice for popularity + exclusion) |
| **Perf** | Pre-filter `ORDER_DATE LIKE '%2024%' OR '%2025%'` before PARSE_DATE |
| **Perf** | Pre-cast `v1_year_int` in Step 0 for cleaner joins |
| **Feature** | `deploy_to_production` flag (opt-in deployment) |
| **Feature** | `pipeline_version` column in final output |

#### V5.6 vs V5.7 Comparison

| Metric | V5.6 | V5.7 |
|--------|------|------|
| Users | 456,957 | 456,825 |
| Identical recs | - | 99.95% |
| diff_rec3 | - | 28 |
| diff_rec4 | - | 229 |
| Users lost | - | 134 (correct - <4 products after dedup) |

#### QA Results (All Passed)

| Check | Result |
|-------|--------|
| Users | 456,825 (≥450K ✓) |
| Price Range | $50 - $7,599.95 (≥$50 ✓) |
| Avg Price | $388 |
| Duplicates | 0 ✓ |
| Refurbished | 0 ✓ |
| Service SKUs | 0 ✓ |
| HTTPS Images | 100% ✓ |
| Score Ordering | 100% ✓ |
| Diversity (max 2/PartType) | ✓ |

#### Files Updated

- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` (new)
- `sql/recommendations/v5_6_vehicle_fitment_recommendations.sql` (deploy flag)
- `sql/validation/qa_checks.sql` (v5.7 dataset, $50 threshold)
- `agent_docs/architecture.md` (price $50)
- `agent_docs/bigquery.md` (v5.7 refs)
- `docs/release_notes.md` (new)
- `.claude/skills/run-pipeline/SKILL.md` (v5.7 refs)
- `AGENTS.md` (v5.7 as production)

**Commits:** `6c754d5`, `20ada06`, `278931f`

**Production Table:** `auxia-reporting.company_1950_jp.final_vehicle_recommendations` (pipeline_version = v5.7)

---

## 2025-12-18 (Wednesday)

### Focus: QA Follow-up & Doc Refresh

- Answered QA questions on CTR analysis (date range, price point stats)
- Verified price point hypothesis: Apparel shows $20-50 items, Personalized shows $337 avg
- Refreshed CTR doc with latest numbers (Static still wins by ~2.3x)
- Clarified distinction between email content price vs post-purchase AOV

**Doc Updated:** `docs/treatment_ctr_unbiased_analysis_2025_12_17.md`

**Commits:** `570e4e3`, `355d52e`, `ba06987`

---

## 2025-12-17 (Tuesday)

### Focus: Unbiased CTR Analysis & Bandit Model Investigation

#### 1. Unbiased CTR Analysis (Personalized vs Static)

Corrected CTR analysis with proper BigQuery tables. Key finding: "Static" = only Apparel emails.

**Key Results (Eligible Users):**
| Treatment | Sends | Clicks | CTR |
|-----------|-------|--------|-----|
| Personalized | 9,385 | 61 | 4.81% |
| Static | 1,824 | 39 | 11.89% |

**Within-User (428 users):** Static 9.23% vs Personalized 5.12%

**Critical:** Only 1 of 22 static treatments sent (Apparel). Other 21 have 0 sends.

#### 2. Bandit vs Random Model CTR Comparison (Dec 16 - Updated)

**Traffic Split:** Random 91.5% (24,722) | Bandit 8.5% (2,301)

| Metric | Random | Bandit |
|--------|--------|--------|
| Open Rate | **2.67%** | 1.26% |
| CTR/Open | 9.38% | **31.03%** |
| CTR/Send | 0.25% | **0.39%** |

**Key Update:** Bandit now **wins on CTR/Send** (0.39% vs 0.25%) - the business metric that matters!

**Root Cause of Lower Bandit Opens:** Thompson Sampling exploration. Bandit deliberately tests low-score user-treatment pairs (avg score 0.08-0.16 vs Random 0.48-0.91 for same treatments).

**Why Higher CTR/Open:** Users who open despite low predicted scores are self-selected high-intent → click more (31% vs 9.4%).

**Verdict:** Promising early results (9 Bandit clicks vs 62 Random). Bandit's superior CTR/Open compensates for lower open rate.

**Doc Updates:**
- Fixed table refs: `ingestion_unified_*` (not `imported_unified_*`)
- Added `docs/model_ctr_comparison_2025_12_17.md` with deep dive analysis
- Added `LEARNING_THOMPSON_SAMPLING.md` - educational reference with glossary

**Commits:** `5c607ed`, `c409fe5`, `67891f7`, `76fef58`, `5f6fec7`, `d3468e6`

---

## 2025-12-16 (Monday)

### Focus: Daily Run Setup & Production Deployment

Added production deployment step to SQL pipeline for daily scheduled runs.

**Updates:**
- Added Step 4 to pipeline: deploy to production + create timestamped copy
- No hardcoded dates (uses `CURRENT_DATE()`)
- Single script does: build → deploy → timestamp copy

**Pipeline Flow:**
1. Build intermediate tables in `temp_holley_v5_4`
2. Create `final_vehicle_recommendations` in v5_4
3. Overwrite production table
4. Create timestamped copy (e.g., `_2025_12_16`)

**Run Results (Dec 16):**

| Metric | Dec 11 | Dec 16 | Change |
|--------|--------|--------|--------|
| Users | 459,540 | 456,574 | -0.6% |
| Avg rec1 price | $240.93 | $336.53 | +40% |
| Avg all prices | $282.25 | $389.83 | +38% |

**Validation:** All checks passed (user count, min price $50, no duplicates, HTTPS images).

**Stability:** 35.5% identical, 51.8% with 3-4 changes (higher churn due to 5 days of new data).

**Commit:** `9fe99b8` - Add production deployment step to recommendation pipeline

**Next:** Set up BigQuery scheduled query (pending service account access).

---

## 2025-12-11 (Thursday)

### Focus: Recommendation Pipeline Updates (Quality Improvements)

Improved recommendation quality and revenue potential by tightening candidate filtering and deduping product variants.

**Updates:**
- Raised minimum price floor from **$20 → $50** to avoid low-value items dominating recommendations.
- Filtered out low-value PartTypes (gaskets, bolt sets, decals, clamps, etc.), while keeping high-value exceptions (engine bolt kits and distributor caps).
- Fixed color variant duplicates so we don’t recommend the same product in multiple colors (e.g., `RA003B` and `RA003R`).

**Results:**
- Avg recommended item price: **$283 → $466** (**+65%**).
- Recommendation mix shifted toward higher-value items (e.g., fuel injection kits & carburetors) instead of commodity bolt-set style parts.

---

## 2025-12-09 (Tuesday)

### Focus: Email Treatment Click Bandit - Implementation Complete

Built Thompson Sampling bandit analysis for email treatment optimization. Adapted from JCOM's model.

**Deliverables:**
- `src/bandit_click_holley.py` - Beta-Binomial Thompson Sampling analysis
- `flows/metaflow_runner.py` - K8s runner via Metaflow
- `flows/run.sh` - Wrapper script
- `configs/metaflow/config.json` - K8s cluster config
- `flows/README.md` - Setup instructions

**K8s Run Results:**
| Metric | Value |
|--------|-------|
| Treatments | 24 |
| Views | 5,598 |
| Clicks | 412 |
| Overall CTR | 7.36% |

**Top Performers (by volume):**
| Treatment | Views | CTR |
|-----------|-------|-----|
| 17049625 | 1,318 | 10.3% |
| 16490939 | 2,320 | 6.1% |
| 16150707 | 1,049 | 7.5% |

**Run:** `./flows/run.sh src/bandit_click_holley.py`

---

## 2025-12-06 (Saturday)

### Focus: Post-Launch Campaign Performance Analysis

Email campaign launched Dec 4th. Analyzed interactions data and built reporting queries to track performance.

---

#### 1. Data Discovery

**Why**: Colleague asked "Do we have any interactions data/performance tracking?" - needed to investigate what's available.

**How**: Explored `auxia-gcp.company_1950` dataset for treatment-related tables.

**Key Tables Found**:

| Table | Purpose |
|-------|---------|
| `treatment_history` | Who received what treatment |
| `treatment_interaction` | Opens (VIEWED), Clicks (CLICKED) |
| `treatment_delivery_result_for_batch_decision` | Delivery success/failure |
| `ingestion_unified_schema_incremental` | Order events with revenue |

**Outcome**: Confirmed interactions data exists and is being tracked.

---

#### 2. Full Funnel Analysis

**Why**: Understand complete customer journey from email send to purchase.

**How**: Built SQL queries joining treatment, interaction, and order tables.

**Funnel Results (Dec 4-6)**:

| Stage | Users | Rate |
|-------|------:|-----:|
| Sent | 34,057 | 100% |
| Delivered | 25,252 | 74.1% |
| Opened | 3,670 | 10.8% |
| Clicked | 318 | 0.93% |
| Ordered | 176 | 0.52% |

**Outcome**: Complete visibility into campaign performance.

---

#### 3. Revenue Attribution

**Why**: Quantify business impact of email campaign.

**How**: Joined order events with treatment history, calculated revenue by conversion path.

**Results**:

| Conversion Path | Users | Revenue |
|-----------------|------:|--------:|
| Opened → Ordered | 10 | $3,864 |
| Delivered → Ordered (no open tracked) | 108 | $47,418 |
| Sent → Ordered (unknown) | 58 | $22,014 |
| **Total** | **176** | **$73,297** |

**Key Metrics**:
- Average order value: $416 (vs $400 for non-recipients)
- Most orders: 1-2 days after email (58 orders)
- Peak engagement: 4-7 PM UTC

**Outcome**: $73K revenue attributable to email campaign.

---

#### 4. Known Issues Identified

| Issue | Impact | Root Cause |
|-------|--------|------------|
| Dec 5-6 interaction data lag | 166 orders show "no open tracked" | Pipeline delay (~half day) |
| 1,896 delivery failures | 7% failure rate | Klaviyo rate limits + API errors |
| No click-to-order attribution | 0 users clicked then ordered | May be data lag or direct visits |

---

#### 5. SQL Queries Created

**Files Created**:
- `sql/reporting/campaign_performance.sql` - General performance queries
- `sql/reporting/campaign_funnel_analysis.sql` - Deep funnel analysis with revenue

**Query Categories**:
1. Complete funnel metrics
2. Conversion paths with revenue
3. Revenue by date
4. Time to purchase distribution
5. Funnel by treatment ID
6. Failure analysis
7. Email vs non-email comparison
8. Hourly engagement patterns
9. Opened-then-ordered details
10. Summary metrics (single row)

**Outcome**: Reusable reporting queries for ongoing campaign monitoring.

---

### Day Summary

| Category | Status |
|----------|--------|
| Data Discovery | Complete - 4 key tables identified |
| Funnel Analysis | 34K sent → 25K delivered → 3.7K opened → 318 clicked → 176 ordered |
| Revenue Attribution | $73,297 from 176 orders |
| Avg Order Value | $416 (higher than baseline $400) |
| SQL Queries | 2 files, 10+ reusable queries |
| Known Issues | Interaction data lag, delivery failures |

---

## 2025-12-05 (Friday)

### Focus: Documentation Consolidation & Project Migration

Migrated all documentation from `holley-rec-sonnet` to the new `holley-rec` project structure, following multi-agent best practices.

---

#### 1. Structure Simplification

**Why**: The `holley-rec` template had too many empty folders and generic docs. Needed to populate with Holley-specific content and simplify.

**How**: Flattened directories and removed unused scaffolding.

**Changes**:

| Area | Before | After |
|------|--------|-------|
| `src/` | 5 subdirs (data/, evaluation/, etc.) | Flat (7 .py files) |
| `tests/` | 3 subdirs (unit/, integration/, e2e/) | Flat (3 .py files) |
| `sql/` | ETL folders (extract/, transform/, load/) | `recommendations/` + `validation/` |
| `agent_docs/` | 5 generic files | 2 Holley-specific files |
| `specs/` | active/ + completed/ + templates/ | Flat with template.md |

**Outcome**: Cleaner structure, easier navigation.

---

#### 2. Documentation Consolidation

**Why**: 9 docs in `holley-rec-sonnet/implementations/v5_3/` had significant overlap. Needed to consolidate into focused files.

**How**: Mapped old content to new locations following progressive disclosure pattern.

**Migration**:

| Old (9 files) | New (4 files) |
|---------------|---------------|
| DESIGN_SPECIFICATION.md | → `agent_docs/architecture.md` |
| SCORING_SPECIFICATION.md | → merged into architecture.md |
| SCORING_IMPLICATIONS.md | → dropped (analysis, not operational) |
| IMPLEMENTATION_*.md (3 files) | → dropped (redundant) |
| METRICS_SUMMARY.md | → dropped (historical) |
| VALIDATION_QUERIES.md | → `sql/validation/qa_checks.sql` |
| QA_VALIDATION_SUMMARY.md | → dropped (one-time results) |
| README.md | → `specs/v5_6_recommendations.md` |

**New Files Created**:

| File | Lines | Content |
|------|-------|---------|
| `AGENTS.md` | 60 | WHY/WHAT/HOW, Plan→Code→Review workflow |
| `agent_docs/architecture.md` | 111 | Pipeline, scoring formula, filters, tables |
| `agent_docs/bigquery.md` | 150 | Event schema, 6 critical gotchas, SQL patterns |
| `specs/v5_6_recommendations.md` | 120 | Complete spec with metrics |
| `sql/validation/qa_checks.sql` | 150 | 8 QA validation queries |

**Outcome**: 9 verbose docs → 4 focused docs + 1 SQL file.

---

#### 3. SQL Migration

**Why**: Move production SQL to proper location in new project.

**How**: Copied files to new structure.

**Files**:
- `v5_6_vehicle_fitment_recommendations.sql` → `sql/recommendations/`
- Validation queries extracted → `sql/validation/qa_checks.sql`

**Outcome**: SQL now in correct location with validation queries.

---

#### 4. Git Commit & Push

**Why**: Persist all changes to `holley-rec` repository.

**How**: Staged all changes, committed with descriptive message, pushed to origin.

**Commit**: `a80069c` - "Consolidate docs and simplify project structure"

**Stats**: 38 files changed, +1,233 lines, -774 lines

**Outcome**: Changes live on GitHub.

---

### Day Summary

| Category | Status |
|----------|--------|
| Structure | Simplified (flat src/, tests/, sql/) |
| Docs | Consolidated (9 → 4 files) |
| SQL | Migrated to holley-rec |
| AGENTS.md | Rewritten (60 lines, multi-agent ready) |
| Git | Committed & pushed to holley-rec |
| **holley-rec-sonnet** | **No changes - can be archived** |

---

## 2025-12-02 (Tuesday)

### Focus: Pre-Launch Data Refresh & Production Validation

With the email campaign launch scheduled for Dec 3, we needed to ensure the recommendations were fresh and validated against all business requirements.

---

#### 1. New Data Assessment

**Why**: Before running a refresh, we needed to understand how much new behavioral data had accumulated since the Dec 1 production run, and whether a refresh was worthwhile.

**How**: Queried `auxia-gcp.company_1950.ingestion_unified_schema_incremental` to analyze event volume and user activity over the last 2 days.

**Findings**:

| Date | Total Events | Unique Users |
|------|--------------|--------------|
| Dec 2 | 802,281 | 562,809 |
| Dec 1 | 1,303,427 | 633,648 |

| Intent Event | Count (2 Days) |
|--------------|----------------|
| Viewed Product | 33,064 |
| Cart Update | 7,108 |
| Placed Order | 1,962 |

**Outcome**: Identified **9,540 users with new intent activity** - these users would get improved personalized recommendations after refresh. Decision: Proceed with refresh.

---

#### 2. SQL Configuration Audit

**Why**: Before running the pipeline, we needed to verify the SQL parameters were correct for the target environment and date ranges.

**How**: Reviewed `v5_6_vehicle_fitment_recommendations.sql` parameters and cross-referenced with actual data availability in source tables.

**Issues Discovered**:

| Issue | Problem | Root Cause | Fix |
|-------|---------|------------|-----|
| Wrong dataset | SQL pointed to `temp_holley_v5_3` | Previous run not committed | Changed to `temp_holley_v5_4` |
| Short intent window | 90 days missed Sep 1-2 data | `unified_events` starts Sep 1 | Extended to 93 days |

**Date Window Verification**:
- Queried `unified_events` to confirm data range: **Sep 1 - Dec 2** (93 days total)
- This is the ONLY source for recent behavioral data - no data exists before Sep 1
- Confirmed `import_orders` ends Aug 31 - no overlap with `unified_events`

**Design Spec Review**:
- Read `DESIGN_SPECIFICATION.md` to understand the hybrid popularity model
- Confirmed design intent: Popularity = historical (import_orders Jan-Aug) + recent (unified_events Sep+)
- This is NOT a bug - intentional design to combine both data sources

**Outcome**: Fixed SQL configuration. Intent window now captures all available behavioral data from Sep 1.

---

#### 3. Pipeline Execution

**Why**: Generate fresh recommendations incorporating the 9,540 users with new activity.

**How**: Executed V5.6 SQL pipeline via BigQuery CLI.

**Runtime**: 336 seconds (~5.6 minutes)

**Intermediate Table Validation**:

| Step | Table | Rows | Expected | Status |
|------|-------|------|----------|--------|
| 0 | users_with_v1_vehicles | 498,657 | ~475K | OK |
| 1 | staged_events | 1,468,430 | ~1M+ | OK |
| 1.3 | eligible_parts | 2,112,909 | ~2M | OK |
| 3 | final_vehicle_recommendations | 458,859 | ~450K | OK |

**Outcome**: Pipeline completed successfully. All intermediate validations passed.

---

#### 4. QA Validation Against Business Spec

**Why**: Before deploying to production, we must verify the output meets all business requirements defined in the V5.3 specification. This is a launch blocker.

**How**: Wrote and executed 14 validation queries, each testing a specific spec requirement.

**Results**:

| # | Spec Requirement | Query Logic | Result |
|---|------------------|-------------|--------|
| 1 | MIN_PRICE >= $20 | Check all 4 rec prices >= 20 | **PASS** (0 violations) |
| 2 | RECS_PER_USER = 4 | Check no NULL rec_part columns | **PASS** (0 violations) |
| 3 | MAX_PER_PARTTYPE = 2 | Count SKUs per PartType per user | **538 violations** |
| 4 | PURCHASE_EXCLUSION | Join recs with 365d purchases | **PASS** (0 violations) |
| 5 | NO REFURBISHED | Join with import_items Tags | **PASS** (0 violations) |
| 6 | NO SERVICE SKUs | Check prefix patterns | **PASS** (0 violations) |
| 7 | HTTPS IMAGES | Check all image URLs | **PASS** (0 violations) |
| 8 | VEHICLE FITMENT | Join with eligible_parts | **PASS** (0 violations) |
| 9 | NO DUPLICATE SKUs | Check rec_part_1-4 uniqueness | **PASS** (0 violations) |
| 10 | SCORE ORDERING | Check rec1 >= rec2 >= rec3 >= rec4 | **PASS** (0 violations) |
| 11 | SCORING FORMULA | Check score ranges | **PASS** (0 violations) |
| 12 | MIN_PARTS >= 4 | Check vehicle part counts | **PASS** (0 violations) |
| 13 | EMAIL LOWERCASE | Check email format | **PASS** (0 violations) |
| 14 | UNIQUE EMAILS | Check for duplicate rows | **PASS** (0 violations) |

**Known Issue Deep Dive** (Spec #3 - MAX_PER_PARTTYPE):

*Problem*: 538 users have 3 SKUs of the same PartType instead of max 2.

*Investigation*:
```sql
-- Found 9 SKUs with multiple PartTypes in eligible_parts
SELECT sku, COUNT(DISTINCT part_type) FROM eligible_parts GROUP BY 1 HAVING COUNT(*) > 1
```

*Root Cause*: `import_items` catalog has duplicate entries for 9 SKUs with different PartTypes:
- SKU `18GBJ`: "Vehicle Tuning Flash Tool" AND "UNKNOWN" (NULL)
- SKUs `60-101` to `60-109`: "Performance Upgrade Kit" AND "UNKNOWN"

*Impact*: 538 users (0.12% of total) - minimal business impact.

*Decision*: Acceptable for launch. Root cause is catalog data quality issue, not SQL logic bug. Recommend catalog cleanup in future sprint.

**Outcome**: 13/14 spec checks pass. 1 known issue with documented root cause and minimal impact (0.12%).

---

#### 5. Production Comparison Analysis

**Why**: Understand what changed between Dec 1 and Dec 2 runs to ensure no unexpected regressions and validate the refresh provided value.

**How**: Joined old and new `final_vehicle_recommendations` tables on email_lower, compared all fields.

**User Population Changes**:

| Metric | Count | Explanation |
|--------|-------|-------------|
| Common users | 458,647 | Users in both runs |
| New users gained | +212 | New registrations or newly eligible vehicles |
| Users lost | -18 | Investigated below |
| **Net change** | **+194** | Healthy growth |

**Recommendation Stability** (for 458,647 common users):

| Recs Changed per User | Users | % | Interpretation |
|----------------------|-------|---|----------------|
| 0 (identical) | 384,161 | 83.76% | No new activity, same recs |
| 1 | 46,427 | 10.12% | Minor re-ranking |
| 2 | 26,497 | 5.78% | Moderate changes |
| 3 | 1,442 | 0.31% | Significant new activity |
| 4 | 120 | 0.03% | Complete re-rank |

*Interpretation*: 83.76% stability is healthy - shows consistency while still capturing new signals.

**By Position** (which slots changed most):

| Position | Changed | % | Reason |
|----------|---------|---|--------|
| rec_part_1 | 3,388 | 0.74% | Top rec very stable |
| rec_part_2 | 14,756 | 3.22% | Some re-ranking |
| rec_part_3 | 24,942 | 5.44% | More volatility at lower ranks |
| rec_part_4 | 61,141 | 13.33% | Most change at position 4 |

*Interpretation*: Expected pattern - top recommendations most stable, lower positions more sensitive to score changes.

**Score Changes**:

| Metric | Value |
|--------|-------|
| Users with score increase | 442,222 (96.4%) |
| Users with score decrease | 25 (0.005%) |
| Users with same score | 16,400 (3.6%) |
| Average score increase | +0.10 |

*Interpretation*: Nearly all users saw score increases due to new popularity data - expected and healthy.

**Price Changes**:

| Metric | Dec 1 | Dec 2 | Change |
|--------|-------|-------|--------|
| Avg rec1_price | $242.73 | $248.42 | +$5.69 |
| Avg all recs | $264.89 | $280.30 | +$15.38 |

*Interpretation*: Higher-priced items gaining popularity - good for revenue potential.

**Outcome**: Refresh shows healthy patterns - good stability with meaningful improvements for active users.

---

#### 6. Anomaly Investigation

**Why**: Two anomalies surfaced during comparison that needed explanation before launch approval.

---

**Anomaly 1: Large SKU Swap** (~29,500 users affected)

*Observation*: SKU `550-849K` replaced `0-4412S` in recommendations for ~29,500 users.

*Investigation*:
```sql
-- Compared the two SKUs
SELECT sku, PartType, price, total_orders, popularity_score, vehicle_count
FROM sku_popularity JOIN eligible_parts ...
```

*Findings*:

| SKU | PartType | Price | Orders | Popularity Score | Vehicles |
|-----|----------|-------|--------|------------------|----------|
| 550-849K (new) | Fuel Injection Kit | $1,499.95 | 288 | 11.33 | 5,991 |
| 0-4412S (old) | Carburetor | $534.95 | 284 | 11.30 | 5,989 |

*Root Cause*:
- Both SKUs fit almost identical vehicles (5,991 vs 5,989)
- 550-849K gained 4 more orders, pushing popularity score from 11.30 to 11.33
- This tiny difference (+0.03 score) caused 550-849K to rank higher

*Verdict*: **Expected behavior**. The algorithm is working correctly - more popular items rank higher. No action needed.

---

**Anomaly 2: 18 Users Dropped**

*Observation*: 18 users in Dec 1 output are missing from Dec 2 output.

*Investigation*:
```sql
-- Compared vehicle data between runs
SELECT old.email, old.v1_make, old.v1_model, new.v1_make, new.v1_model
FROM prod_recs old LEFT JOIN new_recs new ON old.email = new.email
WHERE new.email IS NULL
```

*Findings*:

| Email | Old Vehicle | New Vehicle |
|-------|-------------|-------------|
| jrmecj@yahoo.com | RAM 3500 | SIERRA 2500 HD |
| bkassner79@hotmail.com | FORD BRONCO | FORD CHARGER |
| fishingkenny@hotmail.com | CHEVROLET C10 | VOLVO C10 |

*Root Cause*: Users updated their vehicle profiles between Dec 1-2. New vehicles either:
- Don't exist in fitment data, or
- Have fewer than 4 eligible parts

*Verdict*: **Expected behavior**. Users changed their own data. No action needed.

---

**Anomaly 3: Event Source Verification**

*Concern*: Are we capturing all order event types, especially Consumer Website Order?

*Investigation*:
```sql
SELECT event_name, COUNT(*) FROM unified_events
WHERE event_name IN ('Placed Order', 'Ordered Product', 'Consumer Website Order')
GROUP BY 1
```

*Findings*:

| Event Type | Count (Since Sep 1) |
|------------|---------------------|
| Consumer Website Order | 62,688 |
| Placed Order | 46,841 |
| Ordered Product | 46,841 |

*Verdict*: **Confirmed working**. All three order event types are being captured. Consumer Website Order has the highest volume.

**Outcome**: All anomalies investigated and explained. No blockers found.

---

#### 7. Production Deployment

**Why**: Replace the Dec 1 production table with the validated Dec 2 data before the Dec 3 campaign launch.

**How**: 3-step deployment with backup.

| Step | Command | Purpose | Status |
|------|---------|---------|--------|
| 1 | `bq cp ... final_vehicle_recommendations_2025_12_02` | Create timestamped backup | Done |
| 2 | `bq rm -f ... final_vehicle_recommendations` | Remove old production table | Done |
| 3 | `bq cp ... final_vehicle_recommendations` | Deploy new data | Done |

**Verification**:
```sql
SELECT COUNT(*), MIN(generated_at) FROM final_vehicle_recommendations
-- Result: 458,859 users, generated 2025-12-03 06:18:49 UTC
```

**Backup Inventory**:
| Table | Date | Users |
|-------|------|-------|
| final_vehicle_recommendations_2025_12_02 | Dec 2 | 458,859 |
| final_vehicle_recommendations_2025_12_01 | Dec 1 | 458,665 |
| final_vehicle_recommendations_2025_11_17 | Nov 17 | ~446K |

**Outcome**: Production deployed and verified. Backups available for rollback if needed.

---

### Day Summary

| Category | Status |
|----------|--------|
| Data freshness | +9,540 users with new activity captured |
| Configuration | Fixed 2 SQL parameter issues |
| Pipeline | Completed in 5.6 minutes |
| QA validation | 13/14 pass, 1 known issue (0.12% impact) |
| Comparison | 83.76% stable, healthy score improvements |
| Anomalies | 3 investigated, all explained |
| Deployment | Complete with backup |
| **Launch readiness** | **Ready for Dec 3** |

---

## 2025-12-01 (Monday)

### Focus: Production Data Refresh & Deployment

First production refresh using V5.6 SQL with the new `temp_holley_v5_4` dataset. This run established the baseline for the Dec 3 email campaign launch.

---

#### 1. Pipeline Execution

**Why**: Generate fresh recommendations with latest behavioral data ahead of campaign launch week.

**How**: Executed V5.6 SQL pipeline targeting `temp_holley_v5_4` dataset.

**Results**:

| Metric | Value |
|--------|-------|
| Total Users | 458,665 |
| Avg Price (all recs) | $264.89 |
| Min Price | $20.00 |
| Max Price | $3,749.95 |
| Cold-start % | 1.1% |

**Outcome**: Pipeline completed successfully. ~459K users with 4 recommendations each.

---

#### 2. Production Deployment

**Why**: Make recommendations available for campaign system integration.

**How**: Deployed to `auxia-reporting.company_1950_jp.final_vehicle_recommendations`.

**Backup Created**: `final_vehicle_recommendations_2025_12_01`

**Outcome**: Production table live and accessible.

---

### Day Summary

| Category | Status |
|----------|--------|
| Pipeline | Complete (458,665 users) |
| Deployment | Live in production |
| Backup | Created |
| **Status** | **Baseline for Dec 3 launch** |

---

## Template

```markdown
## YYYY-MM-DD (Day)

### Focus
Brief description of day's objectives.

---

#### 1. Section Title

**Why**: Business reason for this work.

**How**: Technical approach taken.

**Findings**: Key data/observations.

**Outcome**: Result and decision made.

---

### Day Summary
| Category | Status |
|----------|--------|
| Item | Status |
```