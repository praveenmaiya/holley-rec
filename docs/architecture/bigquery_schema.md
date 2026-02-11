# BigQuery Schema Reference

## Source Tables

### auxia-gcp.company_1950

#### ingestion_unified_attributes_schema_incremental
**Purpose**: User profile attributes (email, vehicle registration)

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | STRING | Unique user identifier |
| `user_properties` | ARRAY<STRUCT> | Property bag with name/value pairs |

**user_properties structure**:
```sql
STRUCT<
  property_name STRING,
  string_value STRING,
  long_value INT64,
  double_value FLOAT64
>
```

**Key properties**:
- `email` - User email (string_value)
- `v1_year` - Vehicle year (string_value OR long_value)
- `v1_make` - Vehicle make (string_value)
- `v1_model` - Vehicle model (string_value)

**Gotcha**: 17-18% of values are in `long_value`, not `string_value`:
```sql
COALESCE(
  TRIM(p.string_value),
  CAST(p.long_value AS STRING)
) AS value
```

---

#### ingestion_unified_schema_incremental
**Purpose**: User behavioral events (views, carts, orders)

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | STRING | User identifier |
| `event_name` | STRING | Event type (case varies!) |
| `client_event_timestamp` | TIMESTAMP | When event occurred |
| `event_properties` | ARRAY<STRUCT> | Event-specific data |

**Event types**:
| Event | What it captures |
|-------|------------------|
| `Viewed Product` | Single product view |
| `Cart Update` | Cart add/remove (multi-item) |
| `Placed Order` | Order placed (multi-item) |
| `Ordered Product` | Single product ordered |
| `Consumer Website Order` | Full order with all SKUs |

**event_properties patterns**:
| Event | SKU Property | Price Property | Index Pattern |
|-------|--------------|----------------|---------------|
| Viewed Product | `ProductId` | `Price` | None |
| Cart Update | `Items_N.ProductId` | `Items_N.ItemPrice` | N = 0,1,2... |
| Placed Order | `Items_N.ProductId` | `Items_N.ItemPrice` | N = 0,1,2... |
| Consumer Website Order | `SKUs_N` | None | N = 0,1,2... |

**Gotcha - Case sensitivity**:
- Cart events: `ProductId` (lowercase d)
- Order events: `ProductID` (uppercase D) - but regex handles both

**Gotcha - Multi-item extraction**:
```sql
-- Extract all SKUs from Consumer Website Order
SELECT user_id,
  COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) as sku
FROM events, UNNEST(event_properties) ep
WHERE event_name = 'Consumer Website Order'
  AND REGEXP_CONTAINS(ep.property_name, r'^SKUs_[0-9]+$')
```

---

#### treatment_history_sent
**Purpose**: Treatment (email campaign) send records

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | STRING | User who received treatment |
| `treatment_id` | INT64 | Treatment identifier |
| `treatment_tracking_id` | STRING | Unique send ID (join key to interactions) |
| `treatment_sent_timestamp` | TIMESTAMP | When sent |
| `arm_id` | INT64 | Arm (4103=Random, 4689=Bandit) |
| `model_id` | INT64 | Model (1=Random, 195001001=Bandit) |
| `score` | FLOAT64 | Model score at selection time |
| `boost_factor` | FLOAT64 | Boost weight applied |
| `surface_id` | INT64 | Channel (929=Email) |
| `request_source` | STRING | `LIVE`, `SIMULATION`, or `QA` |

---

#### treatment_interaction
**Purpose**: Treatment engagement (opens, clicks)

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | STRING | User who interacted |
| `treatment_id` | INT64 | Treatment identifier |
| `treatment_tracking_id` | STRING | Unique send ID (join key from treatment_history_sent) |
| `interaction_type` | STRING | `VIEWED` (opened) or `CLICKED` |
| `interaction_timestamp_micros` | TIMESTAMP | When interaction occurred |

**CTR calculation**:
```sql
-- Always use DISTINCT to prevent multi-click inflation
COUNT(DISTINCT CASE WHEN interaction_type = 'VIEWED' THEN user_id END) as views,
COUNT(DISTINCT CASE WHEN interaction_type = 'CLICKED' THEN user_id END) as clicks
```

---

### auxia-gcp.data_company_1950

#### vehicle_product_fitment_data
**Purpose**: Maps vehicles to compatible products

| Column | Type | Description |
|--------|------|-------------|
| `v1_year` | STRING/INT64 | Vehicle year (type varies!) |
| `v1_make` | STRING | Vehicle make |
| `v1_model` | STRING | Vehicle model |
| `products` | ARRAY<STRUCT> | Compatible products |

**products structure**:
```sql
STRUCT<
  product_number STRING  -- SKU
>
```

