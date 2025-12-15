# Deep Analysis: Auxia Bandit Models

**Date:** 2025-12-14
**Scope:** `prediction/python/src/main/python/auxia.prediction.colab` and `auxia.prediction.metaflow`

---

## Executive Summary

**"What did you think of the Bandit model?"**

The bandit implementation is **solid, production-ready, but conservative**. It uses a well-understood Bayesian approach (Normal-Inverse-Gamma Thompson Sampling) that prioritizes stability and interpretability over cutting-edge sophistication. This is a reasonable choice for a production system, but there are clear opportunities for improvement.

---

## 1. Model Inventory and Structure

### The Bandit Model Ecosystem

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        BANDIT MODEL ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    ALGORITHM LAYER                               │   │
│  │  auxia.prediction.colab/algorithms/bandits.py                   │   │
│  │                                                                  │   │
│  │  ┌──────────────────────────┐  ┌───────────────────────────────┐│   │
│  │  │ NormalInverseGamma      │  │ IPSNormalInverseGamma         ││   │
│  │  │ ClickBandit             │──│ ClickBandit                   ││   │
│  │  │                         │  │ (extends parent)              ││   │
│  │  │ • Thompson Sampling     │  │ • IPS weighting for           ││   │
│  │  │ • Conjugate prior       │  │   observational bias          ││   │
│  │  │ • Batch training        │  │ • Propensity correction       ││   │
│  │  └──────────────────────────┘  └───────────────────────────────┘│   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ▼                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    SERVING LAYER                                 │   │
│  │  modeltraining/models/bandit_click_serving_model.py             │   │
│  │                                                                  │   │
│  │  ┌──────────────────────────────────────────────────────────┐   │   │
│  │  │ BanditClickModel (TensorFlow Module)                      │   │   │
│  │  │                                                           │   │   │
│  │  │ • Lookup tables: treatment_id → (mean, stddev)            │   │   │
│  │  │ • Stateless random sampling (seeded by user+treatment+day)│   │   │
│  │  │ • O(1) inference per treatment                            │   │   │
│  │  └──────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ▼                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    WORKFLOW LAYER                                │   │
│  │  auxia.prediction.metaflow/flows/modeltraining/common/         │   │
│  │  bandit_click_model.py                                          │   │
│  │                                                                  │   │
│  │  start → nig_implementation → metrics → end                     │   │
│  │    │           │                  │                              │   │
│  │    │           │                  └─ AUC evaluation              │   │
│  │    │           └─ Train + Deploy to Docker                       │   │
│  │    └─ BigQuery data extraction (122 days)                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Comparison with Other Models in Codebase

| Model | Type | Complexity | Personalization |
|-------|------|------------|-----------------|
| **BanditClickModel** | Thompson Sampling | Low | None (treatment-level only) |
| **UserClickModel** | LightGBM/Neural | High | User + Treatment features |
| **HVAUpliftModel** | Causal/Uplift | High | User + Treatment features |
| **TwoTower** | Deep Learning | Very High | Embeddings for both |

---

## 2. Technical Deep Dive

### The Mathematical Model

**Normal-Inverse-Gamma (NIG) Prior:**

The model uses the NIG distribution as a conjugate prior for estimating CTR:

```
Prior: NIG(α=1, β=1, μ=0, λ=1) for each arm

After observing n views and k clicks:

Updated parameters:
  μ_new = (λ·μ_old + k) / (λ + n)           # Posterior mean CTR
  λ_new = λ + n                              # Precision (confidence)
  α_new = α + 0.5·n                          # Shape parameter
  β_new = β + variance_adjustment            # Scale parameter
```

**Thompson Sampling Selection:**
```python
# Sample from posterior and pick highest
sampled_mean = μ + stddev * random_normal()
where stddev = sqrt(β / (λ * (α - 0.5)))
```

### Key Implementation Details

**1. Stateless Design** (`bandits.py:6-10`)
```python
"""
This is a stateless implementation as the model is retrained
every time with the entire dataset.
In the future, we can look into saving current parameters
and only performing online learning
"""
```

This is a **batch learning** approach - the model is completely retrained from scratch every cycle using ~120 days of data.

**2. Deterministic Randomness** (`bandit_click_serving_model.py:45`)
```python
user_treatment_concated = treatment_ids_cart + ':' + user_ids_cart + '@' + \
    tf.strings.as_string(tf.math.floordiv(tf.timestamp(), 86400))
probabilities = tf_random.stateless_normal_batched(user_treatment_concated, 1)
```

