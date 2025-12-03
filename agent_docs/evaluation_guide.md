# Evaluation Guide

## Overview
Offline evaluation framework for recommendation quality metrics.

## Metrics

### Ranking Metrics
| Metric | Description | Target |
|--------|-------------|--------|
| Precision@K | Fraction of top-K that are relevant | ≥ 0.15 |
| Recall@K | Fraction of relevant items in top-K | ≥ 0.08 |
| NDCG@K | Normalized discounted cumulative gain | ≥ 0.12 |
| MAP | Mean average precision | ≥ 0.10 |

### Coverage Metrics
| Metric | Description | Target |
|--------|-------------|--------|
| Catalog Coverage | % of items ever recommended | ≥ 5% |
| User Coverage | % of users with recommendations | ≥ 95% |

## Running Evaluation

### Quick Eval
```bash
make eval
```

### Full Eval with Options
```bash
python scripts/run_eval.py \
  --config configs/dev.yaml \
  --model-path artifacts/model.pkl \
  --output evals/reports/eval_$(date +%Y%m%d).json
```

### Compare Models
```bash
python evals/scripts/compare_models.py \
  --baseline evals/baselines/v1_als_baseline.json \
  --candidate evals/reports/latest.json
```

## Evaluation Pipeline

### Using Metaflow
```bash
python flows/eval_flow.py run --config dev
```

### Steps
1. **Load model** from GCS or local path
2. **Load test set** from `evals/datasets/golden_set.csv`
3. **Generate predictions** for holdout users
4. **Compute metrics** against ground truth
5. **Log to W&B** for tracking
6. **Save report** to `evals/reports/`

## Dataset Management

### Golden Set
Curated test interactions in `evals/datasets/golden_set.csv`:
```csv
user_id,item_id,timestamp,label
123,456,2024-01-15,1
123,789,2024-01-16,1
```

### Holdout Users
List of user IDs for evaluation:
```
# evals/datasets/holdout_users.txt
123
456
789
```

### Splitting Strategy
```python
# Time-based split
train: interactions before cutoff_date
test: interactions after cutoff_date

# User-based split
train: 80% of users
test: 20% of users (holdout)
```

## Thresholds

### Absolute Thresholds
Defined in `configs/eval/thresholds.yaml`:
```yaml
precision_at_10: 0.15
recall_at_10: 0.08
ndcg_at_10: 0.12
coverage: 0.05
```

### Regression Threshold
Fail if metrics drop more than 5% vs baseline:
```yaml
max_regression_percent: 5.0
```

## W&B Integration

Experiments logged automatically:
```python
import wandb
from src.utils.wandb_utils import init_wandb, log_metrics

run = init_wandb(config, job_type="evaluation")
log_metrics({
    "precision_at_10": 0.18,
    "recall_at_10": 0.09,
    "ndcg_at_10": 0.14,
})
wandb.finish()
```

## Baseline Management

### Create New Baseline
When metrics improve significantly:
```bash
cp evals/reports/latest.json evals/baselines/v2_als_baseline.json
git add evals/baselines/v2_als_baseline.json
git commit -m "Add v2 baseline with improved metrics"
```

### Baseline Format
```json
{
  "model_version": "v2_als",
  "date": "2024-01-15",
  "metrics": {
    "precision_at_10": 0.18,
    "recall_at_10": 0.09,
    "ndcg_at_10": 0.14,
    "coverage": 0.06
  },
  "config": {
    "factors": 128,
    "iterations": 15
  }
}
```

## CI Integration
PRs with model changes trigger:
1. `make eval` runs
2. Metrics compared to baseline
3. PR fails if below threshold or regression > 5%
