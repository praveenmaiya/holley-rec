# Code Conventions

## Python Style

### Type Hints
Required on all functions:
```python
def compute_features(
    df: pd.DataFrame,
    config: dict[str, Any]
) -> pd.DataFrame:
    """Compute user features from interactions."""
    ...
```

### Docstrings
Required for public functions:
```python
def train_model(
    interactions: pd.DataFrame,
    factors: int = 128,
) -> ImplicitModel:
    """Train ALS collaborative filtering model.

    Args:
        interactions: User-item interaction matrix.
        factors: Number of latent factors.

    Returns:
        Trained ALS model.

    Raises:
        ValueError: If interactions is empty.
    """
```

### Logging
Use logging, not print:
```python
import logging

logger = logging.getLogger(__name__)

def process_data(df: pd.DataFrame) -> pd.DataFrame:
    logger.info(f"Processing {len(df)} rows")
    # ... process ...
    logger.debug(f"Processed columns: {df.columns.tolist()}")
    return df
```

## Configuration

### No Hardcoded Values
```python
# BAD
project_id = "my-project"
df = client.query(f"SELECT * FROM `{project_id}.dataset.table`")

# GOOD
from src.utils.config import load_config
config = load_config("configs/dev.yaml")
df = client.query_file("sql/query.sql", project=config["project_id"])
```

### Config Structure
```yaml
# configs/dev.yaml
project_id: ${PROJECT_ID}  # From environment
dataset: recommendations_dev
gcs_bucket: gs://holley-models-dev
wandb:
  project: holley-rec
  entity: auxia
model:
  factors: 64
  iterations: 10
limits:
  max_users: 10000
  max_items: 5000
```

## Error Handling
```python
# Specific exceptions
def load_data(path: str) -> pd.DataFrame:
    if not Path(path).exists():
        raise FileNotFoundError(f"Data file not found: {path}")
    try:
        return pd.read_parquet(path)
    except pyarrow.ArrowInvalid as e:
        raise ValueError(f"Invalid parquet file: {path}") from e
```

## Testing
- One test file per module: `test_<module>.py`
- Test functions: `test_<function>_<scenario>`
- Use fixtures for common setup

```python
# tests/unit/test_features.py
import pytest
from src.features.feature_engineering import compute_features

@pytest.fixture
def sample_interactions():
    return pd.DataFrame({
        "user_id": [1, 1, 2],
        "item_id": [10, 20, 10],
    })

def test_compute_features_basic(sample_interactions):
    result = compute_features(sample_interactions)
    assert "user_feature" in result.columns

def test_compute_features_empty():
    empty_df = pd.DataFrame()
    with pytest.raises(ValueError):
        compute_features(empty_df)
```

## File Organization
```
src/
├── __init__.py           # Package marker
├── data/
│   ├── __init__.py
│   ├── bq_client.py      # BigQuery operations
│   └── extractors.py     # Data extraction logic
├── features/
│   ├── __init__.py
│   └── feature_engineering.py
└── models/
    ├── __init__.py
    ├── base.py           # Abstract base class
    └── als_model.py      # Specific implementation
```