The randomness is seeded by `treatment_id:user_id@day`. This means:
- Same user sees same ranking all day (consistency)
- Different users see different rankings (exploration diversity)
- Rankings change daily (continued exploration)

**3. High-Performance Random Number Generation** (`tf_random.py`)
Uses custom Box-Muller transform with FarmHash fingerprinting for batched, deterministic random sampling - much faster than `tf.random.stateless_*`.

---

## 3. Strengths (Pros)

### What's Done Well

| Strength | Why It Matters |
|----------|----------------|
| **Conjugate Prior** | Closed-form posterior updates - no iterative optimization, no neural network training |
| **Interpretable** | Can explain exactly why each treatment is ranked (posterior mean, variance) |
| **Computationally Efficient** | O(1) lookup at serving time, minimal training compute |
| **Numerically Stable** | Handles edge cases (zero trials, clicks > views, infinite variance) |
| **IPS Variant Exists** | Can correct for observational bias when needed |
| **Deterministic Per-Day** | Consistent user experience within a day |
| **Well-Tested** | 395 lines of comprehensive tests covering edge cases |
| **Production-Ready** | Clean separation of algorithm/serving/workflow layers |

### The Conservative Choice is Often Correct

For CTR prediction in recommendation systems, simple models often outperform complex ones because:
1. **Cold start is common** - New treatments lack data for complex models
2. **Non-stationarity** - User preferences shift; simple models adapt faster
3. **Debuggability** - When something goes wrong, you can diagnose it

---

## 4. Weaknesses (Cons)

### Critical Limitations

| Weakness | Impact | Severity |
|----------|--------|----------|
| **No Contextual Information** | Ignores user features, time, device, etc. | **HIGH** |
| **Treatment-Level Only** | All users get same posterior for each treatment | **HIGH** |
| **Batch Retraining** | Can't adapt to real-time feedback | MEDIUM |
| **Gaussian Assumption** | CTR is Bernoulli, not Normal (misspecified likelihood) | MEDIUM |
| **No Feature Sharing** | Similar treatments don't share information | MEDIUM |
| **Fixed Training Window** | 122 days may be too long for fast-changing domains | LOW |

### The Elephant in the Room: No Personalization

Looking at `bandit_click_serving_model.py:35`:
```python
def __call__(self, treatment_features, treatment_count, user_features):
    # ...
    scoring_means = self.lookup_mean.lookup(treatment_ids_cart)  # Only uses treatment_id!
    # user_features is only used for seeding randomness, NOT for scoring
```

**The user features are completely ignored for scoring.** They only seed the random number generator. This means:
- A power user and a new user see the same underlying treatment scores
- Time of day, device, location - all ignored
- Massive missed opportunity for personalization

Compare with `UserClickModel` which uses full user features + treatment embeddings.

---

## 5. State of the Art Comparison

### What the Literature Says (2024-2025)

| Advancement | Description | Auxia Has? |
|-------------|-------------|------------|
| **Contextual Bandits** | Use user/context features in arm selection | No |
| **Linear Thompson Sampling** | Linear payoff model with context | No |
| **Feel-Good Thompson Sampling** | Optimism bonus for better regret bounds | No |
| **Variance-Aware TS** | Variance-dependent exploration | Partially (uses stddev) |
| **Neural Thompson Sampling** | Deep learning for complex patterns | No |
| **Diffusion Model Priors** | Modern generative priors | No |

### Regret Bounds Context

The current implementation achieves approximately O(√(KT)) regret where:
- K = number of treatments (arms)
- T = number of trials

State-of-the-art contextual bandits achieve O(d√T) where d = feature dimension, which can be much better when K >> d.

---

## 6. Improvement Opportunities

### Tier 1: Quick Wins (Low Effort, High Impact)

**1. Add Contextual Features (Linear Thompson Sampling)**
```python
# Current: treatment-only
score = posterior_mean[treatment_id] + stddev * random()

# Improved: contextual
score = dot(theta, concat(user_features, treatment_features)) + stddev * random()
```

**2. Online Learning Mode**
The code already mentions this as future work (`bandits.py:9-10`). Store and incrementally update parameters instead of full retraining.

**3. Hierarchical Priors**
Share information between similar treatments (same category, same surface) to improve cold-start.

### Tier 2: Medium Effort

