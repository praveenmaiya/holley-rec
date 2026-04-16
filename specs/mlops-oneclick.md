# Feature: MLOps One-Click

## Status
- [x] Draft
- [ ] In Review
- [ ] Approved
- [ ] In Progress
- [ ] Completed

## Problem Statement
You are already on GCP with a solid execution stack:
- Orchestration: Argo Workflows on GKE
- Pipeline runtime: Metaflow on GKE
- Data platform: BigQuery (heavy usage)
- Experiment workflows: Colab Enterprise + ad hoc scripts

The core problem is not missing infrastructure. The problem is missing a consistent control plane that lets a business analyst launch safe production runs with one click across many client/model variants.

Current operational pain:
- Too many manual handoffs (BA -> DS -> MLE -> MLOps) for each release.
- Different models/clients require custom run logic and manual parameter wiring.
- Deployment is slow and risky because validation, registration, canary, and monitoring are not enforced as one pipeline.
- Reproducibility and lineage are incomplete across code commit, dataset snapshot, model artifact, and endpoint version.
- Data freshness lag causes training-serving skew when online behavior changes faster than batch feature refresh.
- Drift/quality issues are detected late, and retraining is mostly manual.

## Data Requirements

### Input Data
| Table/Source | Columns Used | Purpose |
|--------------|--------------|---------|
| `BigQuery feature/event tables` | entity keys, feature columns, event timestamps | Training and validation datasets |
| `BigQuery model config tables` | client_id, model_id, hyperparams, enable flags | Drive parameterized runs |
| `Git repo + commit SHA` | commit, branch, workflow version | Reproducibility and rollback |
| `GCS model artifacts` | artifact URI, schema version | Registry and deployment input |
| `Secret Manager` | API keys, DB creds, webhook secrets | Secure runtime access |

### Output Data
| Table/Destination | Columns | Purpose |
|-------------------|---------|---------|
| `Vertex AI Model Registry` | model version metadata | Single source of truth for deployable models |
| `Vertex AI Endpoint` | endpoint ID, deployed model, traffic split | Managed serving and rollout control |
| `BigQuery release_manifest` | run_id, client_id, model_id, commit, data snapshot, endpoint, status | Audit, traceability, rollback |
| `Cloud Monitoring / Alerting` | drift metrics, error rate, latency alerts | Automated operational response |

### Data Volume
- Estimated input rows: client dependent (10M to 10B+ events/features)
- Estimated output rows: 1 release manifest row per run; model artifacts per version
- Processing frequency: on-demand one-click (with optional scheduled retraining)

## Approach
1. Keep Argo + Metaflow on GKE as the execution engine.
2. Add a standard one-click control layer that passes validated parameters (`client_id`, `model_family`, `environment`, `release_mode`) into a single Argo `WorkflowTemplate`.
3. Enforce fixed stages in workflow: data validation -> train/eval -> register -> deploy canary -> monitor gate -> promote/rollback.
4. Centralize lineage and governance in release metadata and Vertex AI registry/endpoint state.
5. Add automated drift and health-based retraining triggers.

## Reference Architecture

| Layer | Service | Responsibility |
|-------|---------|----------------|
| Trigger | Cloud Build (manual trigger / API) | One-click entry point with validated parameters |
| Orchestration | Argo Workflows (GKE) | End-to-end DAG execution and gating |
| Compute Runtime | Metaflow steps (GKE pods) | Train, evaluate, package, and publish model |
| Data Plane | BigQuery + Dataflow (+ optional Vertex Feature Store) | Offline/streaming feature readiness |
| Model Plane | Vertex AI Experiments + Model Registry + Endpoints | Tracking, versioning, serving, canary rollout |
| Governance | IAM Workload Identity + Secret Manager | Secure runtime auth, no JSON keys |
| Observability | Vertex Monitoring + Cloud Monitoring + Alerting | Drift, latency, error, and automated retrain trigger |

