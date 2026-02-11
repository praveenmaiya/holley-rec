# Click Bandit Model - Technical Reference

Beta-Binomial Thompson Sampling for email treatment optimization.

---

## What is Thompson Sampling?

Thompson Sampling is a **Bayesian approach to the multi-armed bandit problem** - the classic explore vs exploit tradeoff. In Auxia's context:

- **Problem**: You have multiple email treatments (templates/variants). Which one should you show to maximize clicks?
- **Challenge**: You don't know the true click rate of each treatment. You need to learn while also maximizing results.

---

## How the Beta-Binomial Model Works

### 1. The Setup

Each treatment has an unknown true click-through rate (CTR). We model our **belief** about this CTR using a **Beta distribution**.

```
CTR ~ Beta(α, β)
```

### 2. Prior (Starting Belief)

Before seeing any data, we start with a **uniform prior**:
```python
PRIOR_ALPHA = 1.0  # α = 1
PRIOR_BETA = 1.0   # β = 1
```

This means: "Any CTR between 0% and 100% is equally likely" (no initial bias).

### 3. Posterior Update (Learning from Data)

After observing clicks, we update our belief using **Bayes' theorem**:

```
Posterior = Beta(α + clicks, β + views - clicks)
```

| Parameter | Formula | Meaning |
|-----------|---------|---------|
| α (alpha) | 1 + clicks | "Successes" observed |
| β (beta) | 1 + views - clicks | "Failures" observed |

**Example**: Treatment A has 100 views, 10 clicks
- α = 1 + 10 = 11
- β = 1 + 90 = 91
- Posterior mean CTR = 11/(11+91) = **10.8%**

### 4. Thompson Sampling (Decision Making)

For each new user:
1. **Sample** a CTR from each treatment's Beta posterior
2. **Select** the treatment with the highest sampled CTR
3. **Observe** outcome and update posterior

```python
# Sample from each treatment's posterior
samples = rng.beta(alphas, betas)  # Random CTR draw for each

# Pick the winner
selected = argmax(samples)
```

---

## Key Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `PRIOR_ALPHA` | 1.0 | Initial "pseudo-clicks" (exploration bias) |
| `PRIOR_BETA` | 1.0 | Initial "pseudo-non-clicks" |
| `DATA_WINDOW_DAYS` | 60 | How far back to look for data |
| `SURFACE_ID` | 929 | Email surface filter |
| `n_simulations` | 10,000 | Monte Carlo samples for selection distribution |

---

## Why Thompson Sampling is Effective

| Property | Benefit |
|----------|---------|
| **Automatic exploration/exploitation** | High-uncertainty treatments get explored; proven winners get exploited |
| **Probability matching** | Selection probability matches probability of being optimal |
| **Handles cold start** | New treatments with few views still get tried (wide uncertainty) |
| **Adapts over time** | As data accumulates, uncertainty shrinks → converges to best |
| **No tuning required** | Unlike ε-greedy, no exploration rate to tune |

---

## Visual Intuition

```
Treatment A: 1000 views, 100 clicks (10% CTR)
  Beta(101, 901) → tight distribution around 10%

Treatment B: 50 views, 8 clicks (16% CTR)
  Beta(9, 43) → wide distribution, high uncertainty

Thompson Sampling will:
- Usually pick A (more confident)
- Sometimes pick B (might be better, worth exploring)
- Over time, learn which is truly better
```

---

## Posterior Metrics

```python
posterior_mean = α / (α + β)                      # Expected CTR
posterior_stddev = sqrt(αβ / ((α+β)²(α+β+1)))    # Uncertainty
```

- **High stddev** = high uncertainty → more exploration
- **Low stddev** = confident → more exploitation

---

## Implementation Flow

1. **Query BigQuery** for last 60 days of views/clicks per treatment
2. **Compute posteriors** for each treatment
3. **Simulate** 10K users to estimate selection distribution
4. **Output** which treatments would be selected and how often

---

## Source Tables

| Table | Purpose |
|-------|---------|
| `auxia-gcp.company_1950.treatment_history_sent` | Email sends with treatment_id |
| `auxia-gcp.company_1950.treatment_interaction` | Opens (VIEWED) and clicks (CLICKED) |

---

## Code Reference

- `src/bandit_click_holley.py` - Main implementation
- `flows/run.sh src/bandit_click_holley.py` - Run on K8s

---

## Next Steps (TODO)

- [ ] Run latest bandit analysis
- [ ] Compare personalized vs static treatments
- [ ] Analyze treatment selection distribution

---

*Reference doc created: Dec 10, 2025*