**Gotcha - Year type inconsistency**:
```sql
SAFE_CAST(COALESCE(
  TRIM(fit.v1_year),
  CAST(fit.v1_year AS STRING)
) AS INT64) AS year
```

---

#### import_items
**Purpose**: Product catalog (PartType for diversity filtering)

| Column | Type | Description |
|--------|------|-------------|
| `PartNumber` | STRING | SKU (needs UPPER+TRIM for join) |
| `PartType` | STRING | Product category |
| `Tags` | STRING | Product tags (check for 'Refurbished') |

**Gotcha - Refurbished check**:
```sql
WHERE LOWER(Tags) LIKE '%refurbished%'  -- Case insensitive
```

---

#### import_items_tags
**Purpose**: Alternative tags source

| Column | Type | Description |
|--------|------|-------------|
| `PartNumber` | STRING | SKU |
| `Tags` | STRING | Comma-separated tags |

---

#### import_orders
**Purpose**: Historical orders (popularity + purchase exclusion)

| Column | Type | Description |
|--------|------|-------------|
| `ITEM` | STRING | SKU purchased |
| `SHIP_TO_EMAIL` | STRING | Customer email (for join to user) |
| `ORDER_DATE` | STRING | Date string "Friday, January 10, 2025" |

**Gotcha - Date parsing**:
```sql
-- String pre-filter FIRST (partition pruning)
WHERE ORDER_DATE LIKE '%2025%' OR ORDER_DATE LIKE '%2024%'

-- Then parse
SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)
```

**Gotcha - Service SKU exclusion**:
```sql
WHERE ITEM NOT LIKE 'EXT-%'
  AND ITEM NOT LIKE 'GIFT-%'
  AND ITEM NOT LIKE 'WARRANTY-%'
  AND ITEM NOT LIKE 'SERVICE-%'
  AND ITEM NOT LIKE 'PREAUTH-%'
```

---

## Output Tables

### auxia-reporting.temp_holley_v5_7.final_vehicle_recommendations
**Purpose**: Staging table (working dataset)

| Column | Type | Description |
|--------|------|-------------|
| `email_lower` | STRING | User email (lowercased) |
| `v1_year` | STRING | Vehicle year |
| `v1_make` | STRING | Vehicle make |
| `v1_model` | STRING | Vehicle model |
| `rec_part_1` | STRING | Top recommendation SKU |
| `rec1_price` | FLOAT64 | Price |
| `rec1_score` | FLOAT64 | Final score |
| `rec1_image` | STRING | HTTPS image URL |
| `rec_part_2..4` | ... | Recommendations 2-4 |
| `generated_at` | TIMESTAMP | Pipeline run time |
| `pipeline_version` | STRING | e.g., "v5.7" |

### auxia-reporting.company_1950_jp.final_vehicle_recommendations
**Purpose**: Production table (consumed by email system)

Same schema as staging table.

---

## Common Query Patterns

### Extract user properties (pivot pattern)
```sql
SELECT user_id,
  MAX(IF(LOWER(p.property_name) = 'email', TRIM(p.string_value), NULL)) AS email,
  MAX(IF(LOWER(p.property_name) = 'v1_year',
    COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`,
  UNNEST(user_properties) AS p
WHERE LOWER(p.property_name) IN ('email', 'v1_year')
GROUP BY user_id
```

### Extract multi-item cart/order SKUs
```sql
SELECT user_id,
  REGEXP_EXTRACT(ep.property_name, r'^Items_([0-9]+)\.ProductId$') AS item_idx,
  COALESCE(ep.string_value, CAST(ep.long_value AS STRING)) AS sku
FROM events, UNNEST(event_properties) ep
WHERE REGEXP_CONTAINS(ep.property_name, r'^Items_[0-9]+\.ProductId$')
```

### Join on normalized SKU
```sql
-- Always normalize before joining
ON UPPER(TRIM(a.sku)) = UPPER(TRIM(b.PartNumber))
```

### Safe date parsing with pre-filter
```sql
WHERE ORDER_DATE LIKE '%2025%'  -- String filter first
  AND SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE) >= target_date
```

---

## Performance Tips

1. **Filter early**: Apply WHERE clauses in CTEs before JOINs
2. **Use COUNTIF**: Single table scan for multiple conditions
3. **Cluster tables**: On join keys (user_id, sku)
4. **String pre-filter**: Before PARSE_DATE for partition pruning
5. **EXISTS vs JOIN**: Use EXISTS for existence checks (no row multiplication)

---

## Related Documentation

- [Pipeline Architecture](pipeline_architecture.md) - How data flows
- [Common Failures & Fixes](../CLAUDE.md#common-failures--fixes) - Error solutions
