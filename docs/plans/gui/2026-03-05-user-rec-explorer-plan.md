# User Recommendation Explorer — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Streamlit-based user recommendation explorer that shows a chronological timeline for any user: vehicle info, purchase history before emails, recommendation cards with images, email engagement, and post-email purchases with hit/miss attribution.

**Architecture:** Streamlit multi-page app with a services layer for BQ queries. All data comes from live BigQuery queries cached with 5-min TTL. User lookup is by email (the join key across recs, orders, and attributes tables). Timeline renders chronologically with email events interleaved between purchases.

**Tech Stack:** Python 3.12, Streamlit, google-cloud-bigquery, plotly, pandas, uv

**Design Doc:** `docs/plans/gui/2026-03-05-user-rec-explorer-design.md`

---

## Critical Schema Notes

These join patterns are essential — get them wrong and nothing works:

| Table | Join Key | Normalization |
|-------|----------|---------------|
| `final_vehicle_recommendations` | `email_lower` | Already lowercase |
| `import_orders` | `SHIP_TO_EMAIL` | `LOWER(TRIM(SHIP_TO_EMAIL))` |
| `treatment_history_sent` | `user_id` | Need email↔user_id bridge |
| `treatment_interaction` | `treatment_tracking_id` | Join to treatment_history_sent |
| `ingestion_unified_attributes` | `user_id` + pivot `email` property | Bridge table |
| `import_items` | `PartNumber` | `UPPER(TRIM(PartNumber))` |
| `vehicle_product_fitment_data` | `v1_year/make/model` + `product_number` | `UPPER(TRIM(...))` |

**SKU normalization everywhere:** `UPPER(TRIM(sku))`
**Variant dedup:** `REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1')`
**Order date parsing:** `SAFE.PARSE_DATE('%A, %B %d, %Y', ORDER_DATE)`

---

## Task 1: Project Scaffolding

**Files:**
- Create: `gui/app.py`
- Create: `gui/pyproject.toml`
- Create: `gui/.streamlit/config.toml`

**Step 1: Create dashboard directory and pyproject.toml**

```toml
# gui/pyproject.toml
[project]
name = "holley-gui"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "streamlit>=1.28",
    "google-cloud-bigquery>=3.0",
    "db-dtypes>=1.0",
    "pandas>=2.0",
    "plotly>=5.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
```

**Step 2: Create Streamlit config**

```toml
# gui/.streamlit/config.toml
[theme]
primaryColor = "#E31937"
backgroundColor = "#FFFFFF"
secondaryBackgroundColor = "#F5F5F5"
textColor = "#1E1E1E"

[server]
headless = true
```

**Step 3: Create minimal app.py**

```python
# gui/app.py
import streamlit as st

st.set_page_config(
    page_title="Holley Rec Explorer",
    page_icon="🔧",
    layout="wide",
)

st.title("Holley Recommendation Explorer")
st.write("User journey timeline — recommendations, purchases, email engagement.")
```

**Step 4: Install and verify it runs**

Run:
```bash
cd dashboard && uv sync && uv run streamlit run app.py --server.port 8501
```
Expected: Browser opens, shows title and subtitle.

**Step 5: Commit**

```bash
git add gui/
git commit -m "feat(dashboard): scaffold Streamlit project with uv"
```

---

## Task 2: BQ Client Service

**Files:**
- Create: `gui/services/__init__.py`
- Create: `gui/services/bq_client.py`
- Create: `gui/tests/__init__.py`
- Create: `gui/tests/test_bq_client.py`

**Step 1: Write the failing test**

```python
# gui/tests/test_bq_client.py
from unittest.mock import patch, MagicMock
from services.bq_client import get_bq_client, run_query


def test_get_bq_client_returns_client():
    with patch("services.bq_client.bigquery.Client") as mock_client:
        client = get_bq_client()
        assert client is not None
        mock_client.assert_called_once()


def test_run_query_returns_dataframe():
    mock_client = MagicMock()
    mock_df = MagicMock()
    mock_client.query.return_value.to_dataframe.return_value = mock_df

    with patch("services.bq_client.get_bq_client", return_value=mock_client):
        result = run_query("SELECT 1")
        assert result is mock_df


def test_run_query_substitutes_params():
    mock_client = MagicMock()
    mock_client.query.return_value.to_dataframe.return_value = MagicMock()

    with patch("services.bq_client.get_bq_client", return_value=mock_client):
        run_query("SELECT * FROM {table}", table="my_table")
        call_args = mock_client.query.call_args[0][0]
        assert "my_table" in call_args
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_bq_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'services'`

**Step 3: Write implementation**

```python
# gui/services/__init__.py
# (empty)
```

```python
# gui/services/bq_client.py
"""BigQuery client with Streamlit caching."""
from google.cloud import bigquery
import streamlit as st
import pandas as pd

BQ_PROJECT = "auxia-reporting"


@st.cache_resource
def get_bq_client() -> bigquery.Client:
    """Return a cached BQ client."""
    return bigquery.Client(project=BQ_PROJECT)


@st.cache_data(ttl=300)
def run_query(query: str, **params: str) -> pd.DataFrame:
    """Run a BQ query with string substitution, cached 5 min."""
    formatted = query.format(**params) if params else query
    client = get_bq_client()
    return client.query(formatted).to_dataframe()
```

**Step 4: Run test to verify it passes**

Run: `cd dashboard && uv run pytest tests/test_bq_client.py -v`
Expected: 3 passed

