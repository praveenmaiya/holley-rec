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
                    │         (50/50)               │
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

| Arm | ID | Traffic | Selection Method |
|-----|----|---------|--------------------|
| **Random** | 4103 | 50% | Boost-weighted random (deterministic) |
| **Bandit** | 4689 | 50% | Thompson Sampling (learns from CTR) |

### Random Arm
- Uses boost factors as weights
- Personalized (boost=100) is 100x more likely than Static (boost=1)
- No learning — consistent baseline

### Bandit Arm
- Uses historical CTR to select treatments
- Explores underperforming treatments
- Exploits high-performing treatments
- Adapts over time

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
| 2026-02-03 | Initial documentation for stakeholder communication |
