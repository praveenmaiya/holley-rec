# GCP Database Access Guide

Generic guide for accessing BigQuery and PostgreSQL from GCP projects.

---

## 1. BigQuery Access

### Authentication

#### Option A: Interactive (Local Development)
```bash
# Install gcloud CLI: https://cloud.google.com/sdk/docs/install

# Login and set up Application Default Credentials (ADC)
gcloud auth login
gcloud auth application-default login

# Verify
gcloud auth list
```

#### Option B: Service Account (CI/CD, Production)
```bash
# Download service account key JSON from GCP Console
# IAM & Admin → Service Accounts → Keys → Add Key

# Set environment variable
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
```

#### Option C: Workload Identity (Kubernetes)
```yaml
# Pod automatically gets credentials via mounted service account
# No explicit credentials needed in code
```

---

### BigQuery CLI (`bq`)

#### Basic Commands
```bash
# List datasets in a project
bq ls project-id:

# List tables in a dataset
bq ls project-id:dataset_name

# Show table schema
bq show project-id:dataset_name.table_name

# Run a query
bq query --use_legacy_sql=false "SELECT * FROM \`project-id.dataset.table\` LIMIT 10"

# Run query from file
bq query --use_legacy_sql=false < query.sql

# Dry run (validate + estimate bytes)
bq query --dry_run --use_legacy_sql=false < query.sql
```

#### Query Options
```bash
bq query \
  --use_legacy_sql=false \
  --project_id=my-project \
  --format=json \
  --max_rows=1000 \
  "SELECT * FROM \`project.dataset.table\`"
```

| Flag | Description |
|------|-------------|
| `--use_legacy_sql=false` | Use Standard SQL (recommended) |
| `--project_id=X` | Override default project |
| `--format=json` | Output as JSON (also: csv, pretty) |
| `--dry_run` | Validate without executing |
| `--max_rows=N` | Limit output rows |

---

### Python Client

#### Installation
```bash
pip install google-cloud-bigquery pandas db-dtypes
```

#### Basic Usage
```python
from google.cloud import bigquery

# Client automatically uses ADC or GOOGLE_APPLICATION_CREDENTIALS
client = bigquery.Client(project="your-project-id")

# Run query and get DataFrame
query = """
SELECT *
FROM `project.dataset.table`
WHERE date >= '2025-01-01'
LIMIT 100
"""
df = client.query(query).to_dataframe()
```

#### With Explicit Credentials
```python
from google.cloud import bigquery
from google.oauth2 import service_account

credentials = service_account.Credentials.from_service_account_file(
    '/path/to/service-account.json'
)
client = bigquery.Client(credentials=credentials, project="your-project-id")
```

#### Parameterized Queries
```python
from google.cloud import bigquery

client = bigquery.Client()

query = """
SELECT *
FROM `project.dataset.table`
WHERE user_id = @user_id
  AND date >= @start_date
"""

job_config = bigquery.QueryJobConfig(
    query_parameters=[
        bigquery.ScalarQueryParameter("user_id", "STRING", "user123"),
        bigquery.ScalarQueryParameter("start_date", "DATE", "2025-01-01"),
    ]
)

df = client.query(query, job_config=job_config).to_dataframe()
```

#### Write Data to BigQuery
```python
from google.cloud import bigquery
import pandas as pd

client = bigquery.Client()
table_id = "project.dataset.table_name"

# From DataFrame
df = pd.DataFrame({"col1": [1, 2], "col2": ["a", "b"]})

job_config = bigquery.LoadJobConfig(
    write_disposition="WRITE_TRUNCATE",  # or WRITE_APPEND
)

job = client.load_table_from_dataframe(df, table_id, job_config=job_config)
job.result()  # Wait for completion
```

---

## 2. PostgreSQL Access via BigQuery Federated Query

BigQuery can query external PostgreSQL databases using `EXTERNAL_QUERY`.

### Prerequisites

1. **Create a Cloud SQL connection** in BigQuery:
   - BigQuery → Add Data → External data source → Cloud SQL
   - Or via `bq mk --connection`

2. **Connection resource format:**
   ```
   projects/{project}/locations/{location}/connections/{connection_name}
   ```

### Syntax

```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/{project}/locations/{location}/connections/{connection_name}",
  "{PostgreSQL query}"
)
```

### Examples

#### Basic Query
```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/my-project/locations/us/connections/my-postgres-connection",
  "SELECT id, name, created_at FROM users WHERE active = true LIMIT 100"
)
```

#### With Filtering
```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/my-project/locations/us/connections/my-postgres-connection",
  "SELECT * FROM orders WHERE order_date >= '2025-01-01'"
)
```

