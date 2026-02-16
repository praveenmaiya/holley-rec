# GNN + LLM Recommendation System Proposal

**Author:** Praveen M | **Date:** February 2026 | **Status:** Proposal
**Audience:** Engineering Leadership + Implementation Engineers
**Supersedes:** `gnn_architecture_proposal.md`, `gnn_meeting_talking_points.md`, `specs/gnn_recommendation_system.md`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Industry Landscape](#2-industry-landscape)
3. [System Architecture](#3-system-architecture)
4. [Graph Schema Design](#4-graph-schema-design)
5. [Model Architecture](#5-model-architecture)
6. [Database Design](#6-database-design)
7. [Metaflow Pipeline Design](#7-metaflow-pipeline-design)
8. [Platform Integration](#8-platform-integration)
9. [Cold-Start Strategy](#9-cold-start-strategy)
10. [Multi-Tenant Design](#10-multi-tenant-design)
11. [Evaluation & Experimentation](#11-evaluation--experimentation)
12. [Cost Model](#12-cost-model)
13. [Phased Rollout](#13-phased-rollout)
14. [Appendix](#14-appendix)

---

## 1. Executive Summary

### What

A production recommendation platform combining Graph Neural Networks (GNN) with Large Language Model (LLM) integration, built as a generic multi-tenant system with Holley (automotive aftermarket) as the first customer.

### Why

The current SQL pipeline (v5.17, 1,105 lines) hits a hard ceiling. It delivers vehicle-fitment-filtered product recommendations via email, but SQL cannot:

- **Learn user similarity** — no way to discover "users with similar vehicles buy similar parts"
- **Propagate intent through graphs** — a view on product A cannot boost product B even if they're co-purchased 90% of the time
- **Generate semantic understanding** — product descriptions are unused; "high-performance carburetor" and "racing carb" are unrelated strings
- **Handle cold-start structurally** — 98% of users have zero intent events and receive pure popularity fallbacks

### Expected Impact

| Metric | Target | Basis |
|--------|--------|-------|
| Recall@10 (offline) | +5-10% vs SQL | Faire: +10.5% recall@10 vs factorization machines |
| CTR (online) | +10% | Faire: +4.85% order lift; Zalando: +0.6pp AUC |
| Cold-start coverage | 98% → 98% (better quality) | Vehicle-mediated embedding transfer |
| Recommendation diversity | +15% unique products | Embedding space diversity vs popularity concentration |

### Investment

| Item | Cost |
|------|------|
| Compute (Phase 1: GNN only) | ~$70/month |
| Compute (Phase 2: +Semantic) | ~$75/month |
| Compute (Phase 3: +Reranking, peak) | ~$125/month |
| Compute (Phase 4: Steady-state) | ~$75/month |
| Timeline | 12-16 weeks, phased with go/no-go gates |
| Staffing | 1 engineer |
| Per additional customer | +$50-70/month |

### Key Differentiator

Holley's vehicle fitment graph is a **structural cold-start killer**. While 98% of users have no behavioral data, every user has a registered vehicle. Through 2 layers of GNN message passing, cold users receive embedding signal from their vehicle's product compatibility AND similar vehicle owners' behavior — something SQL popularity fallbacks cannot replicate.

---

## 2. Industry Landscape

### The 4-Stage RecSys + LLM Framework

Eugene Yan's framework (AI Engineer World's Fair 2025) defines four stages where LLMs enhance recommendation systems. Each stage has independent value:

```
Stage 1: Semantic Enrichment   → LLM generates product descriptions → embeddings
Stage 2: Hybrid Retrieval      → GNN + SQL + semantic signals combined
Stage 3: LLM Re-Ranking        → Re-rank top candidates with reasoning
Stage 4: Distillation           → Train small model on LLM outputs → zero marginal cost
```

We implement all four stages, phased so each has its own go/no-go gate.

### Production Case Studies

| Company | Architecture | Scale | Result | Source |
|---------|-------------|-------|--------|--------|
| **Faire** | Two-tower HeteroGAT | 3M retailers, 11M products | +4.85% order lift, +25.8% recall@10 from time-decay | [craft.faire.com](https://craft.faire.com/graph-neural-networks-at-faire-386024e5a6d9) |
| **Zalando** | GNN embeddings as features | Fashion e-commerce | +0.6pp AUC, 40% less feature engineering | [engineering.zalando.com](https://engineering.zalando.com/posts/2024/12/gnn-recommendations-zalando.html) |
| **Pinterest** | OmniSage (heterogeneous) | 5.6B nodes | ~2.5% sitewide repins | [Pinterest Engineering](https://medium.com/pinterest-engineering) |
| **LinkedIn** | LiGNN + Cross-Domain | 8.6B nodes | +8% AUC from cross-domain signals | LinkedIn Engineering Blog |
| **YouTube** | PLUM (Semantic IDs) | Billions | +4.96% CTR Shorts, 13x coverage | Google Research |
| **Netflix** | UniCoRn (Unified Ranker) | Multi-task | +10% rec quality, +7% search | Netflix Tech Blog |
| **ContextGNN** | Hybrid repeat+explore | ICLR 2025 | +20% avg on RelBench | [arxiv.org](https://arxiv.org/abs/2502.06148) |

### Why HeteroGAT Over ContextGNN

ContextGNN (ICLR 2025) shows impressive benchmarks (+20% avg on RelBench) with its hybrid repeat/exploratory architecture. We evaluated it but selected HeteroGAT for three reasons:

1. **Production track record**: Faire deployed HeteroGAT at scale with measured business impact (+4.85% orders). ContextGNN has academic benchmarks only.
2. **Holley's data profile**: 98% cold-start users have no repeat purchase patterns. ContextGNN's repeat-purchase module would be inactive for nearly all users.
3. **Complexity vs risk**: HeteroGAT is simpler to debug, monitor, and iterate on. ContextGNN's dual-pathway architecture adds operational complexity without clear benefit for our user profile.

### Why Full 4-Stage From Day 1

Each stage has independent value and its own go/no-go gate:

- **Stage 1 (Semantic Enrichment)** improves cold-start immediately — products with no purchase history get meaningful embeddings from LLM-generated descriptions
- **Stage 2 (GNN + Hybrid Retrieval)** is the core value proposition
- **Stage 3 (LLM Re-Ranking)** applies only to the 2% of warm+hot users where the payoff is highest
- **Stage 4 (Distillation)** eliminates ongoing LLM costs while preserving quality

Designing for all four from the start avoids costly architectural retrofits. Building Stage 2 without Stage 1's embedding columns in the schema would require a migration later.

---

## 3. System Architecture

### End-to-End Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           BigQuery Source Tables                                │
│  auxia-gcp.company_1950: attributes, events, treatment_history, interactions   │
│  auxia-gcp.data_company_1950: fitment, catalog, orders                         │
└──────────────────┬──────────────────────────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
┌───────────────┐    ┌────────────────────┐
│ Stage 1       │    │ Stage 2            │
│ SEMANTIC      │    │ GRAPH CONSTRUCTION │
│ ENRICHMENT    │    │ + GNN TRAINING     │
│               │    │                    │
│ LLM batch →   │    │ SQL export →       │
│ descriptions  │    │ Parquet → GCS →    │
│ → SentenceTF  │    │ HeteroData →       │
│ → 384-dim emb │    │ HeteroGAT train    │
│ (weekly, CPU) │    │ → 128-dim emb      │
│               │    │ (weekly, GPU)      │
└───────┬───────┘    └────────┬───────────┘
        │                     │
        └──────────┬──────────┘
                   ▼
        ┌────────────────────┐
        │ Stage 3            │
        │ HYBRID RETRIEVAL   │
        │ + SCORING          │
        │                    │
        │ GNN emb + semantic │
        │ + SQL popularity   │
        │ + recency →        │
        │ FAISS top-K →      │
        │ business rules     │
        │ (daily, CPU)       │
        └────────┬───────────┘
                 │
                 ▼
        ┌────────────────────┐
        │ Stage 4            │
        │ LLM RE-RANKING     │
        │ + DISTILLATION     │
        │                    │
        │ Re-rank top-20     │
        │ for warm+hot users │
        │ → distill to MLP   │
        │ (daily, CPU)       │
        │ [Phase 2+]         │
        └────────┬───────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  BigQuery: final_recommendations (backward-compatible wide format)              │
│  → Auxia Treatment System → Thompson Sampling Bandit → Email Delivery          │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Stage 1 — Semantic Enrichment (offline, weekly)

**Purpose:** Give every product a dense semantic representation, solving the "no purchase history" problem.

- LLM batch generates product descriptions for the catalog (~25K products)
  - Input: PartType, price, fitment breadth, product name
  - Output: 2-3 sentence natural language description
  - Cost: ~$7/run (incremental — only new/updated products)
- SentenceTransformer (`all-MiniLM-L6-v2`, 384-dim) encodes descriptions into embeddings
- Stored as continuous node features in the graph
- **Value:** Products with no purchase history get meaningful embeddings. "High-performance 4-barrel carburetor for classic muscle cars" clusters near other carburetors in embedding space.

### Stage 2 — Graph Construction + GNN Training (weekly, GPU)

**Purpose:** Learn user and product embeddings that capture structural relationships SQL cannot represent.

- SQL exports node and edge tables to BigQuery staging tables
- Export to Parquet → upload to GCS
- `GenericGraphBuilder`: DataFrame → PyG `HeteroData` with config-driven schema
- HeteroGAT training: 2-layer `HeteroConv` wrapping `GATConv`, 4 attention heads, dual optimizer
- Faire techniques: edge-weighted BCE, time-decay (30-day halflife), mixed negative sampling
- **Output:** 128-dim L2-normalized user and product embeddings

### Stage 3 — Hybrid Retrieval + Scoring (daily, CPU)

**Purpose:** Combine GNN, semantic, and SQL signals with business rules to produce final recommendations.

- Load trained model, generate embeddings for all users/products
- FAISS `ApproxMIPSKNNIndex` for top-100 candidates per user
- Hybrid score blending:
  ```
  hybrid_score = w_gnn × gnn + w_sem × semantic + w_pop × popularity + w_rec × recency
  (weights vary by engagement tier — see tier-specific blending below)
  ```
- Apply business rules (identical to SQL v5.17):
  - Vehicle fitment filter
  - 365-day purchase exclusion
  - Variant deduplication (`[0-9][BRGP]$` → strip suffix)
  - Diversity cap: max 2 SKUs per PartType
  - Min price $50, HTTPS image required
- **Output:** `final_recommendations` in backward-compatible wide format

### Stage 4 — LLM Re-Ranking + Distillation (Phase 2+)

**Purpose:** Use LLM reasoning to improve recommendation quality for engaged users, then distill to eliminate LLM costs.

- Re-rank top-20 for warm+hot users only (2% of base = ~9,500 users, ~$12/run)
- Cold users (98%) get hybrid score directly — they lack the interaction history needed for meaningful LLM reasoning
- Distill LLM preferences into a 2-layer MLP student model (259→128→1)
  - Input: concatenated user embedding (128-dim) + product embedding (128-dim) + 3 features (gnn_score, semantic_score, popularity)
  - Trains on accumulated LLM rankings (~190K examples/week)
  - After ~4 weeks: student replaces LLM for ALL users at zero marginal cost

### PyG Classes Used

| Component | PyG Class | Version |
|-----------|-----------|---------|
| Graph storage | `HeteroData` | 2.0+ |
| Message passing | `HeteroConv` wrapping `GATConv` | 2.0+ |
| Mini-batch training | `LinkNeighborLoader` | 2.1+ |
| ANN retrieval | `ApproxMIPSKNNIndex` | 2.4+ |
| Text encoding | `torch_geometric.nn.nlp.SentenceTransformer` | 2.5+ |
| Metrics | `LinkPredNDCG`, `HitRatio` | 2.4+ |
| Coverage/Diversity | Custom (see `src/gnn/evaluator.py`) | — |

---

## 4. Graph Schema Design

### Generic Schema System

The graph schema is defined in configuration, not code. A `GraphSchema` dataclass describes arbitrary node and edge types:

```python
@dataclass
class NodeSpec:
    table: str                          # BigQuery source table
    id_column: str                      # Primary key column
    categorical_features: dict[str, int]  # feature_name → embedding_dim
    continuous_features: list[str]       # column names
    semantic_text_template: str | None   # LLM description template

@dataclass
class EdgeSpec:
    source_type: str
    target_type: str
    relation: str
    weight_column: str | None           # None = binary
    add_reverse: bool = True            # Auto-create rev_ edges
    bidirectional: bool = False         # Same weight in both directions

@dataclass
class GraphSchema:
    nodes: dict[str, NodeSpec]          # node_type → spec
    edges: list[EdgeSpec]
    query_node_type: str = "user"       # For evaluation
    item_node_type: str = "product"     # For evaluation
```

This schema drives `GenericGraphBuilder`, which converts DataFrames into PyG `HeteroData` without any customer-specific code.

### Holley Instantiation

**Nodes:**

| Type | Count | Categorical Features | Continuous Features |
|------|-------|---------------------|---------------------|
| user | ~475K | engagement_tier (3 values, 32-dim emb) | — |
| product | ~25K | part_type (~200 values, 32-dim emb) | price, log_popularity, fitment_breadth, semantic_embedding (384-dim) |
| vehicle | ~2K | — | user_count, product_count |

**Edges (4 declared → 7 actual with reverses):**

| Edge | Relation | Weight | Reverse |
|------|----------|--------|---------|
| user → product | `interacts` | time-decayed: `base × exp(-days/30)` | `rev_interacts` |
| product → vehicle | `fits` | binary (from fitment catalog) | `rev_fits` |
| user → vehicle | `owns` | binary (from v1 registration) | `rev_owns` |
| product ↔ product | `co_purchased` | `log(1 + count)`, threshold ≥2 | bidirectional |

**Edge weight details:**

| Interaction | Base Weight | Example (7 days old) | Example (60 days old) |
|-------------|------------|---------------------|----------------------|
| view | 1.0 | 0.79 | 0.25 |
| cart | 3.0 | 2.37 | 0.74 |
| order | 5.0 | 3.95 | 1.23 |

Time-decay was Faire's single biggest improvement: +25.8% recall@10.

### Multi-Customer Example: Fashion E-Commerce

To demonstrate genericity, here's what a fashion customer's schema looks like — zero Python code changes:

**Nodes:**

| Type | Categorical | Continuous |
|------|------------|------------|
| user | age_bucket, gender | lifetime_value |
| product | category, brand, color | price, log_popularity |
| store | region | avg_order_value |

**Edges:**

| Edge | Relation | Weight |
|------|----------|--------|
| user → product | `interacts` | time-decayed |
| user → product | `purchased` | binary |
| product ↔ product | `same_brand` | binary |
| user → store | `shops_at` | frequency |

No vehicle nodes, no fitment edges — the `GenericGraphBuilder` handles this automatically from the YAML config.

---

## 5. Model Architecture

### Layer-by-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 0: NODE FEATURE ENCODING                                  │
│                                                                 │
│ User:    engagement_tier → Embedding(3, 32) → MLP → 128-dim    │
│ Product: part_type → Embedding(200, 32)                         │
│          + [price, log_pop, fitment_breadth] (3-dim)            │
│          + semantic_embedding (384-dim)                          │
│          → MLP(419, 256, 128) → 128-dim                        │
│ Vehicle: [user_count, product_count] → MLP(2, 64, 128) → 128   │
│                                                                 │
│ + nn.Embedding(num_nodes, 128) added as residual                │
└──────────────────────────┬──────────────────────────────────────┘
                           │ x_dict: {user: [475K, 128],
                           │          product: [25K, 128],
                           │          vehicle: [2K, 128]}
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: HeteroConv (7 independent GATConv modules)             │
│                                                                 │
│ (user, interacts, product):      GATConv(128→64, heads=4)=256  │
│ (product, rev_interacts, user):  GATConv(128→64, heads=4)=256  │
│ (product, fits, vehicle):        GATConv(128→64, heads=4)=256  │
│ (vehicle, rev_fits, product):    GATConv(128→64, heads=4)=256  │
│ (user, owns, vehicle):           GATConv(128→64, heads=4)=256  │
│ (vehicle, rev_owns, user):       GATConv(128→64, heads=4)=256  │
│ (product, co_purchased, product):GATConv(128→64, heads=4)=256  │
│                                                                 │
│ Aggregation: sum | Activation: ELU | Dropout: 0.1              │
└──────────────────────────┬──────────────────────────────────────┘
                           │ x_dict: {user: [475K, 256],
                           │          product: [25K, 256],
                           │          vehicle: [2K, 256]}
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: HeteroConv (same structure as Layer 1)                 │
│                                                                 │
│ 7× GATConv(256→64, heads=4) = 256-dim                         │
│ Activation: ELU (no dropout on final layer)                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
┌─────────────────────┐   ┌─────────────────────┐
│ User Tower          │   │ Product Tower        │
│ Linear(256, 256)    │   │ Linear(256, 256)     │
│ ReLU                │   │ ReLU                 │
│ Dropout(0.1)        │   │ Dropout(0.1)         │
│ Linear(256, 128)    │   │ Linear(256, 128)     │
│ L2 Normalize        │   │ L2 Normalize         │
└─────────┬───────────┘   └─────────┬───────────┘
          │                         │
          │   ┌─────────────────┐   │
          └──→│  Dot Product    │←──┘
              │  score ∈ [-1,1] │
              └─────────────────┘
```

**Why 2 layers?** Two layers of message passing enable the critical path: `User → owns → Vehicle → rev_fits → Product`. This allows cold users to receive product signal through their vehicle, which is the core cold-start mechanism.

### Hyperparameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `embedding_dim` | 128 | Faire's dimension; sufficient for 25K products |
| `hidden_dim` | 256 | 4 heads × 64-dim per head |
| `num_heads` | 4 | Attention heads per GATConv layer |
| `num_layers` | 2 | Enables User→Vehicle→Product path |
| `dropout` | 0.1 | Conservative for sparse data |
| `emb_lr` | 0.001 | Stability for sparse embedding gradients |
| `gnn_lr` | 0.01 | Faster convergence for dense conv layers |
| `time_decay_halflife` | 30 days | Faire's biggest single improvement |
| `neg_ratio` | 50% in-batch / 50% random | Balance hard + diverse negatives |
| `patience` | 10 | Early stopping epochs |
| `max_grad_norm` | 1.0 | Gradient clipping |

### Loss Function

Edge-weighted Binary Cross-Entropy with mixed negative sampling:

```python
pos_loss = -log(sigmoid(score(u, p_pos))) × edge_weight
neg_loss = -log(sigmoid(-score(u, p_neg)))
loss = mean(pos_loss + neg_loss) / 2
```

Edge weights encode interaction strength AND time recency:
```
weight = base_weight × exp(-days_since_event / halflife)
```

Where `base_weight`: view=1.0, cart=3.0, order=5.0.

### Training Strategy

- **Full-graph for Holley v1**: ~475K users + 25K products + 2K vehicles fits in GPU memory (A10: 24GB)
- **Migrate to `LinkNeighborLoader` when**: graph exceeds ~10M edges or memory exceeds 20GB
- **Dual optimizer**: embedding parameters at LR=0.001 (sparse, needs stability), GNN/MLP at LR=0.01 (dense, faster convergence)
- **Warm-start retraining**: weekly retrain loads previous checkpoint, preventing embedding drift

---

## 6. Database Design

### BigQuery Dataset Organization (Per Customer)

```
auxia-reporting.graph_{company_id}         — Graph construction tables
auxia-reporting.embeddings_{company_id}    — User/product/semantic embeddings
auxia-reporting.scoring_{company_id}       — Scored recommendations
auxia-reporting.meta_{company_id}          — Model registry, snapshots, experiments
```

Separate datasets per customer enable:
- IAM access control at dataset granularity
- Automatic cost attribution via billing labels
- Independent TTL policies
- Operational isolation (one customer's spike doesn't affect others)

### Graph Tables

```sql
-- Graph node table (one per node type)
CREATE TABLE `auxia-reporting.graph_1950.nodes_user` (
  node_id         STRING NOT NULL,
  engagement_tier STRING,            -- cold/warm/hot
  v1_year         STRING,
  v1_make         STRING,
  v1_model        STRING,
  snapshot_date   DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY node_id;

CREATE TABLE `auxia-reporting.graph_1950.nodes_product` (
  node_id          STRING NOT NULL,
  part_type        STRING,
  price            FLOAT64,
  log_popularity   FLOAT64,
  fitment_breadth  INT64,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY node_id;

CREATE TABLE `auxia-reporting.graph_1950.nodes_vehicle` (
  node_id        STRING NOT NULL,    -- "FORD/MUSTANG"
  user_count     INT64,
  product_count  INT64,
  snapshot_date  DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY node_id;

-- Graph edge tables (one per relation)
CREATE TABLE `auxia-reporting.graph_1950.edges_interacts` (
  source_node_id     STRING NOT NULL,
  target_node_id     STRING NOT NULL,
  weight             FLOAT64,
  max_interaction    FLOAT64,        -- highest base_weight (view=1, cart=3, order=5)
  interaction_count  INT64,
  snapshot_date      DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY source_node_id, target_node_id;

CREATE TABLE `auxia-reporting.graph_1950.edges_fits` (
  source_node_id  STRING NOT NULL,   -- product
  target_node_id  STRING NOT NULL,   -- vehicle
  snapshot_date   DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY source_node_id, target_node_id;

CREATE TABLE `auxia-reporting.graph_1950.edges_owns` (
  source_node_id  STRING NOT NULL,   -- user
  target_node_id  STRING NOT NULL,   -- vehicle
  snapshot_date   DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY source_node_id, target_node_id;

CREATE TABLE `auxia-reporting.graph_1950.edges_co_purchased` (
  source_node_id     STRING NOT NULL,  -- product A
  target_node_id     STRING NOT NULL,  -- product B
  weight             FLOAT64,          -- log(1 + count)
  co_purchase_count  INT64,
  snapshot_date      DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY source_node_id, target_node_id;
```

### Embedding Tables

```sql
CREATE TABLE `auxia-reporting.embeddings_1950.embeddings_user` (
  user_id          STRING NOT NULL,
  embedding        ARRAY<FLOAT64>,    -- 128-dim
  embedding_norm   FLOAT64,           -- for drift detection
  engagement_tier  STRING,
  model_version    STRING NOT NULL,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY user_id;

CREATE TABLE `auxia-reporting.embeddings_1950.embeddings_product` (
  product_id       STRING NOT NULL,
  embedding        ARRAY<FLOAT64>,    -- 128-dim
  embedding_norm   FLOAT64,
  part_type        STRING,
  price            FLOAT64,
  model_version    STRING NOT NULL,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY product_id;

CREATE TABLE `auxia-reporting.embeddings_1950.embeddings_semantic` (
  product_id       STRING NOT NULL,
  embedding        ARRAY<FLOAT64>,    -- 384-dim (SentenceTransformer)
  llm_model        STRING,            -- e.g., "gpt-4o-mini"
  input_text       STRING,            -- generated product description
  model_version    STRING NOT NULL,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY product_id;
```

### Scoring Tables

```sql
CREATE TABLE `auxia-reporting.scoring_1950.scored_recommendations` (
  user_id          STRING NOT NULL,
  product_id       STRING NOT NULL,
  gnn_score        FLOAT64,
  semantic_score   FLOAT64,
  popularity_score FLOAT64,
  recency_score    FLOAT64,
  hybrid_score     FLOAT64,
  rank             INT64,
  score_components JSON,              -- full breakdown for debugging
  model_version    STRING NOT NULL,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY user_id;

CREATE TABLE `auxia-reporting.scoring_1950.reranked_recommendations` (
  user_id          STRING NOT NULL,
  product_id       STRING NOT NULL,
  pre_rerank_rank  INT64,
  post_rerank_rank INT64,
  rerank_score     FLOAT64,
  rerank_reason    STRING,            -- LLM explanation
  model_version    STRING NOT NULL,
  snapshot_date    DATE NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY user_id;

-- Backward-compatible output (matches existing treatment system schema)
CREATE TABLE `auxia-reporting.scoring_1950.final_recommendations` (
  email_lower      STRING NOT NULL,
  v1_year          STRING,
  v1_make          STRING,
  v1_model         STRING,
  rec_part_1       STRING,
  rec1_price       FLOAT64,
  rec1_score       FLOAT64,
  rec1_image       STRING,
  rec1_type        STRING,
  rec_part_2       STRING,
  rec2_price       FLOAT64,
  rec2_score       FLOAT64,
  rec2_image       STRING,
  rec2_type        STRING,
  rec_part_3       STRING,
  rec3_price       FLOAT64,
  rec3_score       FLOAT64,
  rec3_image       STRING,
  rec3_type        STRING,
  rec_part_4       STRING,
  rec4_price       FLOAT64,
  rec4_score       FLOAT64,
  rec4_image       STRING,
  rec4_type        STRING,
  generated_at     TIMESTAMP,
  pipeline_version STRING,
  model_version    STRING NOT NULL,
  scoring_method   STRING,            -- "sql" | "gnn_hybrid" | "gnn_reranked"
  experiment_id    STRING
)
CLUSTER BY email_lower;
-- Not partitioned: fully replaced on each pipeline run (matches existing treatment system pattern)
```

### Metadata Tables

```sql
CREATE TABLE `auxia-reporting.meta_1950.model_registry` (
  model_id          STRING NOT NULL,
  model_version     STRING NOT NULL,
  model_type        STRING,           -- "gnn" | "semantic" | "distillation"
  checkpoint_gcs    STRING,           -- gs://auxia-models/1950/gnn/checkpoints/v1/best_model.pt
  training_config   JSON,
  metrics           JSON,             -- {"recall@10": 0.35, "mrr": 0.21, ...}
  graph_snapshot_id STRING,
  status            STRING,           -- trained | deployed | retired
  created_at        TIMESTAMP,
  deployed_at       TIMESTAMP
);

CREATE TABLE `auxia-reporting.meta_1950.graph_snapshots` (
  snapshot_id    STRING NOT NULL,
  snapshot_date  DATE NOT NULL,
  node_counts    JSON,                -- {"user": 475000, "product": 25000, "vehicle": 2000}
  edge_counts    JSON,                -- {"interacts": 85000, "fits": 350000, ...}
  parquet_gcs    STRING,              -- gs://auxia-models/1950/graphs/2026-02-11/
  quality        JSON,                -- {"isolated_nodes": 120, "avg_degree": 3.2}
  created_at     TIMESTAMP
);

CREATE TABLE `auxia-reporting.meta_1950.experiment_config` (
  experiment_id   STRING NOT NULL,
  name            STRING,
  arms            JSON,               -- [{"id": "sql", "weight": 0.5}, {"id": "gnn", "weight": 0.5}]
  targeting       JSON,               -- {"engagement_tier": ["cold", "warm", "hot"]}
  start_date      DATE,
  end_date        DATE,
  primary_kpi     STRING,             -- "per_user_binary_click_rate"
  status          STRING,             -- active | paused | completed
  results         JSON
);

CREATE TABLE `auxia-reporting.meta_1950.embedding_drift` (
  snapshot_date    DATE NOT NULL,
  embedding_type   STRING,            -- "user" | "product" | "semantic"
  mean_norm        FLOAT64,
  std_norm         FLOAT64,
  mean_cosine_sim  FLOAT64,           -- avg pairwise similarity (sample)
  drift_from_prev  FLOAT64,           -- cosine distance from previous snapshot
  alert_triggered  BOOL
);
```

### GCS Layout

```
gs://auxia-models/{customer_id}/
  gnn/
    checkpoints/{version}/best_model.pt
    embeddings/{date}/user_embeddings.parquet
    embeddings/{date}/product_embeddings.parquet
  graphs/
    {date}/nodes_user.parquet
    {date}/nodes_product.parquet
    {date}/nodes_vehicle.parquet
    {date}/edges_interacts.parquet
    {date}/edges_fits.parquet
    {date}/edges_owns.parquet
    {date}/edges_co_purchased.parquet
  llm/
    descriptions/{version}/product_descriptions.parquet
    embeddings/{version}/semantic_embeddings.parquet
  distillation/
    training_data/{date}/rankings.parquet
    models/{version}/student_model.pt
```

---

## 7. Metaflow Pipeline Design

### Overview: 5 Flows, Independently Schedulable

```
                 ┌──────────────┐
                 │ Flow 1       │
  Daily, CPU     │ Construct    │
  ──────────────→│ Graph        │─────┐
                 └──────────────┘     │
                                      │  GCS Parquet
                 ┌──────────────┐     │
  Weekly, CPU    │ Flow 2       │     │
  ──────────────→│ Enrich       │─────┤
                 │ Semantics    │     │
                 └──────────────┘     │
                                      ▼
                 ┌──────────────┐
  Weekly, GPU    │ Flow 3       │
  ──────────────→│ Train GNN    │─────┐
                 └──────────────┘     │
                                      │  Model checkpoint
                                      ▼
                 ┌──────────────┐
  Daily, CPU     │ Flow 4       │
  ──────────────→│ Score        │─────┐
                 │ Recs         │     │
                 └──────────────┘     │
                                      │  Top-K candidates
                                      ▼
                 ┌──────────────┐
  Daily, CPU     │ Flow 5       │
  [Phase 2+]     │ Rerank +     │
  ──────────────→│ Distill      │
                 └──────────────┘
```

All flows parameterized by: `--customer`, `--config`, `--snapshot-date`

### Flow 1: ConstructGraphFlow (daily, CPU)

```python
class ConstructGraphFlow(FlowSpec):
    customer = Parameter("customer", default="holley")
    config_path = Parameter("config", default="configs/customers/holley.yaml")
    snapshot_date = Parameter("snapshot_date", default=str(date.today()))

    @kubernetes(cpu=4, memory=16384, service_account="ksa-metaflow")
    @step
    def start(self):
        """Load config and determine export queries."""
        self.config = load_config(self.config_path)
        self.next(self.export_nodes)

    @step
    def export_nodes(self):
        """Run customer-specific SQL to export node tables."""
        for node_type in self.config.graph.nodes:
            sql = load_sql(f"sql/gnn/customers/{self.customer}/export_{node_type}_nodes.sql")
            run_bq_query(sql, params={"snapshot_date": self.snapshot_date})
        self.next(self.export_edges)

    @step
    def export_edges(self):
        """Run customer-specific SQL to export edge tables."""
        for edge in self.config.graph.edges:
            sql = load_sql(f"sql/gnn/customers/{self.customer}/export_{edge.relation}_edges.sql")
            run_bq_query(sql, params={"snapshot_date": self.snapshot_date})
        self.next(self.validate_graph)

    @step
    def validate_graph(self):
        """Check minimum node counts, edge existence, no orphans."""
        for node_type, spec in self.config.graph.nodes.items():
            count = count_rows(f"graph_{self.config.company_id}.nodes_{node_type}")
            assert count >= spec.min_count, f"{node_type}: {count} < {spec.min_count}"
        self.next(self.save_snapshot)

    @step
    def save_snapshot(self):
        """Export to Parquet, upload to GCS, register metadata."""
        gcs_path = f"gs://auxia-models/{self.customer}/graphs/{self.snapshot_date}/"
        export_to_parquet_and_upload(self.config, gcs_path)
        register_snapshot(self.config.company_id, self.snapshot_date, gcs_path)
        self.next(self.end)

    @step
    def end(self):
        pass
```

### Flow 2: EnrichSemanticsFlow (weekly, CPU)

```python
class EnrichSemanticsFlow(FlowSpec):
    customer = Parameter("customer", default="holley")

    @kubernetes(cpu=4, memory=16384, service_account="ksa-metaflow")
    @step
    def start(self):
        self.config = load_config(f"configs/customers/{self.customer}.yaml")
        self.next(self.load_products)

    @step
    def load_products(self):
        """Load products needing descriptions (new or updated only)."""
        self.products = load_new_products(self.config)
        self.next(self.generate_descriptions)

    @step
    def generate_descriptions(self):
        """Call LLM API in batches to generate product descriptions."""
        template = load_prompt(f"prompts/{self.customer}_product_enrichment.txt")
        self.descriptions = []
        for batch in chunk(self.products, size=100):
            results = llm_batch_generate(batch, template, model="gpt-4o-mini")
            self.descriptions.extend(results)
        self.next(self.encode_embeddings)

    @step
    def encode_embeddings(self):
        """Encode descriptions with SentenceTransformer → 384-dim."""
        encoder = SentenceTransformer("all-MiniLM-L6-v2")
        texts = [d.description for d in self.descriptions]
        self.embeddings = encoder.encode(texts, batch_size=256, show_progress_bar=True)
        self.next(self.store_embeddings)

    @step
    def store_embeddings(self):
        """Write to embeddings_semantic table."""
        write_semantic_embeddings(self.config.company_id, self.descriptions, self.embeddings)
        self.next(self.end)

    @step
    def end(self):
        pass
```

### Flow 3: TrainGNNFlow (weekly, GPU)

```python
class TrainGNNFlow(FlowSpec):
    customer = Parameter("customer", default="holley")
    snapshot_date = Parameter("snapshot_date", default=str(date.today()))

    @kubernetes(cpu=16, memory=131072, gpu=1, service_account="ksa-metaflow")
    @step
    def start(self):
        self.config = load_config(f"configs/customers/{self.customer}.yaml")
        self.next(self.load_graph)

    @step
    def load_graph(self):
        """Download Parquet snapshot from GCS."""
        gcs_path = f"gs://auxia-models/{self.customer}/graphs/{self.snapshot_date}/"
        self.dataframes = download_parquet(gcs_path)
        self.next(self.build_pyg_data)

    @step
    def build_pyg_data(self):
        """Build HeteroData from config-driven GraphSchema."""
        schema = GraphSchema.from_config(self.config)
        builder = GenericGraphBuilder(schema)
        self.data = builder.build(self.dataframes)
        self.builder = builder
        self.next(self.train_model)

    @step
    def train_model(self):
        """Train HeteroGAT with dual optimizer, early stopping."""
        model = GenericHeteroGAT(
            node_specs=self.data.metadata(),
            edge_types=self.data.edge_types,
            **self.config.model
        )
        trainer = GNNTrainer(model, self.data, config=self.config.training, device="cuda")
        self.history = trainer.train()
        self.model = trainer.model
        self.next(self.evaluate)

    @step
    def evaluate(self):
        """Evaluate against held-out clicks, stratified by engagement tier."""
        evaluator = GNNEvaluator(self.model, self.data, self.builder)
        self.metrics = evaluator.evaluate_against_clicks(
            test_clicks=self.dataframes["test_clicks"],
            user_nodes=self.dataframes["user_nodes"]
        )
        self.next(self.register_model)

    @step
    def register_model(self):
        """Upload checkpoint to GCS, register in model_registry."""
        version = f"v{self.snapshot_date.replace('-', '')}"
        gcs_path = f"gs://auxia-models/{self.customer}/gnn/checkpoints/{version}/"
        upload_checkpoint(self.model, gcs_path)
        register_model(self.config.company_id, version, self.metrics, gcs_path)
        self.next(self.end)

    @step
    def end(self):
        pass
```

### Flow 4: ScoreRecommendationsFlow (daily, CPU)

```python
class ScoreRecommendationsFlow(FlowSpec):
    customer = Parameter("customer", default="holley")

    @kubernetes(cpu=8, memory=65536, service_account="ksa-metaflow")
    @step
    def start(self):
        self.config = load_config(f"configs/customers/{self.customer}.yaml")
        self.next(self.generate_embeddings)

    @step
    def generate_embeddings(self):
        """Load latest model, generate user/product embeddings."""
        model, builder = load_latest_model(self.config)
        data = load_latest_graph(self.config)
        model.eval()
        with torch.no_grad():
            self.user_emb, self.product_emb = model(data)
        self.builder = builder
        self.next(self.hybrid_scoring)

    @step
    def hybrid_scoring(self):
        """FAISS top-K, blend with SQL/semantic scores."""
        # FAISS approximate nearest neighbors
        index = build_faiss_index(self.product_emb)
        candidates = search_top_k(index, self.user_emb, k=100)

        # Load semantic embeddings and popularity scores
        semantic = load_semantic_embeddings(self.config)
        popularity = load_popularity_scores(self.config)

        # Hybrid blend
        weights = self.config.scoring.weights  # {gnn: 0.6, semantic: 0.2, ...}
        self.scored = compute_hybrid_scores(candidates, semantic, popularity, weights)
        self.next(self.apply_filters)

    @step
    def apply_filters(self):
        """Apply business rules: fitment, purchase exclusion, diversity."""
        self.filtered = apply_business_rules(
            self.scored,
            fitment_table=self.config.scoring.fitment_table,
            purchase_window_days=365,
            max_per_parttype=2,
            min_price=50.0,
            required_recs=4
        )
        self.next(self.write_output)

    @step
    def write_output(self):
        """Write to final_recommendations (backward-compatible schema)."""
        write_final_recommendations(
            self.filtered,
            table=f"scoring_{self.config.company_id}.final_recommendations",
            pipeline_version=self.config.pipeline_version,
            scoring_method="gnn_hybrid"
        )
        self.next(self.end)

    @step
    def end(self):
        pass
```

### Flow 5: RerankLLMFlow (weekly, CPU — Phase 2+)

```python
class RerankLLMFlow(FlowSpec):
    customer = Parameter("customer", default="holley")

    @kubernetes(cpu=8, memory=32768, service_account="ksa-metaflow")
    @step
    def start(self):
        self.config = load_config(f"configs/customers/{self.customer}.yaml")
        self.next(self.load_candidates)

    @step
    def load_candidates(self):
        """Load top-20 candidates for warm+hot users."""
        self.candidates = load_warm_hot_candidates(self.config, top_k=20)
        self.next(self.rerank)

    @step
    def rerank(self):
        """Re-rank via LLM batch with chain-of-thought prompting."""
        template = self.config.reranking.prompt_template
        self.rankings = []
        for batch in chunk(self.candidates, size=50):
            results = llm_batch_rerank(batch, template)
            self.rankings.extend(results)
        self.next(self.store_rankings)

    @step
    def store_rankings(self):
        """Store re-ranked results with LLM explanations."""
        write_reranked(self.config.company_id, self.rankings)
        self.next(self.distill)

    @step
    def distill(self):
        """Train/update student MLP when enough data accumulated."""
        training_data = load_accumulated_rankings(self.config)
        if len(training_data) >= self.config.distillation.min_examples:
            student = train_student_model(training_data, self.config.distillation)
            upload_student(self.config, student)
        self.next(self.end)

    @step
    def end(self):
        pass
```

---

## 8. Platform Integration

### How GNN Plugs Into Auxia

The GNN system replaces recommendation **content** within the existing treatment system — it does not replace the treatment system itself.

```
BEFORE (SQL v5.17):
  SQL pipeline → final_vehicle_recommendations → Treatment System → Bandit → Email

AFTER (GNN hybrid):
  GNN pipeline → final_recommendations → Treatment System → Bandit → Email
                 (same schema)           (unchanged)         (unchanged)
```

**Key integration points:**

1. **Output table** `final_recommendations` has identical schema to current `final_vehicle_recommendations`. The treatment system reads from the same BigQuery table — this is a config change (table name), not a code change.

2. **Thompson Sampling Bandit** continues to select which treatment template to send. The bandit operates on treatment-level CTR. GNN changes the recommendation content WITHIN each treatment, not treatment SELECTION.

3. **Treatment IDs** remain the same. The 10 Personalized Fitment treatments (from `configs/personalized_treatments.csv`) and 22 Static treatments (from `configs/static_treatments.csv`) are unchanged.

### A/B Testing via Existing Infrastructure

```
                    ┌──────────────────────┐
                    │  All Eligible Users   │
                    │      (~475K)          │
                    └───────────┬──────────┘
                                │
                     User-level 50/50 split
                     (deterministic hash)
                    ┌───────────┴──────────┐
                    │                      │
              ┌─────┴─────┐         ┌─────┴─────┐
              │  Control   │         │ Treatment  │
              │  SQL-only  │         │ GNN-hybrid │
              │  v5.17     │         │ v6.0       │
              └────────────┘         └────────────┘
```

- **Randomization:** User-level, maintained across all sends (deterministic hash of user_id)
- **Same treatment IDs**, different recommendation content
- **Primary KPI:** Per-user binary click rate (not per-send CTR — see [Send Frequency Confound](#known-measurement-issues))
- **Duration:** Minimum 2 weeks (account for email fatigue pattern: CTR drops 70% from 1st to 7th+ send)

### Known Measurement Issues

From our bandit investigation and uplift analysis:

| Issue | Impact | Mitigation |
|-------|--------|------------|
| Send frequency confound | P: 6.3 sends/user vs S: 1.9 — dilutes per-send CTR | Use per-user binary click rate as primary KPI |
| Email fatigue | CTR drops 70% from 1st to 7th+ send | Control for send count in analysis |
| Phantom clicks | Image-blocking clients: clicked=1, opened=0 | Use corrected CTR formula: `SUM(CASE WHEN opened=1 AND clicked=1 ...)` |
| Static = Apparel only | Only 1 of 22 Static treatments has sends | Compare within Personalized arms only |

### Embedding Reuse Beyond Email

User and product embeddings stored in BigQuery enable cross-surface consumption:

| Surface | Use Case | How |
|---------|----------|-----|
| Web personalization | "Recommended for your vehicle" | Query user embedding → ANN search products |
| Product detail page | "Similar products" | Query product embedding → nearest neighbors |
| Search ranking | Boost fitment-compatible results | Blend search score with embedding similarity |
| User segmentation | Cluster users by embedding similarity | K-means on user embeddings |
| Churn prediction | Embedding drift as feature | Track user embedding movement over time |

---

## 9. Cold-Start Strategy

### The Problem

98% of Holley users have zero intent events (no views, carts, or orders since Sep 2025). These "cold" users currently receive pure popularity-based recommendations — the same top products regardless of their specific vehicle.

### GNN's Structural Solution: Vehicle-Mediated Embedding Transfer

Through 2 layers of message passing, cold users receive embedding signal from their vehicle's product compatibility AND similar vehicle owners' behavior patterns:

```
                           Layer 1                    Layer 2
Cold User ──owns──→ Vehicle ──rev_fits──→ Products (popular among same-vehicle owners)
                             ──rev_owns──→ Warm Users ──interacts──→ Products
```

**Concrete example:**

1. Cold user registers a 2018 Ford Mustang GT
2. Layer 1: User receives embedding signal from the "FORD/MUSTANG" vehicle node
3. The vehicle node has already aggregated signal from:
   - 1,200 other Mustang owners (via `rev_owns` edges)
   - 450 compatible products (via `rev_fits` edges)
4. Layer 2: User receives signal from products that other Mustang owners interacted with
5. Result: Cold user's embedding encodes "Mustang owner preferences" without any direct behavioral data

**Why this is better than SQL popularity fallback:**
- SQL gives the same top products to ALL cold users regardless of vehicle
- GNN gives vehicle-specific products informed by what owners of THAT vehicle actually buy

### Tier-Specific Score Blending

| Tier | % of Users | GNN Weight | Popularity Weight | Rationale |
|------|-----------|------------|-------------------|-----------|
| Cold | 98% | 0.4 | 0.6 | GNN provides vehicle signal; popularity provides safety |
| Warm | ~2% | 0.7 | 0.3 | GNN has behavioral + vehicle signal |
| Hot | <1% | 0.9 | 0.1 | GNN has rich signal; minimal popularity needed |

### Phase 2 Enhancement: Semantic Vehicle Features

Add SentenceTransformer encoding of `"{year} {make} {model}"` as a continuous user feature:

```python
# "2018 Ford Mustang GT" → 384-dim embedding
vehicle_text = f"{user.v1_year} {user.v1_make} {user.v1_model}"
vehicle_semantic = sentence_transformer.encode(vehicle_text)
```

This provides dense semantic signal BEFORE graph message passing. Vehicles with similar names (e.g., "Ford Mustang" and "Chevrolet Camaro") get similar initial embeddings, allowing the GNN to leverage semantic vehicle similarity on top of structural graph similarity.

---

## 10. Multi-Tenant Design

### Principle: Code Is Generic, Config Is Specific

The entire system is parameterized by customer configuration. Adding a new customer requires three artifacts and zero Python code changes.

### Customer Onboarding (3 Artifacts)

**1. YAML Config:** `configs/customers/{customer}.yaml`

Defines graph schema, model parameters, LLM templates, scoring weights, and all customer-specific settings. (See Appendix C and D for full examples.)

**2. SQL Exports:** `sql/gnn/customers/{customer}/export_*.sql`

Customer-specific SQL queries that extract nodes and edges from that customer's BigQuery source tables. These are inherently customer-specific because source table schemas differ.

**3. LLM Prompts:** `prompts/{customer}_product_enrichment.txt`

Domain-specific product description template for semantic enrichment. A carburetor description template differs fundamentally from a dress description template.

### What's Already Generic

| Component | File | Generic? | Notes |
|-----------|------|----------|-------|
| `GenericGraphBuilder` | `src/gnn/graph_builder.py` | Yes | Accepts arbitrary node/edge types from `GraphSchema` |
| `GenericHeteroGAT` | `src/gnn/model.py` | Yes | Parameterized by num_nodes, edge_types, feature dims |
| `GNNTrainer` | `src/gnn/trainer.py` | Yes | Works with any `HeteroData` |
| `GNNEvaluator` | `src/gnn/evaluator.py` | Yes | Uses schema's query/item node types |
| Metaflow flows | `flows/*.py` | Needs work | Currently hardcoded defaults for Holley |
| SQL exports | `sql/gnn/*.sql` | Holley-specific | Inherently customer-specific |

### What Needs Generalization (Before Multi-Tenant)

| Component | Current State | Target State |
|-----------|--------------|--------------|
| `GNNDataLoader` | Hardcoded table names (`user_nodes`, `product_nodes`, etc.) | Read table names from config, parameterize dataset |
| Metaflow flows | No customer parameter | Accept `--customer` param, load config dynamically |
| Graph builder | `HolleyGraphBuilder` class name | `GenericGraphBuilder` driven by `GraphSchema` |
| Model | `HolleyGAT` class name | `GenericHeteroGAT` parameterized by schema |

### Validation: Second Customer Test

Phase 5 of the rollout (weeks 13-16) onboards a second customer to validate that zero Python code changes are needed. The gate is explicit: if any `.py` file must be modified, the multi-tenant design has failed.

---

## 11. Evaluation & Experimentation

### Offline Metrics (Per Engagement Tier)

| Metric | Target vs SQL | Go/No-Go? |
|--------|--------------|-----------|
| Recall@10 | >= +5% | **Yes** — Phase 1 gate |
| MRR | >= +10% | No — tracked, not gated |
| NDCG@10 | >= +5% | No — tracked, not gated |
| Coverage | >= +15% unique products | No — tracked |
| Diversity (avg PartType entropy) | >= SQL | No — tracked |

Metrics are computed stratified by engagement tier (cold/warm/hot) to ensure GNN doesn't sacrifice cold-start quality for warm-user gains.

### Embedding Health Monitoring

| Check | Expected | Alert Threshold |
|-------|----------|-----------------|
| Embedding norm distribution | ~1.0 (L2-normalized) | Mean norm deviates >10% from 1.0 |
| Cosine similarity distribution | Not collapsed (std > 0.1) | All embeddings converging to same vector |
| Vehicle cluster coherence | Silhouette score > 0.3 | Vehicle clusters become meaningless |
| Cold-warm embedding gap | Should decrease over training | Gap increasing over 3 consecutive snapshots |
| Embedding drift (cosine distance) | < 0.1 between snapshots | Sudden drift > 0.3 |

### Online A/B Protocol

| Parameter | Value |
|-----------|-------|
| Randomization | User-level, deterministic hash, maintained across all sends |
| Primary KPI | Per-user binary click rate |
| Secondary KPIs | Conversion rate, revenue/user, recommendation diversity, cold-start click rate |
| Minimum duration | 2 weeks |
| Sample size | ~237K per arm (50/50 split of 475K users) |
| Guardrail | CTR regression > 5% → automatic pause |

**Statistical framework:**
- Two-proportion z-test for binary click rate
- 95% confidence interval
- Minimum detectable effect: ~0.5pp (given ~237K users per arm and ~3.5% baseline click rate)

---

## 12. Cost Model

### Monthly Compute Costs

| Phase | Component | Monthly Cost | Details |
|-------|-----------|-------------|---------|
| **Phase 1: GNN only** | | **~$70** | |
| | Graph construction (daily, CPU) | ~$15 | K8s: 4 CPU, 16GB, ~10min/run |
| | GNN training (weekly, GPU) | ~$30 | K8s: 16 CPU, 128GB, 1 GPU, ~2-4hr/run |
| | Scoring pipeline (daily, CPU) | ~$15 | K8s: 8 CPU, 64GB, ~20min/run |
| | BigQuery (storage + queries) | ~$10 | Graph tables, embeddings, scoring |
| **Phase 2: +Semantic** | | **~$75** | |
| | All Phase 1 | ~$70 | |
| | LLM enrichment (weekly) | ~$5 | ~$7/catalog run, incremental updates |
| **Phase 3: +Reranking** | | **~$125** | |
| | All Phase 2 | ~$75 | |
| | LLM reranking (weekly, warm+hot) | ~$50 | ~$12/run × ~4 runs/month, ~9.5K users/run |
| **Phase 4: +Distillation** | | **~$75** | |
| | All Phase 2 | ~$75 | |
| | LLM costs eliminated | -$50 | Student model replaces LLM |
| | Student inference (daily, CPU) | ~$0 | Negligible — runs within scoring flow |

### Per Additional Customer

| Item | Cost | Notes |
|------|------|-------|
| Base compute | +$50-70/month | Shared K8s cluster, separate BigQuery datasets |
| Onboarding | ~1 week engineer time | YAML config + SQL exports + LLM prompt |
| LLM enrichment | +$5-15/month | Depends on catalog size |

### Comparison to Current System

| System | Incremental over SQL | Total Monthly |
|--------|---------------------|---------------|
| SQL v5.17 pipeline (baseline) | — | ~$50 |
| + Phase 1: GNN only | +$20 | ~$70 |
| + Phase 2: Semantic enrichment | +$5 | ~$75 |
| + Phase 3: LLM reranking (peak) | +$50 | ~$125 |
| + Phase 4: Distillation (steady-state) | -$50 (LLM eliminated) | ~$75 |

---

## 13. Phased Rollout

```
Phase 1 (Weeks 1-3):   Offline GNN evaluation — does it beat SQL?
Phase 2 (Weeks 4-5):   Semantic enrichment — does it help cold-start?
Phase 3 (Weeks 6-8):   Hybrid integration + online A/B test
Phase 4 (Weeks 9-12):  LLM reranking + distillation
Phase 5 (Weeks 13-16): Second customer onboarding — validate multi-tenant
```

### Phase Details

**Phase 1: Offline GNN Eval (Weeks 1-3)**
- Recode `src/gnn/` from scratch with generic architecture
- Export graph from BigQuery (nodes + edges)
- Train HeteroGAT on K8s GPU
- Evaluate vs SQL baseline on held-out 30-day clicks
- **Gate:** Recall@10 >= SQL + 5%
- **Cost to stop:** ~$100 total compute, 3 weeks engineer time

**Phase 2: Semantic Enrichment (Weeks 4-5)**
- Implement LLM batch description generation
- Encode with SentenceTransformer → 384-dim embeddings
- Add as product node features, retrain GNN
- **Gate:** Cold-user Recall@10 >= Phase 1 + 2%
- **Cost to stop:** ~$10 (just the LLM API cost)

**Phase 3: Hybrid Integration + A/B Test (Weeks 6-8)**
- Build scoring pipeline: GNN + semantic + SQL blending
- Apply all business rules (fitment, exclusion, diversity)
- Write to `final_recommendations` (backward-compatible)
- Launch 50/50 A/B test
- **Gate:** Per-user binary click rate lift >= 10%
- **Fallback:** Product-similarity-only mode (use GNN for product ranking, keep SQL for user scoring)

**Phase 4: LLM Reranking + Distillation (Weeks 9-12)**
- Implement LLM re-ranking for warm+hot users
- Accumulate rankings as training data
- Train student MLP on accumulated data
- Validate student quality vs teacher
- **Gate:** Student NDCG@10 >= 85% of LLM teacher
- **Fallback:** Keep LLM for warm/hot only (higher cost but proven quality)

**Phase 5: Second Customer Onboarding (Weeks 13-16)**
- Create YAML config, SQL exports, LLM prompt for new customer
- Run full pipeline: graph → train → score → validate
- **Gate:** Zero Python code changes needed
- **Cost to stop:** ~1 week engineer time

### Risk Summary

| Phase | Risk | Likelihood | Mitigation |
|-------|------|-----------|------------|
| 1 | GNN doesn't beat SQL (cold-start) | Medium-High | Vehicle graph is structural advantage; 98% cold users make this testable |
| 2 | Semantic embeddings don't improve cold-start | Low | Independent value even without GNN improvement |
| 3 | Online CTR doesn't match offline gains | Medium | Common offline/online gap; hybrid blend is tunable |
| 4 | Student model can't match LLM quality | Low | Can keep LLM for warm/hot at higher cost |
| 5 | Multi-tenant requires code changes | Low | Architecture designed for this; early validation |

---

## 14. Appendix

### Appendix A: Industry References

| Company | Architecture | Scale | Key Metric | Year | Source |
|---------|-------------|-------|------------|------|--------|
| Faire | Two-tower HeteroGAT | 3M retailers, 11M products | +4.85% order lift, +25.8% recall@10 | 2026 | [craft.faire.com](https://craft.faire.com/graph-neural-networks-at-faire-386024e5a6d9) |
| Zalando | GNN embeddings → existing pipeline | Fashion e-commerce | +0.6pp AUC, 40% less FE | 2024 | [engineering.zalando.com](https://engineering.zalando.com/posts/2024/12/gnn-recommendations-zalando.html) |
| Pinterest | OmniSage (heterogeneous GNN) | 5.6B nodes | ~2.5% sitewide repins | 2024 | [Pinterest Engineering](https://medium.com/pinterest-engineering) |
| LinkedIn | LiGNN + Cross-Domain | 8.6B nodes | +8% AUC | 2025 | LinkedIn Engineering Blog |
| YouTube | PLUM (Semantic IDs) | Billions | +4.96% CTR Shorts, 13x coverage | 2025 | Google Research |
| Netflix | UniCoRn (Unified Ranker) | Multi-task | +10% rec, +7% search | 2024 | Netflix Tech Blog |
| Amazon | DAEMON (Dual-embedding) | Product graph | +30-160% HitRate/MRR | 2025 | [amazon.science](https://www.amazon.science/blog/using-graph-neural-networks-to-recommend-related-products) |
| ContextGNN | Hybrid repeat+explore | ICLR 2025 | +20% avg on RelBench | 2025 | [arxiv.org/abs/2502.06148](https://arxiv.org/abs/2502.06148) |
| Kuaishou | DAS (Semantic IDs) | 400M+ users | — | 2025 | Kuaishou Research |
| Indeed | GPT-4 → GPT-3.5 distillation | Job recs | Quality parity at 10x less cost | 2025 | Indeed Engineering |

### Appendix B: PyG API Reference

| Class | Module | Version | Purpose |
|-------|--------|---------|---------|
| `HeteroData` | `torch_geometric.data` | 2.0+ | Heterogeneous graph storage |
| `HeteroConv` | `torch_geometric.nn.conv` | 2.0+ | Wrapper for per-edge-type convolutions |
| `GATConv` | `torch_geometric.nn.conv` | 2.0+ | Graph Attention convolution |
| `LinkNeighborLoader` | `torch_geometric.loader` | 2.1+ | Mini-batch training for link prediction |
| `ApproxMIPSKNNIndex` | `torch_geometric.nn.knn` | 2.4+ | Approximate nearest neighbor retrieval |
| `SentenceTransformer` | `torch_geometric.nn.nlp` | 2.5+ | Text → embedding encoding |
| `LinkPredNDCG` | `torch_geometric.nn.metrics` | 2.4+ | Link prediction NDCG metric |
| `HitRatio` | `torch_geometric.nn.metrics` | 2.4+ | Hit ratio metric |

### Appendix C: Full YAML Config — Holley

```yaml
# configs/customers/holley.yaml

customer:
  name: holley
  company_id: "1950"
  domain: automotive_aftermarket

bigquery:
  project: auxia-reporting
  source_project: auxia-gcp
  source_datasets:
    attributes: company_1950
    events: company_1950
    catalog: data_company_1950
  target_datasets:
    graph: graph_1950
    embeddings: embeddings_1950
    scoring: scoring_1950
    meta: meta_1950

gcs:
  bucket: auxia-models
  prefix: "1950"

graph:
  intent_window_start: "2025-09-01"
  min_price: 50.0
  co_purchase_threshold: 2
  time_decay_halflife: 30.0

  nodes:
    user:
      table: user_nodes
      id_column: user_id
      min_count: 400000  # Validation threshold (actual: ~475K)
      categorical_features:
        engagement_tier: 32
      continuous_features: []
    product:
      table: product_nodes
      id_column: sku
      min_count: 10000  # Validation threshold (actual: ~25K)
      categorical_features:
        part_type: 32
      continuous_features:
        - price
        - log_popularity
        - fitment_breadth
      semantic_text_template: >
        {part_type} automotive part, priced at ${price:.2f}.
        Fits {fitment_breadth} vehicle models.
    vehicle:
      table: vehicle_nodes
      id_column: vehicle_id
      min_count: 500  # Validation threshold (actual: ~2K)
      categorical_features: {}
      continuous_features:
        - user_count
        - product_count

  edges:
    - source_type: user
      target_type: product
      relation: interacts
      weight_column: weight
      add_reverse: true
    - source_type: product
      target_type: vehicle
      relation: fits
      weight_column: null
      add_reverse: true
    - source_type: user
      target_type: vehicle
      relation: owns
      weight_column: null
      add_reverse: true
    - source_type: product
      target_type: product
      relation: co_purchased
      weight_column: weight
      add_reverse: false
      bidirectional: true

model:
  embedding_dim: 128
  hidden_dim: 256
  num_heads: 4
  num_layers: 2
  dropout: 0.1

training:
  epochs: 100
  emb_lr: 0.001
  emb_weight_decay: 1.0e-5
  gnn_lr: 0.01
  gnn_weight_decay: 1.0e-4
  max_grad_norm: 1.0
  patience: 10
  neg_ratio_inbatch: 0.5
  neg_ratio_random: 0.5

scoring:
  top_k: 100
  hybrid_weights:
    gnn: 0.6
    semantic: 0.2
    popularity: 0.1
    recency: 0.1
  tier_blending:
    cold:
      gnn: 0.4
      popularity: 0.6
    warm:
      gnn: 0.7
      popularity: 0.3
    hot:
      gnn: 0.9
      popularity: 0.1
  fitment_table: "auxia-gcp.data_company_1950.vehicle_product_fitment_data"
  purchase_window_days: 365
  max_per_parttype: 2
  min_price: 50.0
  required_recs: 4
  output_table: "scoring_1950.final_recommendations"

semantic:
  llm_model: gpt-4o-mini
  sentence_transformer: all-MiniLM-L6-v2
  embedding_dim: 384
  prompt_file: prompts/holley_product_enrichment.txt

reranking:
  enabled: false  # Phase 2+
  llm_model: gpt-4o-mini
  top_k: 20
  target_tiers:
    - warm
    - hot

distillation:
  enabled: false  # Phase 4+
  min_examples: 50000
  student_hidden_dim: 128
  student_lr: 0.001
  student_epochs: 50

evaluation:
  test_window_days: 30
  k_values: [1, 5, 10, 20]
  sql_baseline_table: "auxia-reporting.company_1950_jp.final_vehicle_recommendations"

pipeline_version: "v6.0"

metaflow:
  graph_construction:
    cpu: 4
    memory: 16384
  semantic_enrichment:
    cpu: 4
    memory: 16384
  training:
    cpu: 16
    memory: 131072
    gpu: 1
  scoring:
    cpu: 8
    memory: 65536
  reranking:
    cpu: 8
    memory: 32768
```

### Appendix D: Full YAML Config — Hypothetical Fashion Customer

```yaml
# configs/customers/fashion_demo.yaml

customer:
  name: fashion_demo
  company_id: "2100"
  domain: fashion_ecommerce

bigquery:
  project: auxia-reporting
  source_project: auxia-gcp
  source_datasets:
    attributes: company_2100
    events: company_2100
    catalog: data_company_2100
  target_datasets:
    graph: graph_2100
    embeddings: embeddings_2100
    scoring: scoring_2100
    meta: meta_2100

gcs:
  bucket: auxia-models
  prefix: "2100"

graph:
  intent_window_start: "2025-06-01"
  min_price: 10.0
  co_purchase_threshold: 3
  time_decay_halflife: 14.0  # Fashion trends change faster

  nodes:
    user:
      table: user_nodes
      id_column: user_id
      min_count: 100000
      categorical_features:
        age_bucket: 16
        gender: 8
      continuous_features:
        - lifetime_value
    product:
      table: product_nodes
      id_column: sku
      min_count: 5000
      categorical_features:
        category: 32
        brand: 32
        color: 16
      continuous_features:
        - price
        - log_popularity
      semantic_text_template: >
        {brand} {category} in {color}, priced at ${price:.2f}.
        Style: {style_tags}.
    store:
      table: store_nodes
      id_column: store_id
      min_count: 100
      categorical_features:
        region: 16
      continuous_features:
        - avg_order_value

  edges:
    - source_type: user
      target_type: product
      relation: interacts
      weight_column: weight
      add_reverse: true
    - source_type: user
      target_type: product
      relation: purchased
      weight_column: null
      add_reverse: true
    - source_type: product
      target_type: product
      relation: same_brand
      weight_column: null
      add_reverse: false
      bidirectional: true
    - source_type: user
      target_type: store
      relation: shops_at
      weight_column: frequency
      add_reverse: true

model:
  embedding_dim: 128
  hidden_dim: 256
  num_heads: 4
  num_layers: 2
  dropout: 0.15  # Slightly higher for fashion (more noise)

training:
  epochs: 150
  emb_lr: 0.001
  emb_weight_decay: 1.0e-5
  gnn_lr: 0.01
  gnn_weight_decay: 1.0e-4
  max_grad_norm: 1.0
  patience: 15
  neg_ratio_inbatch: 0.5
  neg_ratio_random: 0.5

scoring:
  top_k: 100
  hybrid_weights:
    gnn: 0.5
    semantic: 0.3  # Higher — fashion is more semantic
    popularity: 0.1
    recency: 0.1
  tier_blending:
    cold:
      gnn: 0.3
      popularity: 0.7
    warm:
      gnn: 0.6
      popularity: 0.4
    hot:
      gnn: 0.85
      popularity: 0.15
  purchase_window_days: 180  # Shorter for fashion
  max_per_parttype: 3
  min_price: 10.0
  required_recs: 6
  output_table: "scoring_2100.final_recommendations"

semantic:
  llm_model: gpt-4o-mini
  sentence_transformer: all-MiniLM-L6-v2
  embedding_dim: 384
  prompt_file: prompts/fashion_demo_product_enrichment.txt

pipeline_version: "v1.0"

metaflow:
  graph_construction:
    cpu: 4
    memory: 16384
  semantic_enrichment:
    cpu: 4
    memory: 16384
  training:
    cpu: 16
    memory: 131072
    gpu: 1
  scoring:
    cpu: 8
    memory: 65536
```

**Key differences from Holley (zero code changes):**
- No vehicle nodes or fitment edges
- Store nodes instead (different graph topology)
- Shorter time-decay (14 vs 30 days — fashion trends move faster)
- Higher semantic weight (0.3 vs 0.2 — fashion is more description-driven)
- Lower min price ($10 vs $50)
- 6 recs per user instead of 4

### Appendix E: BigQuery DDL Summary

All DDL statements are provided in [Section 6: Database Design](#6-database-design). The tables are organized into four datasets per customer:

| Dataset | Tables | Purpose |
|---------|--------|---------|
| `graph_{id}` | `nodes_user`, `nodes_product`, `nodes_vehicle`, `edges_interacts`, `edges_fits`, `edges_owns`, `edges_co_purchased` | Graph construction data |
| `embeddings_{id}` | `embeddings_user`, `embeddings_product`, `embeddings_semantic` | Trained embeddings |
| `scoring_{id}` | `scored_recommendations`, `reranked_recommendations`, `final_recommendations` | Recommendation outputs |
| `meta_{id}` | `model_registry`, `graph_snapshots`, `experiment_config`, `embedding_drift` | Operational metadata |

**Partitioning strategy:** All graph and embedding tables partitioned by `snapshot_date` for efficient temporal queries and automatic TTL management.

**Clustering strategy:** Node tables clustered by `node_id`; edge tables clustered by `(source_node_id, target_node_id)` for fast graph traversal joins.

---

*This proposal is designed with explicit go/no-go gates at each phase. The worst outcome is 3 weeks and ~$100 confirming that SQL is the right approach for Holley's data density. The best outcome is a reusable multi-tenant ML platform that compounds in value as interaction data grows and new customers onboard.*
