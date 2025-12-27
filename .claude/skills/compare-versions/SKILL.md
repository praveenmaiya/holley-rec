---
name: compare-versions
description: Compare two pipeline versions. Use when validating a new version against baseline.
allowed-tools: Bash, Read, Glob
---

# Version Comparison Skill

Compares recommendation outputs between pipeline versions.

## When to Use
- After implementing a new version
- Before deploying to production
- Debugging unexpected changes
- Validating bug fixes

## Process

### Step 1: Get Baseline Stats (Production)

```bash
bq query --use_legacy_sql=false "
SELECT
  'production' as version,
  COUNT(*) as total_users,
  COUNT(DISTINCT email_lower) as unique_emails,
  ROUND(AVG(rec1_score), 2) as avg_score,
  ROUND(MIN(rec1_price), 2) as min_price,
  ROUND(MAX(rec1_price), 2) as max_price,
  COUNTIF(rec1_image LIKE 'https://%') * 100.0 / COUNT(*) as https_pct
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
"
```

### Step 2: Get New Version Stats

```bash
bq query --use_legacy_sql=false "
SELECT
  'staging' as version,
  COUNT(*) as total_users,
  COUNT(DISTINCT email_lower) as unique_emails,
  ROUND(AVG(rec1_score), 2) as avg_score,
  ROUND(MIN(rec1_price), 2) as min_price,
  ROUND(MAX(rec1_price), 2) as max_price,
  COUNTIF(rec1_image LIKE 'https://%') * 100.0 / COUNT(*) as https_pct
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
"
```

### Step 3: Compare Recommendations (User-Level)

```bash
bq query --use_legacy_sql=false "
WITH old AS (
  SELECT email_lower, rec_part_1, rec_part_2, rec_part_3, rec_part_4,
         rec1_score, rec2_score, rec3_score, rec4_score
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
),
new AS (
  SELECT email_lower, rec_part_1, rec_part_2, rec_part_3, rec_part_4,
         rec1_score, rec2_score, rec3_score, rec4_score
  FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
)
SELECT
  COUNT(*) as users_in_both,
  COUNTIF(o.rec_part_1 = n.rec_part_1) as same_rec1,
  COUNTIF(o.rec_part_1 != n.rec_part_1) as diff_rec1,
  COUNTIF(o.rec_part_2 != n.rec_part_2) as diff_rec2,
  COUNTIF(o.rec_part_3 != n.rec_part_3) as diff_rec3,
  COUNTIF(o.rec_part_4 != n.rec_part_4) as diff_rec4,
  ROUND(100.0 * COUNTIF(o.rec_part_1 = n.rec_part_1) / COUNT(*), 2) as pct_same_rec1
FROM old o
JOIN new n ON o.email_lower = n.email_lower
"
```

### Step 4: Investigate Differences

If differences found, dig deeper:

```bash
# Sample users with different rec1
bq query --use_legacy_sql=false "
WITH old AS (
  SELECT email_lower, rec_part_1 as old_rec1, rec1_score as old_score
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
),
new AS (
  SELECT email_lower, rec_part_1 as new_rec1, rec1_score as new_score
  FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
)
SELECT
  o.email_lower,
  o.old_rec1, o.old_score,
  n.new_rec1, n.new_score
FROM old o
JOIN new n ON o.email_lower = n.email_lower
WHERE o.old_rec1 != n.new_rec1
LIMIT 20
"
```

## Output Format

| Metric | Old | New | Change |
|--------|-----|-----|--------|
| Users | X | Y | +/- N |
| Same rec1 | - | - | X% |
| Diff rec1 | - | - | N users |
| Avg score | X | Y | +/- Z |

## Interpretation Guide

- **>99% same rec1**: Minor change, likely edge cases
- **95-99% same**: Significant but expected for bug fixes
- **<95% same**: Major change, investigate thoroughly
- **User count diff**: Check audience filtering logic

## Related Files
- `docs/pipeline_run_stats.md` - Historical comparisons
- `docs/release_notes.md` - Version change documentation