**4. Neural Bandit Hybrid**
Use the `UserClickModel` (LightGBM) for exploitation, bandit for exploration:
```
final_score = (1-ε) * neural_score + ε * bandit_score
```

**5. Time-Decayed Observations**
Weight recent data more heavily:
```python
effective_views = sum(views * decay^(days_ago))
```

**6. Multi-Objective Bandits**
Optimize for CTR + other objectives (revenue, engagement duration).

### Tier 3: Strategic (High Effort, Transformative)

**7. Full Contextual Thompson Sampling**
Replace the entire model with contextual bandits that use:
- User embeddings
- Treatment embeddings
- Interaction features
- Time/device context

**8. Neural Thompson Sampling**
Use the TwoTower architecture with posterior approximation for scalable contextual bandits.

---

## 7. Verdict and Recommendations

### Overall Assessment

| Aspect | Rating | Comment |
|--------|--------|---------|
| **Code Quality** | ★★★★☆ | Clean, well-tested, production-ready |
| **Algorithm Choice** | ★★★☆☆ | Solid but dated - missing personalization |
| **Serving Efficiency** | ★★★★★ | Excellent - O(1) lookup |
| **Exploration/Exploitation** | ★★★★☆ | Thompson Sampling is well-balanced |
| **Scalability** | ★★★★☆ | Handles large treatment sets well |
| **Personalization** | ★☆☆☆☆ | Major gap - ignores user context |

### What to Tell Your Superior

> "The bandit model is a **solid, conservative implementation** of Thompson Sampling with Normal-Inverse-Gamma priors. It's production-ready, computationally efficient, and well-tested.
>
> **However, it has a significant limitation**: it doesn't use any user context for personalization. Every user sees the same underlying treatment scores - only the random exploration varies. This is a missed opportunity given that we already have the `UserClickModel` infrastructure that does use user features.
>
> **My recommendation**: In the short term, the model serves its purpose for treatment-level optimization. For the medium term, we should consider upgrading to contextual Thompson Sampling to incorporate user features, which the research literature shows can significantly improve regret bounds and recommendation quality."

---

## 8. Key File References

| File | Path | Purpose |
|------|------|---------|
| Core Algorithm | `prediction/python/src/main/python/auxia.prediction.colab/auxia/prediction/colab/algorithms/bandits.py` | NIG and IPS bandit implementations |
| Serving Model | `prediction/python/src/main/python/auxia.prediction.colab/auxia/prediction/colab/modeltraining/models/bandit_click_serving_model.py` | TensorFlow serving wrapper |
| Training Workflow | `prediction/python/src/main/python/auxia.prediction.metaflow/flows/modeltraining/common/bandit_click_model.py` | Metaflow orchestration |
| Data Generation | `prediction/python/src/main/python/auxia.prediction.colab/auxia/prediction/colab/datageneration/querytemplate/banditclick/bandit_click_template.py` | BigQuery SQL templates |
| Tests | `prediction/python/src/main/python/auxia.prediction.colab/auxia/prediction/colab/algorithms/tests/test_bandits.py` | Comprehensive test suite |
| Random Utils | `prediction/python/src/main/python/auxia.prediction.colab/auxia/prediction/colab/tensorflow/tf_random.py` | High-performance stateless random |

---

## References

- [Thompson Sampling for Contextual Bandits with Linear Payoffs](https://arxiv.org/abs/1209.3352)
- [Variance-Aware Feel-Good Thompson Sampling](https://arxiv.org/abs/2511.02123)
- [Thompson Sampling in Partially Observable Contextual Bandits](https://arxiv.org/abs/2402.10289)
- [Thompson Sampling with Noisy Contexts](https://www.mdpi.com/1099-4300/26/7/606)
- [Diffusion Models Meet Contextual Bandits](https://www.semanticscholar.org/paper/Diffusion-Models-Meet-Contextual-Bandits-with-Large-Aouali/c37c1a18245684ba8403f17ce92ed874c91a71b6)
- [Normal-Inverse-Gamma Distribution](https://en.wikipedia.org/wiki/Normal-inverse-gamma_distribution)
- [Bayesian Bandits Linear Comparison](https://bayesianbandits.readthedocs.io/en/latest/notebooks/linear-bandits.html)
- [Kevin Murphy's Conjugate Bayesian Analysis](https://www.cs.ubc.ca/~murphyk/Papers/bayesGauss.pdf)
