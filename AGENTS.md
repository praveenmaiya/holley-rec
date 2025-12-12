# Holley Recommendation System

Vehicle fitment recommendations for automotive parts using collaborative filtering.

## Stack
- Python 3.12+, uv, BigQuery (bq CLI), MLflow, W&B
- Production: `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
- Working: `auxia-reporting.temp_holley_v5_4`

## Workflow: Plan → Code → Review

### PLAN
1. Create spec in `specs/` using template
2. Define: problem, data, output, validation
3. ASK if unclear - don't assume

### CODE
1. Reference `@agent_docs/` for patterns
2. Use existing SQL in `sql/recommendations/`
3. Run `bq query --dry_run` before execution

### REVIEW
1. Run `sql/validation/qa_checks.sql`
2. Verify: 450K users, 0 duplicates, prices ≥$20
3. Update docs if architecture changed

## Key Files

| Path | Purpose |
|------|---------|
| `sql/recommendations/v5_6_*.sql` | Production pipeline |
| `sql/validation/qa_checks.sql` | QA validation |
| `agent_docs/architecture.md` | System design, scoring |
| `agent_docs/bigquery.md` | Event schema, SQL gotchas |
| `specs/v5_6_recommendations.md` | Current spec |
| `configs/dev.yaml` | Configuration |
| `configs/personalized_treatments.csv` | 10 Personalized Fitment treatment IDs |
| `configs/static_treatments.csv` | 22 Static treatment IDs |
| `docs/campaign_reports_2025_12_10.md` | Post-purchase email campaign analysis |
| `docs/pipeline_run_stats.md` | Pipeline run history & comparison stats |
| `src/bandit_click_holley.py` | Email treatment Click Bandit analysis |
| `flows/metaflow_runner.py` | K8s script runner via Metaflow |
| `flows/run.sh` | Run scripts on K8s |
| `flows/README.md` | Metaflow setup instructions |

## Commands
```bash
# Validate SQL
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_6_*.sql

# Run pipeline
bq query --use_legacy_sql=false < sql/recommendations/v5_6_*.sql

# Run QA checks
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql

# Run Python script on K8s (via Metaflow)
./flows/run.sh src/bandit_click_holley.py

# Python
make test && make lint
```

## Critical Rules
- Never hardcode project IDs (use configs/)
- Always COALESCE(string_value, long_value) for event properties
- Run qa_checks.sql after any pipeline change
- Max 2 SKUs per PartType (diversity filter)
- Variant dedup: Single-char color suffixes (B, R, G, P) are deduplicated
- Sep 1, 2025 is fixed boundary between historical/recent data - don't change

## Docs (read before coding)
- `@agent_docs/architecture.md` - Pipeline, scoring formula
- `@agent_docs/bigquery.md` - Event bugs, SQL patterns
