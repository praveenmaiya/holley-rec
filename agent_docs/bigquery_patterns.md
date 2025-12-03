# BigQuery SQL Patterns

## Query Organization
```
sql/recommendations/
├── extract/    # Read from source tables
├── transform/  # Feature engineering SQL
├── load/       # Write to output tables
└── tests/      # SQL validation queries
```

## Parameterized Queries
Use `@param` syntax for Python integration:
```sql
-- sql/recommendations/extract/user_interactions.sql
SELECT
    user_id,
    item_id,
    interaction_type,
    timestamp
FROM `${PROJECT}.${DATASET}.interactions`
WHERE DATE(timestamp) >= @start_date
  AND DATE(timestamp) < @end_date
LIMIT @limit
```

## Running Queries

### Via bq CLI
```bash
# Dry run (validate syntax, estimate cost)
bq query --dry_run --use_legacy_sql=false < sql/recommendations/extract/users.sql

# With parameters
bq query --use_legacy_sql=false \
  --parameter='start_date:DATE:2024-01-01' \
  --parameter='end_date:DATE:2024-01-02' \
  --parameter='limit:INT64:10000' \
  < sql/recommendations/extract/users.sql

# Output to table
bq query --use_legacy_sql=false \
  --destination_table=project:dataset.output_table \
  --replace \
  < sql/recommendations/load/recommendations.sql
```

### Via Python
```python
from src.data.bq_client import BQClient

client = BQClient()
df = client.run_query_file(
    "sql/recommendations/extract/users.sql",
    params={
        "start_date": "2024-01-01",
        "end_date": "2024-01-02",
        "limit": 10000
    }
)
```

## Conventions
- Use lowercase with underscores for file names
- Project/dataset via config, never hardcoded
- Always include LIMIT during development
- Use `_PARTITIONTIME` for partitioned tables

## Cost Control
```bash
# Check estimated bytes before running
bq query --dry_run --use_legacy_sql=false --format=json < query.sql | jq '.statistics.totalBytesProcessed'
```

## Testing SQL
SQL test files return rows only on failure:
```sql
-- sql/recommendations/tests/test_no_null_users.sql
SELECT user_id
FROM `${PROJECT}.${DATASET}.recommendations`
WHERE user_id IS NULL
-- Returns 0 rows = PASS, >0 rows = FAIL
```
