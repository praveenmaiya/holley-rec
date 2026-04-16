# GNN Design for Holley Recommendations: PyG Heterogeneous Graph Approach

## 1. Why a Graph? The Intuition

Our current pipeline (v5.17) uses hand-crafted scoring:

```
final_score = intent_score(user, sku) + popularity_score(sku)
```

This works, but it treats each signal independently. A GNN can learn **latent relationships** across all our entities simultaneously. Think of it this way:

- **Current system**: "User viewed Product A, Product A is popular → recommend A"
- **GNN system**: "User viewed Product A, Product A fits Mustang 2018, other Mustang 2018 users bought B after A, B has similar PartType to what this user bought before → recommend B with high confidence"

The GNN captures multi-hop reasoning that our SQL scoring formulas can't express.

---

## 2. What is a Heterogeneous Graph?

A **heterogeneous graph** has multiple types of nodes and multiple types of edges. This is exactly what our data looks like — users, products, and vehicles are fundamentally different entities with different features, connected by different relationship types.

In PyG, this is represented with `HeteroData`:

```python
from torch_geometric.data import HeteroData

data = HeteroData()

# Each node type has its own feature tensor
data['user'].x = ...       # [num_users, user_feature_dim]
data['product'].x = ...    # [num_products, product_feature_dim]
data['vehicle'].x = ...    # [num_vehicles, vehicle_feature_dim]

# Each edge type is a triplet: (source_type, relation, target_type)
data['user', 'viewed', 'product'].edge_index = ...
data['product', 'fits', 'vehicle'].edge_index = ...
```

This is different from a **homogeneous graph** (all nodes same type) because different node/edge types can have different feature dimensions and different learned parameters.

---

## 3. Mapping Holley Data to Graph Nodes

### Node Type 1: User (~475K nodes)

**Source**: `ingestion_unified_attributes_schema_incremental`

| Feature | Source | Encoding |
|---------|--------|----------|
| Has email | email presence | Binary (0/1) |
| Vehicle count | count of v1, v2... profiles | Integer |
| Purchase count (historical) | import_orders | Log-scaled float |
| View count (recent) | unified events, Sep 1+ | Log-scaled float |
| Cart count (recent) | unified events, Sep 1+ | Log-scaled float |
| Days since last event | unified events | Float |
| Segment embedding | v1_make + v1_model hash | Learned embedding |

```python
# Example: user features
data['user'].x = torch.tensor([
    [1, 1, 2.3, 4.1, 0.7, 12.0],  # user_0: has email, 1 vehicle, 10 purchases, ...
    [1, 2, 0.0, 1.2, 0.3, 45.0],  # user_1: has email, 2 vehicles, 0 purchases, ...
    ...
], dtype=torch.float)
# Shape: [~475,000, 6+]
```

### Node Type 2: Product/SKU (~50K+ nodes)

**Source**: `import_items` + `sku_prices` + `vehicle_product_fitment_data`

| Feature | Source | Encoding |
|---------|--------|----------|
| Price | sku_prices (max observed) | Log-scaled float |
| PartType | import_items.PartType | Learned embedding or one-hot |
| Global popularity | import_orders count | Log-scaled float |
| Is refurbished | import_items_tags | Binary (0/1) |
| Has image | sku_image_urls | Binary (0/1) |
| Vehicle fit count | fitment_data | Integer (how many YMMs it fits) |
| Recent order velocity | unified events | Float |

```python
data['product'].x = torch.tensor([
    [4.6, 0, 3.2, 0, 1, 45, 0.8],  # SKU_A: $100, embedding_id 0, popular, not refurb...
    ...
], dtype=torch.float)
# Shape: [~50,000, 7+]
```

### Node Type 3: Vehicle/YMM (~15K nodes)

**Source**: `vehicle_product_fitment_data` (distinct year/make/model combos)

| Feature | Source | Encoding |
|---------|--------|----------|
| Year | v1_year | Normalized float |
| Make | v1_make | Learned embedding |
| Model | v1_model | Learned embedding |
| Eligible part count | fitment_data | Integer |
| User count | users_with_v1_vehicles | Log-scaled float |

```python
data['vehicle'].x = torch.tensor([
    [0.85, 12, 43, 250, 5.2],  # 2018/FORD/MUSTANG
    ...
], dtype=torch.float)
# Shape: [~15,000, 5+]
```

---

## 4. Mapping Holley Data to Graph Edges

