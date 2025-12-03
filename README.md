# Holley Recommendation System

Automotive parts recommendation engine using collaborative filtering.

## Tech Stack

- **Python 3.12+** with **uv** package manager
- **BigQuery** for data (via `bq` CLI)
- **Metaflow** for pipeline orchestration
- **W&B** for experiment tracking
- **GCS** for model storage

## Quick Start

```bash
# Install uv (if not installed)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Setup project
make setup

# Run tests
make test

# Run linting
make lint
```

## Folder Structure

```
holley-rec/
│
├── AGENTS.md                        # Multi-agent instructions (Claude/Codex/Gemini)
├── CLAUDE.md -> AGENTS.md           # Symlink for Claude Code
├── GEMINI.md -> AGENTS.md           # Symlink for Gemini CLI
├── README.md                        # This file
│
├── .claude/                         # Claude Code configuration
│   ├── settings.json                # Team settings (tracked)
│   ├── settings.local.json          # Personal settings (gitignored)
│   ├── skills/                      # Auto-invoked capabilities
│   │   ├── bq-query/
│   │   │   └── SKILL.md             # BigQuery operations
│   │   ├── implement-spec/
│   │   │   └── SKILL.md             # Implement from spec
│   │   ├── notebook-to-script/
│   │   │   └── SKILL.md             # Convert notebooks to production
│   │   └── review-code/
│   │       └── SKILL.md             # Pre-PR code review
│   └── commands/                    # User-triggered commands
│       ├── plan.md                  # /plan - create feature spec
│       ├── implement.md             # /implement - code from spec
│       ├── review.md                # /review - pre-PR checklist
│       └── eval.md                  # /eval - run evaluation
│
├── .gemini/                         # Gemini CLI configuration
│   └── settings.json
│
├── .github/
│   └── workflows/
│       ├── test.yml                 # Unit + integration tests
│       ├── lint.yml                 # Ruff, mypy, SQL validation
│       └── coderabbit.yml           # AI PR review
│
├── agent_docs/                      # Progressive disclosure docs for agents
│   ├── architecture.md              # System design, data flow
│   ├── bigquery_patterns.md         # SQL conventions, BQ CLI usage
│   ├── code_conventions.md          # Python style guide
│   ├── evaluation_guide.md          # Metrics, baselines, thresholds
│   └── testing_guide.md             # Test pyramid, mocking patterns
│
├── configs/                         # Configuration files
│   ├── dev.yaml                     # Development config
│   ├── staging.yaml                 # Staging config (TODO)
│   ├── prod.yaml                    # Production config (TODO)
│   └── eval/
│       ├── metrics.yaml             # Which metrics to compute
│       └── thresholds.yaml          # Pass/fail criteria
│
├── data/                            # Data directory
│   ├── raw/                         # Downloaded from BQ (gitignored)
│   ├── processed/                   # Feature-engineered (gitignored)
│   └── samples/                     # Small test fixtures (tracked)
│       └── .gitkeep
│
├── evals/                           # Evaluation framework
│   ├── datasets/                    # Test datasets
│   │   ├── golden_set.csv           # Curated test interactions (TODO)
│   │   └── holdout_users.txt        # User IDs for holdout (TODO)
│   ├── baselines/                   # Baseline model results
│   │   └── .gitkeep
│   ├── reports/                     # Generated eval reports (gitignored)
│   └── scripts/
│       ├── run_offline_eval.py      # Compute metrics (TODO)
│       ├── compare_models.py        # Model vs model (TODO)
│       └── generate_report.py       # HTML/markdown report (TODO)
│
├── flows/                           # Metaflow pipelines
│   ├── __init__.py
│   ├── train_flow.py                # Training pipeline (TODO)
│   ├── predict_flow.py              # Inference pipeline (TODO)
│   ├── eval_flow.py                 # Evaluation pipeline (TODO)
│   └── common.py                    # Shared flow utilities (TODO)
│
├── notebooks/                       # Jupyter/Colab prototypes
│   ├── exploration/                 # Data exploration
│   │   └── .gitkeep
│   └── experiments/                 # Model experiments
│       └── .gitkeep
│
├── scripts/                         # CLI entry points
│   ├── run_training.py              # Training script (TODO)
│   ├── run_inference.py             # Inference script (TODO)
│   ├── run_eval.py                  # Evaluation CLI
│   ├── validate_sql.py              # SQL syntax validation
│   └── sync_from_bq.py              # Download data locally (TODO)
│
├── specs/                           # Feature specifications (Plan mode)
│   ├── templates/
│   │   └── feature_spec.md          # Spec template
│   ├── active/                      # WIP specs
│   │   └── .gitkeep
│   └── completed/                   # Done specs
│       └── .gitkeep
│
├── sql/                             # BigQuery SQL files
│   └── recommendations/             # Domain: recommendations
│       ├── extract/                 # Data extraction queries
│       │   └── .gitkeep
│       ├── transform/               # Feature transformation queries
│       │   └── .gitkeep
│       ├── load/                    # Output table creation
│       │   └── .gitkeep
│       └── tests/                   # SQL validation queries
│           └── .gitkeep
│
├── src/                             # Production Python code
│   ├── __init__.py
│   ├── data/                        # Data operations
│   │   ├── __init__.py
│   │   ├── bq_client.py             # BigQuery wrapper
│   │   ├── extractors.py            # Data extraction (TODO)
│   │   └── loaders.py               # Data loading (TODO)
│   ├── features/                    # Feature engineering
│   │   ├── __init__.py
│   │   └── feature_engineering.py   # Feature logic (TODO)
│   ├── models/                      # ML models
│   │   ├── __init__.py
│   │   ├── base.py                  # Abstract base model (TODO)
│   │   └── als_model.py             # ALS implementation (TODO)
│   ├── evaluation/                  # Evaluation logic
│   │   ├── __init__.py
│   │   ├── metrics.py               # Precision, recall, NDCG, MAP
│   │   ├── splitters.py             # Train/test splitting
│   │   └── reporters.py             # Report generation
│   └── utils/                       # Shared utilities
│       ├── __init__.py
│       ├── config.py                # YAML config with env substitution
│       ├── gcs_utils.py             # GCS upload/download
│       └── wandb_utils.py           # W&B integration
│
├── tests/                           # Test suite
│   ├── __init__.py
│   ├── conftest.py                  # Pytest fixtures
│   ├── unit/                        # Fast, isolated tests
│   │   ├── __init__.py
│   │   └── test_metrics.py          # Evaluation metrics tests
│   ├── integration/                 # Tests with BQ/GCS
│   │   └── .gitkeep
│   └── e2e/                         # End-to-end tests
│       └── .gitkeep
│
├── artifacts/                       # Local model cache (gitignored)
│   └── .gitkeep
│
├── .env.example                     # Environment variables template
├── .gitignore                       # Git ignore rules
├── .python-version                  # Python version for uv (3.12)
├── Makefile                         # Common commands
└── pyproject.toml                   # Project dependencies
```

