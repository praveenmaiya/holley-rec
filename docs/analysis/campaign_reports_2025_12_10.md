# Campaign Reports - Dec 10, 2025

Post-Purchase Email Campaign Performance Update

---

## 1. Post-Purchase Email Campaign Performance (Dec 4-10)

### Dec 4 Cohort - Updated Metrics

| Metric | Dec 6 Report | Dec 10 Update | Change |
|--------|--------------|---------------|--------|
| **Sent** | 23,585 | 34,057 | +10,472 |
| **Opened** | 8,556 | 4,635 | * |
| **Open Rate** | 36.3% | 13.6% | * |
| **Clicked** | 688 | 413 | * |
| **Click Rate** | 2.9% | 1.2% | * |
| **Ordered** | 120 | 358 | +238 |
| **Revenue** | $73K | $158K | +$85K |
| **AOV** | $416 | $441 | +$25 |

*Note: Opens/clicks methodology changed - Dec 10 uses unique users from treatment_interaction table*

### Daily Engagement - Dec 4 Cohort

| Date | Unique Opens | Unique Clicks | Users Ordered | Revenue |
|------|-------------|---------------|---------------|---------|
| Dec 4 | 3,670 | 318 | 68 | $31,652 |
| Dec 5 | - | - | 56 | $20,995 |
| Dec 6 | - | - | 57 | $22,770 |
| Dec 7 | 856 | 65 | 57 | $23,557 |
| Dec 8 | 569 | 23 | 65 | $29,721 |
| Dec 9 | 313 | 18 | 48 | $17,227 |
| Dec 10 | - | - | 24 | $12,109 |

### Daily Email Sends (Campaign Now Running Daily)

| Send Date | Users Sent |
|-----------|------------|
| Dec 4 | 34,057 |
| Dec 7 | 11,196 |
| Dec 8 | 9,580 |
| Dec 9 | 8,134 |
| Dec 10 | 3,963 |
| **Total** | **41,834** |

### Key Observations