This is where it gets interesting. Each relationship type becomes a distinct edge type in the heterogeneous graph.

### Edge Type 1: `('user', 'viewed', 'product')`
**Source**: `ingestion_unified_schema_incremental` where event_name = 'Viewed Product'

```python
# edge_index shape: [2, num_view_events]
data['user', 'viewed', 'product'].edge_index = torch.tensor([
    [0, 0, 1, 2, 2, 2, ...],  # source user indices
    [5, 12, 5, 3, 7, 42, ...]  # target product indices
])

# Optional edge features: view count, recency
data['user', 'viewed', 'product'].edge_attr = torch.tensor([
    [3, 0.2],  # user_0 viewed product_5: 3 times, 0.2 recency score
    ...
])
```

### Edge Type 2: `('user', 'carted', 'product')`
**Source**: unified events where event_name = 'Cart Update'

Stronger signal than views. In our current system this is weighted 10x vs 2x for views. Constructed the same way as view edges — separate edge type so the GNN learns different weights automatically.

```python
data['user', 'carted', 'product'].edge_index = torch.tensor([
    [0, 1, 2, ...],     # user indices
    [12, 5, 42, ...]    # product indices
])
data['user', 'carted', 'product'].edge_attr = torch.tensor([
    [2, 0.5],  # cart_count, recency
    ...
])
```

### Edge Type 3: `('user', 'purchased', 'product')`
**Source**: `import_orders` (historical) + unified events (Placed Order, Ordered Product, Consumer Website Order) for Sep 1+ data

Strongest signal. Currently weighted 20x. Note: two data sources with different schemas feed this one edge type — import_orders uses email join, unified events use user_id join.

```python
data['user', 'purchased', 'product'].edge_index = torch.tensor([
    [0, 0, 3, 5, ...],   # user indices
    [7, 22, 7, 100, ...]  # product indices
])
data['user', 'purchased', 'product'].edge_attr = torch.tensor([
    [1, 0.1],  # purchase_count, recency
    ...
])
```

### Edge Type 4: `('product', 'fits', 'vehicle')`
**Source**: `vehicle_product_fitment_data`

This is the **fitment constraint** — the backbone of our recommendations. A product can only be recommended if it fits the user's vehicle.

```python
# This is a bipartite graph: products → vehicles they fit
data['product', 'fits', 'vehicle'].edge_index = torch.tensor([
    [0, 0, 0, 1, 1, 2, ...],    # product indices
    [10, 11, 12, 10, 15, 12, ...]  # vehicle (YMM) indices they fit
])
```

### Edge Type 5: `('user', 'drives', 'vehicle')`
**Source**: `ingestion_unified_attributes_schema_incremental` (v1_year/make/model)

Links users to their registered vehicle. This is critical for the fitment constraint.

```python
data['user', 'drives', 'vehicle'].edge_index = torch.tensor([
    [0, 1, 2, ...],     # user indices
    [42, 108, 42, ...]   # vehicle (YMM) indices
])
```

### Edge Type 6: `('product', 'co_purchased_with', 'product')`
**Source**: Co-purchase logic from v5.17 collaborative filtering prototype (`v5_17_collaborative_filtering_prototype.sql`)

This is product-to-product similarity from actual purchasing behavior. The v5.17 prototype computes these as temp tables — to use in the GNN, we'll need to **materialize** them or replicate the logic in the graph construction pipeline.

**Important design choice**: The SQL prototype computes co-purchases **per vehicle segment** (FORD/MUSTANG pairs are separate from CHEVY/CAMARO pairs). For the GNN, we have two options:

- **Option A (recommended)**: Collapse to global product-product edges and let the GNN learn segment context from the vehicle node neighborhood. Simpler graph, and the model can generalize across segments.
- **Option B**: Include segment as an edge feature. Preserves segment specificity but increases edge count.

```python
# Option A: Global co-purchase edges with strength as edge feature
data['product', 'co_purchased_with', 'product'].edge_index = ...
data['product', 'co_purchased_with', 'product'].edge_attr = torch.tensor([
    [0.85, 15],  # prob_b_given_a=0.85, users_bought_both=15
    ...
])
```

### Edge Type 7 (optional): `('product', 'same_parttype', 'product')`
**Source**: `import_items.PartType`

Connects products of the same category. Helps the GNN learn that a user interested in carburetors might like related carburetor accessories.

---

## 5. The Complete Graph Structure (Visual)

