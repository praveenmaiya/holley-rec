# Treatment Selection System

How email treatments are selected and delivered to users.

**Last Updated:** 2026-01-19

---

## Overview

The Holley email system uses a **two-arm A/B test** to select treatments:
- **Random Arm** - Boost-weighted random selection
- **Bandit Arm** - Thompson Sampling based on historical CTR

Both arms operate on **Surface 929** (Email Channel).

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     USER ACTION TRIGGER                          │
│  (Purchase, Browse Product, Abandon Cart)                        │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SURFACE 929 (Email)                          │
│                                                                  │
│  1. Determine eligible treatments based on user behavior         │
│  2. Apply eligibility rules (vehicle data, cart items, etc.)     │
│  3. Route to Random or Bandit arm (50/50 split)                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                    ┌─────┴─────┐
                    │  50/50    │
                    │  Split    │
                    └─────┬─────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
┌─────────────────────┐   ┌─────────────────────┐
│    RANDOM ARM       │   │    BANDIT ARM       │
│                     │   │                     │
│  arm_id: 4103       │   │  arm_id: 4689       │
│  model_id: 1        │   │  model_id: 195001001│
│                     │   │                     │
│  Selection Method:  │   │  Selection Method:  │
│  Boost-weighted     │   │  Thompson Sampling  │
│  random sampling    │   │  (Beta-Binomial)    │
│                     │   │                     │
│  Score Range:       │   │  Score Range:       │
│  0.5 - 0.9 (high)   │   │  0.05 - 0.18 (low)  │
│                     │   │                     │
│  Behavior:          │   │  Behavior:          │
│  Exploits boost     │   │  Explores + exploits│
│  factor weights     │   │  based on CTR       │
└──────────┬──────────┘   └──────────┬──────────┘
           │                         │
           └───────────┬─────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                   TREATMENT DELIVERY                             │
│                                                                  │
│  - Record in treatment_history_sent                              │
│  - Send email via Klaviyo                                        │
│  - Track interactions (opens, clicks)                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Traffic Split History

The Random/Bandit split has changed over time:

| Period | Random | Bandit | Notes |
|--------|--------|--------|-------|
| Before Jan 14, 2026 | ~90% | ~10% | Bandit in exploration phase |
| **Jan 14, 2026 onwards** | ~50% | ~50% | Current production split |

### Daily Traffic (Recent)

| Date | Random | Bandit | Split |
|------|--------|--------|-------|
| Jan 19 | 1,514 | 1,463 | 50.8% / 49.2% |
| Jan 18 | 5,861 | 5,870 | 50.0% / 50.0% |
| Jan 17 | 7,131 | 7,067 | 50.2% / 49.8% |
| Jan 16 | 6,264 | 6,273 | 50.0% / 50.0% |

---

## Campaign Type Determination

Campaign type is **NOT selected by the arm**. It is determined by **user behavior/eligibility**:

```
┌─────────────────────────────────────────────────────────────────┐
│                     USER BEHAVIOR                                │
└─────────────────────────┬───────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│ Made Purchase │ │ Browsed Items │ │ Cart Abandon  │
└───────┬───────┘ └───────┬───────┘ └───────┬───────┘
        │                 │                 │
        ▼                 ▼                 ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│ POST PURCHASE │ │BROWSE RECOVERY│ │ ABANDON CART  │
│               │ │               │ │               │
│ Eligible:     │ │ Eligible:     │ │ Eligible:     │
│ - Personalized│ │ - Pers. Recs  │ │ - Fitment Recs│
│   Fitment (10)│ │   (25)        │ │   (15)        │
│ - Static (22) │ │ - No Recs (11)│ │ - Static (15) │
└───────────────┘ └───────────────┘ └───────────────┘
```

### Eligibility Rules

| Campaign Type | Trigger | Additional Eligibility |
|---------------|---------|----------------------|
| **Post Purchase** | User completed an order | Personalized Fitment requires vehicle data (YMM) |
| **Browse Recovery** | User viewed products without purchasing | User must have browsed 1-5 items |
| **Abandon Cart** | User added to cart but didn't checkout | Cart must have 1-5 items |

### User Can Receive Multiple Campaign Types

A single user can receive different campaign types over time as their behavior changes:

```
Day 1: User browses products → Browse Recovery email
Day 3: User adds to cart, leaves → Abandon Cart email
Day 5: User completes purchase → Post Purchase email
Day 8: User browses again → Browse Recovery email
```

Example user received all 4 campaign types in 30 days:
- Post Purchase - Personalized
- Post Purchase - Static
- Browse Recovery
- Abandon Cart

---

## Traffic Distribution by Campaign Type

**60-day data (LIVE traffic only):**

| Campaign Type | Sends | % of Total | Unique Users | Treatments |
|---------------|-------|------------|--------------|------------|
| **Browse Recovery** | 463,285 | 73.4% | 58,114 | 35 |
| **Abandon Cart** | 81,328 | 12.9% | 28,348 | 15 |
| **Post Purchase - Static** | 68,783 | 10.9% | 34,140 | 1* |
| **Post Purchase - Personalized** | 17,225 | 2.7% | 2,570 | 10 |

*Note: Post Purchase Static shows only 1 treatment (16490939 - Apparel) with actual sends. The other 21 Static treatments have zero sends.

---

## Arm Selection Algorithms

### Random Arm (model_id = 1)

**Method:** Boost-weighted random sampling

