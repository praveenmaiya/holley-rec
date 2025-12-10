# Metaflow K8s Runner

Run Python scripts on Kubernetes via Metaflow.

## Prerequisites

1. **Python 3.10+** installed
2. **gcloud CLI** installed and authenticated:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
3. **Access to auxia-ml project** (GKE cluster `gke-metaflow-dev`)

## Setup (One-time per machine)

No manual setup required. On first run, `run.sh` will:
- Create `.venv-metaflow/` with required packages
- Configure kubectl for `gke-metaflow-dev` cluster

## Usage

```bash
# Run any Python script on K8s
./flows/run.sh src/bandit_click_holley.py

# With arguments
./flows/run.sh src/my_script.py "--days 30 --verbose"
```

## What happens

1. Script configures gcloud project to `auxia-ml`
2. Gets K8s credentials for `gke-metaflow-dev`
3. Metaflow embeds your script and sends it to K8s
4. Packages (numpy, pandas, google-cloud-bigquery) are installed on the pod
5. Output streams back to your terminal

## Files

| File | Purpose |
|------|---------|
| `metaflow_runner.py` | Metaflow flow that runs scripts on K8s |
| `run.sh` | Wrapper script |
| `../configs/metaflow/config.json` | K8s cluster config |

## Troubleshooting

**"gcloud: command not found"**
```bash
# Install gcloud CLI: https://cloud.google.com/sdk/docs/install
```

**"ModuleNotFoundError" on K8s pod**
- Add missing packages to `--pip` in `run.sh` line 61

**"Permission denied" on GCS**
- Ensure you have access to `auxia-ml` project
- Run `gcloud auth application-default login`

## Adding new scripts

1. Create your script in `src/`
2. Run: `./flows/run.sh src/your_script.py`

Scripts should be self-contained - all imports must be available via pip.
