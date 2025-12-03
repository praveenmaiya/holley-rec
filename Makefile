.PHONY: setup test test-unit test-integration lint format sql-validate eval clean help

# Setup
setup:
	uv sync --all-extras
	uv run pre-commit install

# Testing
test:
	uv run pytest tests/ -v

test-unit:
	uv run pytest tests/unit/ -v --cov=src --cov-report=term-missing

test-integration:
	uv run pytest tests/integration/ -v -m integration

test-e2e:
	uv run pytest tests/e2e/ -v -m e2e

# Linting
lint:
	uv run ruff check src/ tests/ flows/ scripts/
	uv run mypy src/

format:
	uv run ruff format src/ tests/ flows/ scripts/
	uv run ruff check --fix src/ tests/ flows/ scripts/

# SQL
sql-validate:
	uv run python scripts/validate_sql.py --all

sql-test:
	uv run python scripts/validate_sql.py --run-tests

# Evaluation
eval:
	uv run python scripts/run_eval.py --config configs/dev.yaml

eval-compare:
	uv run python evals/scripts/compare_models.py

# Data
sync-data:
	uv run python scripts/sync_from_bq.py --limit 10000 --output data/raw/

# Training
train-dev:
	uv run python scripts/run_training.py --config configs/dev.yaml --test-mode

train-staging:
	uv run python flows/train_flow.py run --config staging

# Notebooks
nb-clean:
	uv run jupyter nbconvert --clear-output --inplace notebooks/**/*.ipynb 2>/dev/null || true

# Clean
clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	rm -rf build/ dist/ *.egg-info/

# Help
help:
	@echo "Available targets:"
	@echo "  setup           - Install dependencies with uv and pre-commit hooks"
	@echo "  test            - Run all tests"
	@echo "  test-unit       - Run unit tests with coverage"
	@echo "  test-integration- Run integration tests"
	@echo "  lint            - Run ruff and mypy"
	@echo "  format          - Format code with ruff"
	@echo "  sql-validate    - Validate SQL syntax"
	@echo "  eval            - Run offline evaluation"
	@echo "  train-dev       - Run training in dev mode"
	@echo "  clean           - Remove cache files"
