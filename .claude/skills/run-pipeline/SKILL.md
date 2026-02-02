---
name: run-pipeline
description: Execute the v5.17 vehicle fitment recommendation pipeline. Use when user asks to run the pipeline, refresh recommendations, or generate new recs.
allowed-tools: Bash, Read, Glob
---

# Run Pipeline Skill

Execute the Holley v5.17 vehicle fitment recommendation pipeline.

## When to Use

- User asks to "run the pipeline" or "refresh recommendations"
- Daily scheduled recommendation refresh
- After making changes to the SQL pipeline
- Before deploying new recommendations to production

## Pipeline Overview

```
Step 0: Users with V1 vehicles (~500K users)
Step 1: Fitment pipeline (eligibility filters)
Step 2: Scoring (intent + popularity)
Step 3: Recommendations (exclusion + dedup + diversity + top 4)
Step 4: Production deployment + timestamped backup
```

## Commands

### 1. Dry Run (Validate Syntax + Estimate Cost)

```bash
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_17_vehicle_fitment_recommendations.sql
```

### 2. Execute Pipeline

```bash
bq query --use_legacy_sql=false < sql/recommendations/v5_17_vehicle_fitment_recommendations.sql
```

Expected runtime: ~5-7 minutes

### 3. Quick Validation After Run

```bash
bq query --use_legacy_sql=false "
SELECT
  COUNT(*) as users,
  ROUND(AVG(rec1_price), 2) as avg_rec1_price,
  ROUND((AVG(rec1_price) + AVG(rec2_price) + AVG(rec3_price) + AVG(rec4_price)) / 4, 2) as avg_all_prices,
  MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)) as min_price,
  MAX(generated_at) as generated_at
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
"
```

## Expected Metrics

| Metric | Expected Value | Action if Failed |
|--------|----------------|------------------|
| Users | ≥450,000 | Check user attributes table |
| Min price | ≥$50 | Verify min_price filter |
| Avg price | $300-500 | Review commodity filters |
| Duplicates | 0 | Check variant dedup regex |
| HTTPS images | 100% | Check image URL normalization |

## Intermediate Tables

Pipeline creates these tables in `auxia-reporting.temp_holley_v5_17`:

| Table | Purpose |
|-------|---------|
| `users_with_v1_vehicles` | Users with email + vehicle |
| `staged_events` | Intent events (Sep 1 to today) |
| `sku_prices` | Max price per SKU |
| `sku_image_urls` | HTTPS images per SKU |
| `eligible_parts` | Filtered fitment data |
| `dedup_intent` | Intent scores per user/SKU |
| `sku_popularity_324d` | Popularity scores |
| `user_purchased_parts_365d` | Purchase exclusion |
| `scored_recommendations` | All scored candidates |
| `diversity_filtered` | After variant dedup + diversity |
| `ranked_recommendations` | Top 4 per user |
| `final_vehicle_recommendations` | Final output (wide format) |

## Production Tables

| Table | Purpose |
|-------|---------|
| `auxia-reporting.company_1950_jp.final_vehicle_recommendations` | Live production |
| `auxia-reporting.company_1950_jp.final_vehicle_recommendations_YYYY_MM_DD` | Daily backup |

## Troubleshooting

### Low user count (<450K)

```bash
# Check users_with_v1_vehicles
bq query --use_legacy_sql=false "
SELECT COUNT(*) as users
FROM \`auxia-reporting.temp_holley_v5_17.users_with_v1_vehicles\`
"
```

### Price issues

```bash
# Check price distribution
bq query --use_legacy_sql=false "
SELECT
  COUNTIF(price < 50) as below_50,
  COUNTIF(price >= 50 AND price < 100) as p50_100,
  COUNTIF(price >= 100 AND price < 250) as p100_250,
  COUNTIF(price >= 250) as above_250
FROM \`auxia-reporting.temp_holley_v5_17.eligible_parts\`
"
```

### Duplicate SKU issues

```bash
# Check for variant duplicates
bq query --use_legacy_sql=false "
SELECT email_lower, rec_part_1, rec_part_2, rec_part_3, rec_part_4
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
WHERE rec_part_1 = rec_part_2 OR rec_part_1 = rec_part_3 OR rec_part_1 = rec_part_4
   OR rec_part_2 = rec_part_3 OR rec_part_2 = rec_part_4 OR rec_part_3 = rec_part_4
LIMIT 10
"
```

## Auto-Verification (REQUIRED)

**IMPORTANT**: After every pipeline execution, AUTOMATICALLY run these validation checks before reporting success:

### Step 1: Quick Stats Check
```bash
bq query --use_legacy_sql=false "
SELECT
  COUNT(*) as users,
  ROUND(MIN(LEAST(rec1_price, rec2_price, rec3_price, rec4_price)), 2) as min_price,
  ROUND(MAX(GREATEST(rec1_price, rec2_price, rec3_price, rec4_price)), 2) as max_price,
  COUNTIF(rec1_image NOT LIKE 'https://%') as non_https_images,
  pipeline_version
FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
GROUP BY pipeline_version
"
```

### Step 2: Duplicate Check
```bash
bq query --use_legacy_sql=false "
SELECT COUNT(*) as duplicate_users
FROM (
  SELECT email_lower
  FROM \`auxia-reporting.company_1950_jp.final_vehicle_recommendations\`
  GROUP BY email_lower
  HAVING COUNT(*) > 1
)
"
```

### Step 3: Interpret Results

| Check | Pass Criteria | If Failed |
|-------|---------------|-----------|
| Users | ≥450,000 | STOP - investigate user attributes |
| Min Price | ≥$50 | STOP - check price filter |
| Max Price | ≤$10,000 | WARN - review outliers |
| Non-HTTPS | 0 | STOP - fix image URLs |
| Duplicates | 0 | STOP - check dedup logic |

### Step 4: Report Status

After verification, report:
```
✅ Pipeline run successful
- Users: XXX,XXX
- Price range: $XX - $X,XXX
- HTTPS: 100%
- Duplicates: 0
- Version: vX.X
```

Or if failed:
```
❌ Pipeline run FAILED validation
- Issue: <specific failure>
- Action: <recommended fix>
```

## Post-Run Checklist

After running the pipeline:

1. Verify user count ≥450K
2. Verify min price ≥$50
3. Run `sql/validation/qa_checks.sql` for full validation
4. Update `STATUS_LOG.md` with run results
5. Update `docs/pipeline_run_stats.md` if significant changes

## Related Files

- SQL: `sql/recommendations/v5_17_vehicle_fitment_recommendations.sql`
- QA: `sql/validation/qa_checks.sql`
- Stats: `docs/pipeline_run_stats.md`
- Architecture: `agent_docs/architecture.md`