```
P(treatment_i) ∝ boost_factor_i

Example:
- Treatment A: boost_factor = 1.0      → weight 1
- Treatment B: boost_factor = 100.0    → weight 100
- Treatment C: boost_factor = 1000.0   → weight 1000

Selection probability:
- P(A) = 1/1101 = 0.09%
- P(B) = 100/1101 = 9.08%
- P(C) = 1000/1101 = 90.83%
```

**Characteristics:**
- High scores (0.5 - 0.9)
- Deterministic based on boost factors
- No learning from historical performance
- Good for consistent baseline

### Bandit Arm (model_id = 195001001)

**Method:** Thompson Sampling with Beta-Binomial model

```
For each treatment:
1. Maintain Beta posterior: Beta(α + clicks, β + views - clicks)
2. Sample θ_i ~ Beta(α_i, β_i) for each treatment
3. Select treatment with highest sampled θ

Prior: Beta(1, 1) - uniform prior
```

**Characteristics:**
- Low scores (0.05 - 0.18) due to exploration
- Learns from click-through rates
- Balances exploration vs exploitation
- Adapts to changing treatment performance

---

## Data Model

### Key Tables

| Table | Purpose |
|-------|---------|
| `treatment_history_sent` | Records of all treatment sends |
| `treatment_interaction` | Opens (VIEWED) and clicks (CLICKED) |
| `treatment` (PostgreSQL) | Treatment metadata and configuration |

### Key Fields in treatment_history_sent

| Field | Description |
|-------|-------------|
| `treatment_id` | Which treatment was sent |
| `user_id` | Who received it |
| `request_source` | LIVE, SIMULATION, or QA |
| `arm_id` | Which arm (4103=Random, 4689=Bandit) |
| `model_id` | Which model (1=Random, 195001001=Bandit) |
| `score` | Score assigned by the model |
| `boost_factor` | Boost factor applied |
| `control_arm` | Boolean - is this control? |
| `eligibility_result` | ELIGIBLE or RULES_NOT_EVALUATED |

### Request Source Values

| Value | Meaning |
|-------|---------|
| `LIVE` | Actually sent to user |
| `SIMULATION` | Shadow traffic (logged but not sent) |
| `QA` | Quality assurance testing |

---

## Boost Factor Scaling

Boost factors scale with user engagement level:

### Browse Recovery

| # Browsed Items | Boost Factor | Interpretation |
|-----------------|--------------|----------------|
| 1 item | 100 | Low engagement |
| 2 items | 1,000 | |
| 3 items | 10,000 | |
| 4 items | 100,000 | |
| 5 items | 1,000,000 | High engagement |

### Abandon Cart

| # Cart Items | Boost Factor | Interpretation |
|--------------|--------------|----------------|
| 1 item | 200 | Low intent |
| 2 items | 2,000 | |
| 3 items | 20,000 | |
| 4 items | 200,000 | |
| 5 items | 2,000,000 | High intent |

### Post Purchase

| Type | Boost Factor |
|------|--------------|
| Personalized Fitment | 100 |
| Static | 1 |

---

## Querying the System

### Check Arm Distribution
```sql
SELECT
  CASE WHEN model_id = 1 THEN 'Random' ELSE 'Bandit' END as arm,
  COUNT(*) as sends
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929 AND request_source = 'LIVE'
  AND DATE(treatment_sent_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY arm
```

### Check Campaign Type Distribution
```sql
SELECT
  CASE
    WHEN treatment_id IN (16150700, 20142778, 20142785, 20142804, 20142811,
                          20142818, 20142825, 20142832, 20142839, 20142846)
      THEN 'Post Purchase - Personalized'
    WHEN treatment_id IN (16490932, 16490939, 16518436, 16518443, 16564380,
                          16564387, 16564394, 16564401, 16564408, 16564415,
                          16564423, 16564431, 16564439, 16564447, 16564455,
                          16564463, 16593451, 16593459, 16593467, 16593475,
                          16593483, 16593491)
      THEN 'Post Purchase - Static'
    WHEN treatment_id BETWEEN 21265193 AND 21265513
      OR treatment_id IN (16150707, 17049625)
      THEN 'Browse Recovery'
    ELSE 'Abandon Cart / Other'
  END as campaign_type,
  COUNT(*) as sends
FROM `auxia-gcp.company_1950.treatment_history_sent`
WHERE surface_id = 929 AND request_source = 'LIVE'
GROUP BY campaign_type
```

### Get Treatment Metadata from PostgreSQL
```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  "SELECT treatment_id, name, boost_factor, is_paused
   FROM treatment
   WHERE company_id = 1950
   ORDER BY treatment_id DESC"
)
```

---

## Fair A/B Comparison Guidelines

For valid performance comparison:

### DO Compare (Same Campaign Type)
- Post Purchase: Personalized Fitment vs Static
- Browse Recovery: Personalized Recs vs No Recs
- Abandon Cart: Fitment Recs vs Static Recs

### DON'T Compare (Different Campaign Types)
- ❌ Post Purchase vs Browse Recovery (different triggers)
- ❌ Abandon Cart vs Post Purchase (different user intent)
- ❌ Post Purchase Personalized vs Browse Recovery Personalized (different eligibility)

### Compare Within Same Arm
- Random arm performance: Treatment A vs Treatment B
- Bandit arm performance: Treatment A vs Treatment B
- Cross-arm: Same treatment, Random vs Bandit

---

## Changelog

| Date | Change |
|------|--------|
| 2026-01-19 | Initial documentation |
| 2026-01-14 | Traffic split changed from 90/10 to 50/50 |
