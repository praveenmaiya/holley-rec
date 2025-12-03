# System Architecture

## Overview
Holley recommendation system using collaborative filtering for automotive parts.

## Data Flow
```
BigQuery (raw) → Extract SQL → Python Features → Model → Recommendations → BigQuery (output)
     ↓                              ↓                          ↓
  sql/extract/              src/features/              sql/load/
```

## Component Responsibilities

| Directory | Purpose |
|-----------|---------|
| `sql/recommendations/extract/` | Pull raw data from BQ |
| `sql/recommendations/transform/` | Feature transformations in SQL |
| `sql/recommendations/load/` | Write results back to BQ |
| `src/data/` | Python data loading and BQ client |
| `src/features/` | Feature engineering in Python |
| `src/models/` | Model training and inference |
| `src/evaluation/` | Metrics computation |
| `flows/` | Metaflow pipelines orchestrating all steps |

## Metaflow Flow Pattern
```python
from metaflow import FlowSpec, step

class TrainFlow(FlowSpec):
    @step
    def start(self):
        """Load config and initialize."""
        self.next(self.extract)

    @step
    def extract(self):
        """Extract data from BigQuery."""
        self.next(self.transform)

    @step
    def transform(self):
        """Feature engineering."""
        self.next(self.train)

    @step
    def train(self):
        """Train model."""
        self.next(self.evaluate)

    @step
    def evaluate(self):
        """Compute metrics."""
        self.next(self.end)

    @step
    def end(self):
        """Save artifacts."""
        pass
```

## Model Architecture
- Algorithm: ALS (Alternating Least Squares) collaborative filtering
- Library: `implicit`
- Output: User and item embeddings
- Similarity: FAISS for fast nearest neighbor search

## Storage
- **Models**: GCS bucket (path in config)
- **Experiments**: W&B for tracking
- **Data**: BigQuery tables

## Environments
| Env | Config | Purpose |
|-----|--------|---------|
| dev | `configs/dev.yaml` | Local development, limited data |
| staging | `configs/staging.yaml` | Pre-prod testing |
| prod | `configs/prod.yaml` | Production runs |
