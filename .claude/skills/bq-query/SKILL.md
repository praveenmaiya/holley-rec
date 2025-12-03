---
name: bq-query
description: Execute BigQuery SQL queries using bq CLI. Use when user asks to run SQL, query data, extract features, or interact with BigQuery tables.
allowed-tools: Bash, Read, Glob
---

# BigQuery Query Skill

## When to Use
- Running SQL queries against BigQuery
- Extracting data for analysis
- Creating or updating tables
- Validating SQL syntax

## Commands

### Run a query from file
```bash
bq query --use_legacy_sql=false --format=prettyjson < sql/recommendations/extract/query.sql
```

### Run with parameters
```bash
bq query --use_legacy_sql=false \
  --parameter='start_date:DATE:2024-01-01' \
  --parameter='end_date:DATE:2024-01-02' \
  < sql/recommendations/extract/users.sql
```

### Dry run (estimate cost, validate syntax)
```bash
bq query --dry_run --use_legacy_sql=false < sql/recommendations/extract/query.sql
```

### Run inline query
```bash
bq query --use_legacy_sql=false "SELECT COUNT(*) FROM \`project.dataset.table\`"
```

## Conventions
- SQL files are in `sql/recommendations/` organized by ETL stage
- Always use `--use_legacy_sql=false` (standard SQL)
- Check `agent_docs/bigquery_patterns.md` for naming conventions
- Use `--dry_run` first for large queries to estimate cost

## Test Mode
For development, limit results:
```bash
bq query --use_legacy_sql=false --max_rows=1000 < query.sql
```