## One-Click Workflow (Target)
1. BA selects `client`, `model`, and `environment` in a simple trigger form.
2. Cloud Build starts Argo workflow with signed, validated parameters.
3. Argo runs preflight checks:
   - Config exists and is active
   - BigQuery source snapshot is available
   - Required secrets and IAM bindings are healthy
4. Metaflow executes training/evaluation and logs:
   - Parameters/metrics to Vertex Experiments
   - Artifact to GCS
5. Model is registered in Vertex Model Registry with labels:
   - `client_id`, `model_family`, `dataset_snapshot`, `git_sha`, `run_id`
6. Argo deploys canary to Vertex Endpoint (for example 5% traffic).
7. Gate period checks monitoring metrics (latency/error/drift/business KPI).
8. If gates pass, promote to 100%; else auto-rollback and mark run failed.
9. Write release record to `release_manifest` and notify stakeholders (Slack/Email).

## Guardrails (Non-Negotiable)
- No direct prod deploy without:
  - Data quality checks passed
  - Minimum offline metric thresholds passed
  - Canary health gate passed
- Every deployment must be reproducible via `run_id`.
- Secrets only from Secret Manager.
- Pod auth only through Workload Identity (no static key files).
- All prod changes must leave an immutable release manifest entry.

## Open Questions
- [ ] What exact BA-facing trigger UI do you prefer: Cloud Build form, internal portal, or Slack command?
- [ ] Should each client have dedicated endpoint(s), or shared multi-tenant endpoints with routing?
- [ ] What are mandatory promotion gates per model family (AUC/lift/CTR/revenue/safety)?
- [ ] What is acceptable rollback SLA after canary degradation detection?

## Success Criteria
- [ ] BA can launch a standard production release in one click without shell access.
- [ ] Median release time drops from ~90 minutes to <= 20 minutes.
- [ ] 100% of production models trace to commit + dataset snapshot + artifact + endpoint version.
- [ ] Canary rollout and rollback are fully automated for all supported model families.
- [ ] Drift alerts are active on all production endpoints.

## Evaluation Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Deploy lead time | ~90 min | <= 20 min |
| Manual handoffs per release | 3-5 | 0-1 |
| Reproducible releases | Partial | 100% |
| Canary coverage | Ad hoc | 100% |
| Drift detection coverage | Low/manual | 100% prod endpoints |

## Test Plan

### Unit Tests
- [ ] Validate parameter schema and policy checks for one-click trigger payload.
- [ ] Validate release manifest writer with required immutable fields.
- [ ] Validate rollback decision logic based on monitoring thresholds.

### Integration Tests
- [ ] Dry run end-to-end workflow in staging (`client_id` test tenant).
- [ ] Canary deployment simulation with forced failure to verify auto-rollback.
- [ ] Workload Identity and Secret Manager access verification from Argo and Metaflow pods.
- [ ] BigQuery-to-training snapshot consistency check in a reproducibility replay run.

## Dependencies
- [ ] Workload Identity configured for Argo and Metaflow service accounts.
- [ ] Secret Manager integration completed for runtime secrets.
- [ ] Vertex AI APIs enabled (Experiments, Registry, Endpoints, Monitoring).
- [ ] Standardized config schema for client/model definitions in BigQuery or Git.
- [ ] Cloud Monitoring alert routes (Slack/Email/PagerDuty) defined.

## Implementation Notes

### Phase 1 (Weeks 1-3): Reproducibility Foundation
- Build standardized run contract and release manifest.
- Enable Vertex Experiments logging and Model Registry publishing from Metaflow.
- Wire Workload Identity + Secret Manager in all workflow pods.

### Phase 2 (Weeks 4-7): Data Freshness and Consistency
- Define feature contracts and data snapshot policy.
- Add Dataflow streaming for the highest-impact near-real-time features.
- Introduce Feature Store only where online low-latency serving is needed.

### Phase 3 (Weeks 8-12): One-Click Production Rollout
- Build one-click trigger (Cloud Build/API) with parameter validation.
- Add canary + promotion/rollback gates in Argo.
- Enable endpoint drift monitoring with automated retraining trigger hook.

---
Created: 2026-02-18
Author: Codex
Approved by: [TBD]
