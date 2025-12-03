# Project Context

**Last Updated**: 2024-12-02

## What Was Built

- **Multi-agent project structure** for ML recommendation system
- **AGENTS.md** with symlinks for Claude/Gemini/Codex
- **3-mode workflow**: Plan → Code → Review
- **4 Claude skills**: bq-query, notebook-to-script, implement-spec, review-code
- **4 Claude commands**: /plan, /implement, /review, /eval
- **Evaluation framework**: metrics, splitters, reporters
- **CI/CD**: GitHub workflows for tests, lint, CodeRabbit
- **Utilities**: BQ client, GCS, W&B integration
- **Config**: uv package manager, Python 3.12+

## Key Files

| File/Directory | Purpose |
|----------------|---------|
| `AGENTS.md` | Multi-agent instructions (< 60 lines) |
| `agent_docs/` | Progressive disclosure docs (architecture, BQ patterns, conventions) |
| `src/evaluation/` | Metrics implementation (precision, recall, NDCG, MAP) |
| `configs/` | Dev/eval configs with env var substitution |
| `.claude/skills/` | Auto-invoked Claude capabilities |
| `.claude/commands/` | User-triggered commands (/plan, /implement, /review, /eval) |
| `specs/` | Feature specifications for Plan mode |

## Tech Stack

- **Python**: 3.12+
- **Package Manager**: uv
- **Data**: BigQuery (bq CLI)
- **Pipeline**: Metaflow
- **Experiment Tracking**: Weights & Biases (W&B)
- **Model Storage**: GCS bucket
- **Evaluation**: Offline only (precision@k, recall@k, NDCG@k, MAP)

## Design Decisions

1. **AGENTS.md over CLAUDE.md**: Using agent-agnostic naming with symlinks for multi-agent support
2. **Progressive disclosure**: Keep AGENTS.md < 60 lines, detailed docs in `agent_docs/`
3. **ETL-style SQL**: `sql/recommendations/{extract,transform,load,tests}/` - dbt-ready
4. **Separate flows/**: Metaflow pipelines separate from `src/` library code
5. **Specs before code**: Plan mode with `specs/active/` requires approval before implementation
6. **Evals in review**: Model changes must pass `make eval` before merge

## What's NOT Implemented Yet (TODO)

### High Priority
- [ ] Actual ML model (`src/models/als_model.py`)
- [ ] Training flow (`flows/train_flow.py`)
- [ ] SQL queries in `sql/recommendations/`
- [ ] First feature spec in `specs/active/`

### Medium Priority
- [ ] Metaflow flows (train, predict, eval)
- [ ] Feature engineering (`src/features/`)
- [ ] Data extractors/loaders (`src/data/`)
- [ ] Golden test set (`evals/datasets/golden_set.csv`)
- [ ] Baseline model results (`evals/baselines/`)

### Lower Priority
- [ ] staging.yaml and prod.yaml configs
- [ ] Integration tests with real BQ
- [ ] E2E tests

## Commands Reference

```bash
# Setup
make setup              # uv sync --all-extras

# Development
make test               # Run all tests
make test-unit          # Unit tests with coverage
make lint               # Ruff + mypy
make format             # Auto-format code
make sql-validate       # Validate SQL syntax

# ML
make eval               # Run offline evaluation
make train-dev          # Training in dev mode (--test-mode)

# Claude Commands
/plan <feature>         # Create feature spec
/implement <spec>       # Implement from spec
/review                 # Pre-PR checklist
/eval                   # Run evaluation
```

## Environment Setup

```bash
# 1. Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. Setup project
make setup

# 3. Set environment variables (copy .env.example to .env)
export PROJECT_ID=your-project
export GCS_BUCKET=your-bucket
export WANDB_API_KEY=your-key
```

## References

- [HumanLayer Blog: Writing a Good CLAUDE.md](https://www.humanlayer.dev/blog/writing-a-good-claude-md)
- Claude Code documentation for skills, commands, agents

## Git History

| Commit | Description |
|--------|-------------|
| `e094baa` | Add comprehensive folder structure to README |
| `1ff1653` | Add ML project structure with multi-agent support |
| `192844b` | Initial commit |

---

*This file serves as context for AI agents and developers returning to the project.*
