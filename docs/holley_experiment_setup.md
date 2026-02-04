# Holley Email Experiment Setup

A stakeholder-friendly explanation of the Holley post-purchase email experiment architecture.

**Last Updated:** 2026-02-03

---

## Quick Summary

| Question | Answer |
|----------|--------|
| Is there a control group? | **No** — we compare two treatment types, not treatment vs no-treatment |
| What is the "baseline"? | Static treatments (category-based recommendations) |
| What is "Personalized"? | Vehicle-specific parts recommendations for users with YMM data |
| What does "2.5x open rate" mean? | Personalized emails are opened 2.5x more than Static emails |
| Is this a fair comparison? | Partially — see [Caveats](#caveats-and-limitations) below |
| Why 2 arms (Random + Bandit)? | Random provides stable baseline for comparison; 50/50 split failed — see [Why Two Arms?](#why-two-arms-deep-dive) |
| Can we go 100% Bandit? | **No** — we need a baseline holdout. See [Can We Remove the Random Arm?](#can-we-remove-the-random-arm) |
| Do YMM users get Static emails? | **Yes** — ~969 users received both types over 60 days. See [User Overlap](#user-overlap-analysis) |

---

## Experiment Architecture

```
                          USER COMPLETES PURCHASE
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   Has vehicle data (v1 YMM)?  │
                    └───────────────┬───────────────┘
                                    │
                 ┌──────────────────┴──────────────────┐
                YES                                    NO
                 │                                      │
                 ▼                                      ▼
        ┌─────────────────┐                   ┌─────────────────┐
        │ ELIGIBLE FOR:   │                   │ ELIGIBLE FOR:   │
        │ • Personalized  │                   │ • Static ONLY   │
        │ • Static        │                   │                 │
        └────────┬────────┘                   └────────┬────────┘
                 │                                      │
                 └──────────────────┬──────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │      ARM ASSIGNMENT           │
                    │  (50/50 current → 10/90 rec)  │
                    └───────────────┬───────────────┘
                                    │
                 ┌──────────────────┴──────────────────┐
                 ▼                                      ▼
        ┌─────────────────┐                   ┌─────────────────┐
        │   RANDOM ARM    │                   │   BANDIT ARM    │
        │                 │                   │                 │
        │ Boost-weighted  │                   │ Thompson        │
        │ random selection│                   │ Sampling (CTR)  │
        │                 │                   │                 │
        │ arm_id: 4103    │                   │ arm_id: 4689    │
        └────────┬────────┘                   └────────┬────────┘
                 │                                      │
                 └──────────────────┬──────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │     TREATMENT SELECTED        │
                    │     (Personalized or Static)  │
                    └───────────────────────────────┘
```

---

## Why Two Arms? Deep Dive

Understanding why we need both Random and Bandit arms is critical for experiment design.

### The Purpose of Each Arm

| Aspect | Random Arm (10% recommended) | Bandit Arm (90% recommended) |
|--------|------------------------------|------------------------------|
| **Model ID** | 1 (baseline) | 195001001 |
| **Algorithm** | Boost-weighted random | Thompson Sampling |
| **Purpose** | Stable baseline for comparison | Exploration + learning |
| **Scores** | 0.5–0.9 (high) | 0.05–0.18 (low) |
| **Behavior** | Deterministic from boost factors | Adapts based on CTR |

### Why NOT 100% Bandit?

1. **No reference baseline** — Without Random arm, we can't measure if Bandit is improving
2. **Single point of failure** — If Bandit breaks, all traffic is affected
3. **Score mismatch** — Bandit model produces scores ~10x lower than baseline (0.05 vs 0.5)
4. **Slower learning** — Signal spread across 100% traffic vs concentrated in 10%
5. **No cold-start baseline** — New treatments need Random arm for initial data

### The 50/50 Experiment Failure (Jan 14, 2026)

When traffic was split 50/50 between arms, we observed:

| Metric | Before | After (50/50) | Impact |
|--------|--------|---------------|--------|
| **CTR** | 3.15% | 0% | **Crashed** |
| Personalized sends | High | Near zero | Model favored low-boost treatments |
| User experience | Stable | Inconsistent | Different treatments for same user |

**Root cause:** The 50/50 split diluted the learning signal across both arms. Neither arm had enough concentrated traffic to optimize effectively.

**Recommendation:** Use 10/90 split (10% Random / 90% Bandit) — enough baseline for comparison while maximizing Bandit learning.

---

## Can We Remove the Random Arm?

**Short answer: No.**

### What We'd Lose

| Capability | Without Random Arm |
|------------|-------------------|
| Baseline measurement | ❌ No reference point for improvement |
| Failure recovery | ❌ 100% traffic affected by Bandit bugs |
| A/B comparisons | ❌ Can't compare algorithms |
| Score normalization | ❌ Bandit scores not calibrated to baseline |

### Recommended Configuration

| Configuration | Random | Bandit | Use Case |
|---------------|--------|--------|----------|
| **Recommended** | 10% | 90% | Maximize learning with baseline holdout |
| **Conservative** | 5% | 95% | Minimal baseline, maximum learning |
| ❌ **Avoid** | 50% | 50% | Caused CTR crash — dilutes signal |
| ❌ **Never** | 0% | 100% | No baseline for comparison |

---

## User Overlap Analysis

**Key finding: YMM-eligible users DO receive both Personalized and Static treatments.**

### Overlap Statistics

| Study | Time Period | Users Receiving Both |
|-------|-------------|---------------------|
| Post Purchase Analysis | 60 days | **969 users** |
| Uplift Analysis | 60 days | **480 users** |
| Unbiased CTR Analysis | 14 days | **428 users** |

### Why Overlap Exists

Even with 100:1 boost factor, users can receive both treatment types because:

1. **Multiple email opportunities** — Same user may receive multiple post-purchase emails
2. **Randomization** — Even 1% chance means some Static selection over many emails
3. **Arm assignment varies** — User may be in Random arm (99% Personalized) one day, Bandit arm (CTR-based) another
4. **Treatment availability** — If a Personalized treatment is paused, user falls back to Static

### Selection Ratio for Eligible Users

For users with v1 YMM data (eligible for both types):

| Treatment Type | Observed Selection | Theoretical (boost-weighted) |
|----------------|-------------------|------------------------------|
| **Personalized** | ~83% | 99% |
| **Static** | ~17% | 1% |
| **Ratio** | ~5:1 | 100:1 |

The observed ratio differs from theoretical because:
- Bandit arm uses CTR, not just boost factors
- Multiple treatments with different boosts compete
- Some Personalized treatments may be paused

### Value of Within-User Comparison

Users receiving both types enable the **cleanest possible comparison**:

| Metric | Personalized | Static | Lift |
|--------|--------------|--------|------|
| Open Rate | 35.1% | 28.0% | **+7.1 pp** |
| CTR | 4.2% | 3.1% | +1.1 pp |

This controls for user-level confounds (engagement, email habits, customer value).

---

## Selection Logic Deep Dive

### Boost Factor Math

For users eligible for both treatment types, selection probability is:

```
P(treatment) = boost(treatment) / Σ boost(all eligible treatments)
```

**Example: 1 Personalized (boost=100) vs 1 Static (boost=1)**

```
P(Personalized) = 100 / (100 + 1) = 99.0%
P(Static)       = 1 / (100 + 1)   = 1.0%
```

**Example: 10 Personalized (boost=100 each) vs 1 Static (boost=1)**

```
Total Personalized boost = 10 × 100 = 1000
Total Static boost       = 1 × 1    = 1

P(any Personalized) = 1000 / (1000 + 1) = 99.9%
P(Static)           = 1 / (1000 + 1)    = 0.1%
```

### Why YMM Users Sometimes Get Static

Despite 100:1 boost, Static selection happens because:

1. **Randomization** — Even 0.1% chance means some Static emails over many sends
2. **Bandit exploration** — Thompson Sampling may select Static to gather data
3. **Treatment unavailability** — If all Personalized treatments are paused or exhausted
4. **Multiple Static treatments** — More Static options means higher combined probability

### Arm-Specific Selection Behavior

| Arm | Selection Method | YMM User Behavior |
|-----|------------------|-------------------|
| **Random** | Pure boost-weighted | ~99% Personalized, ~1% Static |
| **Bandit** | CTR + exploration | Varies based on historical performance |

In Bandit arm, if Static treatment has higher CTR (unlikely but possible), it may be selected more often than boost factors would suggest.

---

## The Two Treatment Types

### Personalized Fitment (10 treatments)

Vehicle-specific product recommendations based on Year/Make/Model (YMM).

| Property | Value |
|----------|-------|
| **Eligibility** | User must have v1 YMM data |
| **Boost Factor** | 100 |
| **Content** | Parts that fit user's vehicle |
| **Recommendation Source** | ML pipeline (`v5.17_vehicle_recommendations`) |

**Treatment Themes:** Thanks, Warm Welcome, Relatable Wrencher, Completer, Momentum, Weekend Warrior, Visionary, Detail Oriented, Expert Pick, Look Back

### Static (22 treatments)

Fixed product categories — same products shown to all recipients within a category.

| Property | Value |
|----------|-------|
| **Eligibility** | All post-purchase users |
| **Boost Factor** | 1 |
| **Content** | Category-based (Apparel, Tools, etc.) |
| **Recommendation Source** | Manually curated product lists |

**Categories:** Apparel, Tools, Exhaust, Cold Air Intakes, Wheels, Tuners, Brothers Interior/Exterior, Terminator X, etc.

### Critical Finding: Only 1 Static Treatment Has Sent

Despite having 22 Static treatments configured, **only 1 has ever sent emails**:

| Treatment ID | Category | 60-Day Sends |
|--------------|----------|--------------|
| 16490939 | Holley Apparel & Collectibles | 68,783 |
| (21 others) | Various | 0 |

**This means "Personalized vs Static" = "Personalized vs Apparel" in practice.**

---

## The Two Arms (Selection Algorithms)

The arms determine **HOW** a treatment is selected, not **WHICH TYPE** is selected.

| Arm | ID | Current Traffic | Recommended | Selection Method |
|-----|----|-----------------|-------------|------------------|
| **Random** | 4103 | 50% | **10%** | Boost-weighted random (deterministic) |
| **Bandit** | 4689 | 50% | **90%** | Thompson Sampling (learns from CTR) |

> ⚠️ **Note:** The 50/50 split caused a CTR crash on Jan 14, 2026. See [Why Two Arms?](#why-two-arms-deep-dive) for details. Recommended: 10% Random / 90% Bandit.

### Random Arm
- Uses boost factors as weights
- Personalized (boost=100) is 100x more likely than Static (boost=1)
- No learning — consistent baseline
- **Purpose:** Stable reference point for measuring improvement

### Bandit Arm
- Uses historical CTR to select treatments
- Explores underperforming treatments
- Exploits high-performing treatments
- Adapts over time
- **Purpose:** Learning and optimization (but scores are ~10x lower than baseline)

**Both arms can serve both Personalized AND Static treatments.** The arm determines the selection algorithm, not the treatment type.

---

## Why Personalized Dominates Selection

With boost factors:
- Personalized: 100
- Static: 1

The selection probability is heavily skewed:

```
For a user eligible for both:

P(Personalized) = 100 / (100 + 1) = 99.0%
P(Static)       = 1 / (100 + 1)   = 1.0%
```

**This is intentional** — we want to prioritize Personalized for users with vehicle data because it's expected to perform better.

---

## The 2.5x Open Rate Claim

### What We Measured

| Metric | Personalized | Static (Apparel) | Ratio |
|--------|--------------|------------------|-------|
| **Open Rate** | 34.2% | 13.7% | **2.5x** |
| CTR (of sends) | 3.8% | 1.1% | 3.6x |
| CTR (of opens) | 11.1% | 8.0% | 1.4x |

### What This Means

Personalized emails are **opened 2.5x more often** than Static (Apparel) emails.

Once opened, the click rate advantage narrows to 1.4x, suggesting:
1. The vehicle-relevance signal drives opens
2. Content quality is similar once users engage

---

## Caveats and Limitations

### 1. No True Control Group

There is no "send nothing" arm. We cannot measure:
- Absolute lift from any email vs no email
- Whether emails cannibalize organic purchases

### 2. Different Content Types

| Personalized | Static (Apparel) |
|--------------|------------------|
| Vehicle parts | Clothing & collectibles |
| Highly relevant to vehicle owners | General merchandise |

The comparison is not purely "personalized vs non-personalized" — it's also "parts vs apparel."

### 3. Different User Pools

| Personalized Eligibility | Static Eligibility |
|--------------------------|-------------------|
| Must have v1 YMM data | All users |
| Likely more engaged | May include casual browsers |

Users with vehicle data may be inherently more engaged customers.

### 4. Boost Factor Bias

The 100x boost for Personalized means:
- Personalized users are 99% likely to get Personalized
- Selection is not randomized

### 5. Single Active Static Treatment

Only Apparel (1 of 22 treatments) has sent. We're comparing:
- 10 Personalized themes (vehicle parts) vs
- 1 Static theme (apparel)

---

## Same-User Validation (Cleanest Signal)

To address confounds, we analyzed **333 users who received BOTH treatment types**:

| Metric | Personalized | Static | Difference |
|--------|--------------|--------|------------|
| Open Rate | 35.1% | 28.0% | **+7.1 pp** |
| CTR | 4.2% | 3.1% | +1.1 pp |

This within-user comparison controls for:
- User engagement level
- Email habits
- Customer value

**The +7% open rate lift is the cleanest signal** that Personalized outperforms Static for the same users.

---

## Interpreting Results

### What We Can Say

1. **Personalized has higher engagement** — both open rates and CTR are substantially higher
2. **Same-user analysis shows +7% lift** — controlling for user differences
3. **Vehicle relevance drives opens** — users recognize relevant content in subject lines

### What We Cannot Say

1. **Absolute lift vs no email** — no control group exists
2. **Pure personalization effect** — content types differ (parts vs apparel)
3. **Long-term impact** — only measuring immediate engagement, not revenue attribution

---

## Traffic Distribution

**60-day data (Post Purchase only):**

| Treatment Type | Sends | % of Total | Unique Users |
|----------------|-------|------------|--------------|
| **Personalized** | 17,225 | 20% | 2,570 |
| **Static (Apparel)** | 68,783 | 80% | 34,140 |

**Why is Static higher despite lower boost?**

Static is the only option for users without v1 YMM data. Many users lack vehicle data, so they receive Static by default.

---

## Key Queries

### Check Treatment Distribution
```sql
SELECT
  CASE
    WHEN treatment_id IN (16150700, 20142778, 20142785, 20142804, 20142811,
                          20142818, 20142825, 20142832, 20142839, 20142846)
      THEN 'Personalized'
    ELSE 'Static'
  END as treatment_type,
  COUNT(*) as sends,
  COUNT(DISTINCT user_id) as unique_users
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929
  AND request_source = 'LIVE'
  AND treatment_id IN (
    -- Personalized
    16150700, 20142778, 20142785, 20142804, 20142811,
    20142818, 20142825, 20142832, 20142839, 20142846,
    -- Static
    16490932, 16490939, 16518436, 16518443, 16564380,
    16564387, 16564394, 16564401, 16564408, 16564415,
    16564423, 16564431, 16564439, 16564447, 16564455,
    16564463, 16593451, 16593459, 16593467, 16593475,
    16593483, 16593491
  )
  AND DATE(treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
GROUP BY treatment_type
```

### Same-User Comparison
```sql
WITH user_both AS (
  SELECT user_id
  FROM `auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929 AND request_source = 'LIVE'
  GROUP BY user_id
  HAVING
    SUM(CASE WHEN treatment_id IN (16150700, 20142778, 20142785, 20142804, 20142811,
                                    20142818, 20142825, 20142832, 20142839, 20142846)
             THEN 1 ELSE 0 END) > 0
    AND SUM(CASE WHEN treatment_id = 16490939 THEN 1 ELSE 0 END) > 0
)
-- Then calculate open rates for these users only
```

---

## Glossary

| Term | Definition |
|------|------------|
| **Arm** | Treatment selection algorithm (Random or Bandit) |
| **Boost Factor** | Weight used in treatment selection probability |
| **CTR** | Click-through rate (clicks / opens or clicks / sends) |
| **Open Rate** | Percentage of sent emails that were opened |
| **Personalized** | Vehicle-specific recommendations (requires YMM data) |
| **Static** | Category-based recommendations (no vehicle data needed) |
| **Surface** | Channel for treatment delivery (929 = Email) |
| **Thompson Sampling** | Bandit algorithm that balances exploration/exploitation |
| **v1 YMM** | Version 1 vehicle data (Year/Make/Model) |

---

## Related Documentation

- [Treatment Selection System](treatment_selection_system.md) — detailed system architecture
- [Treatment Structure](treatment_structure.md) — all treatment definitions
- [Pipeline Architecture](pipeline_architecture.md) — recommendation generation

---

## Changelog

| Date | Change |
|------|--------|
| 2026-02-03 | Added deep-dive sections: Why Two Arms?, User Overlap Analysis, Selection Logic |
| 2026-02-03 | Initial documentation for stakeholder communication |
