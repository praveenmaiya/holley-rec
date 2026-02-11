# Engineering Review: Prism Proposal + Tech Stack Alignment

**Author:** Praveen M
**Date:** Feb 10, 2026
**Context:** Review of "Auxia + True Theta: Prism" (DJ Rich, Jan 26) and "Tech Stack Thoughts" (DJ Rich, Jan 28)

---

## 1. Core Tension: Multi-Format Output vs. TF Standardization

The two documents pull in opposite directions on a fundamental question.

- **Tech Stack doc** says: simplify around TensorFlow, fewer models, fewer data types. DS output should be a config file, not code.
- **Prism proposal** says: support Pandas, Polars, TF Datasets, and Streaming as first-class output formats.

Supporting four output formats means maintaining four serialization paths, four sets of null-handling semantics, four sets of dtype edge cases. The Drawbacks section already flags this ("subtle differences in how these libraries handle things like null types or integer overflows could lead to inconsistent model behavior"). This is a real risk, not a theoretical one.

**Recommendation: Use Apache Arrow as the single canonical in-memory format.**

- PyArrow converts zero-copy to both Pandas (`.to_pandas()`) and Polars (`pl.from_arrow()`).
- TensorFlow can consume Arrow via `tf.data` or direct tensor construction.
- Prism maintains one serialization path (BQ result -> Arrow -> GCS as Parquet).
- Users still get format flexibility at the edge, but Prism only tests and guarantees one internal representation.

This reduces the multi-format testing burden from O(N formats) to O(1 internal) + thin conversion wrappers.

---

## 2. Training/Serving Skew: Nail the `get_processor()` Contract First

The `get_processor()` concept is the highest-value piece of Prism. It is also the piece most likely to be designed incorrectly if the serving runtime is not decided upfront.

### Questions That Must Be Answered Before Phase 2

**Q1: What is the serving runtime?**
- If TF Serving: the processor must be a `tf.function` with a concrete `input_signature`, serializable as a SavedModel. No arbitrary Python allowed.
- If a Python gRPC service: more flexibility, but you lose TF Serving's batching/scaling for free.
- This is the single most consequential architectural decision. Everything downstream depends on it.

**Q2: What is the processor's boundary?**
- At training time, features come from BigQuery SQL (batch, offline).
- At serving time, features come from `ml-features` via gRPC (real-time, online).
- These are completely different code paths. The processor can only own the transforms *after* raw features are already in memory. The SQL-to-features path and the gRPC-to-features path must produce identical raw feature dictionaries for the processor to provide skew protection. Who guarantees that?

**Q3: How are processors versioned?**
- If a processor changes (new categorical vocabulary, different normalization), all models trained with the old processor are now invalid.
- Processor version must be tied to model version. A model artifact without its processor is not deployable.

### Recommendation

Define the processor contract narrowly:

```
Input:  Dict[str, tf.Tensor]  (raw features, named)
Output: Dict[str, tf.Tensor]  (model-ready features, named)
```

Requirements:
- Pure function (no I/O, no state, no side effects)
- Serializable as `@tf.function` with `input_signature`
- Vocabulary/normalization parameters baked in at export time
- Versioned with a content hash

This makes the processor deployable to TF Serving directly, testable in isolation, and auditable.

---

## 3. Semantic Mapping Layer: Feature Catalog in Disguise

The API shows `features=["user.demographics", "user.behavioral_28d"]`, mapping customer-agnostic names to customer-specific `data_field_ids`. This is a feature catalog problem, and these are notoriously hard to get right.

### Questions

**Q4: Who owns the mappings and how are they updated?**
- When a new customer onboards, does an engineer write a mapping config?
- When a customer adds a new data field, does Prism auto-discover it or does someone update a registry?
- What's the expected update cadence? Weekly? Per-deployment?

**Q5: Does Prism guarantee semantic equivalence or just structural equivalence?**
- Customer A's `"user.behavioral_28d"` might include page views + clicks + add-to-carts.
- Customer B's might include only clicks.
- Same feature group name, different meaning, different model behavior.
- If Prism doesn't guarantee semantic equivalence, the cross-customer promise is weaker than it appears.

**Q6: What happens when a requested feature group doesn't exist for a customer?**
- Fail hard with an error? Return null columns? Silently skip?
- This matters for any workflow that tries to reuse a feature config across customers.

### Recommendation

Build the registry as versioned YAML configs per customer with schema validation:

