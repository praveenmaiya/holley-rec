# Thompson Sampling: How the Bandit Model Works

**Purpose**: Educational reference for understanding Thompson Sampling exploration behavior.

---

## Glossary: Key Concepts for Beginners

### Email Funnel

```
Send → Impression → Open (View) → Click → Conversion
  │         │           │           │          │
  │         │           │           │          └── User purchases/completes goal
  │         │           │           └── User clicks a link in the email
  │         │           └── User opens/views the email
  │         └── Email lands in inbox (delivered)
  └── System sends the email
```

### Core Metrics

| Term | What it means | Formula |
|------|---------------|---------|
| **Send** | Email dispatched to user | Count of emails sent |
| **Impression** | Email delivered to inbox | Count of emails that reached inbox |
| **Open / View** | User opened the email (tracked via invisible pixel) | Count of opens |
| **Click** | User clicked a link inside the email | Count of clicks |
| **Open Rate** | % of sent emails that were opened | `Opens / Sends × 100` |
| **CTR (Click-Through Rate)** | % that clicked | Depends on denominator (see below) |

### CTR: Three Ways to Calculate

**CTR can mean different things depending on denominator:**

| Metric | Formula | What it measures |
|--------|---------|------------------|
| **CTR/Send** | `Clicks / Sends × 100` | Overall effectiveness (business impact) |
| **CTR/Open** | `Clicks / Opens × 100` | Content quality (once user opens) |
| **CTR/Impression** | `Clicks / Impressions × 100` | Engagement among delivered |

**Example:**
```
1000 emails sent → 100 opens → 10 clicks

CTR/Send  = 10/1000 = 1.0%    ← "1% of all recipients clicked"
CTR/Open  = 10/100  = 10.0%   ← "10% of openers clicked"
```

**Which to use?**
- **CTR/Send**: Best for business decisions (includes deliverability + open + click)
- **CTR/Open**: Best for content optimization (isolates email content quality)

### Engagement

**Engagement** = any user interaction with the email:

| Engagement Type | Description | Tracked As |
|-----------------|-------------|------------|
| **VIEWED** | User opened the email | Open |
| **CLICKED** | User clicked a link | Click |

Higher engagement → user found the email relevant/valuable.

### Treatment & Arms

| Term | Definition |
|------|------------|
| **Treatment** | A specific email variant (subject line, content, recommendations) |
| **Arm** | Same as treatment - terminology from "multi-armed bandit" problem |
| **Control** | Baseline treatment for comparison (often no email or generic email) |
| **Variant** | Alternative treatment being tested |

**Why "Arm"?** Comes from slot machines ("one-armed bandits"). Each treatment is like pulling a different slot machine arm - you're trying to find which one pays out best.

### Multi-Armed Bandit

**The Problem**: You have N slot machines (arms/treatments). Each has unknown payout probability. How do you maximize total reward?

```
Arm A: ??? payout     Arm B: ??? payout     Arm C: ??? payout
   │                     │                     │
   └─────────────────────┼─────────────────────┘
                         │
              Which arm do you pull?
```

**The Dilemma**:
- **Exploit**: Keep pulling the arm that's worked best so far
- **Explore**: Try other arms to see if they're actually better

### Thompson Sampling

A **Bayesian approach** to the multi-armed bandit problem:

1. Maintain a probability distribution for each arm's success rate
2. Sample from each distribution
3. Pick the arm with highest sampled value
4. Update distribution based on outcome

**Key behavior**: Naturally balances exploration/exploitation. Arms with uncertain outcomes get explored; arms with known good outcomes get exploited.

### Model Types in Our System

| Model | model_id | Behavior |
|-------|----------|----------|
| **Random** | 1 | Selects treatments across full score range |
| **Bandit (Click)** | 195001001 | Thompson Sampling optimizing for clicks |

---

## The Problem: Exploration vs Exploitation

When sending emails, we have two competing goals:

| Goal | Description | Risk |
|------|-------------|------|
| **Exploit** | Send what we think works best | Miss better options we haven't tried |
| **Explore** | Try new options to learn | Short-term performance drops |

Thompson Sampling balances both by **deliberately testing low-probability options** to gather data.

---

## The Setup

**Two models selecting which email treatment to send:**

| Model | How it works | Traffic |
|-------|--------------|---------|
| **Random** | Picks treatments across full score range (0.0 to 1.0) | 90% |
| **Bandit** | Thompson Sampling - explores low-score options to learn | 10% |

---

## What is "Score"?

The **score** (0.0 to 1.0) predicts how likely a user-treatment pair will succeed:
- Score = 0.9 → "This user will probably engage with this email"
- Score = 0.1 → "This user probably won't engage with this email"

