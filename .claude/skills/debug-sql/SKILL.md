---
name: debug-sql
description: Debug SQL errors and unexpected results. Use when pipeline fails or produces wrong data.
allowed-tools: Bash, Read, Glob, Grep
---

# SQL Debugger Skill

Diagnoses and fixes SQL issues in the recommendation pipeline.

## When to Use
- Pipeline throws an error
- Results look wrong (missing users, bad scores, duplicates)
- Query is slow or expensive

## Process

### Step 1: Identify the Error
- Read the error message carefully
- Check which CTE/step failed

### Step 2: Check Known Gotchas

| Error Pattern | Likely Cause | Fix |
|---------------|--------------|-----|
| "Column not found" | Case sensitivity (ProductId vs ProductID) | Check exact column name |
| "Division by zero" | Missing NULLIF or SAFE_DIVIDE | Use SAFE_DIVIDE() |
| "Invalid regex" | BigQuery regex syntax | Use [0-9] not \d |
| "Bytes exceeded" | Missing partition filter | Add date filter early |
| "Duplicate rows" | Missing DISTINCT or GROUP BY | Add dedup logic |
| "No matching signature" | Type mismatch | Check COALESCE(string_value, long_value) |
| "Resources exceeded" | Query too complex | Break into smaller CTEs |

### Step 3: Isolate the Failing CTE

Run CTEs incrementally to find which step fails:

```bash
# Test step 0 - users with vehicles
bq query --use_legacy_sql=false "
WITH users_with_v1_vehicles AS (
  SELECT DISTINCT
    LOWER(email) as email_lower,
    v1_year, v1_make, v1_model
  FROM \`auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental\`
  WHERE email IS NOT NULL
    AND v1_year IS NOT NULL
    AND v1_make IS NOT NULL
    AND v1_model IS NOT NULL
  LIMIT 100
)
SELECT COUNT(*) as user_count FROM users_with_v1_vehicles
"

# Test step 1 - eligible parts
bq query --use_legacy_sql=false "
-- Run eligible_parts CTE and count
SELECT COUNT(*) FROM ... LIMIT 1
"
```

### Step 4: Common Fixes

**Case 1: Empty results**
```sql
-- Check if source tables have data
SELECT COUNT(*) FROM `source_table` WHERE date_filter
```

**Case 2: Too many rows (explosion)**
```sql
-- Check for missing join keys causing cross join
SELECT COUNT(*) as row_count, COUNT(DISTINCT key) as key_count FROM table
```

**Case 3: Wrong values**
```sql
-- Sample data to inspect
SELECT * FROM intermediate_cte LIMIT 10
```

### Step 5: Verify Fix

Always dry-run before full execution:
```bash
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_17_*.sql
```

Then run QA checks after:
```bash
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

## Related Files
- `agent_docs/bigquery.md` - Known gotchas and patterns
- `sql/recommendations/v5_17_vehicle_fitment_recommendations.sql` - Pipeline
- `sql/validation/qa_checks.sql` - Validation suite
