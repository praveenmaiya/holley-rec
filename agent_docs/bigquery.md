# BigQuery Patterns - Holley Events

## Event Schema

| Event | SKU Location | Multi-Item | Notes |
|-------|--------------|------------|-------|
| `Viewed Product` | `ProductId` | No | Has Price, ImageURL |
| `Cart Update` | `Items_n.ProductId` | Yes | ⚠️ Fires AFTER purchase |
| `Placed Order` | `Items_n.ProductID` | Yes | Deprecated Nov 2025 |
| `Consumer Website Order` | `SKUs_n` | Yes | Current order event |
| `Ordered Product` | `SKU` | No | ⚠️ Only 1 SKU per order |

## Critical Gotchas

### 1. Value Type: Always COALESCE
17-18% of values are in `long_value`, not `string_value`:
```sql
COALESCE(
  CAST(ep.string_value AS STRING),
  CAST(ep.long_value AS STRING)
) as value
```

### 2. Case Sensitivity
- Cart: `Items_n.ProductId` (lowercase 'd')
- Order: `Items_n.ProductID` (uppercase 'D')

### 3. Cart Timing Bug
Cart events fire AFTER purchase completion, not on "Add to Cart":
```sql
-- WRONG: Cart before order (only 5.6% match)
WHERE cart_timestamp < order_timestamp

-- CORRECT: Presence-based matching
WHERE user_id IN (SELECT user_id FROM cart_events)
  AND user_id IN (SELECT user_id FROM order_events)
```

### 4. Ordered Product Bug
Only fires for 1 SKU even in multi-item orders. Use `Placed Order` or `Consumer Website Order` with UNNEST:
```sql
-- Extract all items from multi-item order
SELECT user_id, sku
FROM events, UNNEST(event_properties) ep
WHERE event_name = 'Placed Order'
  AND REGEXP_CONTAINS(ep.property_name, r'^Items_[0-9]+\.ProductID$')
```

### 5. Protocol-Relative URLs
Fix `//cdn.example.com` to `https://cdn.example.com`:
```sql
CASE
  WHEN STARTS_WITH(url, '//') THEN CONCAT('https:', url)
  ELSE url
END as image_url
```

### 6. Regex in EXECUTE IMMEDIATE
Use `[0-9]+` instead of `\d+` inside FORMAT():
```sql
-- WRONG (escaping issues)
REGEXP_CONTAINS(name, r'^Items_\d+\.ProductID$')

-- CORRECT
REGEXP_CONTAINS(name, r'^Items_[0-9]+\.ProductID$')
```

## SQL Patterns

### Extract User Properties
```sql
SELECT
  user_id,
  MAX(CASE WHEN prop.property_name = 'email'
      THEN LOWER(prop.string_value) END) as email,
  MAX(CASE WHEN prop.property_name = 'v1_year'
      THEN COALESCE(prop.string_value, CAST(prop.long_value AS STRING)) END) as year,
  MAX(CASE WHEN prop.property_name = 'v1_make'
      THEN UPPER(prop.string_value) END) as make,
  MAX(CASE WHEN prop.property_name = 'v1_model'
      THEN UPPER(COALESCE(prop.string_value, CAST(prop.long_value AS STRING))) END) as model
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
UNNEST(user_properties) prop
GROUP BY user_id
```

### Extract Multi-Item Orders
```sql
SELECT
  user_id,
  UPPER(TRIM(COALESCE(ep.string_value, CAST(ep.long_value AS STRING)))) as sku
FROM `auxia-gcp.company_1950.ingestion_unified_schema_incremental`,
UNNEST(event_properties) ep
WHERE event_name IN ('Placed Order', 'Consumer Website Order')
  AND (
    REGEXP_CONTAINS(ep.property_name, r'^Items_[0-9]+\.ProductID$') OR
    REGEXP_CONTAINS(ep.property_name, r'^SKUs_[0-9]+$')
  )
  AND DATE(client_event_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
```

### Extract Prices with Index Matching
```sql
WITH indexed_events AS (
  SELECT
    event_id,
    REGEXP_EXTRACT(ep.property_name, r'Items_([0-9]+)') as item_idx,
    CASE
      WHEN ep.property_name LIKE '%ProductId' THEN 'sku'
      WHEN ep.property_name LIKE '%ItemPrice' THEN 'price'
    END as field_type,
    COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) as value
  FROM events, UNNEST(event_properties) ep
  WHERE REGEXP_CONTAINS(ep.property_name, r'^Items_[0-9]+\.(ProductId|ItemPrice)$')
)
SELECT
  sku.value as sku,
  SAFE_CAST(price.value AS FLOAT64) as price
FROM indexed_events sku
JOIN indexed_events price
  ON sku.event_id = price.event_id
  AND sku.item_idx = price.item_idx
WHERE sku.field_type = 'sku'
  AND price.field_type = 'price'
```

## Running Queries

```bash
# Dry run (validate + estimate cost)
bq query --dry_run --use_legacy_sql=false < sql/recommendations/v5_7_vehicle_fitment_recommendations.sql

# Run pipeline
bq query --use_legacy_sql=false < sql/recommendations/v5_7_vehicle_fitment_recommendations.sql

# Run validation checks
bq query --use_legacy_sql=false < sql/validation/qa_checks.sql
```

## Datasets & Tables

| Dataset | Project | Purpose |
|---------|---------|---------|
| `company_1950` | auxia-gcp | User attributes, events, treatment data |
| `data_company_1950` | auxia-gcp | Catalog, fitment, orders |
| `temp_holley_v5_7` | auxia-reporting | Output tables |
| `company_1950_jp` | auxia-reporting | Production recommendation tables |

### auxia-gcp.company_1950

| Table | Purpose |
|-------|---------|
| `ingestion_unified_attributes_schema_incremental` | User attributes (v1 YMM, email) |
| `ingestion_unified_schema_incremental` | User events (views, carts, orders) |
| `treatment_history_sent` | Treatment assignments (user_id, treatment_id, model_id, score) |
| `treatment_interaction` | Treatment interactions (VIEWED, CLICKED) |

### auxia-gcp.data_company_1950

| Table | Purpose |
|-------|---------|
| `vehicle_product_fitment_data` | Vehicle-to-SKU fitment mapping |
| `import_items` | Product catalog (PartType for diversity) |
| `import_items_tags` | Tags column (Refurbished filter) |
| `import_orders` | Historical orders (popularity, purchase exclusion) |
