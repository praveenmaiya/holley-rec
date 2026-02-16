# Spec: GNN Option A — Vehicle Fitment Graph (HeteroGAT)

**Ticket:** [AUX-12314](https://linear.app/auxia/issue/AUX-12314)
**Status:** Draft
**Author:** Praveen Maiya

---

## 1. Problem

98% of Holley's email recipients have zero browsing or purchase history. The current SQL pipeline ranks products for these users by **global popularity within vehicle fitment** — a SQL JOIN on the fitment table ordered by order count. This ignores any structure in the product catalog beyond what the fitment table explicitly encodes.

**Hypothesis:** A Graph Neural Network trained on the vehicle fitment graph can learn embedding representations that capture product relationships (co-purchase patterns, fitment neighborhood structure) better than a popularity sort. Specifically, the GNN's 2-hop message passing (user → vehicle → product) may discover non-obvious product affinities that SQL misses.

**This is a hypothesis test, not a deployment plan.** Option A exists to answer one question: does graph structure add recommendation value beyond fitment JOIN + popularity?

---

## 2. Architecture

### Overview

```
BigQuery (source tables)
    ↓ export
Parquet files (nodes, edges, test set)
    ↓ build
PyG HeteroData graph
    ↓ train
HeteroGAT model (embeddings)
    ↓ score
Top-K recommendations per user
    ↓ evaluate
Metrics vs SQL baseline
    ↓ write (if eval passes)
BigQuery output table (same schema as SQL pipeline)
```

### Graph Schema

**Node types (3):**

| Node | Source | Count | Features |
|------|--------|-------|----------|
| User | `ingestion_unified_attributes` | ~475K | engagement_tier (cold/warm/hot) |
| Product | `import_items` + `import_orders` | ~25K | part_type (categorical), price, log_popularity, fitment_breadth |
| Vehicle | derived from user registrations + fitment | ~2K | user_count, product_count |

**Edge types (4, each stored bidirectionally = 8 message-passing directions):**

| Edge | Source | Weight | Notes |
|------|--------|--------|-------|
| user → product | `treatment_interaction` + `unified_events` | interaction type (view=1, cart=3, order=5) × time decay | Only exists for ~2% of users |
| user → vehicle | `ingestion_unified_attributes` (v1 YMM) | binary (1.0) | Every user has exactly one |
| product → vehicle | `vehicle_product_fitment_data` | binary (1.0) | Structural backbone — ~200-500 products per vehicle |
| product → product | `import_orders` (co-purchase) | log(co-purchase count), threshold ≥ 2 | Requires ≥2 users to have ordered both |

### Model

**HeteroGAT** (PyTorch Geometric):
- 2-layer `HeteroConv` with `GATConv` per edge type
- Learned embeddings: 128-dim per node type
- Product features: part_type embedding (16-dim) + price + log_popularity + fitment_breadth → MLP → 128-dim
- Projection towers: separate user and product MLPs → L2-normalized 128-dim output
- Scoring: dot product between user and product embeddings
- No LLM, no semantic features — pure graph topology + handcrafted features

---

## 3. Data Pipeline

### Input Tables

| Table | Dataset | What we extract |
|-------|---------|-----------------|
| `ingestion_unified_attributes_schema_incremental` | `auxia-gcp.company_1950` | User nodes: email, v1_year/make/model |
| `ingestion_unified_schema_incremental` | `auxia-gcp.company_1950` | User→product edges: views, carts, orders |
| `treatment_interaction` | `auxia-gcp.company_1950` | User→product edges: email clicks |
| `vehicle_product_fitment_data` | `auxia-gcp.data_company_1950` | Product→vehicle edges |
| `import_items` | `auxia-gcp.data_company_1950` | Product nodes: PartType, price |
| `import_items_tags` | `auxia-gcp.data_company_1950` | Product filter: exclude refurbished |
| `import_orders` | `auxia-gcp.data_company_1950` | Product→product co-purchase edges, popularity |

### Export Queries

Three SQL files export graph data to a working dataset (e.g., `auxia-reporting.temp_holley_gnn`):

1. **`export_nodes.sql`** — User, Product, Vehicle node tables with features
2. **`export_edges.sql`** — Four edge type tables with weights
3. **`export_test_set.sql`** — Held-out clicks for evaluation

### Time Windows

| Data | Window | Rationale |
|------|--------|-----------|
| Interaction edges (user→product) | Sep 1 2025 → T-30 days | Matches SQL pipeline boundary; excludes test window |
| Co-purchase edges (product→product) | All historical orders | More data = denser co-purchase graph |
| Fitment edges (product→vehicle) | Current snapshot | Structural, not temporal |
| Test set (evaluation clicks) | Last 30 days | Held-out future clicks to evaluate against |

### Data Scale

| Asset | Estimated size |
|-------|----------------|
| Node tables (3) | ~50 MB total (Parquet) |
| Edge tables (4) | ~200 MB total (Parquet) |
| PyG HeteroData graph | ~500 MB in memory |
| Trained model checkpoint | ~50 MB |
| Scoring output (475K × top-10) | ~100 MB |

---

## 4. Training

### Objective

Link prediction via embedding similarity. Learn user and product embeddings such that users are close to products they interacted with (positive edges) and far from products they didn't (negative samples).

### Loss

Binary cross-entropy on (positive, negative) edge pairs:
- Positive: existing user→product interaction edges, weighted by interaction type
- Negative: 50% in-batch negatives (other products in same mini-batch) + 50% global random products
- Edge weights: order (5×) > cart (3×) > view (1×)

### Training Configuration

| Parameter | Value | Notes |
|-----------|-------|-------|
| Embedding dim | 128 | Balance of expressiveness vs compute |
| Hidden dim | 256 | GATConv hidden layer |
| GAT heads | 4 | Multi-head attention |
| Layers | 2 | 2-hop message passing |
| Dropout | 0.1 | |
| Epochs | 100 (max) | Early stopping will trigger sooner |
| Early stopping patience | 10 epochs | On validation MRR |
| Optimizer | Dual Adam | Embedding LR: 0.001, GNN LR: 0.01 |
| Gradient clipping | max_norm=1.0 | |
| Batch size | 1024 edges | |

### Train/Val/Test Split

**Temporal split on edges** (not random):
- Training edges: interactions before T-30 days
- Validation: 10% of training edges held out (random)
- Test: clicks in last 30 days (separate export)

This prevents temporal leakage — the model never sees future interactions during training.

### Training Time Estimate

- Graph construction: ~5 min (CPU)
- Training: ~30-60 min (1× T4 GPU) for 100 epochs with early stopping
- Total wall time: ~1 hour

---

## 5. Scoring (Batch Inference)

### Approach: Fitment-Filtered Brute Force

For each user, score only products that fit their registered vehicle. This avoids scoring all 11.9B user×product pairs.

**Steps:**
1. Forward pass: compute all user embeddings (475K) and product embeddings (25K)
2. Group users by vehicle (~2K groups)
3. For each vehicle group: dot-product between group's user embeddings and eligible product embeddings
4. Per user: rank products by score, apply post-processing, keep top-K

**Post-processing (must match SQL pipeline):**
- Price floor: ≥ $50
- No refurbished, no service SKUs, no commodity parts
- Purchase exclusion: remove products ordered in last 365 days
- Variant deduplication: strip color suffixes (`[0-9][BRGP]$`), keep highest score
- Diversity cap: max 2 SKUs per PartType per user
- HTTPS image required

**Scale:**
- 475K users × ~300 avg eligible products = ~142M dot products
- Compute time: ~10-15 min on CPU (embarrassingly parallel by vehicle group)
- No FAISS needed at this scale

### Output Schema

Same as current SQL pipeline for drop-in compatibility:

```
email_lower STRING,
year STRING, make STRING, model STRING,
rec_part_1 STRING, rec1_price FLOAT64, rec1_score FLOAT64, rec1_image STRING,
rec_part_2 STRING, rec2_price FLOAT64, rec2_score FLOAT64, rec2_image STRING,
rec_part_3 STRING, rec3_price FLOAT64, rec3_score FLOAT64, rec3_image STRING,
rec_part_4 STRING, rec4_price FLOAT64, rec4_score FLOAT64, rec4_image STRING
```

Output table: `auxia-reporting.temp_holley_gnn.recommendations`

---

## 6. Offline Evaluation

### Test Set

Held-out clicks from the last 30 days: users who received an email treatment and clicked a product link. Exported from `treatment_interaction` with `interaction_type = 'CLICKED'`.

Expected test set size: ~2,000-5,000 click events across ~1,500-3,000 users.

### Metrics

| Metric | What it measures | Primary? |
|--------|------------------|----------|
| **Hit Rate@4** | Did the clicked product appear in the user's top 4 recs? | Yes — matches the 4 email slots |
| Recall@10 | Broader ranking quality | Secondary |
| Recall@20 | Coverage check | Secondary |
| MRR | How high is the first relevant product? | Secondary |
| NDCG@10 | Graded ranking quality | Secondary |

### Stratification

All metrics reported per engagement tier:

| Tier | Definition | Expected % | Why it matters |
|------|------------|------------|----------------|
| Cold | Zero interactions (no views, carts, orders) | ~98% | This is the target population |
| Warm | Has views but no carts/orders | ~1.5% | |
| Hot | Has carts or orders | ~0.5% | Strongest GNN signal |

### Baseline Comparison

Run the SQL pipeline on the same test window. For each user in the test set, compare:
- SQL's top-4 recommendations vs GNN's top-4 recommendations
- Which set contains the actually-clicked product more often?

Report as: `GNN Hit Rate@4 - SQL Hit Rate@4` = delta. Positive = GNN wins.

### Statistical Significance

With ~2,000 test clicks, a 2% absolute difference in Hit Rate@4 is detectable at p < 0.05 (McNemar's test on paired binary outcomes). Smaller effects will be in the noise.

---

## 7. Serving

### How Results Reach Users

```
GNN output (BigQuery table)
    ↓ Auxia ingestion
User attributes (rec_part_1..4, scores, images)
    ↓ Treatment selection
Email personalization (4 product slots)
```

The GNN writes to the same BigQuery table schema as the SQL pipeline. Auxia's existing ingestion treats this as user attributes. No serving infrastructure changes needed.

### Deployment Strategy

**Phase 1 (offline eval):** GNN writes to a shadow table. Compare offline metrics. No user-facing impact.

**Phase 2 (if eval passes):** A/B test — 50% of users get SQL recs, 50% get GNN recs. Measure CTR, conversion, revenue per send over 2-4 weeks.

**Phase 3 (if A/B wins):** GNN replaces SQL as the primary pipeline. SQL remains as fallback.

---

## 8. Metaflow Deployment

### Pipeline Steps

```python
class GNNRecommendationFlow(FlowSpec):

    @step                          # CPU, 4GB
    def start(self):
        """Load config, validate parameters."""

    @step                          # CPU, 8GB
    def export_data(self):
        """BigQuery → Parquet (nodes, edges, test set)."""

    @step                          # CPU, 16GB
    def build_graph(self):
        """Parquet → PyG HeteroData."""

    @kubernetes(gpu=1, memory=32768, cpu=8)
    @step
    def train(self):
        """HeteroGAT training with early stopping."""

    @kubernetes(memory=32768, cpu=16)
    @step
    def score(self):
        """Batch inference: embeddings → fitment-filtered top-K."""

    @step                          # CPU, 8GB
    def evaluate(self):
        """Compare GNN vs SQL baseline on held-out clicks."""

    @step                          # CPU, 4GB
    def write_output(self):
        """Write recommendations to BigQuery."""

    @step
    def end(self):
        """Log results, clean up."""
```

### Resource Requirements

| Step | CPU | Memory | GPU | Duration |
|------|-----|--------|-----|----------|
| export_data | 4 | 8 GB | - | ~5 min |
| build_graph | 4 | 16 GB | - | ~5 min |
| train | 8 | 32 GB | 1× T4 | ~30-60 min |
| score | 16 | 32 GB | - | ~10-15 min |
| evaluate | 4 | 8 GB | - | ~2 min |
| write_output | 4 | 4 GB | - | ~3 min |
| **Total** | | | | **~60-90 min** |

### Schedule

| Phase | Frequency | What runs |
|-------|-----------|-----------|
| Initial | One-time | Full pipeline: export → train → score → evaluate |
| Production (if approved) | Weekly | Full retrain + score |
| Production (daily option) | Daily | Score only (reuse latest model checkpoint) |

### Infrastructure

| Component | Value |
|-----------|-------|
| Cluster | `gke-metaflow-dev` (auxia-ml, asia-northeast1) |
| Service account | `ksa-metaflow` |
| Datastore | `gs://storage-auxia-ml-metaflow-dev/` (GCS) |
| Model artifacts | `gs://storage-auxia-ml-metaflow-dev/gnn/checkpoints/` |
| Python | 3.12+ |
| Key packages | torch, torch-geometric, torch-sparse, torch-scatter, pyarrow, google-cloud-bigquery |

### Package Structure

Core GNN logic lives in `auxia.prediction.colab` (per Sumeet's comment) or the existing `src/gnn/` module:

```
src/gnn/
    __init__.py
    data_loader.py      # BigQuery ↔ Parquet I/O
    graph_builder.py    # DataFrame → PyG HeteroData
    model.py            # HeteroGAT definition
    trainer.py          # Training loop + checkpointing
    evaluator.py        # Metrics + baseline comparison
    scorer.py           # Batch inference + post-processing
```

Flow definition: `flows/train_gnn.py`
Config: `configs/gnn_config.yaml`
SQL exports: `sql/gnn/export_nodes.sql`, `export_edges.sql`, `export_test_set.sql`

---

## 9. Experiment Tracking

### Per-Run Logging

Every Metaflow run logs to MLflow (existing integration):

| What | Where | Format |
|------|-------|--------|
| Hyperparameters | MLflow params | All values from `gnn_config.yaml` |
| Training curves | MLflow metrics | train_loss, val_loss, val_mrr per epoch |
| Eval results | MLflow metrics | Hit Rate@4, Recall@{10,20}, MRR, NDCG@10 per tier |
| Model checkpoint | GCS | `gs://.../gnn/checkpoints/{run_id}/model.pt` |
| Graph snapshot | GCS | `gs://.../gnn/data/{run_id}/heterodata.pt` |
| Metaflow run ID | MLflow tags | Links back to Metaflow UI for step-level debugging |

### Experiment Comparison

Track across runs:
- Config diff (what changed between runs)
- Metric delta vs SQL baseline (per tier)
- Graph stats: node counts, edge counts, density — to detect data pipeline regressions

### W&B (optional)

If W&B is preferred over MLflow, swap the logger. Both are in the project's stack. No architectural impact.

---

## 10. Monitoring & Fallback

### Failure Handling

| Failure | Detection | Fallback |
|---------|-----------|----------|
| Metaflow job fails (OOM, GPU error) | Metaflow alerts / K8s pod status | SQL pipeline continues serving. GNN output table is not updated. |
| GNN output fails QA checks | `qa_checks.sql` run in evaluate step | Do not write to output table. Alert. SQL recs remain active. |
| Model quality degrades (metrics drop) | Eval step compares to previous run's metrics | Do not promote. Keep previous model checkpoint. |
| Stale recommendations (job didn't run) | Output table timestamp > 7 days old | Alert. SQL pipeline is always available as fallback. |

### Data Freshness

| Schedule | Max staleness | Acceptable? |
|----------|---------------|-------------|
| Weekly retrain + score | 7 days | Yes for email recs — product catalog and fitment change slowly |
| Daily score (reuse model) | 1 day for scores, 7 days for model | Better for interaction-driven users, but ~2% benefit |

The SQL pipeline runs independently and remains the production fallback at all times. GNN never replaces SQL without an explicit promotion step.

---

## 11. Open Questions for Sumeet

| # | Question | Impact on spec |
|---|----------|----------------|
| 1 | **`auxia.prediction.colab` package**: Should GNN code live in this package (Auxia monorepo), or stay in `holley-rec/src/gnn/` and be pip-installed on K8s pods? | Determines package structure (§8) |
| 2 | **Feature store**: Should GNN embeddings be written to Google Cloud Feature Store, or is BigQuery sufficient as the output layer? | Determines serving path (§7) |
| 3 | **GPU availability**: Does `gke-metaflow-dev` have T4/V100 GPU node pools, or do we need to request them? | Determines training step feasibility (§8) |
| 4 | **A/B infrastructure**: When we reach Phase 2, does Auxia have split-test infrastructure for user attributes, or do we need to build it? | Determines deployment strategy (§7) |

---

## 12. Success Criteria

### Go / No-Go Thresholds

| Outcome | GNN vs SQL Hit Rate@4 (cold users) | Decision |
|---------|-------------------------------------|----------|
| Clear win | ≥ +3% absolute | Proceed to A/B test |
| Marginal | +1% to +3% | Proceed to Option A+ (add semantic embeddings), re-evaluate |
| Neutral | -1% to +1% | Graph topology alone doesn't help. Skip to A+. |
| Worse | < -1% | Investigate why. Likely overfitting to sparse warm-user signal. |

### Acceptance Criteria for Output Quality

Before any A/B test, the GNN output must pass the same QA checks as the SQL pipeline:

- [ ] ≥ 450K users with recommendations
- [ ] 0 duplicate SKUs per user
- [ ] 0 refurbished or service SKUs
- [ ] All prices ≥ $50
- [ ] All images HTTPS
- [ ] Score ordering: rec1 ≥ rec2 ≥ rec3 ≥ rec4
- [ ] Max 2 SKUs per PartType per user
- [ ] No products purchased in last 365 days

---

## 13. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| GNN ≈ SQL for cold users (null result) | High | Low — expected outcome, fast and cheap to learn | Budget for this. Have A+ ready as next step. |
| Sparse interaction edges cause overfitting | Medium | Medium — warm-user patterns don't transfer to cold | Monitor train/val gap. Use dropout, early stopping. |
| Test set too small for significance | Medium | Medium — can't distinguish signal from noise | Need ≥ 2,000 test clicks. If fewer, extend test window. |
| Temporal leakage inflates offline metrics | Low | High — false positive → wasted A/B test | Strict temporal split. Test set = future clicks only. |
| PyG/torch version conflicts on K8s | Low | Low — delays, not blockers | Pin versions in requirements. Test locally first. |
| Fitment post-processing mismatch | Medium | High — unfair comparison if GNN skips filters | Implement identical post-processing. Run QA checks. |

---

## 14. What This Spec Does NOT Cover

- **Semantic enrichment (Option A+)** — LLM-generated product embeddings. Separate spec if A shows promise.
- **Online A/B test design** — split strategy, duration, power analysis. Separate doc if offline eval passes.
- **Multi-tenant abstraction** — Holley-specific for now. Generalization deferred.
- **Real-time inference** — batch only. No serving infrastructure.
- **Cost estimates** — covered in [AUX-12314 ticket](https://linear.app/auxia/issue/AUX-12314) discussion.
