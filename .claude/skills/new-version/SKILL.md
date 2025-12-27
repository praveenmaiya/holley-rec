---
name: new-version
description: Create a new pipeline version end-to-end. Use when starting a new feature or major change.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# New Version Workflow

Automates the full pipeline version lifecycle from spec to validation.

## Workflow Diagram

```
┌──────────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐   ┌─────────┐
│  1. Spec │──▶│ 2. Implement│──▶│ 3. Test  │──▶│ 4. Validate│──▶│ 5. Compare│
│  Create  │   │   SQL     │   │  Dry-run │   │   QA     │   │  Diff   │
└──────────┘   └───────────┘   └──────────┘   └──────────┘   └─────────┘
```

## Arguments

- `version`: Version number (e.g., "5.8")
- `description`: Brief description of changes

## Process

### Step 1: Create Spec

First, ask user for:
- What changes are being made?
- Why is this change needed?
- Expected impact on recommendations?

Create spec file:

```bash
# Check existing spec as template
cat specs/v5_6_recommendations.md
```

Create new spec at `specs/v{version}_recommendations.md` with:
- Problem statement
- Proposed solution
- Data changes
- Validation criteria
- Rollback plan

### Step 2: Implement SQL

Copy and modify pipeline:

```bash
# Copy existing pipeline as base
cp sql/recommendations/v5_7_vehicle_fitment_recommendations.sql \
   sql/recommendations/v{version}_vehicle_fitment_recommendations.sql
```

Update in new file:
- `pipeline_version` declaration
- `target_dataset` to new version dataset
- Apply the changes from spec

### Step 3: Test (Dry Run)

Validate SQL syntax:

```bash
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v{version}_*.sql
```

**Must pass before proceeding.**

### Step 4: Run Pipeline

Execute the pipeline:

```bash
bq query --use_legacy_sql=false < sql/recommendations/v{version}_*.sql
```

Verify output table created:

```bash
bq query --use_legacy_sql=false "
SELECT COUNT(*) as users, pipeline_version
FROM \`auxia-reporting.temp_holley_v{version}.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

### Step 5: Validate (QA Checks)

Run full validation suite:

```bash
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

**All checks must pass:**
- User count ~450K
- No duplicates
- Prices $50-$10K
- HTTPS images
- Score ordering valid

### Step 6: Compare with Production

```bash
bq query --use_legacy_sql=false "
WITH new AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as avg_score
  FROM \`auxia-reporting.temp_holley_v{version}.final_vehicle_recommendations\`
),
prod AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as avg_score
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
)
SELECT 'new' as version, * FROM new
UNION ALL
SELECT 'prod' as version, * FROM prod
"
```

Compare recommendation overlap:

```bash
bq query --use_legacy_sql=false "
WITH new AS (
  SELECT email_lower, rec_part_1, rec_part_2
  FROM \`auxia-reporting.temp_holley_v{version}.final_vehicle_recommendations\`
),
prod AS (
  SELECT email_lower, rec_part_1, rec_part_2
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
)
SELECT
  COUNT(*) as users_in_both,
  ROUND(100.0 * COUNTIF(n.rec_part_1 = p.rec_part_1) / COUNT(*), 2) as pct_same_rec1
FROM new n
JOIN prod p ON n.email_lower = p.email_lower
"
```

### Step 7: Document

Update documentation:
1. Add entry to `docs/decisions.md` with changes
2. Update `docs/release_notes.md` with version
3. Update `STATUS_LOG.md`

### Step 8: Ready for Deploy

Present summary to user:
- User count comparison
- Score comparison
- Recommendation overlap %
- QA status

Ask: "Ready to proceed with `/deploy`?"

## Checkpoints

At each step, verify success before proceeding:

| Step | Success Criteria |
|------|------------------|
| Spec | User approved |
| Implement | File created |
| Dry-run | No syntax errors |
| Run | Table created with data |
| Validate | All QA checks pass |
| Compare | <5% user count diff |

## Rollback

If issues found:
1. Do NOT deploy
2. Document issue in `docs/known_issues.md`
3. Fix and re-run from Step 2

## Related Skills
- `/deploy` - Deploy to production
- `/validate` - Run QA checks
- `/compare-versions` - Detailed comparison