#### Join with BigQuery Table
```sql
WITH pg_users AS (
  SELECT * FROM EXTERNAL_QUERY(
    "projects/my-project/locations/us/connections/my-postgres-connection",
    "SELECT user_id, email FROM users"
  )
)
SELECT
  bq.event_name,
  pg.email
FROM `my-project.dataset.events` bq
JOIN pg_users pg ON bq.user_id = pg.user_id
```

### CLI Usage

```bash
bq query --use_legacy_sql=false '
SELECT * FROM EXTERNAL_QUERY(
  "projects/my-project/locations/us/connections/my-postgres-connection",
  "SELECT id, name FROM users LIMIT 10"
)'
```

### Python Usage

```python
from google.cloud import bigquery

client = bigquery.Client()

query = '''
SELECT * FROM EXTERNAL_QUERY(
  "projects/my-project/locations/us/connections/my-postgres-connection",
  "SELECT id, name, email FROM users WHERE active = true"
)
'''

df = client.query(query).to_dataframe()
```

### Creating a Connection

```bash
# Create connection via bq CLI
bq mk --connection \
  --connection_type=CLOUD_SQL \
  --properties='{"instanceId":"my-project:us-central1:my-instance","database":"mydb","type":"POSTGRES"}' \
  --project_id=my-project \
  --location=us \
  my-postgres-connection

# Or via gcloud
gcloud sql connect my-instance --user=postgres --database=mydb
```

### Permissions Required

| Permission | Description |
|------------|-------------|
| `bigquery.connections.use` | Use the connection |
| `bigquery.jobs.create` | Run queries |
| Cloud SQL Client | Access the PostgreSQL instance |

---

## 3. Environment Setup

### Environment Variables

```bash
# .env file
PROJECT_ID=your-gcp-project
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
BQ_LOCATION=US
```

### Python with dotenv

```python
from dotenv import load_dotenv
import os
from google.cloud import bigquery

load_dotenv()

client = bigquery.Client(
    project=os.getenv("PROJECT_ID"),
    location=os.getenv("BQ_LOCATION", "US")
)
```

---

## 4. GitHub Actions Setup

```yaml
name: BigQuery Job

on: [push]

jobs:
  query:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Set up Cloud SDK
        uses: google-github-actions/setup-gcloud@v2

      - name: Run BigQuery query
        run: |
          bq query --use_legacy_sql=false "SELECT COUNT(*) FROM \`project.dataset.table\`"
```

---

## 5. Common Patterns

### Safe Division
```sql
-- Prevents division by zero
SAFE_DIVIDE(numerator, denominator)

-- Or with NULLIF
numerator / NULLIF(denominator, 0)
```

### Date Filtering (Partition Pruning)
```sql
-- Good: Filter on partition column early
WHERE DATE(timestamp_col) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)

-- Good: Use _PARTITIONDATE for ingestion-time partitioned tables
WHERE _PARTITIONDATE >= '2025-01-01'
```

### COALESCE for Nullable Values
```sql
COALESCE(nullable_column, 'default_value')
COALESCE(string_col, CAST(int_col AS STRING))
```

### Parameterized Table Names (Dynamic SQL)
```sql
DECLARE table_name STRING DEFAULT 'my_table';
DECLARE full_table STRING DEFAULT FORMAT('`project.dataset.%s`', table_name);

EXECUTE IMMEDIATE FORMAT("SELECT * FROM %s LIMIT 10", full_table);
```

---

## 6. Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Access Denied` | Missing permissions | Check IAM roles (BigQuery User, Data Viewer) |
| `Not found: Dataset` | Wrong project/dataset | Verify project ID and dataset name |
| `Quota exceeded` | Too many concurrent queries | Add retry logic or reduce parallelism |
| `Connection refused` (EXTERNAL_QUERY) | Network/firewall issue | Check VPC, authorized networks |
| `Invalid credentials` | Expired or wrong credentials | Re-run `gcloud auth application-default login` |

### Verify Authentication
```bash
# Check active account
gcloud auth list

# Check ADC
gcloud auth application-default print-access-token

# Test BigQuery access
bq ls
```

---

## Quick Reference

| Task | Command/Code |
|------|--------------|
| Auth (local) | `gcloud auth application-default login` |
| Auth (service account) | `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json` |
| List datasets | `bq ls project:` |
| Run query | `bq query --use_legacy_sql=false "SELECT ..."` |
| Dry run | `bq query --dry_run --use_legacy_sql=false < file.sql` |
| Python client | `bigquery.Client(project="x")` |
| Query to DataFrame | `client.query(sql).to_dataframe()` |
| PostgreSQL via BQ | `SELECT * FROM EXTERNAL_QUERY("connection", "pg query")` |
