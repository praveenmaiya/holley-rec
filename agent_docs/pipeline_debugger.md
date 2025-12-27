# Pipeline Debugger Agent Guide

Instructions for subagents debugging the recommendation pipeline.

## Debugging Workflow

```
1. READ THE ERROR → What step failed?
2. CHECK GOTCHAS → Is this a known issue?
3. ISOLATE THE CTE → Run incrementally
4. VERIFY DATA → Check row counts, sample data
5. FIX AND VERIFY → Dry-run, then QA checks
```

---

## Common Failure Points

| Step | Common Issue | Debug Query |
|------|--------------|-------------|
| **Step 0** (users) | Missing vehicle data | `SELECT COUNT(*) FROM users_with_v1_vehicles` |
| **Step 1** (fitment) | No matching SKUs | `SELECT COUNT(*) FROM eligible_parts` |
| **Step 2** (scoring) | All zeros | `SELECT COUNT(*) FROM dedup_intent WHERE intent_score > 0` |
| **Step 3** (selection) | Duplicates | `SELECT COUNT(*) FROM diversity_filtered` |

---

## Error Pattern → Solution

### "Column not found"
**Cause**: Case sensitivity
**Check**:
- Cart events: `ProductId` (lowercase d)
- Order events: `ProductID` (uppercase D)

### "Division by zero"
**Cause**: Missing SAFE_DIVIDE
**Fix**: Replace `a/b` with `SAFE_DIVIDE(a, b)`

### "Invalid regex"
**Cause**: BigQuery regex syntax differs
**Fix**: Use `[0-9]` instead of `\d`

### "Bytes billing tier exceeded"
**Cause**: Missing partition filter
**Fix**: Add DATE filter early in query, use string LIKE for ORDER_DATE

### "Resources exceeded"
**Cause**: Query too complex, cross join, or data explosion
**Check**:
```sql
-- Look for unexpected row counts
SELECT 'users' as step, COUNT(*) FROM users_cte
UNION ALL
SELECT 'joined' as step, COUNT(*) FROM joined_cte
-- Explosion = joined >> users
```

### "Empty results"
**Cause**: Filter too restrictive or data missing
**Check**:
```sql
-- Verify source data exists
SELECT COUNT(*) FROM source_table WHERE your_filter
```

---

## Incremental CTE Testing

Run each CTE independently to find failure point:

```bash
# Test Step 0 - Users with vehicles
bq query --use_legacy_sql=false "
WITH users_with_v1_vehicles AS (
  SELECT DISTINCT
    LOWER(email) as email_lower,
    v1_year, v1_make, v1_model
  FROM \`auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental\`
  WHERE email IS NOT NULL
    AND v1_year IS NOT NULL
  LIMIT 100
)
SELECT COUNT(*) as row_count FROM users_with_v1_vehicles
"
```

```bash
# Test Step 1 - Eligible parts (add previous CTEs)
bq query --use_legacy_sql=false "
WITH users_with_v1_vehicles AS (...),
eligible_parts AS (
  SELECT *
  FROM \`auxia-gcp.data_company_1950.vehicle_product_fitment_data\`
  WHERE year = '2020' AND make = 'Ford' AND model = 'Mustang'
  LIMIT 100
)
SELECT COUNT(*) as row_count FROM eligible_parts
"
```

---

## Data Verification Queries

### Check user counts
```sql
SELECT
  'attributes' as source,
  COUNT(DISTINCT user_id) as users,
  COUNT(*) as rows
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
WHERE DATE(event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
```

### Check event data
```sql
SELECT
  event_type,
  COUNT(*) as count,
  COUNT(DISTINCT user_id) as users
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
WHERE DATE(event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
GROUP BY event_type
ORDER BY count DESC
```

### Check fitment coverage
```sql
SELECT
  COUNT(DISTINCT CONCAT(year, make, model)) as vehicle_count,
  COUNT(DISTINCT sku) as sku_count
FROM `auxia-gcp.data_company_1950.vehicle_product_fitment_data`
```

---

## Post-Fix Verification

After any fix:

1. **Dry run** to check syntax:
```bash
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_7_*.sql
```

2. **Run QA checks**:
```bash
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

3. **Compare with baseline** (if applicable):
```bash
# Use /compare-versions skill
```

---

## Reference Files

- `sql/recommendations/v5_7_vehicle_fitment_recommendations.sql` - Full pipeline
- `sql/validation/qa_checks.sql` - Validation suite
- `agent_docs/bigquery.md` - SQL patterns and gotchas
- `docs/known_issues.md` - Known issues and workarounds