```
                    drives
    User ────────────────────── Vehicle (YMM)
     │ │ │                          │
     │ │ │  viewed/carted/purchased │ fits
     │ │ │                          │
     │ │ └─────────── Product ──────┘
     │ │                │   │
     │ │                │   │ co_purchased_with
     │ │                │   │ same_parttype
     │ │                └───┘
     │ │
     │ └── (treatment edges from CTR data, optional)
     │
     └── (user-to-user similarity, optional, derived)
```

### Scale Numbers (approximate)

| Component | Count |
|-----------|-------|
| User nodes | ~475,000 |
| Product nodes | ~50,000 |
| Vehicle nodes | ~15,000 |
| view edges | ~2,000,000+ |
| cart edges | ~500,000 |
| purchase edges | ~1,000,000 |
| fits edges | ~500,000 |
| drives edges | ~475,000 |
| co-purchase edges | depends on min_support |

---

## 6. How Message Passing Works (For The Team)

### The Core Idea

In each GNN layer, every node **collects information from its neighbors**, transforms it, and updates its own representation. After multiple layers, a node "knows about" its multi-hop neighborhood.

### Concrete Example with Holley Data

Imagine User A who drives a 2018 Ford Mustang and viewed Product X:

**Layer 1** — each node gathers info from direct neighbors:
- User A gathers: "I drive a 2018 Mustang" + "I viewed Product X"
- Product X gathers: "User A viewed me" + "I fit 2018 Mustang" + "I'm co-purchased with Product Y"
- Vehicle (2018 Mustang) gathers: "User A drives me" + "Products X, Y, Z fit me"

**Layer 2** — nodes now gather from already-enriched neighbors:
- User A gathers from Product X (which now knows about co-purchases and fitment)
- User A effectively "sees": "Product Y is often co-purchased with X, and Y also fits my Mustang"

**Layer 3** — even longer-range patterns:
- User A can now benefit from: "Other Mustang users who viewed X also viewed Z, and Z has high popularity"

This is the **multi-hop reasoning** that our SQL formulas can't capture.

### In PyG Code (Recommended Approach: `to_hetero()`)

PyG offers multiple approaches. The simplest and recommended one for us: **write a standard GNN, then auto-convert it to heterogeneous** using `to_hetero()`.

```python
import torch
import torch.nn as nn
from torch_geometric.nn import SAGEConv, to_hetero

# Step 1: Define a SIMPLE GNN as if it were a homogeneous graph
# (single node type, single edge type — keep it simple)
class GNN(nn.Module):
    def __init__(self, hidden_channels):
        super().__init__()
        # Use (-1, -1) for lazy initialization — PyG infers input dims
        self.conv1 = SAGEConv((-1, -1), hidden_channels)
        self.conv2 = SAGEConv((-1, -1), hidden_channels)

    def forward(self, x, edge_index):
        x = self.conv1(x, edge_index).relu()
        x = self.conv2(x, edge_index).relu()
        return x

# Step 2: Automatically convert to heterogeneous
model = GNN(hidden_channels=64)
model = to_hetero(model, data.metadata(), aggr='sum')
# PyG automatically creates SEPARATE learned parameters for EACH edge type!
# ('user','viewed','product') gets its own SAGEConv weights
# ('product','fits','vehicle') gets its own SAGEConv weights
# ... and so on for all 7 edge types
```

The `to_hetero()` transform is the magic — it takes your simple model and replicates it with separate learned weights for each edge type. So the model learns that "purchase" edges are weighted differently than "view" edges, automatically.

**Note**: The `(-1, -1)` lazy initialization is important — different node types have different feature dimensions (users have 6+ features, products have 7+, vehicles have 5+), so PyG needs to infer sizes at runtime.

---

## 7. The Recommendation Task: Link Prediction

Our goal is: **for a given user, predict which products they would interact with (buy/click)**. In GNN terms, this is **link prediction** — predicting missing edges of type `('user', 'would_buy', 'product')`.

### Training Setup

