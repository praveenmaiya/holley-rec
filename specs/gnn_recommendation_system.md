# GNN Recommendation System — Spec

## Overview
Heterogeneous GAT model for vehicle fitment recommendations, adapted from Faire's two-tower design.

## Graph Structure

### Nodes
| Type | Count | Features |
|------|-------|----------|
| User | ~475K | engagement_tier (learned embedding) |
| Product | ~25K | part_type, price, log_popularity, fitment_breadth |
| Vehicle | ~2K | user_count, product_count |

### Edges (4 types + reverses = 7 total)
| Edge | Relation | Weight |
|------|----------|--------|
| user → product | interacts | time-decayed: `base_weight * exp(-days/30)` |
| product → vehicle | fits | binary (from fitment catalog) |
| user → vehicle | owns | binary (from v1 registration) |
| product ↔ product | co_purchased | `log(1 + count)`, threshold ≥2 |

## Model Architecture
- **Embeddings**: Learned user/product/vehicle embeddings (128-dim)
- **Product MLP**: part_type embedding + price + log_popularity + fitment_breadth → 128-dim
- **2-layer HeteroConv**: GATConv per edge type, 4 attention heads, hidden_dim=256
- **Two towers**: User MLP + Product MLP → 128-dim L2-normalized embeddings
- **Scoring**: Dot product similarity

## Training (Faire's Tricks)
1. Edge-weighted BCE loss (order=5, cart=3, view=1)
2. Time-decay in edge weights (biggest win: +25.8% recall@10 at Faire)
3. Dual optimizer: embeddings (LR=0.001) vs GNN/MLP (LR=0.01)
4. Mixed negative sampling: 50% in-batch + 50% global random
5. Gradient clipping (max_norm=1.0)
6. Early stopping (patience=10)

## Evaluation
- **Metrics**: MRR, Recall@{1,5,10,20}, NDCG@10
- **Stratified** by engagement tier (cold/warm/hot)
- **Baseline**: SQL v5.7 recommendations
- **Ground truth**: Last 30 days of treatment clicks

## Success Criteria
- Cold users (98%): GNN beats SQL by >20% MRR
- Overall: >10% MRR improvement

## Files
| File | Purpose |
|------|---------|
| `sql/gnn/export_nodes.sql` | Extract user/product/vehicle nodes |
| `sql/gnn/export_edges.sql` | Extract 4 edge types with weights |
| `sql/gnn/export_test_set.sql` | Holdout clicks for eval |
| `notebooks/gnn_exploration.ipynb` | EDA + prototype |
| `src/gnn/data_loader.py` | BigQuery → DataFrames → Parquet |
| `src/gnn/graph_builder.py` | DataFrames → PyG HeteroData |
| `src/gnn/model.py` | Heterogeneous GAT model |
| `src/gnn/trainer.py` | Training loop with Faire tricks |
| `src/gnn/evaluator.py` | Offline eval vs SQL baseline |
| `flows/train_gnn.py` | Metaflow training pipeline |
| `flows/score_gnn.py` | Metaflow batch scoring |
| `configs/gnn_config.yaml` | Hyperparameters & paths |

## Dependencies
- `torch`, `torch-geometric`, `torch-scatter`, `torch-sparse`
- `scikit-learn` (LabelEncoder, metrics)
- `pandas`, `numpy`, `matplotlib`, `networkx`