---

## Step-by-Step Example: Sending to 100 Users

### Step 1: Score Calculation

The system calculates a score for every user-treatment combination:

```
           Treatment A   Treatment B   Treatment C   Treatment D   Treatment E
User 1        0.85          0.12          0.45          0.33          0.91
User 2        0.23          0.78          0.56          0.11          0.44
User 3        0.67          0.89          0.22          0.55          0.71
...
User 100      0.41          0.33          0.88          0.15          0.62
```

### Step 2: Traffic Split (90/10)

```
100 users
    ├── 90 users → Random Model
    └── 10 users → Bandit Model
```

### Step 3a: Random Model (90 users)

**Logic**: Select treatment across the full score range

```
User 1:  Scores = [0.85, 0.12, 0.45, 0.33, 0.91]
         Random picks Treatment E (score 0.91) ✓

User 2:  Scores = [0.23, 0.78, 0.56, 0.11, 0.44]
         Random picks Treatment B (score 0.78) ✓

User 3:  Scores = [0.67, 0.89, 0.22, 0.55, 0.71]
         Random picks Treatment B (score 0.89) ✓
```

**Result**: Random model sends treatments with **avg score ~0.75** (spans full range)

### Step 3b: Bandit Model (10 users)

**Logic**: Thompson Sampling - explore low-score options to learn

```
User 91: Scores = [0.85, 0.12, 0.45, 0.33, 0.91]
         Bandit picks Treatment B (score 0.12) ← LOW SCORE (exploring!)

User 92: Scores = [0.23, 0.78, 0.56, 0.11, 0.44]
         Bandit picks Treatment D (score 0.11) ← LOW SCORE (exploring!)

User 93: Scores = [0.67, 0.89, 0.22, 0.55, 0.71]
         Bandit picks Treatment C (score 0.22) ← LOW SCORE (exploring!)
```

**Result**: Bandit model sends treatments with **avg score ~0.15** (concentrated in low range)

### Step 4: Emails Sent

```
Random Model (90 users):
├── High-score matches (user likely to engage)
├── Avg score: 0.75
└── Sends 90 emails

Bandit Model (10 users):
├── Low-score matches (user unlikely to engage - testing!)
├── Avg score: 0.15
└── Sends 10 emails
```

### Step 5: User Response (Opens)

**Random Model (90 users, high scores):**
```
90 emails sent with avg score 0.75
  → ~2 users open (2.2% open rate)
  → High scores = good match = expected engagement
```

**Bandit Model (10 users, low scores):**
```
10 emails sent with avg score 0.15
  → ~0.1 users open (1.1% open rate)
  → Low scores = poor match = low engagement expected
```

### Step 6: Clicks (Among Openers)

**Random Model:**
```
2 openers
  → 0.17 click (8.4% CTR/open)
  → Normal mix of interest levels
```

**Bandit Model:**
```
0.1 openers (when someone DOES open despite low score)
  → 0.012 click (12% CTR/open)
  → Self-selected: "I opened even though this wasn't targeted at me"
  → These users are genuinely interested → higher click rate
```

### Step 7: Learning (Why Bandit Explores)

The Bandit learns from its experiments:

```
Bandit tested: User 91 + Treatment B (score 0.12)
Result: User opened and clicked!

Learning: "Hmm, the model predicted 12% chance, but user engaged.
          Maybe Treatment B works better for users like User 91
          than we thought. Update beliefs!"
```

Over time:
- Bandit discovers treatments that work better than predicted
- Bandit avoids treatments that work worse than predicted
- Model improves for everyone

---

## Why Bandit Has Lower Opens But Higher CTR/Open

### The Result Chain

```
Bandit picks low scores
    ↓
Sends emails to "poor match" user-treatment pairs
    ↓
Most users don't open (as predicted) → LOW OPEN RATE (1.09%)
    ↓
BUT the few who DO open are genuinely interested (self-selected)
    ↓
Those openers click more → HIGH CTR/OPEN (12%)
```

### Visual Comparison

Imagine 1000 users receiving "Browse Recovery" email:

**Random Model (high scores):**
```
1000 users (predicted to engage)
  → 22 open (2.2% open rate)
  → 2 click (9% of openers)
```

**Bandit Model (low scores):**
```
1000 users (predicted NOT to engage)
  → 11 open (1.1% open rate) ← fewer opens because poor predicted match
  → 1.3 click (12% of openers) ← but openers are "true believers"
```

---

## Real Data: Dec 16, 2025 (First Day)

For the **same treatment** (Browse Recovery - 4 Items):

| Model | Avg Score | Open Rate |
|-------|-----------|-----------|
| Random | 0.91 | 2.12% |
| Bandit | 0.16 | 1.44% |