```python
import torch.nn.functional as F

# Reuse the same GNN class from above (Section 6)
# The Encoder is the same simple GNN, converted via to_hetero()

class Decoder(nn.Module):
    """Predicts link probability from user and product embeddings."""
    def forward(self, z_user, z_product, edge_label_index):
        # Dot product between user and product embeddings
        src = z_user[edge_label_index[0]]
        dst = z_product[edge_label_index[1]]
        return (src * dst).sum(dim=-1)

class RecommenderGNN(nn.Module):
    def __init__(self, hidden_channels, metadata):
        super().__init__()
        # Same pattern as Section 6: define simple GNN, then to_hetero()
        self.encoder = GNN(hidden_channels)
        self.encoder = to_hetero(self.encoder, metadata, aggr='sum')
        self.decoder = Decoder()

    def forward(self, x_dict, edge_index_dict, edge_label_index):
        z_dict = self.encoder(x_dict, edge_index_dict)
        # Score user-product pairs
        return self.decoder(
            z_dict['user'],
            z_dict['product'],
            edge_label_index
        )
```

### Training Data: What We Already Have

| Training signal | Maps to | Label |
|-----------------|---------|-------|
| User purchased product | Positive edge | 1 |
| User carted product | Positive edge (weaker) | 1 |
| User viewed but didn't buy | Can be positive or negative | 0.5 |
| Random user-product pair (fits vehicle) | Negative edge | 0 |
| User already excluded (365d purchase) | Not in training set | — |

### Negative Sampling Strategy

Critical detail: negative samples must respect **fitment constraints**. We don't want the model to learn "don't recommend this carburetor to a Mustang user" when the real reason is the carburetor doesn't fit a Mustang. We only sample negatives from products that **do fit** the user's vehicle.

```python
# Pseudocode for fitment-aware negative sampling
def sample_negatives(user_id, vehicle_ymm, positive_skus, eligible_parts):
    # Only sample from products that fit the user's vehicle
    candidates = eligible_parts[vehicle_ymm] - positive_skus
    return random.sample(candidates, k=num_negatives)
```

---

## 8. How Current Pipeline Features Map to GNN

| Current Pipeline Component | GNN Equivalent |
|---------------------------|----------------|
| Intent score (view/cart/order weights) | Learned edge-type weights via separate SAGEConv per edge type |
| Popularity score | Learned from node degree + neighbor aggregation |
| Fitment constraint | Hard constraint via `('product', 'fits', 'vehicle')` edges |
| Co-purchase patterns (v5.17 CF prototype) | `('product', 'co_purchased_with', 'product')` edges |
| Variant dedup (140061B → 140061) | Pre-processing: merge variant nodes before graph construction |
| Diversity filter (max 2 per PartType) | Post-processing: apply after GNN scoring |
| Purchase exclusion (365d window) | Post-processing: exclude from candidate set |
| Price filter (>= $50) | Pre-processing: exclude from graph OR post-processing filter |

### What stays as pre/post-processing (not learned):
- Variant deduplication (deterministic rule)
- Purchase exclusion window (business rule)
- Price minimum (business rule)
- Diversity cap (business rule)
- Image URL requirement (data quality rule)

### What the GNN replaces:
- The hand-tuned scoring formula (LOG(1+n) x weight)
- The fixed intent hierarchy (order > cart > view)
- The additive combination of intent + popularity
- Static co-purchase scores

The GNN **learns** the optimal weighting from actual click/purchase outcomes.

---

## 9. Mini-Batch Training (Because 475K Users Won't Fit in GPU Memory)

PyG provides `NeighborLoader` for sampling subgraphs during training:

```python
from torch_geometric.loader import NeighborLoader

# Sample 2-hop neighborhoods, 10 neighbors per hop per edge type
train_loader = NeighborLoader(
    data,
    num_neighbors={key: [10, 10] for key in data.edge_types},
    batch_size=1024,
    input_nodes=('user', train_user_mask),
    shuffle=True,
)

for batch in train_loader:
    # batch is a small HeteroData with ~1024 users + their neighborhoods
    pred = model(batch.x_dict, batch.edge_index_dict, batch.edge_label_index)
    loss = F.binary_cross_entropy_with_logits(pred, batch.edge_label)
    loss.backward()
    optimizer.step()
```

Each batch samples ~1024 seed users, then expands 2 hops outward, pulling in the products they interacted with, the vehicles those products fit, and neighboring products via co-purchase edges. This keeps GPU memory manageable.

---

## 10. Evaluation: How Do We Know It's Better?

### Offline Metrics

| Metric | How to measure | Current baseline |
|--------|---------------|-----------------|
| Hit Rate @4 | Did the user click/buy one of top 4? | Measure from CTR data |
| NDCG @4 | Are purchased items ranked higher? | N/A (new metric) |
| Coverage | How many unique SKUs recommended? | From QA checks |
| Diversity | PartType spread in top 4 | From diversity filter stats |

