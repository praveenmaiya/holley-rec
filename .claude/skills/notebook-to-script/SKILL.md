---
name: notebook-to-script
description: Convert Colab/Jupyter notebooks to production Python scripts. Use when user asks to productionize a notebook, create a Metaflow pipeline from notebook code, or convert prototype to production.
allowed-tools: Read, Write, Edit, Glob
---

# Notebook to Production Conversion

## When to Use
- Converting a prototype notebook to production code
- Creating a Metaflow flow from notebook experiments
- Refactoring notebook code into modules

## Process

1. **Read notebook** from `notebooks/`
2. **Identify core logic** - separate from exploration/debugging cells
3. **Extract to modules** in `src/`:
   - Data loading → `src/data/`
   - Feature engineering → `src/features/`
   - Model code → `src/models/`
   - Evaluation → `src/evaluation/`
4. **Create flow** in `flows/` if pipeline needed
5. **Add production concerns**:
   - Config loading (no hardcoded values)
   - Logging
   - Error handling
   - Type hints
6. **Write tests** in `tests/unit/`

## Checklist
- [ ] Remove hardcoded values → use `configs/`
- [ ] Remove print statements → use logging
- [ ] Add type hints to all functions
- [ ] Add docstrings to public functions
- [ ] Extract magic numbers to config
- [ ] Handle edge cases (empty data, missing columns)
- [ ] Write at least one unit test

## Metaflow Flow Template
See `agent_docs/architecture.md` for flow patterns.

## Example Transformation
```python
# Notebook (BAD)
df = pd.read_gbq("SELECT * FROM project.dataset.table")
df['feature'] = df['col'].apply(lambda x: x * 2)

# Production (GOOD)
from src.data.bq_client import BQClient
from src.features.feature_engineering import compute_feature

def extract_data(client: BQClient, config: dict) -> pd.DataFrame:
    """Extract raw data from BigQuery."""
    return client.run_query_file(
        "sql/recommendations/extract/users.sql",
        params={"limit": config.get("limit", 10000)}
    )
```
