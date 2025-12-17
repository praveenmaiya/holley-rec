# PostgreSQL Treatment Database Reference

Treatment data is stored in PostgreSQL and accessed via BigQuery's `EXTERNAL_QUERY` federated query feature.

## Connection Details

```
Project: auxia-gcp
Location: asia-northeast1
Connection: jp-psql_hbProdDb
Company ID: 1950 (Holley)
```

## Quick Query Template

```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  -- Your PostgreSQL query here
  """
);
```

## Schema Overview

### Core Tables

| Table | Purpose |
|-------|---------|
| `treatment` | Main treatment definitions |
| `treatment_version` | Version history & scheduling |
| `treatment_type` | Email vs In-App types |
| `treatment_content_field` | Actual content (subject, body, etc.) |
| `treatment_content_field_type` | Field definitions (from_name, subject, body) |
| `treatment_tag` | Tags/labels for treatments |
| `core_program_treatment_mapping` | Program → treatment relationships |

### Treatment Table Schema

| Column | Type | Description |
|--------|------|-------------|
| `treatment_id` | bigint | Primary key |
| `company_id` | bigint | 1950 for Holley |
| `name` | varchar | Human-readable name |
| `description` | text | Optional description |
| `live_version_id` | bigint | FK to current version |
| `type` | enum | EMAIL, IN_APP, etc. |
| `treatment_type_id` | bigint | FK to treatment_type |
| `is_paused` | boolean | Active/paused status |
| `boost_factor` | float | Scoring boost |
| `created_at_timestamp` | timestamp | Creation time |

### Treatment Version Schema

| Column | Type | Description |
|--------|------|-------------|
| `treatment_version_id` | bigint | Primary key |
| `treatment_id` | bigint | FK to treatment |
| `start_time` | timestamp | Version start |
| `end_time` | timestamp | Version end (9999-12-10 = forever) |
| `modified_time` | timestamp | Last modified |
| `self_dismiss_seconds` | bigint | Self-dismiss cooldown |
| `all_dismiss_seconds` | bigint | All-dismiss cooldown |
| `self_click_seconds` | bigint | Self-click cooldown |

### Content Field Types (Holley)

| Field Name | Data Type | Treatment Type |
|------------|-----------|----------------|
| `from_name` | STRING | EMAIL |
| `from_email` | STRING | EMAIL |
| `subject` | STRING | EMAIL |
| `preheader` | STRING | EMAIL |
| `body` | HTML | EMAIL |
| `reply_to` | STRING | EMAIL |
| `bcc` | STRING | EMAIL |
| `header_list_unsubscribe` | STRING | EMAIL |

## Common Queries

### 1. List All Active Treatments

```sql
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT
    t.treatment_id,
    t.name,
    t.is_paused,
    tt.delivery_type::text
  FROM treatment t
  LEFT JOIN treatment_type tt ON t.treatment_type_id = tt.treatment_type_id
  WHERE t.company_id = 1950
    AND t.is_paused = false
  ORDER BY t.treatment_id DESC;
  """
)'
```

### 2. Get Treatment with Full Content

```sql
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT
    t.treatment_id,
    t.name as treatment_name,
    cft.field_name,
    cf.value
  FROM treatment t
  JOIN treatment_version tv ON t.live_version_id = tv.treatment_version_id
  JOIN treatment_content_field cf ON tv.treatment_version_id = cf.treatment_version_id
  JOIN treatment_content_field_type cft ON cf.content_field_type_id = cft.content_field_type_id
  WHERE t.treatment_id = 20142778
  ORDER BY cft.display_order;
  """
)'
```

### 3. Get Treatments by Category

