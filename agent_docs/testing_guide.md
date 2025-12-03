# Testing Guide

## Test Pyramid
```
        /\
       /E2E\         ← Few, slow, expensive (weekly CI)
      /------\
     /Integr. \      ← Medium, real BQ (PR merge)
    /----------\
   /   Unit     \    ← Many, fast, mocked (every commit)
  ----------------
```

## Running Tests

### Unit Tests (No Cloud)
```bash
# Fast, mocked, no credentials needed
make test-unit

# With coverage
pytest tests/unit/ --cov=src --cov-report=html
```

### Integration Tests (Real BQ)
```bash
# Requires GOOGLE_APPLICATION_CREDENTIALS
make test-integration
```

### SQL Validation
```bash
# Syntax check all SQL
make sql-validate

# Run SQL tests
python scripts/validate_sql.py --run-tests
```

## Test Data Strategy

### Local Fixtures
Small CSV files tracked in git:
```
data/samples/
├── test_users_100.csv
├── test_items_50.csv
└── test_interactions_500.csv
```

### Test Mode Flag
Limit production queries during development:
```python
# scripts/run_training.py
@click.option("--test-mode", is_flag=True)
def main(config: str, test_mode: bool):
    cfg = load_config(config)
    if test_mode:
        cfg["limits"]["max_users"] = 1000
        cfg["limits"]["max_items"] = 500
```

## Mocking Patterns

### Mock BQ Client
```python
# tests/conftest.py
import pytest
from unittest.mock import Mock

@pytest.fixture
def mock_bq_client(mocker):
    client = mocker.Mock()
    client.run_query.return_value = pd.DataFrame({
        "user_id": [1, 2, 3],
        "item_id": [100, 101, 102],
        "score": [0.9, 0.8, 0.7]
    })
    return client

# tests/unit/test_extractors.py
def test_extract_users(mock_bq_client):
    from src.data.extractors import extract_users
    result = extract_users(mock_bq_client, limit=10)
    assert len(result) == 3
    mock_bq_client.run_query.assert_called_once()
```

### Mock GCS
```python
@pytest.fixture
def mock_gcs(mocker, tmp_path):
    def mock_download(bucket, blob, local_path):
        # Create fake file
        Path(local_path).write_text("mock content")

    mocker.patch("src.utils.gcs_utils.download_blob", mock_download)
    return tmp_path
```

## Writing Good Tests

### Test Structure
```python
def test_function_scenario():
    # Arrange
    input_data = create_test_data()

    # Act
    result = function_under_test(input_data)

    # Assert
    assert result.shape[0] > 0
    assert "expected_column" in result.columns
```

### Test Categories
```python
def test_happy_path():
    """Normal operation with valid input."""
    pass

def test_edge_case_empty():
    """Handle empty input gracefully."""
    pass

def test_edge_case_single():
    """Handle single item input."""
    pass

def test_error_invalid_input():
    """Raise appropriate error for invalid input."""
    with pytest.raises(ValueError, match="expected pattern"):
        function(invalid_input)
```

## CI Configuration
Tests run automatically:
- **Unit tests**: Every push
- **Integration tests**: PR to main
- **E2E tests**: Weekly schedule
