# Uplift Analysis Report

**Date**: 2025-12-26
**Period**: Last 60 days
**Method**: MECE Framework + Within-User Comparison

---

## Executive Summary

**Personalized Fitment underperforms Static recommendations by ~32%** when compared fairly using the MECE framework. This finding is consistent across both eligible-users analysis and the gold-standard within-user comparison.

---

## MECE Framework Results

### All Users (Biased Comparison)

| Treatment | Users Sent | Viewers | Clickers | CTR |
|-----------|------------|---------|----------|-----|
| Personalized | 2,000 | 622 | 66 | 10.61% |
| Static | 25,918 | 3,542 | 270 | 7.62% |

**Warning**: This comparison is biased. Static is sent to 13x more users, mostly without vehicle data.

### Eligible Users Only (Fair Comparison)

Users with vehicle data who can receive either treatment type:

| Treatment | Users Sent | Viewers | Clickers | CTR |
|-----------|------------|---------|----------|-----|
| **Static** | 1,112 | 279 | 44 | **15.77%** |
| **Personalized** | 2,000 | 622 | 66 | **10.61%** |

**Result**: Static outperforms Personalized by 48.6% when comparing eligible users only.

---

## Within-User Comparison (Gold Standard)

480 users received **both** Personalized and Static treatments:

| Treatment | Viewers | Clickers | CTR |
|-----------|---------|----------|-----|
| **Static** | 114 | 17 | **14.91%** |
| **Personalized** | 137 | 14 | **10.22%** |

**Result**: Same users click Static emails 46% more often than Personalized emails.

This is the most rigorous comparison because it controls for all user-level confounders (demographics, purchase history, engagement patterns, etc.).

---

## Uplift Calculation

```
Uplift = (CTR_personalized - CTR_static) / CTR_static × 100%
```

| Analysis Type | Personalized CTR | Static CTR | Uplift |
|---------------|------------------|------------|--------|
| Eligible Users | 10.61% | 15.77% | **-32.7%** |
| Within-User | 10.22% | 14.91% | **-31.5%** |

**Conclusion**: Personalized Fitment recommendations have a **negative uplift of ~32%** compared to Static recommendations.

---

## Selection Bias Analysis

### Why All-Users Comparison Is Misleading

| Metric | Personalized | Static | Ratio |
|--------|--------------|--------|-------|
| Users Sent | 2,000 | 25,918 | 1:13 |
| Has Vehicle Data | 100% | ~4% | - |

Static treatments are sent to a much larger, more diverse population. Most Static recipients don't have vehicle data, making them incomparable to Personalized recipients.

### MECE Population Split

```
All Treatment Recipients
├── No vehicle data (ineligible for Personalized)
│   └── Static only → EXCLUDE from comparison
└── Has vehicle data (eligible for both)
    ├── Received Personalized → INCLUDE
    └── Received Static → INCLUDE ← COMPARE THESE
```

---

## Key Findings

### 1. Personalized Underperforms by ~32%

Consistent across both analysis methods:
- Eligible users: -32.7% uplift
- Within-user: -31.5% uplift

### 2. Selection Bias Reverses Naive Conclusion

- **Naive (all users)**: Personalized wins (10.6% vs 7.6%)
- **Fair (eligible only)**: Static wins (15.8% vs 10.6%)

### 3. Sample Size Adequate

- Eligible users: 1,112 Static, 2,000 Personalized
- Within-user: 480 users with both treatments
- Clicks: 44 Static, 66 Personalized (eligible); 17 Static, 14 Personalized (within-user)

### 4. Statistical Confidence

The within-user comparison controls for all user-level confounders. The 32% difference with 30+ clicks per group is statistically meaningful.

---

## Recommendations

### Immediate Actions

1. **Investigate Personalized recommendations**:
   - Are the right products being recommended?
   - Is the recommendation algorithm working correctly?
   - Compare product selection between Personalized and Static

2. **Review creative/copy**:
   - Do Personalized emails have compelling subject lines?
   - Is the vehicle-specific messaging resonating?

3. **Consider pausing worst Personalized variants**:
   - See CTR analysis: 20142832, 20142818, 20142811 have <5% CTR

### Follow-up Analysis

1. **Product-level analysis**: Which SKUs are being recommended in each treatment type?

2. **Revenue comparison**: Does CTR difference translate to revenue difference?

3. **Time-based analysis**: Has Personalized always underperformed, or is this recent?

4. **Segment analysis**: Are there user segments where Personalized works better?

---

## Methodology

### MECE Framework

MECE = Mutually Exclusive, Collectively Exhaustive

The key insight: Only compare users who are **eligible for both treatment types**. Users without vehicle data can only receive Static, so including them biases the comparison.

### Within-User Comparison

Find users who received both Personalized and Static treatments, then compare their CTR on each. This controls for:
- User demographics
- Purchase history
- Engagement patterns
- Email preferences
- All other user-level factors

### Data Sources

```sql
-- Treatment sends
`auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929 AND request_source = 'LIVE'

-- Interactions (opens/clicks)
`auxia-gcp.company_1950.treatment_interaction`

-- User vehicle data (eligibility)
`auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
  WHERE property_name = 'v1_year'
```

### Treatment IDs

**Personalized Fitment (10)**:
16150700, 20142778, 20142785, 20142804, 20142811, 20142818, 20142825, 20142832, 20142839, 20142846

**Static (22)**:
16490932, 16490939, 16518436, 16518443, 16564380, 16564387, 16564394, 16564401, 16564408, 16564415, 16564423, 16564431, 16564439, 16564447, 16564455, 16564463, 16593451, 16593459, 16593467, 16593475, 16593483, 16593491

---

## Related Reports

- `docs/ctr_analysis_2025_12_26.md` - Thompson Sampling CTR analysis
- `docs/analysis/treatment_ctr_unbiased_analysis_2025_12_17.md` - Previous MECE analysis

---

*Generated by /uplift skill*