```sql
-- Post Purchase Personalized Fitment
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT treatment_id, name, is_paused
  FROM treatment
  WHERE company_id = 1950
    AND name LIKE '\''Post Purchase with Personalized Fitment%'\''
  ORDER BY treatment_id;
  """
)'

-- Abandon Cart
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT treatment_id, name, is_paused
  FROM treatment
  WHERE company_id = 1950
    AND name LIKE '\''Abandon Cart%'\''
  ORDER BY treatment_id;
  """
)'

-- Browse Recovery
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT treatment_id, name, is_paused
  FROM treatment
  WHERE company_id = 1950
    AND name LIKE '\''Browse Recovery%'\''
  ORDER BY treatment_id;
  """
)'
```

### 4. Get Subject Lines for A/B Testing Analysis

```sql
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT
    t.treatment_id,
    t.name,
    cf.value as subject_line
  FROM treatment t
  JOIN treatment_version tv ON t.live_version_id = tv.treatment_version_id
  JOIN treatment_content_field cf ON tv.treatment_version_id = cf.treatment_version_id
  JOIN treatment_content_field_type cft ON cf.content_field_type_id = cft.content_field_type_id
  WHERE t.company_id = 1950
    AND cft.field_name = '\''subject'\''
    AND t.name LIKE '\''Post Purchase with Personalized Fitment%'\''
  ORDER BY t.treatment_id;
  """
)'
```

### 5. Treatment Categories Summary

```sql
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  """
  SELECT
    CASE
      WHEN name LIKE '\''Post Purchase with Personalized Fitment%'\'' THEN '\''Personalized Fitment'\''
      WHEN name LIKE '\''Post Purchase with Static%'\'' THEN '\''Static Recommendations'\''
      WHEN name LIKE '\''Abandon Cart%'\'' THEN '\''Abandon Cart'\''
      WHEN name LIKE '\''Browse Recovery%'\'' THEN '\''Browse Recovery'\''
      ELSE '\''Other'\''
    END as category,
    COUNT(*) as count,
    SUM(CASE WHEN is_paused = false THEN 1 ELSE 0 END) as active_count
  FROM treatment
  WHERE company_id = 1950
  GROUP BY 1
  ORDER BY 2 DESC;
  """
)'
```

## Treatment Categories (Holley)

### 1. Post Purchase - Personalized Fitment (10 treatments)
Target: `consumer_website_order`
IDs: 16150700, 20142778-20142846

| ID | Subject Theme |
|----|---------------|
| 16150700 | Thanks |
| 20142778 | Warm Welcome |
| 20142785 | Relatable Wrencher |
| 20142804 | Completer |
| 20142811 | Momentum |
| 20142818 | Weekend Warrior |
| 20142825 | Visionary |
| 20142832 | Detail Oriented |
| 20142839 | Expert Pick |
| 20142846 | Look Back |

### 2. Post Purchase - Static Recommendations (22 treatments)
Target: `consumer_website_order`
IDs: 16490932-16593491

Categories: Sniper 2, Apparel, Air Cleaners, Retrobright, Mr. Gasket, Tools, Exhaust, Cold Air Intakes, Engine Hardware, Brothers (Interior, LED, Grilles, Steering, Exterior, Body/Rust), Terminator X, Wheels, Tuners

### 3. Abandon Cart (multiple variants)
- Fitment Recommendations (1-5 items)
- Static Recommendations (1-5 items)
- Multiple subject line variants

### 4. Browse Recovery (new - Dec 2025)
- Personalized Recommendations (1-5 browsed items)
- No Recommendations (1-5 browsed items)
- Subject variants: Quick Picks, Take Another Look, Still Browsing, Revisit Hot Items, Round Two, Second Look

## Notes

1. **Escaping in EXTERNAL_QUERY**: Use `'\''` to escape single quotes in PostgreSQL strings within the BigQuery query
2. **Enum casting**: Cast USER-DEFINED types with `::text` (e.g., `delivery_type::text`)
3. **Date convention**: End time `9999-12-10T23:59:59.999` means "no end date"
4. **Deprecated treatments**: Prefixed with `[DEPRECATE]`