### Online A/B Test (integrates with existing infrastructure)

We already have the Personalized vs Static treatment framework. The GNN-scored recommendations would become a **new treatment arm**:

1. Treatment A: Current v5.17 pipeline (SQL scoring)
2. Treatment B: GNN-scored recommendations
3. Measure: CTR, conversion rate, revenue per user

Use the existing `treatment_history_sent` and `treatment_interaction` tables + Thompson Sampling analysis from `src/bandit_click_holley.py`.

---

## 11. Architecture: Where GNN Fits in the Pipeline

```
┌─────────────────────────────────────────────────┐
│  OFFLINE (batch, runs daily/weekly)              │
│                                                  │
│  BigQuery ──extract──▶ Graph Construction        │
│  (same source tables)  (Python + PyG)            │
│                              │                   │
│                              ▼                   │
│                     GNN Training/Inference        │
│                     (GPU, PyTorch)                │
│                              │                   │
│                              ▼                   │
│                     Score all (user, product)     │
│                     pairs where product fits      │
│                     user's vehicle                │
│                              │                   │
│                              ▼                   │
│                     Apply post-processing         │
│                     (dedup, diversity, exclusion)  │
│                              │                   │
│                              ▼                   │
│                     Write to BigQuery             │
│                     final_vehicle_recommendations │
│                                                  │
│  (Same output format as current pipeline)        │
└─────────────────────────────────────────────────┘
```

The output table schema stays **identical** — the email system doesn't need to change. We're just replacing the scoring engine.

---

## 12. Practical Considerations

### Data Pipeline

| Step | Tool | Notes |
|------|------|-------|
| Extract from BigQuery | `bq` CLI or Python `google-cloud-bigquery` | Same queries as current pipeline |
| Build graph | Python + PyG `HeteroData` | Map user_id/sku to integer indices |
| Train model | PyTorch + PyG on GPU | Metaflow on K8s (existing infrastructure) |
| Inference | PyTorch | Score all eligible user-product pairs |
| Write results | BigQuery API | Same output table format |

### Challenges to Discuss

1. **Cold start**: New users with no interaction history get no GNN signal. Fallback to popularity-based (same as current pipeline for most users).

2. **Feature engineering vs. end-to-end**: We can either (a) use our existing SQL-computed features as node attributes, or (b) let the GNN learn everything from raw interactions. Option (a) is pragmatic for v1.

3. **Scalability**: 475K users x 50K products = 23.75B potential pairs. We constrain this via fitment (each user's vehicle fits maybe ~2K products), bringing it to ~950M pairs. Mini-batch inference handles this.

4. **Retraining frequency**: Our current pipeline runs on-demand. GNN would need a training schedule — weekly retraining with daily inference is a reasonable starting point.

5. **Explainability**: "Why was this recommended?" is harder to answer with GNN than with our current transparent scoring. Consider extracting attention weights or using GNNExplainer.

---

## 13. Recommended Next Steps

1. **Prototype** — Build the graph from a single BigQuery snapshot. Use the collaborative filtering prototype (v5_17) data as a starting point since it already computes co-purchase edges.

2. **Baseline** — Run the GNN on historical data and compare Hit Rate @4 against current pipeline.

3. **Iterate** — Add edge types incrementally (start with purchase + fitment, then add views, carts, co-purchase).

4. **A/B Test** — Deploy as a new treatment arm using existing infrastructure.

---

## Appendix: Key PyG Concepts Glossary

| Term | Meaning | Holley Example |
|------|---------|----------------|
| **HeteroData** | PyG's data object for multi-type graphs | Our full graph with users, products, vehicles |
| **Node type** | A category of entity | `'user'`, `'product'`, `'vehicle'` |
| **Edge type** | A triplet `(src_type, relation, dst_type)` | `('user', 'purchased', 'product')` |
| **Message passing** | Nodes aggregate info from neighbors | Product gathers purchase signals from users |
| **to_hetero()** | Auto-converts homogeneous GNN to heterogeneous | Creates per-edge-type SAGEConv layers |
| **SAGEConv** | GraphSAGE convolution (sample + aggregate) | Good for large-scale, inductive learning |
| **NeighborLoader** | Mini-batch sampler for large graphs | Samples 1024 users + their neighborhoods |
| **Link prediction** | Predict missing edges | "Will user X buy product Y?" |
| **Negative sampling** | Generate "no interaction" training pairs | Random (but fitment-valid) user-product pairs |