```yaml
# configs/customers/1950_holley/features.yaml
version: "2026-02-01"
feature_groups:
  user.demographics:
    fields:
      - data_field_id: 42
        name: age_bucket
        type: categorical
        vocabulary: ["18-24", "25-34", "35-44", "45-54", "55+"]
      - data_field_id: 87
        name: state
        type: categorical
  user.behavioral_28d:
    fields:
      - data_field_id: 103
        name: page_views_28d
        type: numeric
      - data_field_id: 104
        name: clicks_28d
        type: numeric
```

A schema validation step runs before any query is generated, catching missing fields, type mismatches, and stale vocabulary references. This is config-driven and auditable, consistent with DJ's principle that DS output should be config, not code.

---

## 4. Labels and Targets: The Missing Piece

The Prism proposal focuses entirely on features. From our work on the Holley email recommendation pipeline, we've learned that **label/target construction is as error-prone as feature construction**, and arguably more dangerous because label errors are silent.

### Concrete Examples from Holley

| Issue | Impact | Root Cause |
|-------|--------|------------|
| CTR formula used `SUM(clicked)/SUM(opened)` | ~0.5-0.9pp CTR inflation for Personalized treatments | Image-blocking email clients register `clicked=1` but `opened=0`. Phantom clicks must be excluded. |
| Per-send CTR vs. per-user binary CTR | Completely different treatment rankings | Personalized sends 6.3x/user vs Static 1.9x/user. Frequency dilution dominates per-send metrics. |
| Attribution window ambiguity | Conversion rates vary 2-3x depending on window | Is a purchase 1 hour after click attributed? 24 hours? 7 days? |

These are not Holley-specific. Any email/notification customer will hit the same issues.

### Recommendation

Prism should support standardized target definitions alongside features:

```python
data_reference = client.create_data_request(
    customer_id="1950",
    features=["user.behavioral_28d", "treatment.content"],
    targets=[
        "treatment.clicked_given_opened",   # Excludes phantom clicks
        "treatment.converted_7d",           # 7-day attribution window
    ],
    grain="per_user_binary",                # Not per-send
)
```

Target definitions encode the label construction logic (attribution windows, phantom click exclusion, grain) in the same config-driven, skew-protected way as features. Without this, every DS team will re-derive labels differently and get bitten by the same bugs.

---

## 5. Cost Guardrails

BigQuery charges by bytes scanned. One Prism query without a partition filter can scan terabytes and cost hundreds of dollars. During exploration, DSs will run many queries. This needs guardrails.

### Recommendation

Add cost estimation before execution:

```python
data_reference = client.create_data_request(...)

print(data_reference.metadata.estimated_bytes_scanned)  # "42.3 GB"
print(data_reference.metadata.estimated_cost_usd)       # "$0.21"

# Auto-abort if over threshold (default 500GB, configurable)
data_reference.run(max_bytes=500_000_000_000)
```

Implementation: BQ supports `--dry_run` which returns bytes scanned without executing. Prism should always dry-run first, expose the estimate, and abort if over threshold. This is cheap to build and prevents expensive mistakes.

---

## 6. Point-in-Time Join Semantics

The proposal mentions this as a bullet point. It deserves a dedicated design.

### Why This Matters

Point-in-time (as-of) joins prevent future data leakage. If a user's features are computed as of Jan 15 but the label event (click) happens on Jan 16, the feature row must only use data available on Jan 15. A naive LEFT JOIN on user_id without a timestamp constraint will pull in data from after the label event, inflating model performance during training and causing degradation in production.

### Questions

**Q7: Does Prism enforce point-in-time correctness by default, or is it opt-in?**
- It should be enforced by default. Leakage is a silent model killer. Making it opt-out (with a `allow_future_leakage=True` escape hatch for debugging) is safer than opt-in.

**Q8: How is the "as-of" timestamp determined?**
- Is it the event timestamp of the label? The treatment send time? A user-specified cutoff?
- For Holley, the treatment send timestamp is the anchor. Features must be as-of send time.

### Recommendation

Make point-in-time the default join strategy. Implement it as a templated SQL pattern:

```sql
-- Features as-of the label event timestamp
SELECT f.*
FROM features f
INNER JOIN labels l
  ON f.user_id = l.user_id
  AND f.feature_timestamp <= l.event_timestamp
  AND f.feature_timestamp >= DATE_SUB(l.event_timestamp, INTERVAL @lookback_days DAY)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY l.user_id, l.event_id
  ORDER BY f.feature_timestamp DESC
) = 1
```

This is parameterized by `lookback_days` and always takes the most recent feature snapshot before the event.

---

## 7. Timeline and Scoping Concerns

### Phase 2 Estimate is 2-6 Weeks (3x Range)