## Workflow: Plan → Code → Review

### 1. Plan Mode
Before implementing new features:
```bash
# Create a spec using the template
/plan <feature-name>
```
Specs go in `specs/active/` and must be approved before coding.

### 2. Code Mode
Implement from approved spec:
```bash
/implement <spec-name>
```
Follow conventions in `agent_docs/code_conventions.md`.

### 3. Review Mode
Before creating PR:
```bash
/review
```
Runs tests, linting, SQL validation, and evaluation.

## Make Commands

```bash
make setup           # Install dependencies with uv
make test            # Run all tests
make test-unit       # Run unit tests with coverage
make lint            # Run ruff and mypy
make format          # Format code with ruff
make sql-validate    # Validate SQL syntax
make eval            # Run offline evaluation
make train-dev       # Run training in dev mode
make clean           # Remove cache files
```

## Configuration

Environment variables (copy `.env.example` to `.env`):
```bash
PROJECT_ID=your-gcp-project-id
GCS_BUCKET=your-gcs-bucket
WANDB_API_KEY=your-wandb-key
```

Config files use `${VAR}` syntax for env substitution:
```yaml
# configs/dev.yaml
project_id: ${PROJECT_ID:-temp_holley_v5}
```

## Multi-Agent Support

This project supports multiple AI agents:
- **Claude Code**: Uses `CLAUDE.md` (symlink to `AGENTS.md`)
- **Gemini CLI**: Uses `GEMINI.md` (symlink to `AGENTS.md`)
- **Codex/Others**: Can read `AGENTS.md` directly

All agents share the same instructions via `AGENTS.md`.
