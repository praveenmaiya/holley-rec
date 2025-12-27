---
name: full-deploy
description: End-to-end deployment workflow. Runs pipeline, validates, compares, and deploys in one flow.
allowed-tools: Bash, Read, Glob, AskUserQuestion
---

# Full Deploy Workflow

Complete deployment pipeline from execution to production in a single automated flow.

## Workflow Diagram

```
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│ 1. Run   │──▶│ 2. Verify │──▶│ 3. QA    │──▶│ 4. Compare│──▶│ 5. Confirm│──▶│ 6. Deploy │
│ Pipeline │   │  Output  │   │  Checks  │   │  Versions│   │  User    │   │  Prod    │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
      │              │              │              │              │              │
      ▼              ▼              ▼              ▼              ▼              ▼
   Success?      Has data?      All pass?     <5% diff?      Approved?     Verify!
```

## When to Use

- Weekly recommendation refresh
- After pipeline changes validated in staging
- Scheduled production updates

## Process

### Step 1: Run Pipeline

Execute v5.7 pipeline:

```bash
echo "🚀 Running pipeline..."
bq query --use_legacy_sql=false < sql/recommendations/v5_7_vehicle_fitment_recommendations.sql
```

### Step 2: Verify Output

Check table was created with expected data:

```bash
bq query --use_legacy_sql=false "
SELECT
  'staging' as env,
  COUNT(*) as total_users,
  COUNT(DISTINCT email_lower) as unique_emails,
  pipeline_version,
  MIN(rec1_price) as min_price,
  MAX(rec1_price) as max_price,
  ROUND(AVG(rec1_score), 2) as avg_score
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

**Expected:**
- ~450,000 users
- pipeline_version = 'v5.7'
- min_price >= $50
- max_price <= $10,000

**STOP if:** User count is 0 or significantly different from expected.

### Step 3: Run QA Checks

Full validation suite:

```bash
echo "🔍 Running QA checks..."
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

Parse results and verify:

| Check | Requirement | Action if Fail |
|-------|-------------|----------------|
| User count | ~450K | Investigate data |
| Duplicates | 0 | Fix dedup logic |
| Refurbished | 0 | Check filter |
| Service SKUs | 0 | Check prefix filter |
| Min price | >= $50 | Fix sku_prices |
| HTTPS images | 100% | Fix URL replace |
| Score order | Valid | Fix scoring |

**STOP if:** Any check fails. Do not proceed to deployment.

### Step 4: Compare with Production

Side-by-side comparison:

```bash
echo "📊 Comparing with production..."
bq query --use_legacy_sql=false "
WITH staging AS (
  SELECT
    COUNT(*) as users,
    ROUND(AVG(rec1_score), 2) as avg_score,
    ROUND(AVG(rec1_price), 2) as avg_price
  FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
),
prod AS (
  SELECT
    COUNT(*) as users,
    ROUND(AVG(rec1_score), 2) as avg_score,
    ROUND(AVG(rec1_price), 2) as avg_price
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
)
SELECT 'staging' as env, s.* FROM staging s
UNION ALL
SELECT 'production' as env, p.* FROM prod p
"
```

Recommendation overlap:

```bash
bq query --use_legacy_sql=false "
WITH s AS (SELECT email_lower, rec_part_1 FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`),
p AS (SELECT email_lower, rec_part_1 FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`)
SELECT
  ROUND(100.0 * COUNTIF(s.rec_part_1 = p.rec_part_1) / COUNT(*), 2) as pct_same_rec1
FROM s JOIN p ON s.email_lower = p.email_lower
"
```

### Step 5: User Confirmation

**CRITICAL: Always ask user before deploying.**

Present summary:
```
📋 Deployment Summary
─────────────────────
Staging Users:  XXX,XXX
Prod Users:     XXX,XXX
User Diff:      +/- X%

Avg Score:      XX.XX (staging) vs XX.XX (prod)
Rec1 Overlap:   XX.XX%

QA Status:      ✅ All checks passed
```

Ask: "Deploy staging to production? (yes/no)"

**STOP if:** User does not confirm.

### Step 6: Deploy to Production

```bash
echo "🚀 Deploying to production..."
bq query --use_legacy_sql=false "
CREATE OR REPLACE TABLE \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\` AS
SELECT * FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
"
```

### Step 7: Post-Deploy Verification

Verify production table:

```bash
echo "✅ Verifying deployment..."
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

### Step 8: Update Documentation

After successful deploy:

```bash
# Log deployment
echo "$(date '+%Y-%m-%d %H:%M'): Deployed v5.7 to production" >> STATUS_LOG.md
```

Update `docs/pipeline_run_stats.md` with:
- Deployment timestamp
- User count
- Any notable changes

## Abort Conditions

**Immediately stop workflow if:**

| Condition | Action |
|-----------|--------|
| Pipeline fails | Debug with `/debug-sql` |
| QA checks fail | Fix issue, re-run |
| User count diff >5% | Investigate before proceeding |
| User declines | Abort, no changes to prod |

## Timing

Typical execution time:
- Pipeline run: 2-5 minutes
- QA checks: 30 seconds
- Comparison: 30 seconds
- Deployment: 1 minute
- **Total: ~5-7 minutes**

## Related Skills
- `/run-pipeline` - Just run pipeline (no deploy)
- `/validate` - Just QA checks
- `/deploy` - Just deploy (assumes QA passed)
- `/compare-versions` - Detailed comparison
