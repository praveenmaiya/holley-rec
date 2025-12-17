# Unbiased Treatment CTR Analysis: Personalized vs Static Recommendations

**Date**: December 17, 2025
**Analysis Period**: Last 60-90 days
**Author**: Claude Code analysis

## Executive Summary

The original analysis comparing Personalized Fitment vs Static recommendations was **biased** due to comparing different user populations. When properly controlled, **Static treatments outperform Personalized by ~2x on CTR**.

| Analysis Type | Personalized CTR | Static CTR | Winner |
|---------------|------------------|------------|--------|
| Original (biased) | 9.62% | 7.51% | Personalized (+28%) |
| Eligible users only | 4.86% | 9.62% | **Static (+98%)** |
| Within-user (gold standard) | 5.12% | 9.38% | **Static (+83%)** |

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
- `auxia-gcp.company_1950.imported_unified_attributes` - User vehicle data

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

### Analysis 1: MECE Breakdown (All 4 Groups)

```
┌─────────────────────────────┬────────────────┬─────────┬────────┬────────┬───────┬───────┐
│ Eligibility                 │ Treatment      │  Sends  │ Opens  │ Clicks │ Open% │  CTR  │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼───────┤
│ Eligible (has vehicle)      │ Personalized   │  8,602  │ 1,255  │   61   │ 14.6% │ 4.86% │
│ Eligible (has vehicle)      │ Static         │    918  │   156  │   15   │ 17.0% │ 9.62% │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼───────┤
│ Not Eligible (no vehicle)   │ Static         │ 39,394  │ 3,933  │  228   │ 10.0% │ 5.80% │
│ Not Eligible (no vehicle)   │ Personalized   │    209  │    13  │    0   │  6.2% │ 0.00% │
└─────────────────────────────┴────────────────┴─────────┴────────┴────────┴───────┴───────┘
```

**For eligible users (apples-to-apples)**:
- Personalized: 4.86% CTR
- Static: 9.62% CTR
- **Δ = -4.76%** (Static wins by 98%)

### Analysis 2: Fair Period Only (Dec 4-11, boost_factor=1.0)

```
┌─────────────────────────────┬────────────────┬─────────┬────────┬────────┬───────┬───────┐
│ Eligibility                 │ Treatment      │  Sends  │ Opens  │ Clicks │ Open% │  CTR  │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼───────┤
│ Eligible                    │ Personalized   │  5,922  │   957  │   49   │ 16.2% │ 5.12% │
│ Eligible                    │ Static         │    900  │   156  │   15   │ 17.3% │ 9.62% │
├─────────────────────────────┼────────────────┼─────────┼────────┼────────┼───────┼───────┤
│ Not Eligible                │ Static         │ 34,052  │ 3,165  │  190   │  9.3% │ 6.00% │
└─────────────────────────────┴────────────────┴─────────┴────────┴────────┴───────┴───────┘
```

### Analysis 3: Within-User Comparison (Gold Standard)

424 users received **both** Personalized and Static treatments at different times.

```
┌────────────────┬───────┬───────────────┬────────┬────────┬───────┬───────┐
│ Treatment      │ Sends │ Unique Users  │ Opens  │ Clicks │ Open% │  CTR  │
├────────────────┼───────┼───────────────┼────────┼────────┼───────┼───────┤
│ Personalized   │ 1,763 │     424       │  254   │   13   │ 14.4% │ 5.12% │
│ Static         │   800 │     424       │  128   │   12   │ 16.0% │ 9.38% │
└────────────────┴───────┴───────────────┴────────┴────────┴───────┴───────┘

Δ = 5.12% - 9.38% = -4.26% (Static wins by 83%)
```

This is the most unbiased estimate because it compares the **same users** under different treatments, controlling for all user-level confounders.

## Key Findings

### 1. Original Analysis Was Biased
The +28% lift for personalized was an artifact of comparing different user populations, not treatment effectiveness.

### 2. Static Actually Outperforms Personalized
When properly controlled:
- Eligible users: Static CTR is 2x higher (9.62% vs 4.86%)
- Within-user: Static CTR is 1.8x higher (9.38% vs 5.12%)

### 3. System Is Not Truly Random
Even with model_id=1 ("random" model):
- boost_factor biases selection (100x for personalized)
- Score algorithm favors personalized treatments
- Result: Eligible users 6-9x more likely to get personalized

### 4. Sample Size Imbalance
- Eligible users: 8,602 personalized vs 918 static (9:1 ratio)
- Within-user comparison: 1,763 personalized vs 800 static sends
- Click counts are small (13 vs 12 in within-user analysis)

## Caveats and Limitations

1. **Small click counts**: Statistical significance is limited with 13 vs 12 clicks
2. **Time ordering**: Users may have received treatments at different times, introducing temporal confounds
3. **Product specificity**: Static treatments target specific products (Sniper 2, Brothers, Terminator X) vs generic personalized recommendations
4. **Vehicle data timing**: Some users may have added vehicle data after receiving treatments
5. **209 anomalous sends**: Non-eligible users received personalized treatments (data quality issue)

## Recommendations

1. **Set boost_factor = 1.0 for all treatments** to enable fair A/B testing
2. **Implement true randomization** within eligible user pool
3. **Increase sample size** for static sends to eligible users before drawing conclusions
4. **Consider product-specific analysis** - some static treatments may perform differently
5. **Track treatment effect by subject line** - the "Thanks" variant had highest CTR in original analysis

## SQL Queries Used

### Query 1: MECE Breakdown
```sql
-- See full query in analysis notebook
-- Key joins: treatment_history_sent + imported_unified_attributes + treatment_interaction
-- Filters: model_id = 1, surface_id = 929, request_source = "LIVE"
```

### Query 2: Within-User Comparison
```sql
-- Identifies 424 users who received both treatment types
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
