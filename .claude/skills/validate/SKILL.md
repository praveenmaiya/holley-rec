---
name: validate
description: Run QA validation checks on the recommendation pipeline output. Use after pipeline runs to verify data quality.
allowed-tools: Bash, Read, Glob
---

# Validation Skill

Runs comprehensive QA checks on pipeline output.

## When to Use
- After running v5.7 pipeline
- Before deploying to production
- When debugging data quality issues
- As part of code review

## Process

### Step 1: Run QA Checks

```bash
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

### Step 2: Parse Results

Expected passing results:
| Check | Expected | Status |
|-------|----------|--------|
| User count | ~450,000 | ✓/✗ |
| Duplicates | 0 | ✓/✗ |
| Refurbished items | 0 | ✓/✗ |
| Service SKUs | 0 | ✓/✗ |
| Min price | ≥ $50 | ✓/✗ |
| Max price | ≤ $10,000 | ✓/✗ |
| HTTPS images | 100% | ✓/✗ |
| Score ordering | Valid | ✓/✗ |
| Diversity (max 2/PartType) | Valid | ✓/✗ |

### Step 3: Report Issues

If any check fails:
1. Identify the failing check
2. Query for specific violations
3. Trace back to pipeline step
4. Suggest fix

## Quick Debug Queries

```bash
# Find duplicate SKUs
bq query --use_legacy_sql=false "
SELECT email_lower, rec_part_1, rec_part_2, rec_part_3, rec_part_4
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
WHERE rec_part_1 IN (rec_part_2, rec_part_3, rec_part_4)
   OR rec_part_2 IN (rec_part_3, rec_part_4)
   OR rec_part_3 = rec_part_4
LIMIT 10
"

# Find low-price items
bq query --use_legacy_sql=false "
SELECT email_lower, rec_part_1, rec1_price
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
WHERE rec1_price < 50
LIMIT 10
"

# Check score ordering
bq query --use_legacy_sql=false "
SELECT email_lower, rec1_score, rec2_score, rec3_score, rec4_score
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
WHERE rec1_score < rec2_score
   OR rec2_score < rec3_score
   OR rec3_score < rec4_score
LIMIT 10
"

# Check HTTPS images
bq query --use_legacy_sql=false "
SELECT email_lower, rec1_image
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
WHERE rec1_image NOT LIKE 'https://%'
LIMIT 10
"
```

## Related Files
- `sql/validation/qa_checks.sql` - Full validation suite
- `docs/pipeline_run_stats.md` - Historical comparison
