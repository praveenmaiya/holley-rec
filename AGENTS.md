# Holley Recommendation System

Automotive parts recommendations using collaborative filtering.

## Stack
- Python 3.12+, uv, BigQuery (bq CLI), Metaflow, W&B
- Models: GCS bucket | Experiments: W&B

## Workflow Modes

### PLAN - Before new features
1. Create spec: `specs/active/<feature>.md`
2. Define: problem, data, output, eval criteria
3. ASK if unclear - don't assume

### CODE - Implementing
1. Reference spec and `@agent_docs/`
2. Use `--test-mode` for BQ queries
3. Log experiments to W&B

### REVIEW - Before PR
1. `make test` + `make lint` must pass
2. `make eval` - check metrics vs baseline
3. Update docs if architecture changed

## Directories
- `specs/` - Feature specs (Plan mode)
- `sql/recommendations/` - BQ queries
- `src/` - Production code
- `flows/` - Metaflow pipelines
- `evals/` - Evaluation datasets & scripts
- `notebooks/` - Prototypes (convert to src/)

## Commands
```bash
make test          # Run tests
make lint          # Ruff + mypy
make eval          # Offline evaluation
make sql-validate  # Validate SQL
python scripts/run_training.py --config configs/dev.yaml --test-mode
```

## Docs (read before coding)
- @agent_docs/architecture.md
- @agent_docs/bigquery_patterns.md
- @agent_docs/evaluation_guide.md

## Rules
- Never hardcode project IDs (use configs/)
- Always run evals before merging model changes
- Log all experiments to W&B
