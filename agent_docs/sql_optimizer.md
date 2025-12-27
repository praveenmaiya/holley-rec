# SQL Optimizer Agent Guide

Instructions for subagents optimizing BigQuery SQL in this codebase.

## Optimization Priorities

1. **Reduce bytes scanned** (cost) - BigQuery charges by data scanned
2. **Improve partition pruning** (performance) - Filter early to skip partitions
3. **Eliminate redundant scans** (efficiency) - Scan each table once
4. **Simplify expressions** (readability) - Cleaner code, easier debugging

---

## Common Optimizations

### 1. Single Table Scan Pattern

**BAD**: Scanning same table twice
```sql
-- Popularity (324 days)
SELECT sku, COUNT(*) as orders_324d
FROM import_orders
WHERE order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 324 DAY)
GROUP BY sku

-- Purchase exclusion (365 days) - SECOND SCAN
SELECT user_id, sku
FROM import_orders
WHERE order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
```

**GOOD**: Single scan with conditional aggregation
```sql
SELECT
  sku,
  user_id,
  COUNTIF(order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 324 DAY)) as orders_324d,
  COUNTIF(order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)) as in_365d_window
FROM import_orders
WHERE order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)  -- Outer filter is max window
GROUP BY sku, user_id
```

### 2. Early Filtering Pattern

**BAD**: Filter after JOIN
```sql
SELECT *
FROM large_table a
JOIN small_table b ON a.key = b.key
WHERE a.date >= '2024-01-01'
```

**GOOD**: Filter in CTE before JOIN
```sql
WITH filtered_large AS (
  SELECT * FROM large_table WHERE date >= '2024-01-01'
)
SELECT *
FROM filtered_large a
JOIN small_table b ON a.key = b.key
```

### 3. Partition Pruning Pattern

**BAD**: PARSE_DATE blocks pruning
```sql
SELECT *
FROM orders
WHERE PARSE_DATE('%Y-%m-%d', order_date_string) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
```

**GOOD**: String filter first, then parse
```sql
SELECT *
FROM orders
WHERE order_date_string LIKE '2024%'  -- Prunes partitions
  AND PARSE_DATE('%Y-%m-%d', order_date_string) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
```

### 4. Avoid SELECT *

**BAD**: Selecting all columns
```sql
SELECT * FROM large_events_table
```

**GOOD**: Select only needed columns
```sql
SELECT user_id, event_type, event_timestamp, property_value
FROM large_events_table
```

### 5. Use SAFE_DIVIDE

**BAD**: Division that can fail
```sql
SELECT clicks / views as ctr
```

**GOOD**: Safe division
```sql
SELECT SAFE_DIVIDE(clicks, views) as ctr
```

---

## Cost Estimation

Always run dry-run before actual execution:

```bash
bq query --dry_run --use_legacy_sql=false < file.sql
```

Compare bytes scanned before/after optimization:
- **Good**: 50%+ reduction
- **Acceptable**: 20-50% reduction
- **Marginal**: <20% reduction (may not be worth complexity)

---

## Pipeline-Specific Patterns

### Events Table (ingestion_unified_schema_incremental)
- Very large - always filter by `event_type` first
- Use `DATE(event_timestamp)` for date filtering
- COALESCE property extraction: `COALESCE(string_value, CAST(long_value AS STRING))`

### Fitment Table (vehicle_product_fitment_data)
- Medium size, no partitioning
- Join on (year, make, model) - ensure all three

### Orders Table (import_orders)
- Partition by ORDER_DATE (string format)
- Filter with LIKE before PARSE_DATE
- Historical boundary: Sep 1, 2025

---

## Verification

After optimization:
1. Dry-run to confirm bytes reduction
2. Run on sample data to verify correctness
3. Compare output row counts with original
4. Run QA checks: `sql/validation/qa_checks.sql`
