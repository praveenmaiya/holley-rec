# Post-Launch Conversion Analysis

**Date**: 2026-01-02
**Issue**: AUX-11136 - Post launch data analysis
**Period**: Last 60 days
**Author**: Claude Code analysis

---

## Executive Summary

The 20% conversion uplift seen in Metabase is **valid at the aggregate level** but masks important nuances. When properly controlled using the MECE framework:

1. **Abandon Cart Fitment** campaigns are the top performers (5.05% order rate)
2. **Post-Purchase Static** (Apparel) actually outperforms **Post-Purchase Personalized** when comparing eligible users
3. Revenue per send is highest for **Personalized** due to higher-priced items ($81 vs $11)

---

## Key Findings

### 1. Campaign Performance Ranking (by Order Rate)

| Rank | Campaign Type | Sent | Order Rate | Rev/Send |
|------|---------------|------|------------|----------|
| 1 | **Abandon Cart Fitment** | 2,276 | **5.05%** | $171.95 |
| 2 | Abandon Cart Static | 6,369 | 2.78% | $54.15 |
| 3 | Post-Purchase Personalized | 2,268 | 2.56% | $81.19 |
| 4 | Browse Recovery | 15,655 | 2.33% | $64.59 |
| 5 | Other | 61,343 | 1.68% | $40.21 |
| 6 | Post-Purchase Static | 29,217 | 1.36% | $10.88 |

**Finding**: Abandon Cart Fitment campaigns (16593xxx, 18056xxx) drive the highest conversion at 5.05%.

### 2. MECE Analysis: Personalized vs Static (Fair Comparison)

The naive comparison shows Personalized winning, but this is **biased** because Static is sent to users without vehicle data (less engaged).

| Analysis | Treatment | Sent | Order Rate | Rev/Send |
|----------|-----------|------|------------|----------|
| All Users (Biased) | Personalized | 2,268 | 2.56% | $81.19 |
| All Users (Biased) | Static | 29,217 | 1.36% | $10.88 |
| **Eligible Only (MECE)** | Personalized | 2,268 | 2.56% | $81.19 |
| **Eligible Only (MECE)** | Static | 1,344 | **3.79%** | $33.89 |

**Finding**: When comparing eligible users only, **Static outperforms Personalized by 48%** on order rate.

### 3. Within-User Comparison (Gold Standard)

588 users received **both** Personalized and Static treatments:

| Treatment | Users | Order Rate |
|-----------|-------|------------|
| Personalized | 588 | 2.55% |
| **Static** | 588 | **4.59%** |

**Finding**: Same users order 80% more often after receiving Static vs Personalized emails.

### 4. Top Individual Treatments (by Order Rate)

| Treatment ID | Name | Sent | Order Rate | Rev/Send |
|--------------|------|------|------------|----------|
| 16593531 | Abandon Cart Fitment 4 Items | 391 | 5.37% | $126.94 |
| 16593524 | Abandon Cart Fitment 3 Items | 356 | 4.78% | $128.90 |
| 18056699 | Abandon Cart Fitment 1 Item | 1,008 | 4.66% | $65.54 |
| 18056725 | Abandon Cart Fitment 3 Items | 379 | 4.49% | $100.52 |
| 18056732 | Abandon Cart Fitment 4 Items | 403 | 4.47% | $105.98 |

**Finding**: Abandon Cart with Fitment Recommendations consistently top the charts.

### 5. Model Comparison

| Model ID | Name | Sent | Order Rate | Rev/Send |
|----------|------|------|------------|----------|
| 1 | Random Model | 73,273 | 1.88% | $61.58 |
| 195001001 | Bandit Model | 5,196 | 1.48% | $39.20 |

**Finding**: Random Model outperforms Bandit Model by 27% on order rate. Investigate Bandit targeting.

---

## Why Static May Outperform Personalized

1. **Price Point**: Static (Apparel) shows $20-50 items (impulse buy) vs Personalized shows $200-500 parts
2. **Lower Friction**: T-shirt purchase requires less consideration than performance parts
3. **Novelty Effect**: Apparel is unexpected, drives curiosity clicks
4. **Subject Lines**: Personalized uses abstract copy ("Got plans?") vs Static has direct product messaging

---

## Recommendations

### Immediate Actions

1. **Scale Abandon Cart Fitment campaigns** - Currently only 2,276 sends but 5.05% conversion rate
2. **Investigate Personalized underperformance**:
   - Review product selection algorithm
   - Test different price tiers in recommendations
   - A/B test subject lines

3. **Pause lowest Personalized variants**:
   - 20142832 (Detail Oriented): 2.31% order rate
   - 20142818 (Weekend Warrior): 2.31% order rate

### Strategic Considerations

1. **Revenue vs Conversion Trade-off**:
   - Personalized: Lower conversion but higher AOV ($81.19 rev/send)
   - Static: Higher conversion but lower AOV ($10.88 rev/send)
   - Consider hybrid approach

2. **Bandit Model Review**: Currently underperforming Random Model - needs investigation

3. **Test Apparel in Personalized Recs**: If users engage more with apparel, consider adding safety gear/accessories to Personalized recommendations

---

## Data Sources

```sql
-- Treatment sends
`auxia-gcp.company_1950.treatment_history_sent`
  WHERE surface_id = 929 AND request_source = 'LIVE'

-- Interactions
`auxia-gcp.company_1950.treatment_interaction`

-- Orders
`auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Placed Order'

-- User eligibility
`auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
  WHERE property_name = 'v1_year'
```

---

## Related Documents

- `docs/treatment_ctr_unbiased_analysis_2025_12_17.md` - CTR MECE analysis
- `docs/uplift_analysis_2025_12_26.md` - Previous uplift analysis
- `docs/apparel_vs_vehicle_parts_analysis_2025_12_27.md` - Category analysis

---

*Generated by Claude Code for AUX-11136*
