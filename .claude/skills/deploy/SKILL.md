---
name: deploy
description: Deploy recommendations to production with full validation. Use after pipeline runs and QA passes.
allowed-tools: Bash, Read, Glob, AskUserQuestion
---

# Deploy Skill

Deploys vehicle fitment recommendations from staging to production with comprehensive validation.

## When to Use
- After running v5.17 pipeline successfully
- After QA checks pass
- When ready to push new recommendations live

## Deployment Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Dry Run    │───▶│  QA Checks  │───▶│   Confirm   │───▶│   Deploy    │
│  Validate   │    │  Validate   │    │  With User  │    │  To Prod    │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
      │                  │                   │                  │
      ▼                  ▼                   ▼                  ▼
   Syntax OK?        All pass?          Approved?         Success?
```

## Process

### Step 1: Pre-flight Checks

Verify staging table exists and has data:

```bash
bq query --use_legacy_sql=false "
SELECT
  COUNT(*) as total_users,
  COUNT(DISTINCT email_lower) as unique_emails,
  MIN(rec1_price) as min_price,
  MAX(rec1_price) as max_price,
  pipeline_version
FROM \`auxia-reporting.temp_holley_v5_17.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

Expected: ~450K users, prices $50-$10K, pipeline_version present.

### Step 2: Run Full QA Suite

```bash
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

**All checks must pass:**
| Check | Requirement |
|-------|-------------|
| User count | ~450,000 |
| Duplicates | 0 |
| Refurbished items | 0 |
| Service SKUs | 0 |
| Min price | >= $50 |
| Max price | <= $10,000 |
| HTTPS images | 100% |
| Score ordering | Valid |
| Diversity | Max 2/PartType |

### Step 3: Compare with Current Production

```bash
bq query --use_legacy_sql=false "
WITH staging AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as avg_score
  FROM \`auxia-reporting.temp_holley_v5_17.final_vehicle_recommendations\`
),
prod AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as avg_score
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
)
SELECT
  'staging' as env, s.users, s.avg_score FROM staging s
UNION ALL
SELECT
  'production' as env, p.users, p.avg_score FROM prod p
"
```

### Step 4: User Confirmation

**CRITICAL: Always ask for user confirmation before deploying.**

Present:
- User count comparison (staging vs prod)
- Score comparison
- Any notable differences
- Ask: "Ready to deploy to production?"

### Step 5: Deploy to Production

```bash
bq query --use_legacy_sql=false "
CREATE OR REPLACE TABLE \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\` AS
SELECT * FROM \`auxia-reporting.temp_holley_v5_17.final_vehicle_recommendations\`
"
```

### Step 6: Post-Deploy Verification

```bash
bq query --use_legacy_sql=false "
SELECT
  COUNT(*) as total_users,
  pipeline_version,
  MIN(rec1_price) as min_price,
  MAX(rec1_price) as max_price
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

### Step 7: Update Documentation

After successful deploy:
1. Update `docs/pipeline_run_stats.md` with deployment stats
2. Add entry to `docs/decisions.md` if significant changes
3. Update `STATUS_LOG.md` with deployment entry

## Rollback Procedure

If issues discovered post-deploy:

```bash
# Check if backup exists
bq ls auxia-reporting.company_1950_jp

# Restore from backup (if available)
bq query --use_legacy_sql=false "
CREATE OR REPLACE TABLE \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\` AS
SELECT * FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations_backup\`
"
```

## Safety Checks

**NEVER deploy if:**
- QA checks fail
- User count differs by >5% from production
- User has not confirmed
- Staging table is empty or missing

## Related Files
- `sql/validation/qa_checks.sql` - Validation suite
- `docs/pipeline_run_stats.md` - Deployment history
- `docs/release_notes.md` - Version changes
- `STATUS_LOG.md` - Deployment log