**Step 5: Commit**

```bash
git add gui/services/ gui/tests/
git commit -m "feat(dashboard): add BQ client service with caching"
```

---

## Task 3: User Lookup Service

**Files:**
- Create: `gui/services/user_data.py`
- Create: `gui/tests/test_user_data.py`

This service fetches a user's vehicle info and bridges email↔user_id.

**Step 1: Write the failing test**

```python
# gui/tests/test_user_data.py
from unittest.mock import patch, MagicMock
import pandas as pd
from services.user_data import search_users, get_user_vehicle


def test_search_users_by_email():
    mock_df = pd.DataFrame({
        "email_lower": ["john@test.com"],
        "v1_year": ["2019"],
        "v1_make": ["FORD"],
        "v1_model": ["MUSTANG"],
    })
    with patch("services.user_data.run_query", return_value=mock_df):
        result = search_users("john@test.com")
        assert len(result) == 1
        assert result.iloc[0]["v1_make"] == "FORD"


def test_search_users_by_vehicle():
    mock_df = pd.DataFrame({
        "email_lower": ["a@test.com", "b@test.com"],
        "v1_year": ["2019", "2019"],
        "v1_make": ["FORD", "FORD"],
        "v1_model": ["MUSTANG", "MUSTANG"],
    })
    with patch("services.user_data.run_query", return_value=mock_df):
        result = search_users(year="2019", make="FORD", model="MUSTANG")
        assert len(result) == 2


def test_get_user_vehicle():
    mock_df = pd.DataFrame({
        "email_lower": ["john@test.com"],
        "user_id": ["U123"],
        "v1_year": ["2019"],
        "v1_make": ["FORD"],
        "v1_model": ["MUSTANG GT"],
    })
    with patch("services.user_data.run_query", return_value=mock_df):
        result = get_user_vehicle("john@test.com")
        assert result["user_id"] == "U123"
        assert result["v1_model"] == "MUSTANG GT"
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_user_data.py -v`
Expected: FAIL — `ModuleNotFoundError`

**Step 3: Write implementation**

```python
# gui/services/user_data.py
"""User lookup and vehicle data from BigQuery."""
import pandas as pd
from services.bq_client import run_query

# Bridge table: email_lower ↔ user_id ↔ vehicle
_USER_VEHICLE_SQL = """
SELECT
  u.user_id,
  MAX(IF(LOWER(p.property_name) = 'email', LOWER(TRIM(p.string_value)), NULL)) AS email_lower,
  MAX(IF(LOWER(p.property_name) = 'v1_year',
    COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year,
  MAX(IF(LOWER(p.property_name) = 'v1_make', UPPER(TRIM(p.string_value)), NULL)) AS v1_make,
  MAX(IF(LOWER(p.property_name) = 'v1_model', UPPER(TRIM(p.string_value)), NULL)) AS v1_model
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` u,
  UNNEST(user_properties) AS p
WHERE LOWER(p.property_name) IN ('email', 'v1_year', 'v1_make', 'v1_model')
GROUP BY u.user_id
HAVING email_lower IS NOT NULL
"""


def search_users(
    email: str | None = None,
    year: str | None = None,
    make: str | None = None,
    model: str | None = None,
    limit: int = 50,
) -> pd.DataFrame:
    """Search users by email or vehicle. Returns DataFrame of matches."""
    conditions = []
    if email:
        conditions.append(f"email_lower LIKE '%{email.lower().replace(chr(39), '')}%'")
    if year:
        conditions.append(f"v1_year = '{year}'")
    if make:
        conditions.append(f"v1_make = '{make.upper()}'")
    if model:
        conditions.append(f"v1_model LIKE '%{model.upper()}%'")

    where = " AND ".join(conditions) if conditions else "TRUE"

    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT * FROM users
    WHERE {where}
    LIMIT {limit}
    """
    return run_query(query)