The Bandit sends to users with **6x lower scores** for the same treatment.

### Overall Results

| Metric | Random | Bandit |
|--------|--------|--------|
| Sends | 24,550 | 2,289 |
| Open Rate | **2.22%** | 1.09% |
| CTR/Open | 8.42% | **12.0%** |
| CTR/Send | **0.19%** | 0.13% |

---

## Summary Table

| Aspect | Random Model | Bandit Model |
|--------|--------------|--------------|
| Score selection | High scores (0.75 avg) | Low scores (0.15 avg) |
| Strategy | Exploit what works | Explore to learn |
| Open rate | Higher (2.2%) | Lower (1.1%) |
| CTR/Open | Lower (8.4%) | Higher (12%) |
| Short-term | Better performance | Worse performance |
| Long-term | No learning | Improves the model |

---

## The Trade-off

```
Short-term:  Random wins (higher opens, higher CTR/send)
Long-term:   Bandit learns what actually works vs what we assume works
```

This is the **exploration-exploitation trade-off** - sacrificing some short-term performance to gain long-term knowledge.

---

## Key Takeaways

1. **Lower Bandit open rate is expected** - it's deliberately testing "poor match" combinations
2. **Higher CTR/open is a side effect** - users who open despite low scores are self-selected high-intent
3. **The Bandit is working as designed** - short-term cost for long-term model improvement
4. **Need more data** - 3 clicks is not statistically significant; wait for 50+ clicks per model

---

## NIG Priors vs CTR Smoothing

**Date**: December 20, 2025

### The Problem: Low-Impression, High-CTR Treatments

A treatment with 1 click / 2 views shows **50% CTR**. Without correction, the bandit might over-select this treatment despite the tiny sample size.

### Solution 1: Laplace Smoothing (Additive Smoothing)

Add "pseudo-counts" to regularize CTR:

```
Raw CTR:       clicks / views
Smoothed CTR:  (clicks + click_smoother) / (views + view_smoother)

Example with click_smoother=1, view_smoother=300:
  Raw:      1 / 2 = 50%
  Smoothed: (1 + 1) / (2 + 300) = 2/302 = 0.66%
```

This forces all treatments to start near a baseline CTR (in this case ~0.3%).

**Downside**: Fixed baseline (0.3%) may not be appropriate for all surfaces. Some have naturally higher/lower CTR.

### Solution 2: Empirical Bayes Reparameterization

Instead of fixed smoothers, tie them to observed average CTR:

```
Parameters:
  prior_baseline_factor: 0.2  (e.g., 20% of average CTR)
  prior_strength: 100         (pseudo-observations)

If average treatment CTR = c, then:
  view_count_smoother = prior_strength = 100
  click_count_smoother = prior_baseline_factor × c × view_count_smoother
```

**Benefit**: Adapts automatically to different surfaces/companies with different baseline CTRs.

### Solution 3: NIG (Normal-Inverse-Gamma) Prior

**This is what our Thompson Sampling implementation uses.**

NIG is a Bayesian conjugate prior that models uncertainty around both:
- **Mean** (expected CTR)
- **Variance** (how uncertain we are)

**How it solves the low-impression problem:**

| Observations | NIG Behavior |
|--------------|--------------|
| Few views | High uncertainty → pulls estimate toward prior mean |
| Many views | Low uncertainty → trusts observed CTR |

```
Treatment A: 1 click / 2 views
  → NIG says: "Very uncertain, treat as ~prior mean (e.g., 2%)"

Treatment B: 100 clicks / 1000 views
  → NIG says: "Confident, trust observed 10% CTR"
```

### Why NIG is Preferred

| Approach | Pros | Cons |
|----------|------|------|
| Laplace Smoothing | Simple, easy to understand | Fixed baseline, need to tune 2 params |
| Empirical Bayes | Adapts to different CTRs | More complex, still need 2 params |
| **NIG Prior** | Naturally handles uncertainty, theoretically grounded | Harder to explain |

**Key insight**: NIG already does what smoothing tries to do—it prevents overconfidence in treatments with few observations. So we don't need separate smoothers.

### Hyperparameters to Expose

Instead of adding smoothing parameters, expose the NIG priors directly:

| Parameter | What it controls |
|-----------|------------------|
| `mu_0` (prior mean) | Baseline expected CTR before seeing data |
| `kappa_0` (prior strength) | How strongly to weight the prior |
| `alpha_0`, `beta_0` | Prior on variance (uncertainty) |

Alternatively, a simplified version:
- `default_mean` - prior mean CTR
- `default_std_dev` - prior uncertainty

These can be tuned per company/surface as needed.

---

*Document updated: December 20, 2025*
