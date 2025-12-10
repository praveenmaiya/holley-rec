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

## 2. Treatments with Recommendations vs Without

### Summary Comparison

| Metric | With Recs | Without Recs | Lift |
|--------|-----------|--------------|------|
| **Users Sent** | 7,852 | 33,983 | - |
| **Open Rate** | 14.12% | 12.54% | **+12.6%** |
| **Click Rate** | 1.69% | 1.02% | **+65.7%** |
| **Click-to-Open Rate** | 11.99% | 8.09% | **+48.2%** |
| **Order Rate** | 1.01% | 0.89% | **+13.5%** |
| **Revenue** | $189K | $347K | - |

### Key Findings

Users with personalized product recommendations perform better across all metrics:

1. **Click Rate is 66% higher** (1.69% vs 1.02%) - strongest signal
2. **Click-to-Open Rate is 48% higher** (12% vs 8%) - once opened, more likely to click
3. **Open Rate is 13% higher** (14.1% vs 12.5%) - modest lift
4. **Order Rate is 14% higher** (1.01% vs 0.89%)

### Performance by Treatment ID

| Treatment | Users Sent | % With Recs | Open Rate | Click Rate | CTR |
|-----------|------------|-------------|-----------|------------|-----|
| 17049625 | 23,598 | 33% | 5.6% | 0.65% | **11.7%** |
| 16150707 | 18,940 | 40% | 5.5% | 0.46% | 8.4% |
| 16490939 | 17,298 | 10% | **13.4%** | 1.01% | 7.5% |
| 16444546 | 8,246 | 17% | 4.2% | 0.21% | 4.9% |
| 17049596 | 2,875 | 18% | 2.4% | 0.1% | 4.4% |
| 17049603 | 1,308 | 21% | 2.2% | 0.31% | 13.8% |
| 16593503 | 910 | 100%+ | 2.3% | 0.66% | 28.6% |
| 20142778 | 611 | 100%+ | 7.9% | 0.82% | 10.4% |

### Recommendations

- **Increase recommendation coverage** - only ~19% of sent users currently have personalized product recommendations
- Treatment **16490939** has highest open rate (13.4%) but only 10% rec coverage - opportunity for improvement
- Treatment **17049625** has best CTR (11.7%) with 33% rec coverage

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

### Recommendations vs No Recommendations Query
```sql
WITH user_emails AS (
  SELECT DISTINCT
    user_id,
    LOWER((SELECT up.string_value FROM UNNEST(user_properties) up WHERE up.property_name = 'email' LIMIT 1)) as email
  FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
),
sent_with_rec_flag AS (
  SELECT
    th.user_id,
    th.treatment_id,
    th.treatment_sent_timestamp,
    CASE WHEN r.email_lower IS NOT NULL THEN true ELSE false END as has_recommendation
  FROM `auxia-gcp.company_1950.treatment_history` th
  JOIN user_emails ue ON th.user_id = ue.user_id
  LEFT JOIN `auxia-reporting.temp_holley_v5_4.final_vehicle_recommendations` r
    ON ue.email = r.email_lower
  WHERE th.treatment_sent_status = 'TREATMENT_SENT'
    AND DATE(th.treatment_sent_timestamp) >= '2025-12-04'
),
opens AS (
  SELECT DISTINCT user_id, treatment_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'VIEWED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
clicks AS (
  SELECT DISTINCT user_id, treatment_id
  FROM `auxia-gcp.company_1950.treatment_interaction`
  WHERE interaction_type = 'CLICKED'
    AND DATE(interaction_timestamp_micros) >= '2025-12-04'
),
orders AS (
  SELECT user_id, MIN(client_event_timestamp) as order_time,
    SUM(COALESCE((SELECT ep.double_value FROM UNNEST(event_properties) ep WHERE ep.property_name = 'Subtotal' LIMIT 1), 0)) as revenue
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'
    AND DATE(client_event_timestamp) >= '2025-12-04'
  GROUP BY 1
)
SELECT
  CASE WHEN s.has_recommendation THEN 'With Recommendations' ELSE 'Without Recommendations' END as group_type,
  COUNT(DISTINCT s.user_id) as users_sent,
  COUNT(DISTINCT o.user_id) as users_opened,
  ROUND(100.0 * COUNT(DISTINCT o.user_id) / COUNT(DISTINCT s.user_id), 2) as open_rate,
  COUNT(DISTINCT c.user_id) as users_clicked,
  ROUND(100.0 * COUNT(DISTINCT c.user_id) / COUNT(DISTINCT s.user_id), 2) as click_rate,
  ROUND(100.0 * COUNT(DISTINCT c.user_id) / NULLIF(COUNT(DISTINCT o.user_id), 0), 2) as click_to_open_rate,
  COUNT(DISTINCT CASE WHEN ord.order_time > s.treatment_sent_timestamp THEN s.user_id END) as users_ordered,
  ROUND(100.0 * COUNT(DISTINCT CASE WHEN ord.order_time > s.treatment_sent_timestamp THEN s.user_id END) / COUNT(DISTINCT s.user_id), 2) as order_rate,
  ROUND(SUM(CASE WHEN ord.order_time > s.treatment_sent_timestamp THEN ord.revenue ELSE 0 END), 2) as total_revenue
FROM sent_with_rec_flag s
LEFT JOIN opens o ON s.user_id = o.user_id AND s.treatment_id = o.treatment_id
LEFT JOIN clicks c ON s.user_id = c.user_id AND s.treatment_id = c.treatment_id
LEFT JOIN orders ord ON s.user_id = ord.user_id
GROUP BY 1
ORDER BY 1;
```

---

*Report generated: Dec 10, 2025*
