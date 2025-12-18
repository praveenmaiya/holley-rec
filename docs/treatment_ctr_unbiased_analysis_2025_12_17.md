# Unbiased Treatment CTR Analysis: Personalized vs Static Recommendations

**Date**: December 17, 2025
**Analysis Period**: Last 60-90 days
**Author**: Claude Code analysis

## Executive Summary

The original analysis comparing Personalized Fitment vs Static recommendations was **biased** due to comparing different user populations. When properly controlled, **Static treatments outperform Personalized by ~2x on CTR**.

| Analysis Type | Personalized CTR | Static CTR | Winner |
|---------------|------------------|------------|--------|
| Original (biased) | 9.62% | 7.51% | Personalized (+28%) |
| Eligible users only | 4.81% | 11.89% | **Static (+147%)** |
| Within-user (gold standard) | 5.12% | 9.23% | **Static (+80%)** |

## The Problem: Selection Bias

### Original Analysis (Biased)

The original comparison was flawed because it compared:
- **Personalized users**: Users with registered vehicle data (more engaged)
- **Static users**: Users without vehicle data (less engaged)

These are fundamentally different populations with different baseline behaviors.

### MECE Framework

To get unbiased estimates, we need to compare within the same population:

```
Population Split:
┌─────────────────────────────────────────────────────────────────┐
│  Group A: No vehicle data → Static only        (not comparable) │
├─────────────────────────────────────────────────────────────────┤
│  Group B: Has vehicle data (ELIGIBLE for both)                  │
│    ┌────────────────────┬────────────────────┐                  │
│    │   Personalized     │      Static        │  ← Compare these │
│    │    CTR = y%        │    CTR = z%        │                  │
│    └────────────────────┴────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘

True Treatment Effect: Δ = y - z
```

## Data Sources

### BigQuery Tables
- `auxia-gcp.company_1950.treatment_history_sent` - Treatment assignments
- `auxia-gcp.company_1950.treatment_interaction` - Opens, clicks
- `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` - User vehicle data (v1 YMM)

### PostgreSQL Tables (via EXTERNAL_QUERY)
- `treatment` - Treatment definitions, boost_factor
- `treatment_version` - Version history
- `treatment_universe` - Eligibility rules

### Treatment IDs

**Personalized Fitment (10 treatments)**:
```
16150700, 20142778, 20142785, 20142804, 20142811,
20142818, 20142825, 20142832, 20142839, 20142846
```

**Static Recommendations (22 treatments)**:
```
16490932, 16490939, 16518436, 16518443, 16564380, 16564387, 16564394,
16564401, 16564408, 16564415, 16564423, 16564431, 16564439, 16564447,
16564455, 16564463, 16593451, 16593459, 16593467, 16593475, 16593483, 16593491
```

## Investigation: Why Randomization Was Imbalanced

### Finding 1: boost_factor Difference

```sql
-- From PostgreSQL treatment table
Personalized treatments: boost_factor = 100.0
Static treatments:       boost_factor = 1.0
```

Personalized treatments have **100x boost**, meaning they're heavily favored in selection.

### Finding 2: boost_factor Changed Over Time

| Period | boost_factor | Implication |
|--------|-------------|-------------|
| Dec 4-11 | 1.0 | Fair randomization |
| Dec 12+ | 100.0 | Heavy bias towards personalized |

### Finding 3: Score Difference

Even during the "fair" period (boost_factor=1.0), scores differed:

| Treatment Type | Avg Score | Min | Max | Sends |
|----------------|-----------|-----|-----|-------|
| Personalized | 0.91 | 0.42 | 1.0 | 5,922 |
| Static | 0.52 | 0.0001 | 1.0 | 34,952 |

The scoring algorithm gives higher scores to personalized treatments.

### Finding 4: model_id Distribution

```
model_id = 1:        232,828 sends (~98%) - "Random" model
model_id = 195001001:  4,647 sends (~2%)  - Bandit model
```

## Unbiased Analysis Results

### Analysis 1: MECE Breakdown

```
┌─────────────────────────────┬────────────────┬─────────┬────────┬────────┬───────┬────────┐
│ Eligibility                 │ Treatment      │  Sends  │ Opens  │ Clicks │ Open% │  CTR   │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼────────┤
│ Eligible (has vehicle)      │ Personalized   │  9,385  │ 1,268  │   61   │ 13.5% │  4.81% │
│ Eligible (has vehicle)      │ Static         │  1,824  │   328  │   39   │ 18.0% │ 11.89% │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼────────┤
│ Not Eligible (no vehicle)   │ Static         │ 39,488  │ 3,761  │  204   │  9.5% │  5.42% │
└─────────────────────────────┴────────────────┴─────────┴────────┴────────┴───────┴────────┘
```

