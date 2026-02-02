# Holley Recommendation System

Vehicle fitment recommendations for automotive parts using collaborative filtering.

## Quick Start

| I want to... | Do this |
|--------------|---------|
| Run the pipeline | `/run-pipeline` or `bq query < sql/recommendations/v5_17_*.sql` |
| Check pipeline health | `/status` |
| Validate output quality | `/validate` |
| Deploy to production | `/deploy` (after validation passes) |
| Debug a SQL error | `/debug-sql` or use `sql-debugger` agent |
| Analyze CTR | `/analyze-ctr` or use `ctr-analyst` agent |
| Compare Personalized vs Static | `/uplift` or use `uplift-analyst` agent |
| Create a new version | `/new-version` (guided workflow) |
| Full end-to-end deploy | `/full-deploy` (run → validate → compare → deploy) |
| Write weekly update | `/weekly-update` (from STATUS_LOG + git) |

## Architecture Docs

| Doc | What it explains |
|-----|------------------|
| [Pipeline Architecture](docs/pipeline_architecture.md) | Data flow, scoring algorithm, filters, tuning knobs |
| [BigQuery Schema](docs/bigquery_schema.md) | Table schemas, column types, query patterns, gotchas |
| [Release Notes](docs/release_notes.md) | Version history and changes |

## Stack
- Python 3.12+, uv, BigQuery (bq CLI), MLflow, W&B
- Production: `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
- Working: `auxia-reporting.temp_holley_v5_17`

## Workflow: Plan → Code → Review

### PLAN
1. Create spec in `specs/` using template
2. Define: problem, data, output, validation
3. ASK if unclear - don't assume

### CODE
1. Use existing SQL patterns in `sql/recommendations/`
2. Run `bq query --dry_run` before execution
3. Use `sql-debugger` subagent if errors occur

### REVIEW
1. Run `sql/validation/qa_checks.sql`
2. Verify: 450K users, 0 duplicates, prices ≥$50
3. Update docs if architecture changed

## Key Files

### Architecture (start here)
| Path | Purpose |
|------|---------|
| `docs/pipeline_architecture.md` | **Data flow, scoring, filters, tuning knobs** |
| `docs/bigquery_schema.md` | **Table schemas, gotchas, query patterns** |

### Pipeline
| Path | Purpose |
|------|---------|
| `sql/recommendations/v5_17_*.sql` | Production pipeline |
| `sql/validation/qa_checks.sql` | QA validation |
| `specs/v5_6_recommendations.md` | Current spec |

### Config
| Path | Purpose |
|------|---------|
| `configs/dev.yaml` | Configuration |
| `configs/personalized_treatments.csv` | 10 Personalized Fitment treatment IDs |
| `configs/static_treatments.csv` | 22 Static treatment IDs |

### Analysis & Reports
| Path | Purpose |
|------|---------|
| `docs/campaign_reports_2025_12_10.md` | Post-purchase email campaign analysis |
| `docs/treatment_ctr_unbiased_analysis_2025_12_17.md` | Unbiased CTR analysis (Personalized vs Static) |
| `docs/release_notes.md` | Pipeline version history and changes |
| `docs/pipeline_run_stats.md` | Pipeline run history & comparison stats |
| `src/bandit_click_holley.py` | Email treatment Click Bandit analysis |

### Infrastructure
| Path | Purpose |
|------|---------|
| `flows/metaflow_runner.py` | K8s script runner via Metaflow |
| `flows/run.sh` | Run scripts on K8s |
| `flows/README.md` | Metaflow setup instructions |

## Commands
```bash
# Validate SQL
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_17_*.sql

# Run pipeline
bq query --use_legacy_sql=false < sql/recommendations/v5_17_*.sql

# Run QA checks
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql

# Run Python script on K8s (via Metaflow)
./flows/run.sh src/bandit_click_holley.py

# Query PostgreSQL treatments (via BigQuery federated query)
bq query --use_legacy_sql=false 'SELECT * FROM EXTERNAL_QUERY("projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb", "SELECT treatment_id, name, is_paused FROM treatment WHERE company_id = 1950 ORDER BY treatment_id DESC LIMIT 20")'

# Python
make test && make lint
```

## BigQuery Tables

### auxia-gcp.company_1950

| Table | Purpose |
|-------|---------|
| `ingestion_unified_attributes_schema_incremental` | User attributes (v1 YMM, email) |
| `ingestion_unified_schema_incremental` | User events (views, carts, orders) |
| `treatment_history_sent` | Treatment assignments |
| `treatment_interaction` | Treatment interactions (VIEWED, CLICKED) |

### auxia-gcp.data_company_1950

| Table | Purpose |
|-------|---------|
| `vehicle_product_fitment_data` | Vehicle-to-SKU fitment mapping |
| `import_items` | Product catalog (PartType for diversity) |
| `import_items_tags` | Tags column (Refurbished filter) |
| `import_orders` | Historical orders (popularity, purchase exclusion) |

## Critical Rules
- Never hardcode project IDs (use configs/)
- Always COALESCE(string_value, long_value) for event properties
- Run qa_checks.sql after any pipeline change
- Max 2 SKUs per PartType (diversity filter)
- Variant dedup: B/R/G/P suffixes only stripped when preceded by digit (e.g., 140061B → 140061)
- Sep 1, 2025 is fixed boundary between historical/recent data - don't change

## Common Failures & Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| "Duplicate SKUs in output" | Missing variant dedup | Check regex: `[0-9][BRGP]$` |
| "Price below $50" | Wrong threshold in sku_prices | Verify WHERE clause |
| "Missing HTTPS" | Protocol-relative URL | REPLACE `//cdn` with `https://cdn` |
| "Column ProductId not found" | Case sensitivity | Cart=ProductId, Order=ProductID |
| "Bytes billing exceeded" | Missing partition filter | Add DATE filter early in query |
| "Division by zero" | Missing SAFE_DIVIDE | Use SAFE_DIVIDE() or NULLIF |
| "No matching signature" | Type mismatch | Check COALESCE(string_value, CAST(long_value AS STRING)) |

