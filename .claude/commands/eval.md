---
description: Run model evaluation
---

Run offline evaluation for model changes.

## Arguments
$ARGUMENTS - optional: specific model path or config

## Instructions

1. Run evaluation:
   ```bash
   make eval
   # or with specific config
   python scripts/run_eval.py --config configs/dev.yaml
   ```

2. Compare against baseline:
   ```bash
   python evals/scripts/compare_models.py --baseline evals/baselines/v1_als_baseline.json
   ```

3. Check thresholds in `configs/eval/thresholds.yaml`:
   - precision_at_10 >= 0.15
   - recall_at_10 >= 0.08
   - ndcg_at_10 >= 0.12
   - No regression > 5%

4. Results are logged to W&B automatically

5. If metrics pass, update baseline:
   ```bash
   cp evals/reports/latest.json evals/baselines/v<version>_baseline.json
   ```

## Reference
- @agent_docs/evaluation_guide.md
- @configs/eval/metrics.yaml
- @configs/eval/thresholds.yaml
