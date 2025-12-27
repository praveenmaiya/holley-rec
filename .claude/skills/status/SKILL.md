---
name: status
description: Show current pipeline and deployment status. Use for quick health check.
allowed-tools: Bash, Read, Glob
---

# Status Skill

Quick overview of pipeline health, staging vs production state, and recent activity.

## When to Use

- Start of work session
- Before running pipeline
- After deployment to verify
- Debugging unexpected behavior

## Process

### Step 1: Production Status

Check current production state:

```bash
echo "📦 PRODUCTION STATUS"
echo "────────────────────"
bq query --use_legacy_sql=false "
SELECT
  pipeline_version,
  COUNT(*) as total_users,
  ROUND(AVG(rec1_score), 2) as avg_score,
  ROUND(MIN(rec1_price), 2) as min_price,
  ROUND(MAX(rec1_price), 2) as max_price,
  COUNTIF(rec1_image LIKE 'https://%') * 100.0 / COUNT(*) as https_pct
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

### Step 2: Staging Status

Check staging state:

```bash
echo ""
echo "🔧 STAGING STATUS"
echo "─────────────────"
bq query --use_legacy_sql=false "
SELECT
  pipeline_version,
  COUNT(*) as total_users,
  ROUND(AVG(rec1_score), 2) as avg_score,
  ROUND(MIN(rec1_price), 2) as min_price,
  ROUND(MAX(rec1_price), 2) as max_price
FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
GROUP BY pipeline_version
" 2>/dev/null || echo "No staging data found"
```

### Step 3: Staging vs Production Diff

```bash
echo ""
echo "📊 STAGING vs PRODUCTION"
echo "────────────────────────"
bq query --use_legacy_sql=false "
WITH staging AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as score
  FROM \`auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations\`
),
prod AS (
  SELECT COUNT(*) as users, ROUND(AVG(rec1_score), 2) as score
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
)
SELECT
  s.users as staging_users,
  p.users as prod_users,
  s.users - p.users as user_diff,
  s.score as staging_score,
  p.score as prod_score
FROM staging s, prod p
" 2>/dev/null || echo "Cannot compare - staging may not exist"
```

### Step 4: Recent Treatment Activity

```bash
echo ""
echo "📧 RECENT TREATMENT ACTIVITY (7 days)"
echo "──────────────────────────────────────"
bq query --use_legacy_sql=false "
SELECT
  COUNT(DISTINCT CASE WHEN interaction_type = 'VIEWED' THEN user_id END) as views,
  COUNT(DISTINCT CASE WHEN interaction_type = 'CLICKED' THEN user_id END) as clicks,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN interaction_type = 'CLICKED' THEN user_id END),
    COUNT(DISTINCT CASE WHEN interaction_type = 'VIEWED' THEN user_id END)
  ) * 100, 2) as ctr_pct
FROM \`auxia-gcp.company_1950.treatment_interaction\`
WHERE DATE(TIMESTAMP_MICROS(interaction_timestamp_micros)) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
"
```

### Step 5: Local Git Status

```bash
echo ""
echo "📁 LOCAL CHANGES"
echo "────────────────"
git status --short
```

### Step 6: Recent Decisions

```bash
echo ""
echo "📝 RECENT DECISIONS"
echo "───────────────────"
tail -20 docs/decisions.md | head -15
```

## Output Format

```
📦 PRODUCTION STATUS
────────────────────
Version: v5.7
Users: 450,123
Avg Score: 45.23
Price Range: $50.00 - $9,500.00
HTTPS: 100%

🔧 STAGING STATUS
─────────────────
Version: v5.7
Users: 450,456
Avg Score: 45.31

📊 STAGING vs PRODUCTION
────────────────────────
User Diff: +333
Score Diff: +0.08

📧 RECENT TREATMENT ACTIVITY (7 days)
──────────────────────────────────────
Views: 125,432
Clicks: 3,210
CTR: 2.56%

📁 LOCAL CHANGES
────────────────
M sql/recommendations/v5_7_*.sql

📝 RECENT DECISIONS
───────────────────
### 2024-12-21: Variant Dedup Regex Fix
...
```

## Quick Health Check

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| Users | ~450K | 400-500K | <400K or >500K |
| Avg Score | 40-50 | 30-60 | <30 or >60 |
| HTTPS | 100% | >99% | <99% |
| CTR | >2% | 1-2% | <1% |

## Related Skills
- `/validate` - Full QA checks
- `/compare-versions` - Detailed comparison
- `/analyze-ctr` - Deep CTR analysis