def get_user_vehicle(email_lower: str) -> dict:
    """Get single user's vehicle info + user_id."""
    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT * FROM users
    WHERE email_lower = '{email_lower.lower().replace(chr(39), '')}'
    LIMIT 1
    """
    df = run_query(query)
    if df.empty:
        return {}
    return df.iloc[0].to_dict()
```

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_user_data.py -v`
Expected: 3 passed

**Step 5: Commit**

```bash
git add gui/services/user_data.py gui/tests/test_user_data.py
git commit -m "feat(dashboard): add user lookup service with vehicle bridge"
```

---

## Task 4: Recommendations Service

**Files:**
- Create: `gui/services/recommendations.py`
- Create: `gui/tests/test_recommendations.py`

**Step 1: Write the failing test**

```python
# gui/tests/test_recommendations.py
from unittest.mock import patch
import pandas as pd
from services.recommendations import get_user_recommendations


def test_get_user_recommendations_returns_4_slots():
    mock_df = pd.DataFrame({
        "email_lower": ["john@test.com"],
        "rec_part_1": ["SKU1"], "rec1_price": [849.95], "rec1_score": [47.0],
        "rec1_image": ["https://cdn/img1.jpg"], "rec1_pop_source": ["segment"],
        "rec_part_2": ["SKU2"], "rec2_price": [599.99], "rec2_score": [38.0],
        "rec2_image": ["https://cdn/img2.jpg"], "rec2_pop_source": ["segment"],
        "rec_part_3": ["SKU3"], "rec3_price": [329.95], "rec3_score": [24.0],
        "rec3_image": ["https://cdn/img3.jpg"], "rec3_pop_source": ["make"],
        "rec_part_4": ["SKU4"], "rec4_price": [449.95], "rec4_score": [19.0],
        "rec4_image": ["https://cdn/img4.jpg"], "rec4_pop_source": ["make"],
    })
    with patch("services.recommendations.run_query", return_value=mock_df):
        recs = get_user_recommendations("john@test.com")
        assert len(recs) == 4
        assert recs[0]["sku"] == "SKU1"
        assert recs[0]["price"] == 849.95
        assert recs[0]["image"] == "https://cdn/img1.jpg"
        assert recs[0]["score_tier"] == "segment"


def test_get_user_recommendations_handles_3_slots():
    mock_df = pd.DataFrame({
        "email_lower": ["john@test.com"],
        "rec_part_1": ["SKU1"], "rec1_price": [100.0], "rec1_score": [10.0],
        "rec1_image": ["https://cdn/1.jpg"], "rec1_pop_source": ["segment"],
        "rec_part_2": ["SKU2"], "rec2_price": [90.0], "rec2_score": [8.0],
        "rec2_image": ["https://cdn/2.jpg"], "rec2_pop_source": ["make"],
        "rec_part_3": ["SKU3"], "rec3_price": [80.0], "rec3_score": [6.0],
        "rec3_image": ["https://cdn/3.jpg"], "rec3_pop_source": ["make"],
        "rec_part_4": [None], "rec4_price": [None], "rec4_score": [None],
        "rec4_image": [None], "rec4_pop_source": [None],
    })
    with patch("services.recommendations.run_query", return_value=mock_df):
        recs = get_user_recommendations("john@test.com")
        assert len(recs) == 3


def test_get_user_recommendations_empty():
    with patch("services.recommendations.run_query", return_value=pd.DataFrame()):
        recs = get_user_recommendations("noone@test.com")
        assert recs == []
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_recommendations.py -v`
Expected: FAIL

**Step 3: Write implementation**

```python
# gui/services/recommendations.py
"""Fetch user recommendations from final_vehicle_recommendations."""
import pandas as pd
from services.bq_client import run_query

_RECS_TABLE = "auxia-reporting.company_1950_jp.final_vehicle_recommendations"


def get_user_recommendations(email_lower: str) -> list[dict]:
    """Get a user's 4 recommendation slots as a list of dicts."""
    query = f"""
    SELECT *
    FROM `{_RECS_TABLE}`
    WHERE email_lower = '{email_lower.replace(chr(39), '')}'
    LIMIT 1
    """
    df = run_query(query)
    if df.empty:
        return []

    row = df.iloc[0]
    recs = []
    for i in range(1, 5):
        sku = row.get(f"rec_part_{i}")
        if pd.isna(sku):
            continue
        recs.append({
            "slot": i,
            "sku": sku,
            "price": row.get(f"rec{i}_price"),
            "score": row.get(f"rec{i}_score"),
            "image": row.get(f"rec{i}_image"),
            "score_tier": row.get(f"rec{i}_pop_source"),
        })
    return recs
```

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_recommendations.py -v`
Expected: 3 passed

**Step 5: Commit**

```bash
git add gui/services/recommendations.py gui/tests/test_recommendations.py
git commit -m "feat(dashboard): add recommendations service"
```

---

## Task 5: Purchase History Service

**Files:**
- Create: `gui/services/purchases.py`
- Create: `gui/tests/test_purchases.py`

**Step 1: Write the failing test**

```python
# gui/tests/test_purchases.py
from unittest.mock import patch
import pandas as pd
from services.purchases import get_purchase_history


def test_get_purchase_history_returns_orders():
    mock_df = pd.DataFrame({
        "sku": ["SKU1", "SKU2"],
        "order_date": [pd.Timestamp("2024-01-10"), pd.Timestamp("2024-03-15")],
        "name": ["Holley Carb", "MSD Distributor"],
        "image_url": ["https://cdn/1.jpg", "https://cdn/2.jpg"],
        "part_type": ["Fuel System", "Ignition"],
    })
    with patch("services.purchases.run_query", return_value=mock_df):
        purchases = get_purchase_history("john@test.com")
        assert len(purchases) == 2
        assert purchases.iloc[0]["sku"] == "SKU1"


def test_get_purchase_history_excludes_service_skus():
    mock_df = pd.DataFrame({
        "sku": ["SKU1"],
        "order_date": [pd.Timestamp("2024-01-10")],
        "name": ["Holley Carb"],
        "image_url": ["https://cdn/1.jpg"],
        "part_type": ["Fuel System"],
    })
    with patch("services.purchases.run_query", return_value=mock_df) as mock_run:
        get_purchase_history("john@test.com")
        query = mock_run.call_args[0][0]
        assert "EXT-%" in query  # Service SKU exclusion
        assert "GIFT-%" in query
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_purchases.py -v`
Expected: FAIL

**Step 3: Write implementation**