## Analysis Methodology

### CTR Analysis
- Use `src/bandit_click_holley.py` for Thompson Sampling
- Always use DISTINCT for click/view counts (prevents multi-click inflation)
- 60-day window is standard for treatment analysis
- Reference: `docs/model_ctr_comparison_2025_12_17.md`

### Uplift Analysis
- Use MECE framework: only compare eligible users (with vehicle data)
- Within-user comparison is gold standard (same user, both treatments)
- Reference: `docs/treatment_ctr_unbiased_analysis_2025_12_17.md`

### Key Metrics
| Metric | Formula | Notes |
|--------|---------|-------|
| Open Rate | opens / sent | Delivery-adjusted |
| CTR (of opens) | clicks / opens | Standard email metric |
| CTR (of sent) | clicks / sent | Overall effectiveness |
| Conversion Rate | orders / clicks | Purchase intent |

## Custom Subagents

Project-specific subagents in `.claude/agents/`:

### Pipeline & Code
| Agent | Purpose | When to Use |
|-------|---------|-------------|
| `code-reviewer` | Code quality, security, tests | After writing/modifying code |
| `sql-debugger` | BigQuery errors, optimization | When SQL fails or needs optimization |
| `pipeline-verifier` | QA validation, pass/fail | After running pipeline |

### Analytics
| Agent | Purpose | When to Use |
|-------|---------|-------------|
| `ctr-analyst` | Thompson Sampling, treatment CTR | "What's the CTR?" or ranking treatments |
| `uplift-analyst` | MECE framework, within-user comparison | "Is Personalized beating Static?" |
| `conversion-analyst` | Click-to-order, revenue, AOV | "What's conversion rate?" or revenue analysis |

## When to Spawn Subagents

| Task | Agent Type | Why |
|------|------------|-----|
| "Explore the codebase" | Explore | Fast, focused search |
| "Plan the implementation" | Plan | Architecture decisions |
| "Find where X happens" | Explore | Pattern matching |
| "Debug this SQL error" | `sql-debugger` | Has debugging workflow + gotchas |
| "Review my code" | `code-reviewer` | Has review checklist |
| "Verify pipeline output" | `pipeline-verifier` | Has QA checks + thresholds |
| "What's the CTR?" | `ctr-analyst` | Thompson Sampling + posteriors |
| "Is Personalized beating Static?" | `uplift-analyst` | MECE framework + within-user |
| "What's conversion rate?" | `conversion-analyst` | Funnel + revenue attribution |
| "Compare pipeline versions" | General-purpose | Multiple queries needed |

## Skills Available

### Single-Step Skills
- `/analyze-ctr` - Thompson Sampling CTR analysis
- `/uplift` - Personalized vs Static comparison (MECE)
- `/validate` - QA checks with pass/fail parsing
- `/debug-sql` - SQL error diagnosis
- `/compare-versions` - Pipeline version diff
- `/deploy` - Deploy staging to production
- `/run-pipeline` - Execute v5.17 pipeline
- `/status` - Quick health check (prod vs staging, CTR, git status)

### Workflow Skills (Multi-Step Automation)
- `/new-version` - Create new pipeline version end-to-end (spec → implement → test → validate → compare)
- `/full-deploy` - Complete deployment flow (run → validate → compare → confirm → deploy → verify)

## Hooks & Guardrails

Automatic validation configured in `.claude/settings.json`:

| Hook | Trigger | Action |
|------|---------|--------|
| SQL Validation | Edit/Write `sql/recommendations/*.sql` | Auto dry-run validation (blocks on error) |
| Force Push Block | `git push --force` | Block with warning |

Hooks receive JSON via stdin and use `jq` to parse. Exit code 2 blocks the operation.

**Note:** Restart Claude Code if hooks don't trigger after config changes.

## PostgreSQL Treatment Queries

Query treatment data via BigQuery federated query:
```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  "SELECT treatment_id, name, is_paused FROM treatment WHERE company_id = 1950"
)
```

## Effective Prompts

### Planning & Implementation
```
"Plan how to add [feature]. Consider the existing patterns in v5.17."
"There's a bug where [X happens] but it should [Y]. Analyze and fix it."
"Create a new pipeline version that [adds/changes] [feature]."
```

### Analysis & Debugging
```
"What's the CTR for Personalized vs Static treatments over the last 60 days?"
"Debug this SQL error: [paste error message]"
"Compare v5.17 vs v5.18 output - what changed?"
"Is Personalized beating Static? Use unbiased methodology."
```

### Iteration Tips (from Kevin's workflow)
1. **Let Claude iterate**: Give sample data/test criteria, let it work autonomously
2. **Use planning mode**: For complex tasks, let Claude plan before coding
3. **Provide success criteria**: "Success = QA passes with 450K users, 0 duplicates"
4. **Reference architecture docs**: "See pipeline_architecture.md for scoring algorithm"

### Anti-Patterns (avoid these)
```
❌ "Fix it" (too vague)
❌ "Make it faster" (no specific metric)
❌ "Change the algorithm" (which part?)
✓ "Reduce bytes scanned in Step 1 by 50%"
✓ "Add a filter to exclude SKUs under $100"
```
