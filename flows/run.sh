#!/bin/bash
#
# Wrapper script to run Python scripts on Kubernetes via Metaflow.
#
# Usage:
#   ./flows/run.sh src/bandit_click_holley.py
#   ./flows/run.sh src/bandit_click_holley.py "--arg1 value1"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_ROOT/.venv-metaflow"

SCRIPT=$1
ARGS=${2:-""}

if [ -z "$SCRIPT" ]; then
  echo "Usage: $0 <python_script> [args]"
  echo ""
  echo "Examples:"
  echo "  $0 src/bandit_click_holley.py"
  echo "  $0 src/bandit_click_holley.py \"--days 30\""
  exit 1
fi

# Ensure script path is relative to project root
if [[ ! "$SCRIPT" = /* ]]; then
  SCRIPT="$PROJECT_ROOT/$SCRIPT"
fi

if [ ! -f "$SCRIPT" ]; then
  echo "Error: Script not found: $SCRIPT"
  exit 1
fi

# Create venv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating Metaflow virtual environment..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install metaflow kubernetes google-cloud-bigquery google-cloud-storage pandas numpy
fi

PYTHON="$VENV_DIR/bin/python"

echo "Configuring GCP environment for auxia-ml..."
gcloud config set project auxia-ml
gcloud container clusters get-credentials gke-metaflow-dev --region asia-northeast1 --project auxia-ml

# Configure Metaflow to use our config
export METAFLOW_HOME="$PROJECT_ROOT/configs/metaflow"

echo "Sending $SCRIPT to Kubernetes..."
echo ""

cd "$PROJECT_ROOT"
"$PYTHON" flows/metaflow_runner.py run \
  --script "$SCRIPT" \
  --args "$ARGS" \
  --pip "numpy,pandas,google-cloud-bigquery,db-dtypes" \
  --with kubernetes