```python
# gui/services/purchases.py
"""Fetch user purchase history from import_orders + import_items."""
import pandas as pd
from services.bq_client import run_query


def get_purchase_history(email_lower: str) -> pd.DataFrame:
    """Get all purchases for a user, enriched with product catalog data."""
    query = f"""
    WITH orders AS (
      SELECT
        REGEXP_REPLACE(UPPER(TRIM(o.ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku,
        SAFE.PARSE_DATE('%A, %B %d, %Y', o.ORDER_DATE) AS order_date
      FROM `auxia-gcp.data_company_1950.import_orders` o
      WHERE LOWER(TRIM(o.SHIP_TO_EMAIL)) = '{email_lower.replace(chr(39), '')}'
        AND o.ITEM IS NOT NULL
        AND NOT (o.ITEM LIKE 'EXT-%' OR o.ITEM LIKE 'GIFT-%'
                 OR o.ITEM LIKE 'WARRANTY-%' OR o.ITEM LIKE 'SERVICE-%'
                 OR o.ITEM LIKE 'PREAUTH-%')
    ),
    products AS (
      SELECT
        UPPER(TRIM(PartNumber)) AS sku,
        MAX(PartType) AS part_type
      FROM `auxia-gcp.data_company_1950.import_items`
      GROUP BY 1
    )
    SELECT DISTINCT
      o.sku,
      o.order_date,
      p.part_type
    FROM orders o
    LEFT JOIN products p ON o.sku = p.sku
    WHERE o.order_date IS NOT NULL
    ORDER BY o.order_date
    """
    return run_query(query)
```

Note: `import_items` doesn't have product name or image columns reliably — we use the image from the recs table for recommended products, and show SKU + part_type for historical purchases. If images are needed for purchase history items, they can be looked up from event data in a future enhancement.

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_purchases.py -v`
Expected: 2 passed

**Step 5: Commit**

```bash
git add gui/services/purchases.py gui/tests/test_purchases.py
git commit -m "feat(dashboard): add purchase history service"
```

---

## Task 6: Email Events Service

**Files:**
- Create: `gui/services/emails.py`
- Create: `gui/tests/test_emails.py`

**Step 1: Write the failing test**

```python
# gui/tests/test_emails.py
from unittest.mock import patch
import pandas as pd
from services.emails import get_email_events


def test_get_email_events_returns_send_with_interactions():
    mock_df = pd.DataFrame({
        "treatment_id": [16150700],
        "treatment_tracking_id": ["TT-001"],
        "sent_date": [pd.Timestamp("2026-02-12")],
        "opened": [True],
        "clicked": [True],
    })
    with patch("services.emails.run_query", return_value=mock_df):
        events = get_email_events("U123")
        assert len(events) == 1
        assert events.iloc[0]["opened"] is True
        assert events.iloc[0]["clicked"] is True


def test_get_email_events_multiple_emails():
    mock_df = pd.DataFrame({
        "treatment_id": [16150700, 16490932],
        "treatment_tracking_id": ["TT-001", "TT-002"],
        "sent_date": [pd.Timestamp("2026-01-15"), pd.Timestamp("2026-02-12")],
        "opened": [True, False],
        "clicked": [False, False],
    })
    with patch("services.emails.run_query", return_value=mock_df):
        events = get_email_events("U123")
        assert len(events) == 2
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_emails.py -v`
Expected: FAIL

**Step 3: Write implementation**

```python
# gui/services/emails.py
"""Fetch email send and interaction events from BigQuery."""
import pandas as pd
from services.bq_client import run_query


def get_email_events(user_id: str) -> pd.DataFrame:
    """Get all email events for a user: sends with open/click status."""
    query = f"""
    WITH sends AS (
      SELECT
        treatment_id,
        treatment_tracking_id,
        DATE(treatment_sent_timestamp) AS sent_date
      FROM `auxia-gcp.company_1950.treatment_history_sent`
      WHERE user_id = '{user_id.replace(chr(39), '')}'
        AND request_source = 'LIVE'
        AND surface_id = 929
    ),
    opens AS (
      SELECT DISTINCT treatment_tracking_id
      FROM `auxia-gcp.company_1950.treatment_interaction`
      WHERE interaction_type = 'VIEWED'
    ),
    clicks AS (
      SELECT DISTINCT treatment_tracking_id
      FROM `auxia-gcp.company_1950.treatment_interaction`
      WHERE interaction_type = 'CLICKED'
    )
    SELECT
      s.treatment_id,
      s.treatment_tracking_id,
      s.sent_date,
      o.treatment_tracking_id IS NOT NULL AS opened,
      c.treatment_tracking_id IS NOT NULL AS clicked
    FROM sends s
    LEFT JOIN opens o USING (treatment_tracking_id)
    LEFT JOIN clicks c USING (treatment_tracking_id)
    ORDER BY s.sent_date
    """
    return run_query(query)
```

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_emails.py -v`
Expected: 2 passed

**Step 5: Commit**

```bash
git add gui/services/emails.py gui/tests/test_emails.py
git commit -m "feat(dashboard): add email events service"
```

---

## Task 7: Treatment Config Loader

**Files:**
- Create: `gui/services/treatments.py`
- Create: `gui/tests/test_treatments.py`

Loads treatment names from CSV configs so we can label emails with human-readable names.

**Step 1: Write the failing test**

```python
# gui/tests/test_treatments.py
from services.treatments import get_treatment_name, get_treatment_type


def test_get_treatment_name_personalized():
    name = get_treatment_name(16150700)
    assert "Thanks" in name or name != ""


def test_get_treatment_type_personalized():
    assert get_treatment_type(16150700) == "Personalized"


def test_get_treatment_type_static():
    assert get_treatment_type(16490932) == "Static"


def test_get_treatment_type_unknown():
    assert get_treatment_type(99999999) == "Unknown"
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_treatments.py -v`
Expected: FAIL

**Step 3: Write implementation**