1. **Revenue continues growing**: $158K total from Dec 4 cohort (up from $73K), demonstrating strong 6-day tail
2. **358 users ordered** after receiving email (up from 120)
3. **Daily sends started Dec 7**: Additional cohorts sent on Dec 7 (11K), Dec 8 (10K), Dec 9 (8K), Dec 10 (4K)
4. **Long conversion window**: Orders still coming in 6 days post-send - automotive parts have long consideration cycles
5. **Click-to-Open Rate**: ~8.9% (consistent with Sunday's 8.0%)

### Campaign Status

- **Total users sent (all cohorts)**: 41,834
- **Campaign is now running daily** with ongoing sends

---

## 2. Personalized Fitment vs Static Recommendations

**Note:** This analysis compares all 32 Live post-purchase email treatments:
- **10 Personalized Fitment treatments** (ours) - use vehicle fitment recommendation system
- **22 Static Recommendation treatments** - generic product recommendations

### Summary Comparison (All Time)

| Metric | Personalized Fitment (10) | Static Recs (22) | Lift |
|--------|--------------------------|------------------|------|
| **Users Sent** | 1,415 | 18,380 | - |
| **Open Rate** | 25.72% | 12.61% | **+104%** |
| **Click Rate** | 2.47% | 0.95% | **+160%** |
| **Click-to-Open Rate** | 9.62% | 7.51% | +28% |
| **Order Rate** | 1.34% | 0.78% | **+72%** |
| **Total Revenue** | $29,778 | $88,824 | - |
| **AOV** | $1,567 | $617 | **+154%** |
| **Revenue per User Sent** | **$21.04** | **$4.83** | **+336%** |

### Key Findings

Personalized Fitment treatments significantly outperform Static recommendations:

1. **Revenue per User Sent is 336% higher** ($21.04 vs $4.83) - the true measure of ROI
2. **Open Rate is 104% higher** (25.72% vs 12.61%) - personalized content drives engagement
3. **Click Rate is 160% higher** (2.47% vs 0.95%) - strongest engagement signal
4. **AOV is 154% higher** ($1,567 vs $617) - personalized users buy higher-value items
5. **Order Rate is 72% higher** (1.34% vs 0.78%) - better conversion

### Performance by Personalized Fitment Treatment Variant

| Treatment ID | Variant Name | Users Sent | Open Rate | Click Rate | CTR |
|--------------|--------------|------------|-----------|------------|-----|
| 20142778 | Warm Welcome | 613 | 7.83% | 0.82% | 10.42% |
| 20142818 | Weekend Warrior | 581 | 7.75% | 0.52% | 6.67% |
| 20142825 | Visionary | 574 | 9.06% | 0.70% | 7.69% |
| 20142832 | Detail Oriented | 570 | 7.89% | 0.53% | 6.67% |
| 20142846 | Look Back | 560 | 10.00% | 0.36% | 3.57% |
| 20142839 | Expert Pick | 557 | 9.34% | 0.72% | 7.69% |
| 20142785 | Relatable Wrencher | 549 | 9.11% | 0.55% | 6.00% |
| 20142811 | Momentum | 545 | 7.89% | 0.37% | 4.65% |
| 20142804 | Completer | 533 | 10.32% | 0.75% | 7.27% |
| **16150700** | **Thanks** | **440** | **9.55%** | **1.36%** | **14.29%** |

### Top Performer

**"Thanks"** variant (16150700) has the highest click rate (1.36%) and CTR (14.29%) among all personalized fitment treatments.

### Recommendations

- **Scale Personalized Fitment**: Only 1,391 users (3.3%) received personalized fitment emails - significant opportunity to expand
- **Replicate "Thanks" variant**: Best performing variant should inform future treatment design
- **Increase vehicle fitment coverage**: More users with registered vehicles = more personalized recommendations

---

## Referenced Tables

| Table | Dataset | Purpose |
|-------|---------|---------|
| `treatment_history` | `auxia-gcp.company_1950` | Email send records (user_id, treatment_id, sent timestamp, status) |
| `treatment_interaction` | `auxia-gcp.company_1950` | Opens (VIEWED) and clicks (CLICKED) on emails |
| `ingestion_unified_schema_incremental` | `auxia-gcp.company_1950` | Behavioral events including 'Placed Order' with revenue |
| `ingestion_unified_attributes_schema_incremental` | `auxia-gcp.company_1950` | User attributes (email, vehicle info) |
| `final_vehicle_recommendations` | `auxia-reporting.temp_holley_v5_4` | Generated product recommendations (email, SKUs, prices, scores) |

---

## Supporting Queries

### Overall Funnel Query
```sql
WITH sent AS (
  SELECT COUNT(DISTINCT user_id) as unique_users_sent
  FROM `auxia-gcp.company_1950.treatment_history`
  WHERE treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(treatment_sent_timestamp) >= '2025-12-04'
),
opens AS (
  SELECT
    COUNT(*) as total_opens,
    COUNT(DISTINCT user_id) as unique_users_opened
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
clicks AS (
  SELECT
    COUNT(*) as total_clicks,
    COUNT(DISTINCT user_id) as unique_users_clicked
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
)
SELECT
  s.unique_users_sent as sent,
  o.unique_users_opened as opened,
  ROUND(100.0 * o.unique_users_opened / s.unique_users_sent, 2) as open_rate_pct,
  c.unique_users_clicked as clicked,
  ROUND(100.0 * c.unique_users_clicked / s.unique_users_sent, 2) as click_rate_pct,
  ROUND(100.0 * c.unique_users_clicked / o.unique_users_opened, 2) as click_to_open_pct
FROM sent s, opens o, clicks c;
```

### Personalized Fitment vs Static Recommendations Query
```sql
-- All 32 Live Treatments (see configs/personalized_treatments.csv and configs/static_treatments.csv)
WITH personalized_ids AS (
  SELECT treatment_id FROM UNNEST([
    16150700, 20142778, 20142785, 20142804, 20142811,
    20142818, 20142825, 20142832, 20142839, 20142846
  ]) as treatment_id
),
static_ids AS (
  SELECT treatment_id FROM UNNEST([
    16490932, 16490939, 16518436, 16518443, 16564380, 16564387, 16564394, 16564401,
    16564408, 16564415, 16564423, 16564431, 16564439, 16564447, 16564455, 16564463,
    16593451, 16593459, 16593467, 16593475, 16593483, 16593491
  ]) as treatment_id
),
all_live_ids AS (
  SELECT treatment_id FROM personalized_ids
  UNION ALL
  SELECT treatment_id FROM static_ids
),
sent AS (
  SELECT
    th.user_id,
    th.treatment_id,
    th.treatment_sent_timestamp,
    CASE
      WHEN th.treatment_id IN (SELECT treatment_id FROM personalized_ids) THEN 'Personalized Fitment (10)'
      WHEN th.treatment_id IN (SELECT treatment_id FROM static_ids) THEN 'Static Recommendations (22)'
    END as treatment_type
  FROM `auxia-gcp.company_1950.treatment_history_sent` th
  WHERE th.treatment_sent_status = 'TREATMENT_SENT'
    AND th.treatment_id IN (SELECT treatment_id FROM all_live_ids)
),
opens AS (
  SELECT DISTINCT user_id, treatment_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
),
clicks AS (
  SELECT DISTINCT user_id, treatment_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
),
orders AS (
  SELECT
    user_id,
    MIN(client_event_timestamp) as first_order_time,
    SUM(COALESCE(
      (SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1),
      0
    )) as revenue
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
  GROUP BY 1
)
SELECT
  s.treatment_type,
  COUNT(DISTINCT s.user_id) as users_sent,
  COUNT(DISTINCT o.user_id) as users_opened,
  ROUND(100.0 * COUNT(DISTINCT o.user_id) / COUNT(DISTINCT s.user_id), 2) as open_rate,
  COUNT(DISTINCT c.user_id) as users_clicked,
  ROUND(100.0 * COUNT(DISTINCT c.user_id) / COUNT(DISTINCT s.user_id), 2) as click_rate,
  ROUND(100.0 * COUNT(DISTINCT c.user_id) / NULLIF(COUNT(DISTINCT o.user_id), 0), 2) as ctr,
  COUNT(DISTINCT CASE WHEN ord.first_order_time > s.treatment_sent_timestamp THEN s.user_id END) as users_ordered,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN ord.first_order_time > s.treatment_sent_timestamp THEN s.user_id END) / COUNT(DISTINCT s.user_id), 2) as order_rate,
  ROUND(SUM(CASE WHEN ord.first_order_time > s.treatment_sent_timestamp THEN ord.revenue ELSE 0 END), 2) as total_revenue,
  ROUND(SUM(CASE WHEN ord.first_order_time > s.treatment_sent_timestamp THEN ord.revenue ELSE 0 END) /
    NULLIF(COUNT(DISTINCT CASE WHEN ord.first_order_time > s.treatment_sent_timestamp THEN s.user_id END), 0), 2) as aov
FROM sent s
LEFT JOIN opens o ON s.user_id = o.user_id AND s.treatment_id = o.treatment_id
LEFT JOIN clicks c ON s.user_id = c.user_id AND s.treatment_id = c.treatment_id
LEFT JOIN orders ord ON s.user_id = ord.user_id
GROUP BY 1
ORDER BY 1 DESC;
```

---

## 3. Open Issue: Uncategorized Treatments

### Problem Discovered

When analyzing the 32 "Live" treatments (10 personalized + 22 static), we found a **mismatch in user counts**:

| Category | Users Sent (Dec 4+) |
|----------|---------------------|
| 10 Personalized Fitment treatments | 1,391 |
| 22 Static treatments | 17,316 |
| **Subtotal (32 Live)** | **18,707** |
| **Total campaign sends** | **~77,000+** |
| **Gap (uncategorized)** | **~59,000** |

### Uncategorized Treatments (Top 10 by Volume)

These treatment IDs are sending emails but are NOT in the 32 "Live" treatment list:

| Treatment ID | Users Sent | Status Unknown |
|--------------|------------|----------------|
| 17049625 | 23,598 | ? |
| 16150707 | 18,940 | ? |
| 16444546 | 8,246 | ? |
| 17049596 | 2,875 | ? |
| 17049603 | 1,308 | ? |
| 16593503 | 910 | ? |
| 18056699 | 890 | ? |
| 17049617 | 704 | ? |
| 17049610 | 691 | ? |
| 16593514 | 380 | ? |

### Next Steps

1. **Get treatment names** for the uncategorized IDs from Auxia console
2. **Determine if these are**: older treatments turned off, different campaigns, or missing from the "Live" list
3. **Re-run analysis** once all treatments are properly categorized

### Data Sources

- Treatment names are NOT stored in BigQuery - must be retrieved from Auxia console
- `treatment_history` = all treatment records
- `treatment_history_sent` = only sent treatments
- Treatment IDs provided manually by user from Auxia console export

---

## How This Analysis Was Done

### Context for Future Sessions

1. **Goal**: Compare performance of Personalized Fitment recommendations (ours) vs Static recommendations

2. **Key Discovery**: Treatment names are not in BigQuery. User must export treatment IDs/names from Auxia console.

3. **Treatment ID Sources**:
   - `configs/personalized_treatments.csv` - 10 Personalized Fitment treatment IDs
   - `configs/static_treatments.csv` - 22 Static treatment IDs
   - Both files created from manual Auxia console export

4. **Tables Used**:
   - `treatment_history_sent` - for send counts (NOT `treatment_history` which includes non-sent)
   - `treatment_interaction` - for opens (VIEWED) and clicks (CLICKED)
   - `ingestion_unified_schema_incremental` - for orders and revenue

5. **Current Blocker**: 20 uncategorized treatments sending ~59K users - need names to properly categorize

---

*Report generated: Dec 10, 2025*
*Last updated: Dec 10, 2025 - Added uncategorized treatments issue*