This range signals significant uncertainty about scope. The risk is that Phase 1 produces an ambitious design and Phase 2 cannot deliver it in time.

**Recommendation: Define a Prism 0.1 MVP.**

Prism 0.1 scope:
- One customer (pick one with well-understood data, like Holley or another active customer)
- One surface
- Arrow as the only internal format, with `.to_pandas()` convenience
- `get_processor()` producing a `@tf.function`
- Point-in-time joins enforced by default
- Feature registry as YAML config
- Cost estimation via dry-run

Prism 0.1 explicitly defers:
- Multi-customer semantic mapping
- Polars/Streaming as first-class outputs
- Migration of existing pipelines (Phase 3)

This de-risks the timeline and gives a concrete artifact to validate against.

### Phase 3 Migration: Define "Identical" Upfront

**Q9: What does "identical models" mean for migration testing?**
- Bit-for-bit identical predictions? (Very hard. Different join orders, float aggregation paths, etc.)
- Predictions within tolerance (e.g., max absolute difference < 1e-6)?
- Same model performance metrics on a held-out set (e.g., AUC within 0.001)?

Define acceptance criteria before starting migration, not during.

### Adoption Risk

**Q10: Who is the first Auxia-internal user (not on the True Theta team)?**

If nobody at Auxia adopts Prism during Phase 2, it risks becoming dead code after True Theta's 12-16 week engagement ends. Identify an internal champion who will:
- Use Prism during Phase 2 (not just review PRs)
- Own it after the engagement ends
- Have time allocated for this

---

## 8. Config-Driven Models: What's the Schema?

DJ's point that "the output of a data scientist should be a config file, not code" is a strong and valuable principle. But it raises practical questions.

**Q11: How expressive does the config need to be?**

A simple config might look like:

```yaml
model:
  type: tf_decision_forest
  target: treatment.clicked_given_opened
  features:
    - user.behavioral_28d
    - treatment.content
  hyperparameters:
    num_trees: 300
    max_depth: 12
```

But what happens when a DS needs:
- Custom feature crosses?
- A non-standard loss function?
- Post-processing logic (calibration, threshold tuning)?

**Q12: Is there an escape hatch for custom logic, or is the config the hard boundary?**

### Recommendation

Start with a narrow config schema that covers 80% of use cases (standard classification/regression with tabular features). Provide a documented extension point (e.g., a `custom_transform_fn` hook in the config) for the 20% that requires custom logic. Don't try to make the config language Turing-complete.

---

## Summary of Recommendations

| # | Recommendation | Effort | Impact |
|---|---------------|--------|--------|
| 1 | Arrow as canonical internal format | Low | Eliminates multi-format parity bugs |
| 2 | Decide serving runtime before building `get_processor()` | Zero (it's a decision) | Prevents architectural rework |
| 3 | Define processor contract as pure `@tf.function` | Medium | Enables TF Serving deployment, testability |
| 4 | Versioned YAML feature configs per customer | Medium | Config-driven, auditable, extensible |
| 5 | Include target/label definitions in Prism | Medium | Prevents silent label bugs (phantom clicks, attribution) |
| 6 | Cost guardrails via BQ dry-run | Low | Prevents expensive mistakes |
| 7 | Point-in-time joins as enforced default | Medium | Prevents silent data leakage |
| 8 | Define Prism 0.1 MVP for one customer | Zero (it's scoping) | De-risks the 2-6 week Phase 2 estimate |
| 9 | Define "identical models" tolerance before Phase 3 | Zero (it's criteria) | Prevents open-ended migration QA |
| 10 | Identify an Auxia-internal champion | Zero (it's a conversation) | Prevents post-engagement abandonment |

---

## Questions Checklist for the Meeting

- [ ] Q1: What is the serving runtime? (TF Serving vs. Python gRPC)
- [ ] Q2: Where does the processor boundary sit? (Post-extraction transforms only, or end-to-end?)
- [ ] Q3: How are processors versioned and tied to models?
- [ ] Q4: Who owns feature mappings and how are they updated?
- [ ] Q5: Semantic equivalence vs. structural equivalence across customers?
- [ ] Q6: Behavior when a feature group doesn't exist for a customer?
- [ ] Q7: Point-in-time joins: default-on or opt-in?
- [ ] Q8: How is the as-of timestamp anchor determined?
- [ ] Q9: What does "identical models" mean for migration acceptance?
- [ ] Q10: Who is the Auxia-internal champion post-engagement?
- [ ] Q11: Config schema expressiveness -- where's the boundary?
- [ ] Q12: Escape hatch for custom logic beyond the config?