```python
# gui/services/treatments.py
"""Load treatment configuration from CSV files."""
import csv
from pathlib import Path
from functools import lru_cache

_CONFIGS_DIR = Path(__file__).parent.parent.parent / "configs"


@lru_cache(maxsize=1)
def _load_treatments() -> dict[int, dict]:
    """Load all treatments from CSV configs."""
    treatments = {}

    for csv_file, ttype in [
        ("personalized_treatments.csv", "Personalized"),
        ("static_treatments.csv", "Static"),
    ]:
        path = _CONFIGS_DIR / csv_file
        if not path.exists():
            continue
        with open(path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                tid = int(row["treatment_id"])
                treatments[tid] = {
                    "name": row.get("treatment_name", ""),
                    "type": ttype,
                }
    return treatments


def get_treatment_name(treatment_id: int) -> str:
    """Get human-readable treatment name."""
    t = _load_treatments().get(treatment_id, {})
    return t.get("name", f"Treatment {treatment_id}")


def get_treatment_type(treatment_id: int) -> str:
    """Get treatment type: 'Personalized', 'Static', or 'Unknown'."""
    t = _load_treatments().get(treatment_id, {})
    return t.get("type", "Unknown")
```

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_treatments.py -v`
Expected: 4 passed

**Step 5: Commit**

```bash
git add gui/services/treatments.py gui/tests/test_treatments.py
git commit -m "feat(dashboard): add treatment config loader"
```

---

## Task 8: Attribution Service (Hit/Miss Logic)

**Files:**
- Create: `gui/services/attribution.py`
- Create: `gui/tests/test_attribution.py`

Core logic: given a user's recommendations, email dates, and purchases — determine which purchases are hits (matched a rec) and attribute them to the correct email.

**Step 1: Write the failing test**

```python
# gui/tests/test_attribution.py
import pandas as pd
from services.attribution import build_timeline, TimelineEvent


def test_purchase_before_email_is_history():
    purchases = pd.DataFrame({
        "sku": ["SKU1"],
        "order_date": [pd.Timestamp("2024-06-15")],
        "part_type": ["Engine"],
    })
    emails = pd.DataFrame({
        "treatment_id": [16150700],
        "sent_date": [pd.Timestamp("2026-02-12")],
        "opened": [True],
        "clicked": [False],
        "treatment_tracking_id": ["TT-001"],
    })
    recs = [
        {"slot": 1, "sku": "SKU-A", "price": 100, "score": 10,
         "image": "https://cdn/a.jpg", "score_tier": "segment"},
    ]

    timeline = build_timeline(purchases, emails, recs)
    history_events = [e for e in timeline if e.event_type == "purchase_before"]
    assert len(history_events) == 1
    assert history_events[0].sku == "SKU1"