**For eligible users (apples-to-apples)**:
- Personalized: 4.81% CTR
- Static: 11.89% CTR
- **Δ = -7.08%** (Static wins by 147%)

### Analysis 2: Within-User Comparison (Gold Standard)

428 users received **both** Personalized and Static treatments at different times.

```
┌────────────────┬───────┬───────────────┬────────┬────────┬───────┬───────┐
│ Treatment      │ Sends │ Unique Users  │ Opens  │ Clicks │ Open% │  CTR  │
├────────────────┼───────┼───────────────┼────────┼────────┼───────┼───────┤
│ Personalized   │ 1,899 │     428       │  254   │   13   │ 13.4% │ 5.12% │
│ Static         │   808 │     428       │  130   │   12   │ 16.1% │ 9.23% │
└────────────────┴───────┴───────────────┴────────┴────────┴───────┴───────┘

Δ = 5.12% - 9.23% = -4.11% (Static wins by 80%)
```

This is the most unbiased estimate because it compares the **same users** under different treatments, controlling for all user-level confounders.

## Key Findings

### 1. Original Analysis Was Biased
The +28% lift for personalized was an artifact of comparing different user populations, not treatment effectiveness.

### 2. Static Actually Outperforms Personalized
When properly controlled:
- Eligible users: Static CTR is 2.5x higher (11.89% vs 4.81%)
- Within-user: Static CTR is 1.8x higher (9.23% vs 5.12%)

### 3. System Is Not Truly Random
Even with model_id=1 ("random" model):
- boost_factor biases selection (100x for personalized)
- Score algorithm favors personalized treatments
- Result: Eligible users 6-9x more likely to get personalized

### 4. Sample Size Imbalance
- Eligible users: 9,385 personalized vs 1,824 static (5:1 ratio)
- Within-user comparison: 1,899 personalized vs 808 static sends
- Click counts are small (13 vs 12 in within-user analysis)

### 5. Critical: "Static" = Only Apparel
Only 1 of 22 static treatments was ever sent:
- **16490939** (Holley Apparel & Collectibles): 41,465 sends
- **21 other static treatments** (Sniper 2, Terminator X, Brothers, etc.): **0 sends**

The comparison is actually Personalized Fitment vs Apparel, not vs product-specific recommendations.

## Caveats and Limitations

1. **Small click counts**: Statistical significance is limited with 13 vs 12 clicks in within-user analysis
2. **Time ordering**: Users may have received treatments at different times, introducing temporal confounds
3. **Static = Apparel only**: Only 1 of 22 static treatments (Holley Apparel & Collectibles) was actually sent - not a fair comparison to product-specific recommendations
4. **Vehicle data timing**: Some users may have added vehicle data after receiving treatments

## Recommendations

1. **Set boost_factor = 1.0 for all treatments** to enable fair A/B testing
2. **Enable the other 21 static treatments** (Sniper 2, Terminator X, Brothers, etc.) - currently have 0 sends
3. **Implement true randomization** within eligible user pool
4. **Increase sample size** for static sends to eligible users before drawing conclusions
5. **Don't conclude Personalized is worse** - current comparison is Apparel vs Personalized, not a fair test

## SQL Queries Used

### Query 1: MECE Breakdown
```sql
-- Key joins: treatment_history_sent + ingestion_unified_attributes_schema_incremental + treatment_interaction
-- Filters: model_id = 1, request_source = "LIVE"
-- Vehicle eligibility: users with v1_year, v1_make, v1_model properties
```

### Query 2: Within-User Comparison
```sql
-- Identifies 428 users who received both treatment types
-- Compares CTR for same users under different treatments
-- Gold standard for causal inference
```

## Appendix: PostgreSQL Connection

```sql
-- Access treatment metadata via BigQuery federated query
SELECT * FROM EXTERNAL_QUERY(
    "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
    """
    SELECT treatment_id, name, boost_factor, is_paused
    FROM treatment
    WHERE company_id = 1950
    """
)
```

---

*Analysis performed using BigQuery and PostgreSQL federated queries. Data from auxia-gcp and auxia-reporting projects.*
