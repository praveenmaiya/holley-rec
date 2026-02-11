# Campaign Reports - Dec 6, 2025

Post-Purchase Email Campaign (Launched Dec 4, 2025)

---

## 1. Campaign Performance Report

**Post to Slack:**

```
📊 *Post-Purchase Email Campaign Performance (Dec 4-6)*

*Funnel:*
• Received: 23,585 users
• Opened: 8,556 users (36.3% open rate)
• Clicked: 688 users (2.9% click rate)
• Ordered: 120 users ($73K revenue)

*Daily Breakdown:*
| Date   | Opens  | Clicks |
|--------|--------|--------|
| Dec 4  | 7,311  | 817    |
| Dec 5  | 3,621  | 239    |
| Dec 6  | 576    | 39     |

*Key Metrics:*
• Open Rate: 36.3%
• Click-to-Open Rate: 8.0%
• Avg Order Value: $416 (vs $400 baseline)
• Peak Engagement: 4-7 PM UTC

*Notes:*
• Data sourced from `unified_events` (Campaign Name = 'AuxiaContent')
• 120 users ordered after receiving email
• 20 opened then ordered, 100 ordered without tracked open
```

---

## 2. Data Issue Report

**Post to Slack:**

```
🔴 *Data Issue: treatment_interaction table missing Dec 5-6 data*

*What we found:*
The `treatment_interaction` table stopped syncing after Dec 4 20:00 UTC. Email opens/clicks from Dec 5-6 are NOT being captured.

*Impact:*
| Date   | unified_events | treatment_interaction | Missing |
|--------|----------------|----------------------|---------|
| Dec 4  | 7,311 opens    | 4,674 opens          | 36%     |
| Dec 5  | 3,621 opens    | 0                    | 100%    |
| Dec 6  | 576 opens      | 0                    | 100%    |

*This caused us to underreport:*
• Open rate: reported 10.8% → actual 36.3%
• Clickers: reported 318 → actual 688

*Root cause:*
Pipeline that syncs Klaviyo events (`unified_events`) → `treatment_interaction` appears to have stopped or failed.

*Tables affected:*
• `treatment_interaction` - last updated Dec 5 06:51 UTC (stale)
• `unified_events` - has complete data ✓

*Workaround:*
For accurate reporting, query `ingestion_unified_schema_incremental` with:
WHERE Campaign Name = 'AuxiaContent'

*Action needed:*
@engineering - Can you check the treatment_interaction sync pipeline and backfill Dec 5-6 data?
```

---

## Supporting Data

### Corrected Funnel Query

```sql
-- Use this for accurate campaign metrics
WITH sent AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE (SELECT ep.string_value FROM UNNEST(event_properties) ep
         WHERE ep.property_name = 'Campaign Name' LIMIT 1) = 'AuxiaContent'
    AND event_name = 'Received Email'
    AND DATE(client_event_timestamp) >= '2025-12-04'
),
opened AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE (SELECT ep.string_value FROM UNNEST(event_properties) ep
         WHERE ep.property_name = 'Campaign Name' LIMIT 1) = 'AuxiaContent'
    AND event_name = 'Opened Email'
    AND DATE(client_event_timestamp) >= '2025-12-04'
),
clicked AS (
  SELECT DISTINCT user_id
  FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE (SELECT ep.string_value FROM UNNEST(event_properties) ep
         WHERE ep.property_name = 'Campaign Name' LIMIT 1) = 'AuxiaContent'
    AND event_name = 'Clicked Email'
    AND DATE(client_event_timestamp) >= '2025-12-04'
)
SELECT
  'Received' as stage, COUNT(*) as users FROM sent
UNION ALL
SELECT 'Opened', COUNT(*) FROM opened
UNION ALL
SELECT 'Clicked', COUNT(*) FROM clicked;
```

### Daily Breakdown Query

```sql
SELECT
  DATE(client_event_timestamp) as dt,
  event_name,
  COUNT(*) as count,
  COUNT(DISTINCT user_id) as unique_users
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`
WHERE (SELECT ep.string_value FROM UNNEST(event_properties) ep
       WHERE ep.property_name = 'Campaign Name' LIMIT 1) = 'AuxiaContent'
  AND DATE(client_event_timestamp) >= '2025-12-04'
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## Key Findings Summary

| Metric | Wrong (treatment_interaction) | Correct (unified_events) |
|--------|-------------------------------|--------------------------|
| Open Rate | 10.8% | 36.3% |
| Click Rate | 0.93% | 2.92% |
| Unique Openers | 3,670 | 8,556 |
| Unique Clickers | 318 | 688 |

**Root Cause:** Pipeline sync failure between Klaviyo events and treatment_interaction table after Dec 4 20:00 UTC.