def test_purchase_after_email_is_hit():
    purchases = pd.DataFrame({
        "sku": ["SKU-A"],
        "order_date": [pd.Timestamp("2026-02-15")],
        "part_type": ["Engine"],
    })
    emails = pd.DataFrame({
        "treatment_id": [16150700],
        "sent_date": [pd.Timestamp("2026-02-12")],
        "opened": [True],
        "clicked": [True],
        "treatment_tracking_id": ["TT-001"],
    })
    recs = [
        {"slot": 1, "sku": "SKU-A", "price": 849.95, "score": 47,
         "image": "https://cdn/a.jpg", "score_tier": "segment"},
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    assert after_events[0].is_hit is True
    assert after_events[0].matched_slot == 1


def test_purchase_after_email_miss():
    purchases = pd.DataFrame({
        "sku": ["UNRELATED-SKU"],
        "order_date": [pd.Timestamp("2026-02-20")],
        "part_type": ["Wheels"],
    })
    emails = pd.DataFrame({
        "treatment_id": [16150700],
        "sent_date": [pd.Timestamp("2026-02-12")],
        "opened": [True],
        "clicked": [False],
        "treatment_tracking_id": ["TT-001"],
    })
    recs = [
        {"slot": 1, "sku": "SKU-A", "price": 100, "score": 10,
         "image": "https://cdn/a.jpg", "score_tier": "segment"},
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    assert after_events[0].is_hit is False


def test_multi_email_attribution():
    """Purchase attributed to most recent prior email within 30 days."""
    purchases = pd.DataFrame({
        "sku": ["SKU-B"],
        "order_date": [pd.Timestamp("2026-03-01")],
        "part_type": ["Exhaust"],
    })
    emails = pd.DataFrame({
        "treatment_id": [16150700, 16490932],
        "sent_date": [pd.Timestamp("2026-01-15"), pd.Timestamp("2026-02-20")],
        "opened": [True, True],
        "clicked": [False, False],
        "treatment_tracking_id": ["TT-001", "TT-002"],
    })
    recs = [
        {"slot": 1, "sku": "SKU-A", "price": 100, "score": 10,
         "image": "https://cdn/a.jpg", "score_tier": "segment"},
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    # Attributed to email #2 (Feb 20), not email #1 (Jan 15)
    assert after_events[0].attributed_to_treatment == 16490932
```

**Step 2: Run test to verify it fails**

Run: `cd dashboard && uv run pytest tests/test_attribution.py -v`
Expected: FAIL

**Step 3: Write implementation**

```python
# gui/services/attribution.py
"""Build user timeline with purchase-to-email attribution."""
from dataclasses import dataclass
from datetime import timedelta
import pandas as pd

ATTRIBUTION_WINDOW_DAYS = 30


@dataclass
class TimelineEvent:
    """A single event in the user timeline."""
    date: pd.Timestamp
    event_type: str  # "purchase_before", "email", "purchase_after"
    # Purchase fields
    sku: str | None = None
    part_type: str | None = None
    is_hit: bool | None = None
    matched_slot: int | None = None
    attributed_to_treatment: int | None = None
    # Email fields
    treatment_id: int | None = None
    opened: bool | None = None
    clicked: bool | None = None
    treatment_tracking_id: str | None = None


def build_timeline(
    purchases: pd.DataFrame,
    emails: pd.DataFrame,
    recs: list[dict],
) -> list[TimelineEvent]:
    """Build chronological timeline from purchases, emails, and recs."""
    events: list[TimelineEvent] = []

    if emails.empty:
        # No emails — all purchases are "before"
        for _, row in purchases.iterrows():
            events.append(TimelineEvent(
                date=row["order_date"],
                event_type="purchase_before",
                sku=row["sku"],
                part_type=row.get("part_type"),
            ))
        events.sort(key=lambda e: e.date)
        return events

    first_email_date = emails["sent_date"].min()
    rec_skus = {r["sku"]: r["slot"] for r in recs}

    # Email events
    for _, row in emails.iterrows():
        events.append(TimelineEvent(
            date=row["sent_date"],
            event_type="email",
            treatment_id=int(row["treatment_id"]),
            opened=bool(row["opened"]),
            clicked=bool(row["clicked"]),
            treatment_tracking_id=row.get("treatment_tracking_id"),
        ))

    # Sort emails by date for attribution
    email_dates = emails.sort_values("sent_date")[["sent_date", "treatment_id"]].values.tolist()

    for _, row in purchases.iterrows():
        purchase_date = row["order_date"]
        sku = row["sku"]

        if purchase_date < first_email_date:
            events.append(TimelineEvent(
                date=purchase_date,
                event_type="purchase_before",
                sku=sku,
                part_type=row.get("part_type"),
            ))
        else:
            # Attribute to most recent prior email within window
            attributed_treatment = None
            for email_date, treatment_id in reversed(email_dates):
                if email_date <= purchase_date:
                    delta = purchase_date - email_date
                    if delta <= timedelta(days=ATTRIBUTION_WINDOW_DAYS):
                        attributed_treatment = int(treatment_id)
                    break

            is_hit = sku in rec_skus
            events.append(TimelineEvent(
                date=purchase_date,
                event_type="purchase_after",
                sku=sku,
                part_type=row.get("part_type"),
                is_hit=is_hit,
                matched_slot=rec_skus.get(sku),
                attributed_to_treatment=attributed_treatment,
            ))

    events.sort(key=lambda e: e.date)
    return events
```

**Step 4: Run tests**

Run: `cd dashboard && uv run pytest tests/test_attribution.py -v`
Expected: 4 passed

**Step 5: Commit**

```bash
git add gui/services/attribution.py gui/tests/test_attribution.py
git commit -m "feat(dashboard): add timeline attribution with hit/miss logic"
```

---

## Task 9: Product Card Component

**Files:**
- Create: `gui/components/__init__.py`
- Create: `gui/components/product_card.py`

No tests for UI components — they're visual. We test behavior in services.

**Step 1: Write implementation**

```python
# gui/components/__init__.py
# (empty)
```

```python
# gui/components/product_card.py
"""Reusable product card rendering for Streamlit."""
import streamlit as st

TIER_COLORS = {
    "segment": "🟢",
    "make": "🟡",
    "global": "🔴",
    "none": "⚪",
}


def render_rec_card(rec: dict, hit: bool | None = None):
    """Render a recommendation product card with image."""
    tier_icon = TIER_COLORS.get(rec.get("score_tier", ""), "⚪")

    st.image(rec["image"], width=150)
    st.markdown(f"**{rec['sku']}**")
    st.caption(f"${rec['price']:,.2f} | Score: {rec['score']:.1f}")
    st.caption(f"{tier_icon} {rec.get('score_tier', 'unknown').title()}")

    if hit is True:
        st.success("Bought!", icon="✅")
    elif hit is False:
        pass  # No indicator for non-hits


def render_purchase_card(sku: str, date, part_type: str | None = None,
                         is_hit: bool | None = None, matched_slot: int | None = None):
    """Render a purchase card."""
    st.markdown(f"**{sku}**")
    st.caption(f"{date}")
    if part_type:
        st.caption(f"🏷️ {part_type}")
    if is_hit is True:
        st.success(f"Hit! (Rec #{matched_slot})", icon="🟢")
    elif is_hit is False:
        st.caption("⚪ Not from recs")
```

**Step 2: Commit**

```bash
git add gui/components/
git commit -m "feat(dashboard): add product card UI components"
```

---

## Task 10: Timeline Renderer Component

**Files:**
- Create: `gui/components/timeline.py`

**Step 1: Write implementation**

```python
# gui/components/timeline.py
"""Render the user journey timeline in Streamlit."""
import streamlit as st
from services.attribution import TimelineEvent
from services.treatments import get_treatment_name, get_treatment_type
from components.product_card import render_rec_card, render_purchase_card


def render_timeline(timeline: list[TimelineEvent], recs: list[dict]):
    """Render chronological timeline with email events interleaved."""
    if not timeline:
        st.info("No events found for this user.")
        return

    # Group: before purchases, then email+after interleaved
    before = [e for e in timeline if e.event_type == "purchase_before"]
    rest = [e for e in timeline if e.event_type != "purchase_before"]

    # --- Purchase History ---
    if before:
        st.subheader(f"🔧 Purchase History ({len(before)} orders)")
        cols = st.columns(min(len(before), 4))
        for i, event in enumerate(before):
            with cols[i % 4]:
                render_purchase_card(event.sku, event.date, event.part_type)

    # --- Email Events + Post-Email Purchases ---
    current_email = None
    post_purchases = []

    for event in rest:
        if event.event_type == "email":
            # Flush previous email's purchases
            if current_email is not None:
                _render_post_purchases(post_purchases)
                post_purchases = []

            # Render email header
            current_email = event
            st.divider()
            treatment_name = get_treatment_name(event.treatment_id)
            treatment_type = get_treatment_type(event.treatment_id)
            type_badge = "🟣" if treatment_type == "Personalized" else "🔵"

            st.subheader(f"📧 {treatment_name}")
            st.caption(
                f"{type_badge} {treatment_type} | Sent: {event.date} | "
                f"Opened: {'✅' if event.opened else '❌'} | "
                f"Clicked: {'✅' if event.clicked else '❌'}"
            )

            # Render recommendation cards for this email
            if recs:
                cols = st.columns(len(recs))
                # Build hit lookup from post-purchases
                hit_skus = {
                    e.sku for e in rest
                    if e.event_type == "purchase_after"
                    and e.is_hit
                    and e.attributed_to_treatment == event.treatment_id
                }
                for i, rec in enumerate(recs):
                    with cols[i]:
                        render_rec_card(rec, hit=rec["sku"] in hit_skus)

        elif event.event_type == "purchase_after":
            post_purchases.append(event)

    # Flush final email's purchases
    if post_purchases:
        _render_post_purchases(post_purchases)


def _render_post_purchases(purchases: list[TimelineEvent]):
    """Render post-email purchase section."""
    if not purchases:
        return
    st.markdown(f"**🛒 Purchases after email ({len(purchases)})**")
    cols = st.columns(min(len(purchases), 4))
    for i, event in enumerate(purchases):
        with cols[i % 4]:
            render_purchase_card(
                event.sku, event.date, event.part_type,
                is_hit=event.is_hit, matched_slot=event.matched_slot,
            )


def render_summary(timeline: list[TimelineEvent], recs: list[dict]):
    """Render summary stats at the bottom."""
    after = [e for e in timeline if e.event_type == "purchase_after"]
    emails = [e for e in timeline if e.event_type == "email"]
    hits = [e for e in after if e.is_hit]

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Emails Received", len(emails))
    col2.metric("Hit Rate", f"{len(hits)}/{len(recs)}" if recs else "N/A")
    col3.metric("Post-Email Purchases", len(after))

    hit_skus = {h.sku for h in hits}
    revenue = sum(r["price"] for r in recs if r["sku"] in hit_skus)
    col4.metric("Revenue from Recs", f"${revenue:,.2f}")
```

**Step 2: Commit**

```bash
git add gui/components/timeline.py
git commit -m "feat(dashboard): add timeline renderer component"
```

---

## Task 11: Main App — User Explorer Page

**Files:**
- Modify: `gui/app.py`

**Step 1: Wire everything together**

```python
# gui/app.py
"""Holley Recommendation Explorer — User Journey Timeline."""
import streamlit as st
from services.user_data import search_users, get_user_vehicle
from services.recommendations import get_user_recommendations
from services.purchases import get_purchase_history
from services.emails import get_email_events
from services.attribution import build_timeline
from components.timeline import render_timeline, render_summary

st.set_page_config(
    page_title="Holley Rec Explorer",
    page_icon="🔧",
    layout="wide",
)

st.title("🔧 Holley Recommendation Explorer")

# --- Sidebar: Search ---
with st.sidebar:
    st.header("Search User")

    search_tab = st.radio("Search by", ["Email", "Vehicle"], horizontal=True)

    if search_tab == "Email":
        email_input = st.text_input("Email (partial match)")
        search_clicked = st.button("Search", type="primary")
    else:
        year_input = st.text_input("Year (e.g. 2019)")
        make_input = st.text_input("Make (e.g. Ford)")
        model_input = st.text_input("Model (e.g. Mustang)")
        search_clicked = st.button("Search", type="primary")

# --- Search Results ---
if search_clicked:
    if search_tab == "Email" and email_input:
        results = search_users(email=email_input)
    elif search_tab == "Vehicle":
        results = search_users(
            year=year_input or None,
            make=make_input or None,
            model=model_input or None,
        )
    else:
        results = None

    if results is not None and not results.empty:
        st.session_state["search_results"] = results
        st.session_state["selected_email"] = results.iloc[0]["email_lower"]
    elif results is not None:
        st.warning("No users found.")

# --- User Selector ---
if "search_results" in st.session_state:
    results = st.session_state["search_results"]
    options = [
        f"{row['email_lower']} — {row.get('v1_year', '?')} {row.get('v1_make', '?')} {row.get('v1_model', '?')}"
        for _, row in results.iterrows()
    ]
    selected_idx = st.selectbox("Select user", range(len(options)), format_func=lambda i: options[i])
    selected_email = results.iloc[selected_idx]["email_lower"]

    if selected_email:
        # --- Load User Data ---
        user = get_user_vehicle(selected_email)
        if not user:
            st.error("User not found.")
            st.stop()

        # Vehicle header
        st.header(f"🚗 {user.get('v1_year', '?')} {user.get('v1_make', '?')} {user.get('v1_model', '?')}")
        st.caption(f"User ID: `{user.get('user_id', 'N/A')}` | Email: `{selected_email}`")

        # Fetch all data
        recs = get_user_recommendations(selected_email)
        purchases = get_purchase_history(selected_email)
        emails = get_email_events(user.get("user_id", ""))

        # Build and render timeline
        timeline = build_timeline(purchases, emails, recs)

        # Summary at top
        render_summary(timeline, recs)
        st.divider()

        # Full timeline
        render_timeline(timeline, recs)

else:
    st.info("👈 Use the sidebar to search for a user by email or vehicle.")
```

**Step 2: Run the app**

Run: `cd dashboard && uv run streamlit run app.py`
Expected: App loads, sidebar shows search, can look up users.

**Step 3: Commit**

```bash
git add gui/app.py
git commit -m "feat(dashboard): wire user explorer page with timeline"
```

---

## Task 12: Random Sample & Quick Filters

**Files:**
- Modify: `gui/app.py` (add sidebar filters)
- Modify: `gui/services/user_data.py` (add random sample query)

**Step 1: Add random sample to user_data.py**

```python
# Add to gui/services/user_data.py

def get_random_users(n: int = 10, buyers_only: bool = False) -> pd.DataFrame:
    """Get random sample of users, optionally filtered to buyers."""
    buyer_join = ""
    if buyers_only:
        buyer_join = """
        INNER JOIN (
          SELECT DISTINCT LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower
          FROM `auxia-gcp.data_company_1950.import_orders`
          WHERE ITEM IS NOT NULL
        ) buyers USING (email_lower)
        """

    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT u.* FROM users u
    {buyer_join}
    ORDER BY RAND()
    LIMIT {n}
    """
    return run_query(query)
```

**Step 2: Add quick filters to sidebar in app.py**

Add to the sidebar section:
```python
    st.divider()
    st.header("Quick Actions")
    if st.button("🎲 Random 10 Users"):
        from services.user_data import get_random_users
        results = get_random_users(10)
        st.session_state["search_results"] = results
    if st.button("🎲 Random 10 Buyers"):
        from services.user_data import get_random_users
        results = get_random_users(10, buyers_only=True)
        st.session_state["search_results"] = results
```

**Step 3: Test and commit**

Run: `cd dashboard && uv run streamlit run app.py`
Verify: Random sample buttons work, show real users.

```bash
git add gui/app.py gui/services/user_data.py
git commit -m "feat(dashboard): add random sample and buyer filter"
```

---

## Task 13: Integration Test with Real BQ Data

**Files:**
- Create: `gui/tests/test_integration.py`

This test hits real BigQuery — run manually, not in CI.

**Step 1: Write integration test**

```python
# gui/tests/test_integration.py
"""Integration tests — requires BQ credentials. Run with: pytest -m integration"""
import pytest
import pandas as pd

pytestmark = pytest.mark.integration


def test_search_users_returns_results():
    from services.user_data import search_users
    results = search_users(make="FORD", model="MUSTANG", limit=5)
    assert len(results) > 0
    assert "email_lower" in results.columns
    assert "v1_make" in results.columns


def test_get_recommendations_for_real_user():
    from services.user_data import search_users
    from services.recommendations import get_user_recommendations

    users = search_users(make="FORD", model="MUSTANG", limit=1)
    assert len(users) > 0

    email = users.iloc[0]["email_lower"]
    recs = get_user_recommendations(email)
    assert len(recs) >= 3
    assert all(r["image"].startswith("https://") for r in recs)
    assert all(r["price"] >= 50 for r in recs)


def test_full_timeline_for_real_user():
    from services.user_data import search_users, get_user_vehicle
    from services.recommendations import get_user_recommendations
    from services.purchases import get_purchase_history
    from services.emails import get_email_events
    from services.attribution import build_timeline

    users = search_users(make="FORD", model="MUSTANG", limit=1)
    email = users.iloc[0]["email_lower"]
    user = get_user_vehicle(email)

    recs = get_user_recommendations(email)
    purchases = get_purchase_history(email)
    emails = get_email_events(user["user_id"])

    timeline = build_timeline(purchases, emails, recs)
    assert isinstance(timeline, list)
```

**Step 2: Run integration tests**

Run: `cd dashboard && uv run pytest tests/test_integration.py -m integration -v`
Expected: 3 passed (requires BQ credentials)

**Step 3: Commit**

```bash
git add gui/tests/test_integration.py
git commit -m "test(dashboard): add BQ integration tests"
```

---

## Summary

| Task | What | Files | Tests |
|------|------|-------|-------|
| 1 | Project scaffold | app.py, pyproject.toml, config.toml | Manual |
| 2 | BQ client service | services/bq_client.py | 3 |
| 3 | User lookup | services/user_data.py | 3 |
| 4 | Recommendations | services/recommendations.py | 3 |
| 5 | Purchase history | services/purchases.py | 2 |
| 6 | Email events | services/emails.py | 2 |
| 7 | Treatment config | services/treatments.py | 4 |
| 8 | Attribution logic | services/attribution.py | 4 |
| 9 | Product card UI | components/product_card.py | — |
| 10 | Timeline renderer | components/timeline.py | — |
| 11 | Main app wiring | app.py | Manual |
| 12 | Random sample + filters | app.py, user_data.py | Manual |
| 13 | Integration tests | tests/test_integration.py | 3 |

**Total: 13 tasks, ~24 unit tests, 3 integration tests**
**Estimated commits: 13 atomic commits**
